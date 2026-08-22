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
-- @file        client.lua
--

--
-- the mcp client
--
-- one client talks to one mcp server over its stdio: we spawn the server,
-- exchange the json-rpc messages through a pair of pipes, and expose its tools
-- to the harness.
--
-- the pipe waits yield to the xmake scheduler, so a slow server never blocks
-- the ui or the other tools.
--

-- imports
import("core.base.pipe")
import("core.base.bytes")
import("core.base.object")
import("core.base.process")
import("harness.mcp.jsonrpc")

-- the protocol version we speak
local PROTOCOL_VERSION = "2024-11-05"

-- define the client class
local client = client or object {_init = {"_name", "_config"}}

-- create a client for the given server configuration
--
-- @param name      the server name, e.g. "github"
-- @param config    {command = "npx", args = {..}, envs = {..}, timeout = 30000}
--
function new(name, config)
    local instance = client {name, config or {}}
    instance._nextid = 0
    return instance
end

-- get the server name
function client:name()
    return self._name
end

-- is the server running?
function client:isrunning()
    return self._proc ~= nil
end

-- start the server process
function client:start()
    if self._proc then
        return true
    end
    local errors = nil
    local command = self._config.command
    if not command then
        return false, string.format("mcp(%s): no command is configured!", self._name)
    end

    local inrpipe, inwpipe = pipe.openpair("BA")
    local outrpipe, outwpipe = pipe.openpair()
    local proc = try {
        function ()
            return process.openv(command, self._config.args or {}, {
                stdin = inrpipe, stdout = outwpipe, stderr = self._config.stderr or os.nuldev(),
                curdir = self._config.cwd, envs = _envs(self._config.envs)})
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    inrpipe:close()
    outwpipe:close()
    if not proc then
        inwpipe:close()
        outrpipe:close()
        return false, string.format("mcp(%s): cannot start `%s`: %s", self._name, command, errors or "unknown")
    end

    self._proc = proc
    self._stdin = inwpipe
    self._stdout = outrpipe
    self._buffer = ""
    return self:_handshake()
end

-- stop the server process
function client:stop()
    if not self._proc then
        return
    end
    try {
        function ()
            self._stdin:close()
            self._proc:kill()
            self._proc:wait(1000)
            self._proc:close()
            self._stdout:close()
        end
    }
    self._proc = nil
    self._stdin = nil
    self._stdout = nil
end

-- tell the server who we are and what we support
function client:_handshake()
    local result, errors = self:request("initialize", {
        protocolVersion = PROTOCOL_VERSION,
        capabilities = {tools = {}},
        clientInfo = {name = "xmake-harness", version = "1.0.0"}})
    if not result then
        self:stop()
        return false, string.format("mcp(%s): %s", self._name, errors or "the handshake failed")
    end
    self:notify("notifications/initialized")
    self._serverinfo = result.serverInfo
    return true
end

-- get the server information, e.g. {name = "..", version = ".."}
function client:serverinfo()
    return self._serverinfo
end

-- list the tools of the server
--
-- @return  {{name = "..", description = "..", inputSchema = {..}}}
--
function client:tools()
    local result, errors = self:request("tools/list")
    if not result then
        return nil, errors
    end
    return result.tools or {}
end

-- call one tool of the server
--
-- @return  the text content of the result, and whether it is an error
--
function client:calltool(name, args)
    local result, errors = self:request("tools/call", {name = name, arguments = args or {}})
    if not result then
        return nil, errors
    end
    return _content(result), result.isError
end

-- send a request and wait for its response
--
-- @return  the result, or nil and the errors
--
function client:request(method, params)
    if not self._proc then
        local ok, errors = self:start()
        if not ok then
            return nil, errors
        end
    end

    self._nextid = self._nextid + 1
    local id = self._nextid
    local ok, errors = self:_write(jsonrpc.encode(id, method, params))
    if not ok then
        return nil, errors
    end
    return self:_response(id)
end

-- send a notification, it has no response
function client:notify(method, params)
    if not self._proc then
        return false
    end
    return self:_write(jsonrpc.encode(nil, method, params))
end

-- write one message to the server
function client:_write(data)
    local errors
    local ok = try {
        function ()
            self._stdin:write(data, {block = true})
            return true
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if not ok then
        return false, string.format("mcp(%s): cannot write: %s", self._name, tostring(errors))
    end
    return true
end

-- wait for the response of the given request
function client:_response(id)
    local timeout = self._config.timeout or 30000
    local starttime = os.mclock()
    while true do
        local line = self:_readline(timeout - (os.mclock() - starttime))
        if not line then
            return nil, string.format("mcp(%s): the server did not answer in time", self._name)
        end
        local message = jsonrpc.decode(line)

        -- the server may send its notifications in between, we skip them
        if message and message.id == id then
            local errors = jsonrpc.errors(message)
            if errors then
                return nil, string.format("mcp(%s): %s", self._name, errors)
            end
            return message.result or {}
        end
    end
end

-- read one line from the server
function client:_readline(timeout)
    local buff = bytes(8192)
    while true do
        local pos = self._buffer:find("\n", 1, true)
        if pos then
            local line = self._buffer:sub(1, pos - 1)
            self._buffer = self._buffer:sub(pos + 1)
            return line
        end
        if timeout <= 0 then
            return nil
        end

        local real, data = self._stdout:read(buff)
        if real > 0 then
            self._buffer = self._buffer .. data:str()
        elseif real < 0 then
            return nil
        else
            local waited = os.mclock()
            local events = self._stdout:wait(pipe.EV_READ, math.min(200, timeout))
            timeout = timeout - (os.mclock() - waited)
            if events < 0 then
                return nil
            end
        end
    end
end

-- get the text of a tool result
function _content(result)
    local parts = {}
    for _, item in ipairs(result.content or {}) do
        if item.type == "text" and item.text then
            table.insert(parts, item.text)
        elseif item.type == "resource" and item.resource then
            table.insert(parts, item.resource.text or item.resource.uri or "")
        elseif item.type then
            table.insert(parts, string.format("[%s content]", item.type))
        end
    end
    return table.concat(parts, "\n")
end

-- convert the environment map to the list which process.openv expects
function _envs(envs)
    if not envs then
        return nil
    end
    local envars = os.getenvs()
    for name, value in pairs(envs) do
        envars[name] = value
    end
    local results = {}
    for name, value in pairs(envars) do
        table.insert(results, name .. "=" .. value)
    end
    return results
end
