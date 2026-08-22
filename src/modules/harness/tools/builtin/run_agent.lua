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
-- @file        run_agent.lua
--

-- imports
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "run_agent",
        group = "core",
        permission = "read",
        -- several subagents may work at the same time, each in its own context
        concurrent = true,
        description = [[Delegate a task to a subagent.

A subagent runs in its own context window with its own system prompt and tools,
and it only returns its final report, so it is the right way to do the wide
searches and the long explorations without filling the main context.

Give it a complete self-contained task, it cannot ask you anything back.

Ask for several of them in one turn when the tasks are independent: they run at
the same time, so three explorations cost about as much wall clock as one.]],
        parameters = {
            type = "object",
            properties = {
                agent       = {type = "string", description = "The agent name, see the available agents in the system prompt."},
                prompt      = {type = "string", description = "The complete task for the subagent."},
                description = {type = "string", description = "A short description of the task, 3-6 words."}
            },
            required = {"agent", "prompt"}
        },
        render = function (args)
            return string.format("%s: %s", args.agent or "agent", args.description or "")
        end
    }
end

-- run the tool
function run(context, args)
    local agents = context.harness:service("agents")
    local definition = agents and agents:get(args.agent)
    if not definition then
        local names = {}
        for _, item in ipairs(agents and agents:all() or {}) do
            table.insert(names, item.name)
        end
        raise("the agent(%s) does not exist! the available agents: %s", tostring(args.agent), table.concat(names, ", "))
    end

    local depth = (context.depth or 0) + 1
    if depth > 3 then
        raise("the subagent nesting is too deep, do this task yourself.")
    end

    local agentloop = import("harness.core.agent", {anonymous = true})
    local result = agentloop.run(context.harness, {
        agent = definition,
        prompt = args.prompt,
        depth = depth,
        parent = context,
        signal = context.signal,
        ui = context.ui and context.ui.subagent and context.ui.subagent(definition, args) or nil
    })
    if result.errors then
        raise("the subagent(%s) failed: %s", definition.name, result.errors)
    end
    local usage = result.usage or {}
    return {
        output = result.text ~= "" and result.text or "(the subagent returned nothing)",
        display = {
            title = "Agent",
            subject = string.format("%s: %s", definition.name, args.description or ""),
            summary = string.format("%d step%s · %s tokens", result.steps or 0, (result.steps or 0) == 1 and "" or "s",
                util.count((usage.input or 0) + (usage.output or 0)))
        }
    }
end
