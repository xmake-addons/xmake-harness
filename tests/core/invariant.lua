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
-- @file        invariant.lua
--

-- imports
import("harness.harness")
import("harness.context.window")
import("harness.context.invariant")
import("harness.core.session", {alias = "sessions"})

-- the codes of the violations found
function _codes(messages)
    local codes = {}
    for _, violation in ipairs(invariant.check(messages)) do
        table.insert(codes, violation.code)
    end
    return table.concat(codes, ",")
end

function test_a_plain_conversation_is_fine()
    assert(_codes({
        {role = "user", content = "what does this build?"},
        {role = "assistant", content = "one binary."}
    }) == "")
end

function test_a_tool_call_answered_is_fine()
    assert(_codes({
        {role = "user", content = "read it"},
        {role = "assistant", content = "", toolcalls = {{id = "c1", name = "read_file"}}},
        {role = "tool", toolcallid = "c1", content = "the file"},
        {role = "assistant", content = "it builds one binary."}
    }) == "")
end

function test_two_calls_in_one_turn_are_fine()
    assert(_codes({
        {role = "assistant", content = "", toolcalls = {{id = "c1", name = "read_file"},
                                                        {id = "c2", name = "read_file"}}},
        {role = "tool", toolcallid = "c1", content = "a"},
        {role = "tool", toolcallid = "c2", content = "b"},
        {role = "assistant", content = "both read."}
    }) == "")
end

function test_an_orphan_tool_result_is_caught()
    -- the assistant turn which asked for this was dropped off the front by the
    -- backstop, and the provider refuses the whole request over the unknown id
    assert(_codes({
        {role = "tool", toolcallid = "c1", content = "the file"},
        {role = "assistant", content = "so it builds one binary."}
    }) == "orphan-tool-result")
end

function test_a_result_without_an_id_is_caught()
    assert(_codes({
        {role = "assistant", content = "", toolcalls = {{id = "c1", name = "read_file"}}},
        {role = "tool", content = "the file"}
    }):find("tool-result-without-id", 1, true) ~= nil)
end

function test_an_unanswered_call_is_caught()
    -- the results were pruned away but the call which made them stayed: the
    -- model is asked to carry on about work it can no longer see
    assert(_codes({
        {role = "assistant", content = "", toolcalls = {{id = "c1", name = "read_file"}}},
        {role = "user", content = "and now the tests"}
    }) == "unanswered-tool-call")
end

function test_a_call_left_open_at_the_end_is_caught()
    assert(_codes({
        {role = "user", content = "read it"},
        {role = "assistant", content = "", toolcalls = {{id = "c1", name = "read_file"}}}
    }) == "unanswered-tool-call")
end

function test_a_result_answering_the_wrong_call_is_caught()
    assert(_codes({
        {role = "assistant", content = "", toolcalls = {{id = "c1", name = "read_file"}}},
        {role = "tool", toolcallid = "c9", content = "the file"}
    }):find("orphan-tool-result", 1, true) ~= nil)
end

function test_a_compacted_conversation_is_fine()
    -- what the summary boundary produces: a user message and an assistant one
    assert(_codes({
        {role = "user", content = "here is what happened so far .."},
        {role = "assistant", content = "Understood, I will continue from this summary."},
        {role = "user", content = "carry on"},
        {role = "assistant", content = "done."}
    }) == "")
end

function test_nothing_at_all_is_fine()
    assert(_codes({}) == "")
    assert(_codes(nil) == "")
end

function test_it_says_what_is_wrong()
    local violations = invariant.check({{role = "tool", toolcallid = "c1", content = "x"}})
    local text = invariant.describe(violations)
    assert(text ~= nil and text:find("c1", 1, true), tostring(text))
    assert(invariant.describe({}) == nil)
end

---------------------------------------------------------------------------------
-- against what the context optimizer really produces
---------------------------------------------------------------------------------

-- a session with `count` rounds of tool calls in it
function _session(count, outputsize)
    local session = sessions.new({cwd = os.tmpdir()})
    session:append("user", {text = "fix the build"})
    for idx = 1, count do
        local id = string.format("c%d", idx)
        session:append("assistant", {text = "", toolcalls = {{id = id, name = "read_file",
            arguments_text = string.format('{"path": "f%d"}', idx)}}})
        session:append("tool", {id = id, name = "read_file",
            arguments = {path = string.format("f%d", idx)},
            output = string.rep("x", outputsize or 100)})
    end
    session:append("assistant", {text = "done"})
    return session
end

function test_the_plain_projection_is_well_formed()
    local session = _session(6)
    assert(#invariant.check(session:messages()) == 0)
end

function test_the_optimized_projection_is_well_formed()
    -- pruning replaces old tool output with a marker, it must not remove the
    -- message: a call without its answer is a conversation with a hole in it
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local session = _session(30, 4000)
    local messages = window.optimize(instance, session, session:messages())
    local violations = invariant.check(messages)
    assert(#violations == 0, invariant.describe(violations) or "")
end

function test_the_backstop_leaves_a_conversation_behind()
    -- the hard limit drops whole turns off the front, and the front is exactly
    -- where a tool result can lose the call which asked for it
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local config = instance:config()
    config.context = config.context or {}
    -- a window small enough that the backstop has to cut
    config.providers = config.providers or {}
    local provider = config.providers[config.provider or "deepseek"] or {}
    provider.contextsize = 4000
    config.providers[config.provider or "deepseek"] = provider

    local session = _session(40, 2000)
    local messages = window.optimize(instance, session, session:messages())
    local violations = invariant.check(messages)
    assert(#violations == 0, invariant.describe(violations) or "")
    assert(#messages > 0, "it must not cut everything away")
end
