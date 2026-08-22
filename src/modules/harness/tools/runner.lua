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
-- the model usually asks for several things at once: three files, a search and
-- a listing. running them one by one is pure latency, so everything which
-- cannot change the world runs together in the xmake scheduler.
--
-- what may run together:
--
--   - the read-only tools, they only look at the project
--   - the subagents, they work in their own context and their own session
--   - anything the policy already allows and which declares no side effect
--
-- the results are always reported in the original order, so the session log
-- stays deterministic whatever the timing was.
--

-- imports
import("harness.util.parallel")
import("harness.tools.pipeline")
import("harness.permission.policy")

-- run the tool calls
--
-- @param oncomplete    called with (call, result), in the original order
--
function run(harness, context, toolcalls, ui, oncomplete)
    local results = {}
    local concurrent = _concurrent(harness, context, toolcalls)
    if #concurrent > 1 then
        parallel.run(_jobs(context, toolcalls, concurrent, results, ui),
            {limit = (harness:config().tools or {}).maxconcurrency, signal = context.signal})
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
        if tool and _isconcurrent(tool) and _isallowed(context, tool, call) then
            table.insert(results, index)
        end
    end
    return results
end

-- may this tool run beside the others?
--
-- a tool says so itself with `concurrent = true`, e.g. the subagents: they run
-- long, they only report back, and nothing they do depends on the others
--
function _isconcurrent(tool)
    if tool.concurrent ~= nil then
        return tool.concurrent
    end
    return tool.permission == "read" or tool.permission == "none"
end

-- would this call run without asking the user?
--
-- a confirmation in the middle of a group would fight for the terminal with
-- the others, so anything which may ask runs on its own
--
function _isallowed(context, tool, call)
    local args = _arguments(call)
    return policy.check(context.config, tool, args, {mode = context.mode, cwd = context.cwd}) == "allow"
end

-- decode the arguments of a call, we need them to judge it
function _arguments(call)
    local llm = import("harness.llm.llm", {anonymous = true})
    local args = llm.decode_arguments(call)
    return type(args) == "table" and args or {}
end

-- the jobs of the calls which run together
function _jobs(context, toolcalls, indexes, results, ui)
    local jobs = {}
    for _, index in ipairs(indexes) do
        local call = toolcalls[index]
        table.insert(jobs, function ()
            if ui.on_tool_start then
                ui.on_tool_start(call)
            end
            results[index] = pipeline.execute(context, call)
        end)
    end
    return jobs
end
