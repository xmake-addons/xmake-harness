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
-- @file        replay.lua
--

-- imports
import("core.base.json")
import("harness.harness")
import("harness.core.agent")
import("harness.llm.providers.replay")
import("harness.core.session", {alias = "sessions"})
import("harness.tools.registry", {alias = "toolregistry"})

-- write a cassette and return the provider settings which play it
function _cassette(turns)
    local filepath = os.tmpfile() .. ".json"
    json.savefile(filepath, {turns = turns})
    replay.rewind(filepath)
    return filepath
end

-- a harness whose only provider is the recording, and whose only tool records calls
function _harness(filepath, calls)
    local rootdir = os.tmpdir()
    local instance = harness.bootstrap({rootdir = rootdir})
    local config = instance:config()
    config.provider = "replay"
    config.providers = config.providers or {}
    config.providers.replay = {kind = "replay", cassette = filepath, contextsize = 131072,
                               models = {main = "recorded", small = "recorded"}}

    local tools = toolregistry.new()
    tools:add({
        name = "probe",
        permission = "read",
        description = "a tool for the tests",
        parameters = {type = "object", properties = {path = {type = "string"}}},
        run = function (context, args)
            table.insert(calls, args.path or "")
            return {output = "the file says hello"}
        end
    })
    instance:service("tools", tools)
    return instance
end

-- run one turn against the recording
function _run(turns, prompt)
    local calls = {}
    local streamed = {}
    local instance = _harness(_cassette(turns), calls)
    local result = agent.run(instance, {
        session = sessions.new({cwd = os.tmpdir()}),
        prompt = prompt or "do it",
        mode = "bypass",
        signal = {aborted = false},
        ui = {on_text = function (delta) table.insert(streamed, delta) end}
    })
    return result, calls, streamed
end

function test_a_recorded_answer_comes_back()
    local result = _run({{content = "it builds one target."}})
    assert(result.errors == nil, tostring(result.errors))
    assert(result.text == "it builds one target.", result.text)
    assert(result.steps == 1, tostring(result.steps))
end

function test_the_answer_arrives_in_pieces()
    -- a server sends a few tokens at a time, and the incremental renderer is
    -- most of what this adapter exists to exercise
    local long = string.rep("the same words again and again. ", 6)
    local result, _, streamed = _run({{content = long}})
    assert(result.text == long, "the pieces must add up to what was recorded")
    assert(#streamed > 1, string.format("it arrived in %d piece(s), a stream it is not", #streamed))
end

function test_a_recorded_tool_call_really_runs()
    -- this is the whole point: the turn loop, the tool pipeline and the second
    -- round trip, driven end to end with no network
    local result, calls = _run({
        {content = "let me look", toolcalls = {{name = "probe", arguments = '{"path": "xmake.lua"}'}}},
        {content = "it builds one target."}
    })
    assert(result.errors == nil, tostring(result.errors))
    assert(#calls == 1 and calls[1] == "xmake.lua", table.concat(calls, ","))
    assert(result.steps == 2, tostring(result.steps))
    assert(result.text == "it builds one target.", result.text)
end

function test_several_rounds_of_tools()
    local result, calls = _run({
        {toolcalls = {{name = "probe", arguments = '{"path": "a"}'}}},
        {toolcalls = {{name = "probe", arguments = '{"path": "b"}'}}},
        {content = "both read."}
    })
    assert(#calls == 2 and calls[1] == "a" and calls[2] == "b", table.concat(calls, ","))
    assert(result.steps == 3, tostring(result.steps))
end

function test_two_tool_calls_in_one_step()
    local result, calls = _run({
        {toolcalls = {{name = "probe", arguments = '{"path": "a"}'},
                      {name = "probe", arguments = '{"path": "b"}'}}},
        {content = "done"}
    })
    assert(#calls == 2, table.concat(calls, ","))
    assert(result.steps == 2, tostring(result.steps))
end

function test_the_usage_is_accounted()
    local result = _run({{content = "hello", usage = {input = 1234, output = 7,
                                                     cachehit = 1000, cachemiss = 234}}})
    assert(result.usage.input == 1234, tostring(result.usage.input))
    assert(result.usage.output == 7, tostring(result.usage.output))
end

function test_a_recorded_error_is_an_error()
    local result = _run({{errors = "the model is on fire"}})
    assert(result.errors ~= nil and result.errors:find("on fire", 1, true), tostring(result.errors))
end

function test_running_past_the_end_of_the_cassette_says_so()
    -- the recording ends but the loop wants another turn: that is a test which
    -- needs more recording, and the message has to say that plainly
    local result = _run({{toolcalls = {{name = "probe", arguments = "{}"}}}})
    assert(result.errors ~= nil, "it must not answer out of thin air")
    assert(result.errors:find("no turn left", 1, true), result.errors)
end

function test_the_cassette_is_played_from_the_start()
    -- two runs of the same recording must behave identically, or no test built
    -- on one of them is worth anything
    local turns = {{content = "first"}}
    local one = _run(turns)
    local two = _run(turns)
    assert(one.text == two.text and one.text == "first", one.text .. " vs " .. two.text)
end

function test_the_session_records_what_happened()
    local result = _run({
        {content = "looking", toolcalls = {{name = "probe", arguments = '{"path": "x"}'}}},
        {content = "found it"}
    })
    local kinds = {}
    for _, event in ipairs(result.session:events()) do
        table.insert(kinds, event.kind)
    end
    assert(table.concat(kinds, ",") == "user,assistant,tool,assistant", table.concat(kinds, ","))
end

---------------------------------------------------------------------------------
-- what the guards do to a real turn
---------------------------------------------------------------------------------

-- the same tool call, recorded n times over
function _repeat(turn, count)
    local turns = {}
    for _ = 1, count do
        table.insert(turns, turn)
    end
    return turns
end

function test_the_repeat_guard_stops_a_real_turn()
    -- a model which asks for the very same thing over and over is stuck, and
    -- until now there was no way to make one do that on purpose
    local result, calls = _run(_repeat({toolcalls = {{name = "probe", arguments = '{"path": "same"}'}}}, 12))
    assert(result.steps < 12, string.format("it ran %d steps, the guard never fired", result.steps))
    assert(#calls < 12, string.format("%d calls", #calls))
    local text = table.concat({result.text or "", _lasttext(result.session)}, " ")
    assert(text:find("repeated", 1, true), "the turn must say why it stopped: " .. text)
end

function test_a_changing_tool_call_is_not_stopped()
    -- edit, build, edit, build is progress, not a loop
    local turns = {}
    for idx = 1, 6 do
        table.insert(turns, {toolcalls = {{name = "probe", arguments = string.format('{"path": "f%d"}', idx)}}})
    end
    table.insert(turns, {content = "all read"})
    local result, calls = _run(turns)
    assert(#calls == 6, string.format("%d calls, an iterative fix was cut short", #calls))
    assert(result.text == "all read", tostring(result.text))
end

function test_the_step_budget_is_honoured()
    local turns = {}
    for idx = 1, 40 do
        table.insert(turns, {toolcalls = {{name = "probe", arguments = string.format('{"path": "f%d"}', idx)}}})
    end
    local calls = {}
    local instance = _harness(_cassette(turns), calls)
    local result = agent.run(instance, {
        session = sessions.new({cwd = os.tmpdir()}),
        prompt = "keep going",
        mode = "bypass",
        signal = {aborted = false},
        maxsteps = 5,
        ui = {}
    })
    assert(result.steps == 5, string.format("%d steps against a budget of 5", result.steps))
end

-- the last thing said in the session, whoever said it
function _lasttext(session)
    local last = ""
    for _, event in ipairs(session:events()) do
        if event.text and event.text ~= "" then
            last = event.text
        end
    end
    return last
end

---------------------------------------------------------------------------------
-- why the turn ended
---------------------------------------------------------------------------------

function test_the_ordinary_ending_is_done()
    local result = _run({{content = "there, finished."}})
    assert(result.stop ~= nil, "every ending must say which one it was")
    assert(result.stop.code == "done", tostring(result.stop.code))
end

function test_the_repeat_guard_names_itself()
    local result = _run(_repeat({toolcalls = {{name = "probe", arguments = '{"path": "same"}'}}}, 12))
    assert(result.stop.code == "repeated-tool-calls", tostring(result.stop.code))
    assert(result.stop.text:find("repeated", 1, true), result.stop.text)
end

function test_the_failure_streak_names_itself()
    -- a tool which always raises, three rounds of it — and the arguments have to
    -- differ, or the repeat guard gets there first and this tests that instead
    local turns = {}
    for idx = 1, 8 do
        table.insert(turns, {toolcalls = {{name = "explode",
            arguments = string.format('{"try": %d}', idx)}}})
    end
    local filepath = _cassette(turns)
    local instance = _harness(filepath, {})
    instance:service("tools"):add({
        name = "explode",
        permission = "read",
        description = "it always fails",
        parameters = {type = "object", properties = {}},
        run = function () raise("nothing works today") end
    })
    local result = agent.run(instance, {
        session = sessions.new({cwd = os.tmpdir()}),
        prompt = "try it", mode = "bypass", signal = {aborted = false}, ui = {}})
    assert(result.stop.code == "all-tools-failed", tostring(result.stop.code))
end

function test_the_step_budget_names_itself()
    local turns = {}
    for idx = 1, 40 do
        table.insert(turns, {toolcalls = {{name = "probe", arguments = string.format('{"path": "f%d"}', idx)}}})
    end
    local instance = _harness(_cassette(turns), {})
    local result = agent.run(instance, {
        session = sessions.new({cwd = os.tmpdir()}),
        prompt = "keep going", mode = "bypass", signal = {aborted = false}, maxsteps = 4, ui = {}})
    assert(result.stop.code == "step-budget", tostring(result.stop.code))
    assert(result.steps == 4, tostring(result.steps))
end

function test_a_failed_request_names_itself()
    local result = _run({{errors = "the gateway is on fire"}})
    assert(result.stop.code == "error", tostring(result.stop.code))
    assert(result.stop.text:find("on fire", 1, true), result.stop.text)
end

function test_an_interruption_names_itself()
    -- the user hits esc while the answer streams
    local instance = _harness(_cassette({{content = string.rep("a long answer. ", 20)}}), {})
    local signal = {aborted = false}
    local result = agent.run(instance, {
        session = sessions.new({cwd = os.tmpdir()}),
        prompt = "go", mode = "bypass", signal = signal,
        ui = {ontick = function () signal.aborted = true return false end}})
    assert(result.aborted, "the abort did not take")
    assert(result.stop.code == "aborted", tostring(result.stop.code))
end

function test_the_code_is_in_the_session_too()
    -- whatever reads the log later can route on it without parsing prose
    local result = _run(_repeat({toolcalls = {{name = "probe", arguments = '{"path": "same"}'}}}, 12))
    local found = nil
    for _, event in ipairs(result.session:events()) do
        if event.code then
            found = event.code
        end
    end
    assert(found == "repeated-tool-calls", tostring(found))
end

---------------------------------------------------------------------------------
-- when one provider cannot answer
---------------------------------------------------------------------------------

-- a harness whose main provider plays `primary` and whose fallback plays `backup`
function _twoproviders(primary, backup, fallback)
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local config = instance:config()
    config.provider = "first"
    config.providers = config.providers or {}
    config.providers.first = {kind = "replay", cassette = _cassette(primary), contextsize = 131072,
                              models = {main = "recorded-a", small = "recorded-a"},
                              fallback = fallback or {"second"}}
    config.providers.second = {kind = "replay", cassette = _cassette(backup), contextsize = 131072,
                               models = {main = "recorded-b", small = "recorded-b"}}
    local tools = toolregistry.new()
    instance:service("tools", tools)
    return instance
end

-- run one turn against that pair
function _runpair(primary, backup, fallback)
    local notices = {}
    local instance = _twoproviders(primary, backup, fallback)
    local result = agent.run(instance, {
        session = sessions.new({cwd = os.tmpdir()}),
        prompt = "do it", mode = "bypass", signal = {aborted = false},
        ui = {on_notice = function (text) table.insert(notices, text) end}})
    return result, notices
end

function test_a_dead_provider_is_handed_over()
    -- the service is unreachable, somebody else may well answer
    local result, notices = _runpair(
        {{errors = "connection refused", errorcode = "unreachable"}},
        {{content = "the second one answered."}})
    assert(result.errors == nil, tostring(result.errors))
    assert(result.text == "the second one answered.", tostring(result.text))
    assert(#notices > 0 and notices[1]:find("trying second", 1, true), table.concat(notices, " | "))
end

function test_being_throttled_is_handed_over()
    local result = _runpair(
        {{errors = "too many requests", errorcode = "throttled"}},
        {{content = "answered elsewhere"}})
    assert(result.text == "answered elsewhere", tostring(result.text))
end

function test_a_bad_request_is_not_handed_over()
    -- we built it wrongly, and the next service will reject it identically:
    -- failing over would only spend a second key on the same mistake
    local result, notices = _runpair(
        {{errors = "the tool schema is invalid", errorcode = "bad-request"}},
        {{content = "this must never be reached"}})
    assert(result.errors ~= nil, "it must not paper over our own mistake")
    assert(result.errors:find("tool schema", 1, true), result.errors)
    assert(#notices == 0, table.concat(notices, " | "))
end

function test_the_turn_continues_on_the_new_provider()
    -- the handover happens mid-turn, and the rest of the turn belongs to
    -- whoever answered
    local result = _runpair(
        {{errors = "gateway timeout", errorcode = "server-error"}},
        {{content = "reading", toolcalls = {{name = "probe", arguments = '{"path": "x"}'}}},
         {content = "done on the second"}})
    assert(result.errors == nil, tostring(result.errors))
    assert(result.text == "done on the second", tostring(result.text))
    assert(result.steps == 2, tostring(result.steps))
end

function test_without_a_fallback_it_just_fails()
    local result, notices = _runpair(
        {{errors = "connection refused", errorcode = "unreachable"}},
        {{content = "never reached"}}, {})
    assert(result.errors ~= nil and result.errors:find("connection refused", 1, true), tostring(result.errors))
    assert(#notices == 0)
end

function test_a_provider_is_only_tried_once()
    -- two steps, both failing over: the second step must not announce the same
    -- provider all over again
    local result = _runpair(
        {{errors = "down", errorcode = "unreachable"}},
        {{content = "ok"}}, {"second", "second"})
    assert(result.text == "ok", tostring(result.text))
end
