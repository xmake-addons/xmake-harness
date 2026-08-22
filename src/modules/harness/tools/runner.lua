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
-- @file        runner.lua
--

--
-- the tool call runner of one step
--
-- the read-only calls need no confirmation and touch nothing, so they run
-- concurrently in the xmake scheduler: the model usually asks for several files
-- or searches at once, and waiting for them one by one is pure latency.
--
-- the results are still reported in the original order, so the session log
-- stays deterministic.
--

-- imports
import("core.base.scheduler")
import("harness.tools.pipeline")
import("harness.permission.policy")

-- the name of the coroutine group
local GROUP = "harness/tools"

-- run the tool calls
--
-- @param oncomplete    called with (call, result), in the original order
--
function run(harness, context, toolcalls, ui, oncomplete)
    local results = {}
    local concurrent = _concurrent(harness, context, toolcalls)
    if #concurrent > 1 then
        _runconcurrent(context, toolcalls, concurrent, results, ui)
    end
    for index, call in ipairs(toolcalls) do
        if context.signal and context.signal.aborted then
            break
        end
        local result = results[index]
        if not result then
            if ui.on_tool_start then
                ui.on_tool_start(call)
            end
            result = pipeline.execute(context, call)
        end
        oncomplete(call, result)
    end
end

-- get the indexes of the calls which may run together
function _concurrent(harness, context, toolcalls)
    local registry = harness:service("tools")
    local results = {}
    for index, call in ipairs(toolcalls) do
        local tool = registry:get(call.name)
        if tool and (tool.permission == "read" or tool.permission == "none")
            and policy.check(context.config, tool, {}, {mode = context.mode}) == "allow" then
            table.insert(results, index)
        end
    end
    return results
end

-- run the given calls in their own coroutines
function _runconcurrent(context, toolcalls, indexes, results, ui)
    scheduler.co_group_begin(GROUP, function (co_group)
        for _, index in ipairs(indexes) do
            local call = toolcalls[index]
            if ui.on_tool_start then
                ui.on_tool_start(call)
            end
            scheduler.co_start(function ()
                results[index] = pipeline.execute(context, call)
            end)
        end
    end)
    scheduler.co_group_wait(GROUP)
end
