--!A generic AI agent harness framework based on xmake lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki
-- @file        transport.lua
--

--
-- the http transport of the llm requests
--
-- the xmake runtime does not provide a tls socket, so we drive the system
-- `curl` as a subprocess and read its stdout through a pipe. the pipe waits
-- yield to the xmake scheduler, so the ui and the other coroutines of this
-- session keep running while the model streams.
--

-- imports
import("core.base.pipe")
import("core.base.bytes")
import("core.base.process")
import("lib.detect.find_tool")

-- the status marker appended by curl, so we can get the http status code
-- without polluting the streaming body
local STATUS_MARKER = "\n__XMAKE_HARNESS_STATUS__:"

-- find the curl program
function _curl()
    local tool = find_tool("curl")
    if not tool then
        raise("harness: curl not found! it is required to access the llm api.")
    end
    return tool.program
end

-- post the request and read the response incrementally
--
-- @param opt       the request options
--                  - url, headers, body, timeout, proxy, insecure
-- @param handlers  the handlers
--                  - online(line)  called for every received line
--                  - ontick()      called while we wait, return false to abort
--
-- @return          {status = 200, body = "..", exitcode = 0, aborted = false}
--
function post(opt, handlers)
    opt = opt or {}
    handlers = handlers or {}

    -- the request body may be the whole conversation, it never goes through the
    -- command line arguments
    local bodyfile = os.tmpfile() .. ".json"
    local errfile = os.tmpfile() .. ".err"
    io.writefile(bodyfile, opt.body or "{}")

    local rpipe, wpipe = pipe.openpair()
    local proc = process.openv(_curl(), _argv(opt, bodyfile), {stdout = wpipe, stderr = errfile})
    wpipe:close()

    local state = {status = 0, parts = {}, left = ""}
    local aborted, errors = _stream(rpipe, state, handlers)
    if aborted then
        proc:kill()
    end

    -- reap it once, now that the stream is over
    local exitcode = nil
    local waitok, waitstatus = proc:wait(aborted and 1000 or 10000)
    if waitok > 0 then
        exitcode = waitstatus
    end
    proc:close()
    rpipe:close()

    local stderrdata = os.isfile(errfile) and io.readfile(errfile) or nil
    os.tryrm(bodyfile)
    os.tryrm(errfile)
    return _response(state, {aborted = aborted, errors = errors, exitcode = exitcode,
        stderr = stderrdata, url = opt.url, body = opt.body})
end

-- build the curl arguments
function _argv(opt, bodyfile)
    local argv = {"-sS", "-N", "--no-buffer", "-X", "POST"}
    for name, value in pairs(opt.headers or {}) do
        table.insert(argv, "-H")
        table.insert(argv, name .. ": " .. value)
    end
    table.insert(argv, "--connect-timeout")
    table.insert(argv, tostring(opt.timeout or 30))
    if opt.proxy then
        table.insert(argv, "-x")
        table.insert(argv, opt.proxy)
    end
    if opt.insecure then
        table.insert(argv, "-k")
    end
    return table.join(argv, {"-w", STATUS_MARKER .. "%{http_code}",
                             "--data-binary", "@" .. bodyfile, opt.url})
end

-- read the stream until it ends
--
-- the pipe is the source of truth: a readable pipe which yields no data means
-- the writer is gone. we never poll the process itself, a stale exit event
-- could then arrive after we closed it.
--
-- @return  aborted, errors
--
function _stream(rpipe, state, handlers)
    local aborted = false
    local errors = nil
    local buff = bytes(16384)
    local empty = 0
    local ticker = _ticker(handlers)

    try {
        function ()
            while true do
                local real, data = rpipe:read(buff)
                if real > 0 then
                    empty = 0
                    _feed(state, data:str(), handlers)
                    if not ticker() then
                        aborted = true
                        break
                    end
                elseif real == 0 then
                    local events = rpipe:wait(pipe.EV_READ, 50)
                    if events < 0 then
                        break
                    elseif events > 0 then
                        -- readable but nothing to read: the writer is gone
                        empty = empty + 1
                        if empty >= 2 then
                            break
                        end
                    else
                        empty = 0
                        if not ticker() then
                            aborted = true
                            break
                        end
                    end
                else
                    break
                end
            end
            _feed(state, "", handlers, true)
        end,
        catch {
            function (errs)
                aborted = true
                errors = tostring(errs)
            end
        }
    }
    return aborted, errors
end

-- make the throttled tick
--
-- the user must be able to interrupt a long answer too, so we check while the
-- data flows, not only when the stream idles
--
function _ticker(handlers)
    local last = 0
    return function ()
        local now = os.mclock()
        if now - last < 50 then
            return true
        end
        last = now
        if handlers.ontick and handlers.ontick() == false then
            return false
        end
        return true
    end
end

-- feed the received data, one line at a time
function _feed(state, chunk, handlers, isend)
    state.left = state.left .. chunk
    while true do
        local pos = state.left:find("\n", 1, true)
        if not pos then
            break
        end
        _handleline(state, state.left:sub(1, pos - 1), handlers)
        state.left = state.left:sub(pos + 1)
    end
    if isend and #state.left > 0 then
        _handleline(state, state.left, handlers)
        state.left = ""
    end
end

-- handle one received line
function _handleline(state, line, handlers)

    -- strip the trailing carriage return of the http streams
    line = line:gsub("\r$", "")

    -- the status marker is always written at the very end by `curl -w`
    local marker = STATUS_MARKER:sub(2)
    local pos = line:find(marker, 1, true)
    if pos then
        state.status = tonumber(line:sub(pos + #marker):trim()) or 0
        line = line:sub(1, pos - 1)
        if line == "" then
            return
        end
    end

    table.insert(state.parts, line)
    table.insert(state.parts, "\n")
    if handlers.online then
        handlers.online(line)
    end
end

-- make the response
function _response(state, opt)
    local stderrdata = opt.stderr and opt.stderr:trim() or nil
    local errors = opt.errors

    -- curl failed before any response arrived?
    if not errors and state.status == 0 and not opt.aborted
        and type(opt.exitcode) == "number" and opt.exitcode ~= 0 then
        errors = string.format("curl exited with %d%s", opt.exitcode,
            (stderrdata and stderrdata ~= "") and (": " .. stderrdata) or "")
    end

    local response = {
        status = state.status,
        exitcode = opt.exitcode,
        aborted = opt.aborted,
        body = table.concat(state.parts),
        errors = errors,
        stderr = stderrdata
    }
    _debuglog(opt, response)
    return response
end

-- log the request and the response when XMAKE_HARNESS_DEBUG is set
function _debuglog(opt, response)
    local logfile = os.getenv("XMAKE_HARNESS_DEBUG")
    if not logfile then
        return
    end
    if logfile == "1" or logfile == "true" then
        logfile = path.join(os.getenv("HOME") or os.tmpdir(), ".xmake", "harness", "debug.log")
    end
    os.mkdir(path.directory(logfile))
    local file = io.open(logfile, "a")
    if not file then
        return
    end
    file:print("==== %s %s ====", os.date("%Y-%m-%d %H:%M:%S"), opt.url or "")
    file:print("--- request ---\n%s", opt.body or "")
    file:print("--- response (status %d, exitcode %s%s) ---\n%s", response.status, tostring(response.exitcode),
        response.errors and (", errors: " .. response.errors) or "", response.body or "")
    file:close()
end
