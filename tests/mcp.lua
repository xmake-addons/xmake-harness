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
-- @file        mcp.lua
--

-- imports
import("harness.mcp.mcp")
import("harness.mcp.client")
import("harness.mcp.jsonrpc")
import("harness.core.context")
import("harness.tools.registry", {alias = "toolregistry"})

-- the configuration of the test server
function _config()
    local exec = import("harness.shell.exec", {anonymous = true})
    return {
        command = exec.xmakeprogram(),
        args = {"lua", path.join(os.scriptdir(), "mcpserver.lua")},
        timeout = 15000
    }
end

function test_jsonrpc_encode()
    local data = jsonrpc.encode(1, "tools/list", {a = 1})
    assert(data:endswith("\n"))
    local message = jsonrpc.decode(data)
    assert(message.jsonrpc == "2.0" and message.id == 1 and message.method == "tools/list")
end

function test_jsonrpc_decode_garbage()
    assert(jsonrpc.decode("") == nil)
    assert(jsonrpc.decode("not json") == nil)
end

function test_jsonrpc_errors()
    assert(jsonrpc.errors({error = {code = -32601, message = "nope"}}):find("nope", 1, true))
    assert(jsonrpc.errors({result = {}}) == nil)
end

function test_client_tools()
    local instance = client.new("test", _config())
    local tools, errors = instance:tools()
    assert(tools, tostring(errors))
    assert(#tools == 2, "tools: " .. #tools)
    assert(instance:serverinfo().name == "harness-test-server")
    instance:stop()
end

function test_client_call()
    local instance = client.new("test", _config())
    local output, iserror = instance:calltool("echo", {text = "hello"})
    assert(output == "echo: hello", tostring(output))
    assert(not iserror)
    instance:stop()
end

function test_client_call_error()
    local instance = client.new("test", _config())
    local output, iserror = instance:calltool("fail", {})
    assert(output == "it failed on purpose", tostring(output))
    assert(iserror)
    instance:stop()
end

function test_client_unknown_tool()
    local instance = client.new("test", _config())
    local output, errors = instance:calltool("nosuchtool", {})
    assert(output == nil)
    assert(errors:find("unknown tool", 1, true), tostring(errors))
    instance:stop()
end

function test_client_missing_command()
    local instance = client.new("broken", {command = "no-such-program-here"})
    local tools, errors = instance:tools()
    assert(tools == nil and errors ~= nil)
end

function test_registered_as_tools()
    local instance = context.new({mcp = {servers = {test = _config()}}})
    local tools = toolregistry.new()
    instance:service("tools", tools)
    local count = mcp.load(instance)
    assert(count == 2, "count: " .. tostring(count))

    local tool = tools:get("test__echo")
    assert(tool ~= nil, table.concat(tools:names(), ", "))
    assert(tool.group == "mcp:test")
    assert(tool.permission == "exec")
    assert(tool.description:find("mcp server", 1, true))
    assert(tool.parameters.properties.text ~= nil)
    mcp.stop(instance)
end

function test_tool_call_result()
    local instance = context.new({mcp = {servers = {test = _config()}}})
    local tools = toolregistry.new()
    instance:service("tools", tools)
    mcp.load(instance)

    local result = tools:get("test__echo").run({harness = instance}, {text = "from the tool"})
    assert(result.output == "echo: from the tool", result.output)
    assert(not result.iserror)
    assert(result.display.title == "test__echo")

    local failed = tools:get("test__fail").run({harness = instance}, {})
    assert(failed.iserror)
    mcp.stop(instance)
end

function test_disabled_server()
    local instance = context.new({mcp = {servers = {test = table.join(_config(), {enabled = false})}}})
    instance:service("tools", toolregistry.new())
    assert(mcp.load(instance) == 0)
end

function test_no_servers()
    local instance = context.new({})
    instance:service("tools", toolregistry.new())
    assert(mcp.load(instance) == 0)
end
