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
-- the xmake runtime does not provide a tls socket, so we drive the system `curl`
-- as a subprocess and read its stdout incrementally through a pipe, this keeps
-- the streaming latency low and works on windows/macos/linux without any
-- third-party dependency.
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
--                  - url           the request url
--                  - headers       the request headers, e.g. {["Content-Type"] = "application/json"}
--                  - body          the request body string
--                  - timeout       the connection timeout in seconds
--                  - proxy         the proxy url
--                  - insecure      disable the certificate verification
-- @param handlers  the handlers
--                  - online(line)  called for every received line
--                  - ontick()      called about every 50ms, return false to abort
--
-- @return          {status = 200, body = "..."}, it raises on the transport errors
--
function post(opt, handlers)
    opt = opt or {}
    handlers = handlers or {}

    -- write the body to a temporary file
    --
    -- the request body may be very large (the whole conversation),
    -- so we never pass it through the command line arguments
    --
    local bodyfile = os.tmpfile() .. ".json"
    local errfile = os.tmpfile() .. ".err"
    io.writefile(bodyfile, opt.body or "{}")

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
    table.insert(argv, "-w")
    table.insert(argv, STATUS_MARKER .. "%{http_code}")
    table.insert(argv, "--data-binary")
    table.insert(argv, "@" .. bodyfile)
    table.insert(argv, opt.url)

    -- run curl and read its stdout through the pipe
    local state = {status = 0}
    local bodyparts = {}
    local rpipe, wpipe = pipe.openpair()
    local proc = process.openv(_curl(), argv, {stdout = wpipe, stderr = errfile})
    wpipe:close()

    local aborted = false
    local errormsg = nil
    local exitcode = nil
    local leftstr = ""
    local buff = bytes(16384)
    local function _feed(chunk, isend)
        leftstr = leftstr .. chunk
        while true do
            local pos = leftstr:find("\n", 1, true)
            if not pos then
                break
            end
            local line = leftstr:sub(1, pos - 1)
            leftstr = leftstr:sub(pos + 1)
            _handleline(line, state, bodyparts, handlers)
        end
        if isend and #leftstr > 0 then
            _handleline(leftstr, state, bodyparts, handlers)
            leftstr = ""
        end
    end

    try {
        function ()
            while true do
                local real, data = rpipe:read(buff)
                if real > 0 then
                    _feed(data:str())
                elseif real == 0 then
                    local events = rpipe:wait(pipe.EV_READ, 50)
                    if events < 0 then
                        break
                    end
                    if handlers.ontick and handlers.ontick() == false then
                        aborted = true
                        break
                    end
                    -- the process is polled with a small timeout, `wait(0)` is not reliable,
                    -- and the exit status is only reported once, so we keep it here
                    local waitok, waitstatus = proc:wait(1)
                    if waitok > 0 then
                        exitcode = waitstatus
                        _drain(rpipe, buff, _feed)
                        break
                    elseif events > 0 then
                        -- avoid the busy loop when it is readable but empty
                        os.sleep(5)
                    end
                else
                    break
                end
            end
            _feed("", true)
        end,
        catch {
            function (errors)
                aborted = true
                errormsg = tostring(errors)
            end
        }
    }

    if aborted then
        proc:kill()
    end
    if exitcode == nil then
        local waitok, waitstatus = proc:wait(aborted and 1000 or 5000)
        if waitok > 0 then
            exitcode = waitstatus
        end
    end
    proc:close()
    rpipe:close()

    local stderrdata = os.isfile(errfile) and io.readfile(errfile) or nil
    os.tryrm(bodyfile)
    os.tryrm(errfile)

    -- curl failed before any response arrived?
    if not errormsg and state.status == 0 and not aborted and type(exitcode) == "number" and exitcode ~= 0 then
        errormsg = string.format("curl exited with %d%s", exitcode,
            (stderrdata and stderrdata:trim() ~= "") and (": " .. stderrdata:trim()) or "")
    end

    local response = {
        status = state.status,
        exitcode = exitcode,
        aborted = aborted,
        body = table.concat(bodyparts),
        errors = errormsg,
        stderr = stderrdata and stderrdata:trim() or nil
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

-- drain the rest data of the pipe after the process exited
function _drain(rpipe, buff, feed)
    local idle = 0
    while idle < 3 do
        local real, data = rpipe:read(buff)
        if real > 0 then
            feed(data:str())
            idle = 0
        elseif real == 0 then
            rpipe:wait(pipe.EV_READ, 20)
            idle = idle + 1
        else
            break
        end
    end
end

-- handle one received line
function _handleline(line, state, bodyparts, handlers)

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

    table.insert(bodyparts, line)
    table.insert(bodyparts, "\n")
    if handlers.online then
        handlers.online(line)
    end
end
