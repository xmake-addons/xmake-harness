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
-- @file        jsonrpc.lua
--

--
-- the json-rpc 2.0 framing of the mcp protocol
--
-- the messages are newline delimited json objects over the stdio of the server
-- process, which is what the mcp stdio transport specifies.
--

-- imports
import("core.base.json")

-- encode one request
--
-- @param id        the request id, nil for a notification
-- @param method    the method name, e.g. "tools/list"
-- @param params    the parameters
--
function encode(id, method, params)
    local message = {jsonrpc = "2.0", method = method}
    if id ~= nil then
        message.id = id
    end
    if params ~= nil then
        message.params = params
    end
    return json.encode(message) .. "\n"
end

-- decode one message
--
-- @return  the message, or nil when the line is not a json object
--
function decode(line)
    line = (line or ""):trim()
    if line == "" or not line:startswith("{") then
        return nil
    end
    local message = try { function () return json.decode(line) end }
    if type(message) ~= "table" then
        return nil
    end
    return message
end

-- get the error message of a response
function errors(message)
    local err = message and message.error
    if type(err) ~= "table" then
        return nil
    end
    return string.format("%s%s", err.message or "unknown error",
        err.code and string.format(" (%s)", tostring(err.code)) or "")
end
