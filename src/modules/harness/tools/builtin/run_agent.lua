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
import("harness.core.subagent")

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
                description = {type = "string", description = "A short description of the task, 3-6 words. Always give one: it is what the user watches while this runs."}
            },
            required = {"agent", "prompt"}
        },
        render = function (args)
            -- `description` is optional and models leave it out, which used to
            -- leave a card reading `agent:` with nothing after it for minutes
            local what = (args.description or ""):trim()
            if what == "" then
                what = (args.prompt or ""):split("\n", {strict = true})[1] or ""
                if #what > 60 then
                    what = what:sub(1, 57) .. "..."
                end
            end
            return what ~= "" and string.format("%s: %s", args.agent or "agent", what)
                   or (args.agent or "agent")
        end
    }
end

-- run the tool
function run(context, args)
    local definition, errors = subagent.resolve(context.harness, args.agent)
    if not definition then
        raise(errors)
    end
    local result = subagent.spawn(context, {agent = definition, prompt = args.prompt,
                                            description = args.description})
    if result.errors then
        raise("the subagent(%s) failed: %s", definition.name, result.errors)
    end
    return {
        output = result.text ~= "" and result.text or "(the subagent returned nothing)",
        display = {
            title = "Agent",
            subject = string.format("%s: %s", definition.name, args.description or ""),
            summary = string.format("%d step%s · %s tokens", result.steps or 0, (result.steps or 0) == 1 and "" or "s",
                util.count(subagent.tokensof(result)))
        }
    }
end
