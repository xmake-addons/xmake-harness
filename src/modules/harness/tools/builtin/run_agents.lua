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
-- @file        run_agents.lua
--

-- imports
import("harness.util.util")
import("harness.core.graph")

-- define the tool
function define()
    return {
        name = "run_agents",
        group = "core",
        permission = "read",
        -- the graph fans out on its own, it must not be fanned out again
        concurrent = false,
        description = [[Delegate a whole plan to several subagents at once.

Describe the work as a graph: every node is one subagent with one task, and
`needs` lists the nodes whose reports it must have first. Nodes which need
nothing run at the same time; a node runs once everything it needs is done, and
it is given those reports.

Use it when the work has a shape — explore in three directions, then plan from
what came back, then review the plan. Doing that with run_agent costs one round
trip per level and drags every intermediate report through your own context.
Use run_agent instead when there is only one task, or when what you do next
depends on what you read.

Only the nodes nobody depends on report back to you; the rest already told the
nodes which needed them. If a node fails, whatever needed it is skipped.]],
        parameters = {
            type = "object",
            properties = {
                nodes = {
                    type = "array",
                    description = "The nodes of the graph, at most 12.",
                    items = {
                        type = "object",
                        properties = {
                            id          = {type = "string", description = "A short unique name, the other nodes refer to it."},
                            agent       = {type = "string", description = "The agent name, see the available agents in the system prompt."},
                            prompt      = {type = "string", description = "The complete self-contained task of this node."},
                            needs       = {type = "array", items = {type = "string"},
                                           description = "The ids this node needs first, omit it when it needs nothing."},
                            description = {type = "string", description = "A short description of the task, 3-6 words."}
                        },
                        required = {"id", "agent", "prompt"}
                    }
                }
            },
            required = {"nodes"}
        },
        render = function (args)
            return string.format("%d agents", #((args or {}).nodes or {}))
        end
    }
end

-- run the tool
function run(context, args)
    local nodes = args.nodes
    local states, order = graph.run(context.harness, context, nodes, {
        onnode = function (node, state)
            if context.ui and context.ui.on_notice and state.status ~= "ok" then
                context.ui.on_notice(string.format("the agent(%s) %s", node.id, state.status))
            end
        end})
    return {output = _report(nodes, states), display = _display(nodes, states, order)}
end

-- what goes back to the model
--
-- the leaves carry the result: their reports are given in full. the rest only
-- gets a line, their text already went to the nodes which needed them, and
-- repeating it here would put the whole graph back into the context we just
-- kept it out of
--
function _report(nodes, states)
    local lines = {}
    for _, node in ipairs(graph.leaves(nodes)) do
        local state = states[node.id] or {status = "skipped", output = "it did not run."}
        table.insert(lines, string.format("<report from=\"%s\">", node.id))
        table.insert(lines, (state.output or ""):trim())
        table.insert(lines, "</report>")
        table.insert(lines, "")
    end
    table.insert(lines, _status(nodes, states))
    return table.concat(lines, "\n")
end

-- one line per node, so a failure is visible even when its report is not
function _status(nodes, states)
    local parts = {}
    for _, node in ipairs(nodes) do
        local state = states[node.id] or {status = "skipped"}
        table.insert(parts, string.format("%s: %s", node.id, state.status))
    end
    return "the graph: " .. table.concat(parts, " · ")
end

-- what the user sees
function _display(nodes, states, order)
    local steps, tokens, failed = 0, 0, 0
    for _, state in pairs(states) do
        steps = steps + (state.steps or 0)
        tokens = tokens + (state.tokens or 0)
        failed = failed + (state.status ~= "ok" and 1 or 0)
    end
    return {
        title = "Agents",
        subject = string.format("%d agents · %s", #nodes, table.concat(order, " → ")),
        summary = string.format("%d step%s · %s tokens%s", steps, steps == 1 and "" or "s",
            util.count(tokens), failed > 0 and string.format(" · %d did not finish", failed) or "")
    }
end
