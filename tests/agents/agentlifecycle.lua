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
-- @file        agentlifecycle.lua
--

-- imports
import("harness.agents.script")
import("harness.agents.lifecycle")
import("harness.agents.registry", {alias = "agentregistry"})

-- an agent whose bundle carries the given lua
function _scripted(body)
    local dir = os.tmpfile() .. ".lifecycle"
    os.mkdir(path.join(dir, "clever"))
    io.writefile(path.join(dir, "clever", "AGENT.md"),
        "---\ndescription: A clever one\ntools: read_file\nmaxsteps: 4\n---\nDo it.\n")
    io.writefile(path.join(dir, "clever", "agent.lua"), body)
    local registry = agentregistry.new()
    registry:adddir(dir, "builtin")
    return registry:get("clever")
end

-- a run over that agent, and the errors its stages reported
function _run(body, prompt)
    local definition = _scripted(body)
    local complaints = {}
    local run = lifecycle.new({
        definition = definition,
        prompt = prompt or "Find the targets.",
        context = {agent = definition, prompt = prompt or "Find the targets."}})
    return run, function (errors) table.insert(complaints, errors) end, complaints
end

---------------------------------------------------------------------------------
-- the stages before it runs
---------------------------------------------------------------------------------

function test_an_agent_without_a_script_goes_through_untouched()
    local dir = os.tmpfile() .. ".plain"
    os.mkdir(dir)
    io.writefile(path.join(dir, "plain.md"),
                 "---\ndescription: A plain one\n---\nDo the thing.\n")
    local registry = agentregistry.new()
    registry:adddir(dir, "builtin")

    local definition = registry:get("plain")
    local run = lifecycle.new({definition = definition, prompt = "go", context = {}})
    assert(not lifecycle.scripted(run))
    lifecycle.prepare(run)
    assert(run.definition == definition)
    assert(run.prompt == "go")
end

function test_the_stages_run_in_the_order_they_are_written()
    local run, complain = _run([[
function define(context)
    return {maxsteps = 12, _seen = "define"}
end
function tools(context, current)
    return {table.concat(current, "+"), "after:" .. tostring(context.agent.maxsteps)}
end
function prompt(context)
    return "tools were " .. tostring(#context.agent.tools)
end
function before(context)
    return "instructions end with: " .. context.agent.prompt:sub(-12)
end
]])
    lifecycle.prepare(run, complain)

    -- define ran first, so tools saw its maxsteps
    assert(run.definition.maxsteps == 12, tostring(run.definition.maxsteps))
    assert(run.definition.tools[2] == "after:12", run.definition.tools[2])

    -- tools ran before prompt, so prompt saw the new list
    assert(run.definition.prompt:find("tools were 2", 1, true), run.definition.prompt)

    -- and prompt ran before before, which saw the appended instructions
    assert(run.prompt:find("instructions end with: tools were 2", 1, true), run.prompt)
end

function test_the_tools_hook_is_handed_what_it_would_have_had()
    local run, complain = _run([[
function tools(context, current)
    local list = {}
    for _, name in ipairs(current) do table.insert(list, name) end
    table.insert(list, "write_file")
    return list
end
]])
    lifecycle.prepare(run, complain)
    assert(#run.definition.tools == 2, tostring(#run.definition.tools))
    assert(run.definition.tools[1] == "read_file", run.definition.tools[1])
    assert(run.definition.tools[2] == "write_file")
end

function test_a_hook_which_is_not_there_changes_nothing()
    local run, complain, complaints = _run("function prompt(context) return 'extra' end\n")
    local before = run.prompt
    lifecycle.prepare(run, complain)
    assert(run.prompt == before, run.prompt)
    assert(#complaints == 0, tostring(#complaints))
end

function test_a_stage_which_goes_wrong_is_reported_and_the_rest_still_run()
    local run, complain, complaints = _run([[
function define(context)
    error("I am broken")
end
function before(context)
    return "but I still ran"
end
]])
    lifecycle.prepare(run, complain)
    assert(#complaints == 1, tostring(#complaints))
    assert(complaints[1]:find("script failed", 1, true), complaints[1])
    assert(run.prompt:find("but I still ran", 1, true), run.prompt)
end

function test_the_name_is_not_the_scripts_to_change()
    local run, complain = _run([[
function define(context)
    return {name = "impostor", dir = "/tmp", maxsteps = 3}
end
]])
    lifecycle.prepare(run, complain)
    assert(run.definition.name == "clever", run.definition.name)
    assert(run.definition.maxsteps == 3)
end

---------------------------------------------------------------------------------
-- and the stages after it does
---------------------------------------------------------------------------------

function test_a_report_which_will_do_is_not_questioned()
    local run, complain = _run([[
function validate(context, result)
    if result.text:find("targets") then
        return nil
    end
    return "it does not say how many targets there are"
end
]])
    assert(lifecycle.review(run, {text = "there are 3 targets"}, complain) == nil)
end

function test_a_report_which_will_not_do_says_why()
    local run, complain = _run([[
function validate(context, result)
    return "it does not say how many targets there are"
end
]])
    local reason = lifecycle.review(run, {text = "I had a look"}, complain)
    assert(reason == "it does not say how many targets there are", tostring(reason))
end

function test_going_back_round_tells_it_what_was_wrong()
    local run, complain = _run("function validate(context, result) return 'no number' end\n")
    local reason = lifecycle.review(run, {text = "done"}, complain)
    lifecycle.retry(run, reason)
    assert(run.prompt:find("Find the targets.", 1, true), run.prompt)
    assert(run.prompt:find("not accepted: no number", 1, true), run.prompt)
end

function test_an_agent_with_no_opinion_never_sends_itself_back()
    local run, complain = _run("function before(context) return 'ready' end\n")
    assert(lifecycle.review(run, {text = "anything at all"}, complain) == nil)
end

function test_the_last_word_is_appended_to_the_report()
    local run, complain = _run([[
function after(context, result)
    return "and that took " .. tostring(result.steps) .. " steps."
end
]])
    local result = {text = "3 targets", steps = 4}
    lifecycle.finish(run, result, complain)
    assert(result.text == "3 targets\n\nand that took 4 steps.", result.text)
end

function test_the_cleanup_runs_and_can_go_wrong_without_mattering()
    local marker = os.tmpfile() .. ".cleaned"
    local run, complain, complaints = _run(string.format([[
function cleanup(context)
    io.writefile(%q, "done")
    error("and then I broke")
end
]], marker))
    lifecycle.cleanup(run, complain)
    assert(os.isfile(marker), "the cleanup ran")
    assert(#complaints == 1, tostring(#complaints))
    assert(complaints[1]:find("cleanup", 1, true), complaints[1])
end

---------------------------------------------------------------------------------
-- what the hooks are checked for
---------------------------------------------------------------------------------

function test_what_a_hook_returns_has_to_be_the_right_shape()
    local definition = _scripted([[
function tools(context, current) return "not a list" end
function prompt(context) return 42 end
function validate(context, result) return "   " end
]])
    assert(script.tools(definition, {}) == nil)
    assert(script.prompt(definition, {}) == nil)

    -- a blank reason is not a reason: it would send the agent back round with
    -- nothing to fix
    assert(script.validate(definition, {}, {}) == nil)
end

---------------------------------------------------------------------------------
-- the bundle which ships as an example
---------------------------------------------------------------------------------

function _example()
    local dir = path.join(os.scriptdir(), "..", "..", "examples", "agents", "hello-world")
    local registry = agentregistry.new()
    registry:addfile(path.join(dir, "AGENT.md"), "path")
    return registry:get("hello-world")
end

function test_the_example_bundle_loads()
    local definition = _example()
    assert(definition, "the example is where the docs say it is")
    assert(definition.description ~= "")
    assert(#definition.tools == 2, tostring(#definition.tools))
    assert(definition.maxsteps == 8)
end

function test_the_example_bundle_exports_every_hook()
    -- that is the whole point of it: somebody reading it sees the shape
    local module = script.load(_example())
    assert(module, "it has an agent.lua")
    for _, hook in ipairs({"define", "tools", "prompt", "before",
                           "validate", "after", "cleanup"}) do
        assert(type(module[hook]) == "function", hook .. " is missing")
    end
end

function test_the_example_refuses_a_greeting_which_never_says_the_name()
    local run = lifecycle.new({
        definition = _example(),
        prompt = "greet it",
        context = {cwd = path.join(os.tmpdir(), "somewhere-called-widgets")}})

    local reason = lifecycle.review(run, {text = "Hello, project."})
    assert(reason and reason:find("widgets", 1, true), tostring(reason))

    -- and accepts one which does
    assert(lifecycle.review(run, {text = "Hello, somewhere-called-widgets."}) == nil)
end

function test_the_example_cleans_up_after_its_before()
    local rootdir = os.tmpfile() .. ".hello"
    os.mkdir(rootdir)
    io.writefile(path.join(rootdir, "main.c"), "int main(void){return 0;}\n")

    local run = lifecycle.new({definition = _example(), prompt = "greet it",
                               context = {cwd = rootdir}})
    lifecycle.prepare(run)
    assert(run.prompt:find("I counted them for you", 1, true), run.prompt)
    assert(run.prompt:find("1 source file", 1, true), run.prompt)

    local scratch = run.context._scratch
    assert(scratch and os.isfile(scratch), "before left something behind")
    lifecycle.cleanup(run)
    assert(not os.isfile(scratch), "and cleanup took it away")
end

function test_the_example_says_so_when_there_is_nothing_to_greet()
    local rootdir = os.tmpfile() .. ".empty"
    os.mkdir(rootdir)
    local run = lifecycle.new({definition = _example(), prompt = "greet it",
                               context = {cwd = rootdir}})
    lifecycle.prepare(run)
    assert(run.prompt:find("nothing in it which looks like source", 1, true), run.prompt)

    -- and does not ask for eight steps to say it
    assert(run.definition.maxsteps == 2, tostring(run.definition.maxsteps))
    lifecycle.cleanup(run)
end
