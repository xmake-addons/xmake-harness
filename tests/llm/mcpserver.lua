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
-- @file        mcpserver.lua
--

--
-- a minimal mcp server, it is used by the mcp tests
--
-- it speaks the stdio transport: one json-rpc message per line, and it offers
-- two tools, one which succeeds and one which fails.
--
--   $ xmake l tests/mcpserver.lua
--

-- imports
import("core.base.json")

-- the tools this server offers
function _tools()
    return {
        {
            name = "echo",
            description = "Echo the given text back",
            inputSchema = {type = "object", properties = {text = {type = "string"}}, required = {"text"}}
        },
        {
            name = "fail",
            description = "Always fail, it is used to test the error path",
            inputSchema = {type = "object", properties = {}}
        }
    }
end

-- handle one request
function _handle(request)
    local method = request.method
    if method == "initialize" then
        return {protocolVersion = "2024-11-05", capabilities = {tools = {}},
                serverInfo = {name = "harness-test-server", version = "1.0.0"}}
    elseif method == "tools/list" then
        return {tools = json.mark_as_array(_tools())}
    elseif method == "tools/call" then
        local params = request.params or {}
        if params.name == "echo" then
            return {content = json.mark_as_array({{type = "text",
                text = "echo: " .. tostring((params.arguments or {}).text)}})}
        elseif params.name == "fail" then
            return {content = json.mark_as_array({{type = "text", text = "it failed on purpose"}}), isError = true}
        end
        return nil, {code = -32602, message = "unknown tool: " .. tostring(params.name)}
    end
    return nil, {code = -32601, message = "unknown method: " .. tostring(method)}
end

-- the main entry
function main()
    while true do
        local line = io.read("l")
        if not line then
            break
        end
        line = line:trim()
        if line ~= "" then
            local request = try { function () return json.decode(line) end }
            if type(request) == "table" and request.id ~= nil then
                local result, errors = _handle(request)
                local response = {jsonrpc = "2.0", id = request.id}
                if result then
                    response.result = result
                else
                    response.error = errors
                end
                io.write(json.encode(response) .. "\n")
                io.flush()
            end
        end
    end
end
