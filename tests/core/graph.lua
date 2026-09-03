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

-- imports
import("harness.harness")
import("harness.core.graph")
import("harness.agents.registry", {alias = "agentregistry"})

-- a node
function _node(id, needs, agent)
    return {id = id, agent = agent or "probe", prompt = "do " .. id, needs = needs}
end

-- the ids of one level
function _ids(level)
    local ids = {}
    for _, node in ipairs(level) do
        table.insert(ids, node.id)
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

function test_the_independent_nodes_share_one_level()
    local levels = graph.plan({_node("a"), _node("b"), _node("c")})
    assert(#levels == 1, "three independent nodes must run together")
    assert(_ids(levels[1]) == "a,b,c")
end

function test_a_dependency_makes_a_second_level()
    local levels = graph.plan({_node("explore1"), _node("explore2"), _node("plan", {"explore1", "explore2"})})
    assert(#levels == 2)
    assert(_ids(levels[1]) == "explore1,explore2")
    assert(_ids(levels[2]) == "plan")
end

function test_a_chain_is_one_node_per_level()
    local levels = graph.plan({_node("c", {"b"}), _node("a"), _node("b", {"a"})})
    assert(#levels == 3, "a chain cannot be parallelized")
    assert(_ids(levels[1]) == "a" and _ids(levels[2]) == "b" and _ids(levels[3]) == "c")
end

function test_a_diamond()
    local levels = graph.plan({_node("root"), _node("left", {"root"}), _node("right", {"root"}),
                               _node("join", {"left", "right"})})
    assert(#levels == 3)
    assert(_ids(levels[2]) == "left,right", "both sides of the diamond run together")
end

function test_a_cycle_is_refused()
    local levels, errors = graph.plan({_node("a", {"b"}), _node("b", {"a"})})
    assert(levels == nil, "a cycle must not run")
    assert(errors:find("cycle", 1, true), errors)
end

function test_a_node_which_needs_itself_is_refused()
    local levels, errors = graph.plan({_node("a", {"a"})})
    assert(levels == nil)
    assert(errors:find("itself", 1, true), errors)
end

function test_an_unknown_dependency_is_refused()
    local levels, errors = graph.plan({_node("a", {"nowhere"})})
    assert(levels == nil)
    assert(errors:find("not in the graph", 1, true), errors)
end

function test_a_duplicate_id_is_refused()
    local levels, errors = graph.plan({_node("a"), _node("a")})
    assert(levels == nil)
    assert(errors:find("twice", 1, true), errors)
end

function test_an_empty_graph_is_refused()
    local levels, errors = graph.plan({})
    assert(levels == nil)
    assert(errors:find("empty", 1, true), errors)
end

function test_a_node_without_a_prompt_is_refused()
    local levels, errors = graph.plan({{id = "a", agent = "probe"}})
    assert(levels == nil)
    assert(errors:find("prompt", 1, true), errors)
end

function test_too_many_nodes_are_refused()
    local nodes = {}
    for idx = 1, 20 do
        table.insert(nodes, _node("n" .. idx))
    end
    local levels, errors = graph.plan(nodes)
    assert(levels == nil)
    assert(errors:find("at most", 1, true), errors)
end

function test_the_leaves_are_the_ones_nobody_needs()
    local nodes = {_node("explore"), _node("plan", {"explore"}), _node("review", {"plan"})}
    local leaves = graph.leaves(nodes)
    assert(#leaves == 1 and leaves[1].id == "review")
end

function test_every_node_is_a_leaf_when_nothing_depends()
    assert(#graph.leaves({_node("a"), _node("b")}) == 2)
end

-- a harness whose agents are recorded instead of run
function _harness(behaviour)
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local agents = agentregistry.new()
    for name, _ in pairs(behaviour) do
        agents:add({name = name, description = "a test agent", prompt = "you are a test"})
    end
    instance:service("agents", agents)
    return instance
end

-- run a graph with the agent loop replaced by the given behaviour
function _run(nodes, behaviour, seen)
    local instance = _harness(behaviour)
    local context = {harness = instance, config = instance:config(), cwd = os.tmpdir(),
                     signal = {aborted = false}, depth = 0}
    return graph.run(instance, context, nodes, {spawn = function (_, opt)
        table.insert(seen, {agent = opt.agent.name, prompt = opt.prompt})
        return behaviour[opt.agent.name](opt)
    end})
end

function test_a_report_reaches_the_node_which_needs_it()
    local seen = {}
    local behaviour = {
        finder = function () return {text = "the bug is in parser.c", steps = 1, usage = {input = 10, output = 5}} end,
        fixer = function () return {text = "fixed", steps = 2, usage = {input = 20, output = 5}} end
    }
    local states = _run({{id = "find", agent = "finder", prompt = "find it"},
                         {id = "fix", agent = "fixer", prompt = "fix it", needs = {"find"}}}, behaviour, seen)
    assert(states["find"].status == "ok" and states["fix"].status == "ok")
    assert(#seen == 2)
    local given = seen[2].prompt
    assert(given:find("the bug is in parser.c", 1, true), "the report was not given to the dependent node")
    assert(given:find('<report from="find">', 1, true), "the report was not named")
    assert(seen[1].prompt == "find it", "a node which needs nothing gets its prompt untouched")
end

function test_a_failed_node_skips_what_needed_it()
    local seen = {}
    local behaviour = {
        broken = function () raise("it exploded") end,
        after = function () return {text = "should not run"} end
    }
    local states = _run({{id = "a", agent = "broken", prompt = "explode"},
                         {id = "b", agent = "after", prompt = "carry on", needs = {"a"}}}, behaviour, seen)
    assert(states["a"].status == "failed", "the raise must be caught and recorded")
    assert(states["a"].output:find("exploded", 1, true), states["a"].output)
    assert(states["b"].status == "skipped", "a node whose dependency failed must not run")
    assert(#seen == 1, "the skipped node must not be spawned")
end

function test_an_unknown_agent_fails_only_its_own_node()
    local seen = {}
    local behaviour = {good = function () return {text = "done"} end}
    local states = _run({{id = "a", agent = "nosuchagent", prompt = "x"},
                         {id = "b", agent = "good", prompt = "y"}}, behaviour, seen)
    assert(states["a"].status == "failed" and states["a"].output:find("does not exist", 1, true))
    assert(states["b"].status == "ok", "the other node is independent, it must still run")
end
