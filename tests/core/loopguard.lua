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
-- @file        loopguard.lua
--

-- imports
import("harness.core.guards")

-- the calls of one round
function _calls(...)
    local results = {}
    for _, name in ipairs({...}) do
        table.insert(results, {name = name, arguments_text = "{}"})
    end
    return results
end

function test_a_different_round_is_not_stuck()
    -- edit, build, edit, build is an iterative fix, not a loop
    local state = guards.new({})
    assert(guards.repeated(state, _calls("edit_file")) == nil)
    assert(guards.repeated(state, _calls("xmake_build")) == nil)
    assert(guards.repeated(state, _calls("edit_file")) == nil)
    assert(guards.repeated(state, _calls("xmake_build")) == nil)
end

function test_the_same_round_stops_the_turn()
    local state = guards.new({})
    assert(guards.repeated(state, _calls("xmake_build")) == nil)
    assert(guards.repeated(state, _calls("xmake_build")) == nil)
    local reason = guards.repeated(state, _calls("xmake_build"))
    assert(reason ~= nil, "the third identical round was not caught")
    assert(reason.code == "repeated-tool-calls", tostring(reason.code))
    assert(reason.text:find("repeated", 1, true), reason.text)
end

function test_the_order_of_the_calls_does_not_matter()
    local state = guards.new({})
    guards.repeated(state, _calls("read_file", "list_dir"))
    guards.repeated(state, _calls("list_dir", "read_file"))
    assert(guards.repeated(state, _calls("read_file", "list_dir")) ~= nil)
end

function test_the_arguments_matter()
    -- the same tool on another file is progress
    local state = guards.new({})
    for idx = 1, 5 do
        local calls = {{name = "read_file", arguments_text = string.format('{"path":"f%d"}', idx)}}
        assert(guards.repeated(state, calls) == nil, "reading another file is not a loop")
    end
end

function test_the_limit_is_configurable()
    local state = guards.new({agent = {maxrepeats = 2}})
    assert(guards.repeated(state, _calls("a")) == nil)
    assert(guards.repeated(state, _calls("a")) ~= nil)
end

function test_a_working_step_resets_the_error_streak()
    local state = guards.new({})
    assert(guards.progressing(state, 2, 2) == nil)
    assert(guards.progressing(state, 2, 0) == nil)
    assert(guards.progressing(state, 2, 2) == nil)
    assert(guards.progressing(state, 2, 2) == nil)
    local stopped = guards.progressing(state, 2, 2)
    assert(stopped ~= nil, "three failing steps were not caught")
    assert(stopped.code == "all-tools-failed", tostring(stopped.code))
    assert(stopped.text:find("failed", 1, true), stopped.text)
end

function test_a_partial_failure_is_progress()
    local state = guards.new({})
    for _ = 1, 10 do
        assert(guards.progressing(state, 3, 2) == nil, "one tool worked, that is progress")
    end
end

function test_no_tools_is_not_a_failure()
    local state = guards.new({})
    for _ = 1, 10 do
        assert(guards.progressing(state, 0, 0) == nil)
    end
end

---------------------------------------------------------------------------------
-- looking for something which is not there
---------------------------------------------------------------------------------

function test_a_search_which_keeps_finding_nothing_is_stopped()
    -- the repeat guard sees the same call twice and nothing else, and the shape
    -- this actually takes is a pattern rephrased every round: the signature
    -- never matches and the model goes on asking a question with no answer
    local state = guards.new({agent = {maxfruitless = 3}})
    local nothing = {{name = "glob_files", output = "(no files matched)"}}

    assert(guards.fruitless(state, nothing) == nil, "once is a search")
    assert(guards.fruitless(state, nothing) == nil, "twice is a retry")
    local stop = guards.fruitless(state, nothing)
    assert(stop and stop.code == "nothing-found", tostring(stop and stop.code))
    assert(stop.text:find("not there", 1, true), stop.text)
end

function test_finding_something_starts_the_count_again()
    local state = guards.new({agent = {maxfruitless = 3}})
    guards.fruitless(state, {{name = "glob_files", output = "(no files matched)"}})
    guards.fruitless(state, {{name = "glob_files", output = "(no files matched)"}})
    assert(guards.fruitless(state, {{name = "glob_files", output = "src/main.c"}}) == nil)
    assert(guards.fruitless(state, {{name = "glob_files", output = "(no files matched)"}}) == nil,
           "and it counts from there")
end

function test_a_step_which_did_not_search_is_not_counted()
    -- reading and editing between the searches is progress, and a project where
    -- one directory is empty is not a project which is stuck
    local state = guards.new({agent = {maxfruitless = 2}})
    guards.fruitless(state, {{name = "glob_files", output = "(no files matched)"}})
    assert(guards.fruitless(state, {{name = "read_file", output = "int main() {}"}}) == nil)
    assert(guards.fruitless(state, {{name = "glob_files", output = "(no files matched)"}}),
           "the searches still add up")
end

function test_a_search_which_failed_is_not_a_search_which_found_nothing()
    local state = guards.new({agent = {maxfruitless = 2}})
    local broken = {{name = "search_text", output = "the pattern is invalid", iserror = true}}
    guards.fruitless(state, broken)
    assert(guards.fruitless(state, broken), "it counts, because it is getting nowhere either")
end
