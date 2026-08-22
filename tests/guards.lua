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
-- @file        guards.lua
--

-- imports
import("harness.harness")
import("harness.core.agent")
import("harness.tools.runner")
import("harness.core.context")
import("harness.core.session", {alias = "sessions"})
import("harness.tools.registry", {alias = "toolregistry"})

-- a harness whose tools do what the test asks for
function _harness(opt)
    opt = opt or {}
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local tools = toolregistry.new()
    tools:add({
        name = "probe",
        permission = "read",
        description = "a tool for the tests",
        parameters = {type = "object", properties = {}},
        run = function ()
            if opt.fail then
                raise("it always fails")
            end
            return {output = "ok"}
        end
    })
    instance:service("tools", tools)
    return instance
end

-- run the tool calls of one step through the runner
function _run(instance, calls, opt)
    local context = {harness = instance, config = instance:config(), cwd = os.tmpdir(),
                     session = sessions.new({cwd = os.tmpdir()}), ui = {}, signal = {aborted = false},
                     mode = opt and opt.mode or "bypass"}
    local results = {}
    runner.run(instance, context, calls, {}, function (call, result)
        table.insert(results, result)
    end)
    return results
end

-- make n calls of the probe tool
function _calls(count)
    local calls = {}
    for idx = 1, count do
        table.insert(calls, {id = tostring(idx), name = "probe", arguments_text = "{}"})
    end
    return calls
end

function test_all_calls_report_back()
    -- the batching must not lose or duplicate anything
    local instance = _harness()
    local results = _run(instance, _calls(9))
    assert(#results == 9, "results: " .. #results)
    for _, result in ipairs(results) do
        assert(result.output == "ok", result.output)
    end
end

function test_a_failing_tool_still_reports()
    local instance = _harness({fail = true})
    local results = _run(instance, _calls(3))
    assert(#results == 3)
    for _, result in ipairs(results) do
        assert(result.iserror, "the failure was not reported")
    end
end

function test_results_keep_their_order()
    local instance = _harness()
    local calls = _calls(6)
    for idx, call in ipairs(calls) do
        call.arguments_text = string.format('{"index": %d}', idx)
    end
    local results = _run(instance, calls)
    for idx, result in ipairs(results) do
        assert(result.id == tostring(idx), string.format("%d: %s", idx, tostring(result.id)))
    end
end

function test_concurrency_is_capped()
    -- the cap is a configuration value, the runner must read it
    local instance = _harness()
    instance:config().tools = {maxconcurrency = 2}
    local results = _run(instance, _calls(5))
    assert(#results == 5)
end
