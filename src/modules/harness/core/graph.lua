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
-- @file        graph.lua
--

--
-- the agent graph
--
-- one `run_agent` call is a single task. real work is usually a small graph of
-- them: three explorations which do not know about each other, then a plan
-- which needs all three, then a review of the plan.
--
-- without a graph the model has to drive that itself, one round trip per level,
-- and every intermediate report lands in its context on the way past. with a
-- graph it describes the whole shape once, the harness runs each level on the
-- scheduler, feeds every node the reports of what it depends on, and only the
-- leaves report back.
--
-- the graph is a dag, and it is checked before anything runs: a cycle or a
-- missing dependency is reported as a message the model can act on, not as a
-- half-executed graph.
--

-- imports
import("harness.core.subagent")
import("harness.util.parallel")

-- how many nodes may run at the same time
--
-- a node is a whole agent loop with its own tools and its own subprocesses, so
-- it is far heavier than a tool call and the useful number is smaller
--
local MAXPARALLEL = 3

-- how many nodes one graph may have
local MAXNODES = 12

-- validate the graph and sort it into the levels which may run together
--
-- @return  the levels, e.g. {{node, node}, {node}}, or nil and the reason
--
function plan(nodes)
    local byid, errors = _index(nodes)
    if not byid then
        return nil, errors
    end
    return _levels(nodes, byid)
end

-- index the nodes by id, checking each one of them
function _index(nodes)
    if type(nodes) ~= "table" or #nodes == 0 then
        return nil, "the graph is empty, give it at least one node."
    end
    if #nodes > MAXNODES then
        return nil, string.format("the graph has %d nodes, at most %d are allowed. "
            .. "split it, or give the nodes bigger tasks.", #nodes, MAXNODES)
    end
    local byid = {}
    for _, node in ipairs(nodes) do
        local id = node.id
        if type(id) ~= "string" or id:trim() == "" then
            return nil, "every node needs an id."
        end
        if byid[id] then
            return nil, string.format("the node id(%s) is used twice, the ids must be unique.", id)
        end
        if type(node.agent) ~= "string" or type(node.prompt) ~= "string" or node.prompt:trim() == "" then
            return nil, string.format("the node(%s) needs an agent and a prompt.", id)
        end
        byid[id] = node
    end
    return byid
end

-- sort the nodes into the levels which may run together
--
-- it is a plain topological sort: whatever has nothing left to wait for goes
-- into the next level. what remains when nothing can move is a cycle
--
function _levels(nodes, byid)
    local done = {}
    local levels = {}
    local remaining = table.clone(nodes)
    while #remaining > 0 do
        local level, blocked = _ready(remaining, byid, done)
        if blocked then
            return nil, blocked
        end
        if #level == 0 then
            return nil, string.format("the graph has a cycle between the nodes: %s.",
                _idlist(remaining))
        end
        for _, node in ipairs(level) do
            done[node.id] = true
        end
        table.insert(levels, level)
        remaining = _without(remaining, done)
    end
    return levels
end

-- which of the remaining nodes have nothing left to wait for?
--
-- @return  the ready nodes, or nil and the reason when a dependency is unknown
--
function _ready(remaining, byid, done)
    local level = {}
    for _, node in ipairs(remaining) do
        local ready = true
        for _, need in ipairs(node.needs or {}) do
            if not byid[need] then
                return nil, string.format("the node(%s) needs the node(%s), which is not in the graph.",
                    node.id, tostring(need))
            end
            if need == node.id then
                return nil, string.format("the node(%s) needs itself.", node.id)
            end
            ready = ready and done[need]
        end
        if ready then
            table.insert(level, node)
        end
    end
    return level
end

-- the nodes which are not done yet
function _without(nodes, done)
    local results = {}
    for _, node in ipairs(nodes) do
        if not done[node.id] then
            table.insert(results, node)
        end
    end
    return results
end

-- the ids of the given nodes, for a message
function _idlist(nodes)
    local ids = {}
    for _, node in ipairs(nodes) do
        table.insert(ids, node.id)
    end
    return table.concat(ids, ", ")
end

-- run the graph
--
-- @param opt   - limit     how many nodes at a time, @see MAXPARALLEL
--              - onnode    called with (node, state) when a node finishes
--              - spawn     how a node is run, @see harness.core.subagent.spawn
--
-- @return      the states by id, and the order they finished in
--
function run(harness, context, nodes, opt)
    opt = opt or {}
    local levels, errors = plan(nodes)
    if not levels then
        raise(errors)
    end

    local states = {}
    local order = {}
    for _, level in ipairs(levels) do
        if context.signal and context.signal.aborted then
            break
        end
        parallel.run(_jobs(harness, context, level, states, order, opt),
            {limit = opt.limit or _limit(harness), signal = context.signal})
    end
    return states, order
end

-- how many nodes run at the same time
function _limit(harness)
    return ((harness:config().agent or {}).maxparallel) or MAXPARALLEL
end

-- the jobs of one level
function _jobs(harness, context, level, states, order, opt)
    local jobs = {}
    for _, node in ipairs(level) do
        table.insert(jobs, function ()
            local state = _runnode(harness, context, node, states, opt)
            states[node.id] = state
            table.insert(order, node.id)
            if opt.onnode then
                opt.onnode(node, state)
            end
        end)
    end
    return jobs
end

-- run one node
--
-- @return  {status = "ok"|"failed"|"skipped", output, steps, tokens}
--
function _runnode(harness, context, node, states, opt)
    local missing = _missing(node, states)
    if missing then
        return {status = "skipped", output = string.format("skipped: it needs %s, which did not finish.", missing)}
    end
    local definition, errors = subagent.resolve(harness, node.agent)
    if not definition then
        return {status = "failed", output = errors}
    end

    local result
    try {
        function ()
            local spawn = opt.spawn or subagent.spawn
            result = spawn(context, {agent = definition, prompt = _prompt(node, states),
                                     description = node.description or node.id})
        end,
        catch {
            function (errs)
                result = {errors = tostring(errs)}
            end
        }
    }
    if result.errors then
        return {status = "failed", output = tostring(result.errors)}
    end
    return {status = "ok", output = result.text, steps = result.steps or 0,
            tokens = subagent.tokensof(result)}
end

-- which dependency of this node did not produce anything?
function _missing(node, states)
    for _, need in ipairs(node.needs or {}) do
        local state = states[need]
        if not state or state.status ~= "ok" then
            return need
        end
    end
end

-- the prompt of one node, with the reports it depends on
--
-- the reports are wrapped and named, so a node which needs three of them can
-- tell them apart, and so nothing inside a report reads as an instruction from
-- the caller
--
function _prompt(node, states)
    local needs = node.needs or {}
    if #needs == 0 then
        return node.prompt
    end
    local parts = {node.prompt, "", "The agents you depend on have reported back:"}
    for _, need in ipairs(needs) do
        table.insert(parts, "")
        table.insert(parts, string.format("<report from=\"%s\">", need))
        table.insert(parts, (states[need].output or ""):trim())
        table.insert(parts, "</report>")
    end
    return table.concat(parts, "\n")
end

-- which nodes nobody depends on?
--
-- they are the ones which carry the result of the graph: whatever the others
-- produced already flowed into them
--
function leaves(nodes)
    local needed = {}
    for _, node in ipairs(nodes) do
        for _, need in ipairs(node.needs or {}) do
            needed[need] = true
        end
    end
    local results = {}
    for _, node in ipairs(nodes) do
        if not needed[node.id] then
            table.insert(results, node)
        end
    end
    return results
end
