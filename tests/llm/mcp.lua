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

---------------------------------------------------------------------------------
-- the example server, which is there to be tested against
---------------------------------------------------------------------------------

import("harness.mcp.example")
import("harness.cli.mcp", {alias = "climcp"})
import("harness.cli.agent", {alias = "cliagent"})

function test_the_example_introduces_itself()
    local answer = example.handle({jsonrpc = "2.0", id = 1, method = "initialize"})
    assert(answer.id == 1)
    assert(answer.result.protocolVersion == "2024-11-05", answer.result.protocolVersion)
    assert(answer.result.serverInfo.name == "xmake-harness-example")
    assert(answer.result.capabilities.tools)
end

function test_the_example_lists_what_it_has()
    local answer = example.handle({jsonrpc = "2.0", id = 2, method = "tools/list"})
    local names = {}
    for _, tool in ipairs(answer.result.tools) do
        table.insert(names, tool.name)
        assert(tool.inputSchema, tool.name .. " has a schema")

        -- `run` is ours and not the protocol's
        assert(tool.run == nil, tool.name .. " does not send its implementation")
    end
    assert(table.concat(names, ",") == "echo,now,add,fail", table.concat(names, ","))
end

function test_the_example_arguments_arrive()
    local answer = example.handle({jsonrpc = "2.0", id = 3, method = "tools/call",
        params = {name = "echo", arguments = {text = "hello mcp"}}})
    assert(answer.result.content[1].text == "hello mcp", answer.result.content[1].text)
    assert(not answer.result.isError)
end

function test_a_whole_number_comes_back_whole()
    -- json has one number type and lua has two, so `2 + 40` out of a decode is
    -- a float and `tostring` writes it `42.0`: the arithmetic right and the
    -- answer wrong, which is why `add` is one of the tools
    local answer = example.handle({jsonrpc = "2.0", id = 4, method = "tools/call",
        params = {name = "add", arguments = {a = 2, b = 40}}})
    assert(answer.result.content[1].text == "42", answer.result.content[1].text)
end

function test_a_number_which_is_not_whole_is_left_alone()
    local answer = example.handle({jsonrpc = "2.0", id = 5, method = "tools/call",
        params = {name = "add", arguments = {a = 0.5, b = 0.25}}})
    assert(answer.result.content[1].text == "0.75", answer.result.content[1].text)
end

function test_a_number_which_arrived_as_a_string()
    local answer = example.handle({jsonrpc = "2.0", id = 6, method = "tools/call",
        params = {name = "add", arguments = {a = "x", b = 1}}})
    assert(answer.result.isError)
    assert(answer.result.content[1].text:find("must be numbers", 1, true),
           answer.result.content[1].text)
end

function test_a_tool_which_fails_is_a_result_and_not_a_protocol_error()
    -- the model is meant to read it and try something else; a protocol error
    -- would end the call instead
    local answer = example.handle({jsonrpc = "2.0", id = 7, method = "tools/call",
        params = {name = "fail"}})
    assert(answer.result, "it is a result")
    assert(answer.error == nil, "and not an error")
    assert(answer.result.isError)
end

function test_the_example_has_no_such_tool()
    local answer = example.handle({jsonrpc = "2.0", id = 8, method = "tools/call",
        params = {name = "nosuch"}})
    assert(answer.result.isError)
    assert(answer.result.content[1].text:find("nosuch", 1, true))
end

function test_a_notification_wants_no_answer()
    assert(example.handle({jsonrpc = "2.0", method = "notifications/initialized"}) == nil)
end

function test_a_method_it_does_not_know()
    local answer = example.handle({jsonrpc = "2.0", id = 9, method = "nope"})
    assert(answer.error, "it is an error")
    assert(answer.error.code == -32601, tostring(answer.error.code))
end

---------------------------------------------------------------------------------
-- and the words which reach the subcommands
---------------------------------------------------------------------------------

function test_the_verbs_are_the_ones_the_usage_prints()
    for _, verb in ipairs({"list", "tools", "call", "serve"}) do
        assert(climcp.isverb(verb), verb)
    end
    for _, verb in ipairs({"list", "show", "run"}) do
        assert(cliagent.isverb(verb), verb)
    end
end

function test_a_word_which_is_not_a_verb_is_still_a_prompt()
    -- `xmake ai` takes a prompt, so a word is only claimed where it cannot
    -- plausibly be one: "agent, list the files" keeps working
    assert(not cliagent.isverb("please"))
    assert(not cliagent.isverb(","))
    assert(not climcp.isverb("servers"))
    assert(not climcp.isverb(nil))
end

function test_a_noun_without_a_verb_is_not_sent_to_the_model()
    -- `xmake ai agent hello-world` used to go off to the provider as the
    -- question "agent hello-world", which is the least helpful thing which
    -- could happen to somebody who meant `agent run hello-world`
    assert(not cliagent.isverb("hello-world"))
    assert(not climcp.isverb("demo"))

    -- what happens instead is the usage, which both of them can print with the
    -- word which was typed where a verb goes
    assert(cliagent.usage ~= nil)
    assert(climcp.usage ~= nil)
end
