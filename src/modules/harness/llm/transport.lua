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
-- `curl` as a subprocess and tail its output file. The process pipe can lose a
-- completed response on macOS, while curl keeps flushing this file because of
-- `--no-buffer`; short process waits still yield to the xmake scheduler.
--

-- imports
import("core.base.pipe")
import("core.base.bytes")
import("core.base.process")
import("lib.detect.find_tool")

-- the status marker appended by curl, so we can get the http status code
-- without polluting the streaming body
local STATUS_MARKER = "\n__XMAKE_HARNESS_STATUS__:"

-- how long one wait on curl lasts
local WAITMS = 50

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
    local outfile = os.tmpfile() .. ".out"
    local errfile = os.tmpfile() .. ".err"
    io.writefile(bodyfile, opt.body or "{}")

    local proc = process.openv(_curl(), _argv(opt, bodyfile), {stdout = outfile, stderr = errfile})

    local state = {status = 0, parts = {}, left = ""}
    local aborted, errors, exitcode = streamfile(outfile, proc, state, handlers)
    if aborted then
        proc:kill()
    end

    -- reap it once, now that the stream is over
    --
    -- once, and not once more: the stream may already have found it finished
    -- while it was working out that the pipe had nothing left to say, and
    -- waiting on a process which has already been reaped answers with an error
    -- rather than with the status it answered the first time
    if exitcode == nil then
        local waitok, waitstatus = proc:wait(aborted and 1000 or 10000)
        if waitok > 0 then
            exitcode = waitstatus
        end
    end
    proc:close()

    local stderrdata = os.isfile(errfile) and io.readfile(errfile) or nil
    os.tryrm(bodyfile)
    os.tryrm(outfile)
    os.tryrm(errfile)
    return response(state, {aborted = aborted, errors = errors, exitcode = exitcode,
        stderr = stderrdata, url = opt.url, body = opt.body})
end

-- read curl's output file until its process ends
--
-- `process.openv` can reliably redirect stdout to a file on every supported
-- platform. Reading the newly appended bytes after each short wait preserves
-- the live response without relying on a pipe's EOF notifications.
--
-- @return  aborted, errors, exitcode
--
function streamfile(outfile, proc, state, handlers)
    local aborted = false
    local errors = nil
    local exitcode = nil
    local offset = 0
    local ticker = _ticker(handlers)

    local function readnew()
        local data = os.isfile(outfile) and io.readfile(outfile) or ""
        if #data > offset then
            _feed(state, data:sub(offset + 1), handlers)
            offset = #data
        end
    end

    try {
        function ()
            while true do
                readnew()
                if not ticker() then
                    aborted = true
                    break
                end
                local ok, status = proc:wait(WAITMS)
                if ok and ok > 0 then
                    exitcode = status
                    readnew()
                    break
                elseif ok and ok < 0 then
                    errors = "curl process could not be waited for"
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
    return aborted, errors, exitcode
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

-- how long after curl has gone we keep reading
--
-- it has exited and the last thing it wrote may still be in flight, so the
-- stream does not end the instant the process does: it ends when the process is
-- gone *and* nothing more has arrived for this long
local GRACEMS = 200

-- how often we are willing to ask whether curl is still there
--
-- the answer only changes once and asking is a system call, so it is asked a
-- few times a second and not on every idle wait
local POLLMS = 250

-- read the stream until it ends
--
-- the pipe is the first source of truth: a readable pipe which yields no data
-- means the writer is gone, and that is how this ends nearly every time.
--
-- it is not the only one, because on some platforms it never says so. a pipe
-- whose writer has exited can read as empty and poll as "nothing yet", every
-- time, for as long as anybody is willing to ask — and then the loop below
-- turns forever and the answer never arrives. so when the pipe has gone quiet
-- we ask the other question: is curl still running. that one always has an
-- answer.
--
-- the exit code comes back with it. whoever establishes that the process is
-- over is the one who reaps it, and reaping it twice answers with an error
-- instead of a status.
--
-- @return  aborted, errors, exitcode
--
function stream(rpipe, proc, state, handlers)
    local aborted = false
    local errors = nil
    local exitcode = nil
    local buff = bytes(16384)
    local ticker = _ticker(handlers)
    local asked = 0
    local deadline = nil

    try {
        function ()
            while true do
                local real, data = rpipe:read(buff)
                if real > 0 then
                    if deadline then
                        -- it is still arriving, so whatever curl wrote last has
                        -- not finished arriving either
                        deadline = os.mclock() + GRACEMS
                    end
                    _feed(state, data:str(), handlers)
                    if not ticker() then
                        aborted = true
                        break
                    end
                elseif real == 0 then
                    local events = rpipe:wait(pipe.EV_READ, WAITMS)
                    if events < 0 then
                        break
                    end
                    if not ticker() then
                        aborted = true
                        break
                    end

                    -- A posix pipe usually says its writer has gone by being
                    -- readable while returning no bytes. On macOS that signal
                    -- can also arrive while curl is still running, though: it
                    -- is not enough evidence to close the process. Poll the
                    -- child in both cases and only end after it has exited.
                    local now = os.mclock()
                    if not deadline and now - asked >= POLLMS then
                        asked = now
                        local ok, status = proc:wait(0)
                        if ok and ok > 0 then
                            exitcode = status
                            deadline = now + GRACEMS
                        end
                    elseif deadline and now >= deadline then
                        break
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
    return aborted, errors, exitcode
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
function response(state, opt)
    local stderrdata = opt.stderr and opt.stderr:trim() or nil
    local errors = opt.errors

    -- curl failed before any response arrived?
    if not errors and state.status == 0 and not opt.aborted
        and type(opt.exitcode) == "number" and opt.exitcode ~= 0 then
        errors = string.format("curl exited with %d (%s)%s", opt.exitcode,
            _curlerror(opt.exitcode),
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

-- what curl means by its exit code
--
-- `curl exited with 23` is a number somebody has to go and look up, and the
-- answer to most of them is a sentence. the ones here are the ones which
-- actually happen between this and a model: the address, the network, the
-- certificate, and — on windows more than anywhere — the write
--
function _curlerror(exitcode)
    local reasons = {
        [2]  = "curl could not start, its command line was refused",
        [3]  = "the url is malformed",
        [5]  = "the proxy could not be resolved",
        [6]  = "the host could not be resolved",
        [7]  = "nothing is listening there",
        [16] = "the http/2 connection failed",
        [23] = "curl could not write out what it received",
        [28] = "it timed out",
        [35] = "the tls handshake failed",
        [52] = "the server answered with nothing at all",
        [56] = "the connection was reset while receiving",
        [60] = "the server certificate could not be verified",
        [77] = "the ca certificates could not be read"
    }
    return reasons[exitcode] or "see `curl --help` for what that code means"
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
