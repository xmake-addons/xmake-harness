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
-- @file        example.lua
--

--
-- an mcp server to test against
--
-- the first thing anybody configuring mcp needs is a server which certainly
-- works. without one, a tool which does not appear could be the config, the
-- command line, the transport, the server, or the harness, and there is no way
-- to tell which — so the first hour goes on deciding whether the problem is
-- even yours.
--
-- this is that server. `xmake ai mcp serve` runs it on stdio, it needs nothing
-- installed, and it is about eighty lines of the same lua as everything else.
-- point the harness at it and the tools appear; if they do not, the problem is
-- not the server.
--
-- it is also the smallest readable answer to "what does an mcp server have to
-- do": read a json-rpc message per line, answer `initialize`, answer
-- `tools/list`, answer `tools/call`, ignore the notifications.
--

-- imports
import("core.base.json")

-- the version of the protocol we speak
local PROTOCOL_VERSION = "2024-11-05"

-- the tools it offers
--
-- one of each kind somebody needs while testing: one which echoes what it was
-- given, so the arguments can be checked; one which needs no arguments at all;
-- and one which fails on purpose, because an error which never happens is an
-- error path nobody has looked at
--
function tools()
    return {
        {
            name = "echo",
            description = "Return the text it was given. It is here to prove the arguments arrive.",
            inputSchema = {
                type = "object",
                properties = {text = {type = "string", description = "Anything at all."}},
                required = {"text"}
            },
            run = function (args)
                return tostring(args.text or "")
            end
        },
        {
            name = "now",
            description = "The time on the machine the server runs on, which is not always this one.",
            inputSchema = {type = "object", properties = {}},
            run = function ()
                return os.date("%Y-%m-%d %H:%M:%S")
            end
        },
        {
            name = "add",
            description = "Add two numbers. It is here because a number which arrived as a string is the commonest mcp surprise.",
            inputSchema = {
                type = "object",
                properties = {a = {type = "number"}, b = {type = "number"}},
                required = {"a", "b"}
            },
            run = function (args)
                local a, b = tonumber(args.a), tonumber(args.b)
                if not a or not b then
                    return nil, string.format("`a` and `b` must be numbers, they arrived as %s and %s",
                                              type(args.a), type(args.b))
                end
                return _number(a + b)
            end
        },
        {
            name = "fail",
            description = "Fail on purpose, so the error path can be seen working.",
            inputSchema = {type = "object", properties = {}},
            run = function ()
                return nil, "this tool fails on purpose, which is what it is for"
            end
        }
    }
end

-- a number, as somebody reading it expects to see it
--
-- json has one number type and lua has two, so `2 + 40` comes back out of a
-- decode as a float and `tostring` writes it `42.0`. that is the arithmetic
-- being right and the answer being wrong, which is the whole reason `add` is
-- one of the tools here
--
function _number(value)
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
        return string.format("%d", value)
    end
    return tostring(value)
end

-- what `tools/list` answers with
--
-- the `run` is ours and not the protocol's, so it does not go out
--
function schemas()
    local listed = {}
    for _, tool in ipairs(tools()) do
        table.insert(listed, {name = tool.name, description = tool.description,
                              inputSchema = tool.inputSchema})
    end
    return listed
end

-- run one of them
--
-- @return  the text, or nil and why not
--
function call(name, args)
    for _, tool in ipairs(tools()) do
        if tool.name == name then
            return tool.run(args or {})
        end
    end
    return nil, string.format("there is no tool called `%s`", tostring(name))
end

-- answer one message
--
-- @return  the response to send, or nil when there is nothing to answer
--
function handle(message)
    local method = message.method
    if method == "initialize" then
        return _result(message.id, {
            protocolVersion = PROTOCOL_VERSION,
            capabilities = {tools = {}},
            serverInfo = {name = "xmake-harness-example", version = "1.0.0"}})
    elseif method == "tools/list" then
        return _result(message.id, {tools = schemas()})
    elseif method == "tools/call" then
        local params = message.params or {}
        local output, errors = call(params.name, params.arguments)
        if output == nil then
            -- a tool which failed is a *result* which says it failed, and not a
            -- protocol error: the model is meant to read it and try something
            -- else, and a protocol error would end the call instead
            return _result(message.id, {
                content = {{type = "text", text = tostring(errors)}}, isError = true})
        end
        return _result(message.id, {content = {{type = "text", text = output}}})
    end

    -- a notification has no id and wants no answer, e.g. notifications/initialized
    if message.id == nil then
        return nil
    end
    return _error(message.id, -32601, string.format("no such method: %s", tostring(method)))
end

-- read messages from the stdin and answer them, until it ends
function serve()
    while true do
        local line = io.read("l")
        if not line then
            break
        end
        local message = _decode(line)
        if message then
            local response = handle(message)
            if response then
                io.write(json.encode(response) .. "\n")
                io.flush()
            end
        end
    end
    return true
end

-- one line, when it is a message at all
function _decode(line)
    line = (line or ""):trim()
    if line == "" or not line:startswith("{") then
        return nil
    end
    local message = try { function () return json.decode(line) end }
    return type(message) == "table" and message or nil
end

-- the two shapes of a response
function _result(id, result)
    return {jsonrpc = "2.0", id = id, result = result}
end

function _error(id, code, message)
    return {jsonrpc = "2.0", id = id, error = {code = code, message = message}}
end
