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
-- @file        lifecycle.lua
--

--
-- the life of one subagent, as a list of stages
--
-- an agent which is more than a prompt takes part in its own run, @see
-- harness.agents.script. this is what it may take part *in*: the points at
-- which it is asked something, in the order they happen.
--
-- they are a table and not a run of `if script.has()` branches through the
-- spawn, because that is the difference between adding a hook and editing three
-- functions in two modules. a stage says which function the agent may export
-- and what its answer does to the run; nothing outside this file knows that
-- there are stages at all, and nothing inside it knows what a subagent is.
--
--   define(context)             the definition: tools, model, maxsteps
--   tools(context, tools)       the tool list, when it depends on the directory
--   prompt(context)             text appended to its own instructions
--   before(context)             text appended to the task, e.g. what it found
--   -- the agent runs --
--   validate(context, result)   nil if the report will do, otherwise why not
--   after(context, result)      the last word on the report
--   cleanup(context)            whatever `before` set up, taken down again
--
-- a run is `{definition, prompt, context}` and the stages rewrite it in place,
-- so the caller hands one table around and never assembles arguments twice.
--

-- imports
import("harness.agents.script")

-- create the run which the stages rewrite
--
-- @param opt   - definition   the agent, @see harness.agents.registry
--              - prompt       the complete task
--              - context      what the agent's own lua is given
--
function new(opt)
    return {
        definition = opt.definition,
        prompt = opt.prompt,
        context = opt.context
    }
end

-- does this agent take part in its own run at all?
function scripted(run)
    return script.has(run.definition)
end

-- the stages which run before the agent does, in the order they happen
--
-- built here and not at the top of the file so that every function it names
-- exists by the time it is named. adding a hook is adding a row
--
function _stages()
    return {
        {hook = "define", apply = _applydefine},
        {hook = "tools",  apply = _applytools,
         args = function (run) return run.definition.tools end},
        {hook = "prompt", apply = _applyprompt},
        {hook = "before", apply = _applybefore}
    }
end

-- let the agent have its say before the turn starts
--
-- a stage which goes wrong is reported and then ignored: an agent which cannot
-- be improved is better than a harness which cannot run one
--
-- @param complain   what to do with the errors of a stage, may be nil
-- @return           the run
--
function prepare(run, complain)
    if not scripted(run) then
        return run
    end
    for _, stage in ipairs(_stages()) do
        local value, errors = script[stage.hook](run.definition, run.context,
                                                 stage.args and stage.args(run) or nil)
        _complain(complain, errors)
        if value ~= nil then
            stage.apply(run, value)
        end
    end
    return run
end

-- is the report good enough, according to the agent which wrote it?
--
-- the one which can tell is the one with a shape to its answer: json which has
-- to parse, a claim which has to carry the file it came from. it is the only
-- stage which can send the agent back round, so it is the only one the caller
-- has to do anything about
--
-- @return  the reason it will not do, or nil
--
function review(run, result, complain)
    if not scripted(run) then
        return nil
    end
    local reason, errors = script.validate(run.definition, run.context, result)
    _complain(complain, errors)
    return reason
end

-- send it back round, knowing what was wrong with the last answer
--
-- the wording lives here rather than in the caller because it is part of the
-- bargain `validate` makes: a script which returns a reason is promising the
-- agent will be told it
--
function retry(run, reason)
    run.prompt = string.format(
        "%s\n\nYour previous answer was not accepted: %s\n"
        .. "Answer the task again, and fix that.", run.prompt or "", reason)
    return run
end

-- the last word on the report
function finish(run, result, complain)
    if not scripted(run) then
        return result
    end
    local extra, errors = script.after(run.definition, run.context, result)
    _complain(complain, errors)
    if extra and extra ~= "" then
        result.text = string.format("%s\n\n%s", result.text or "", extra)
    end
    return result
end

-- whatever the run set up, taken down again
--
-- it runs whether the agent finished, failed or was interrupted: a `before`
-- which made a temporary directory has to be able to rely on that
--
function cleanup(run, complain)
    if not scripted(run) then
        return
    end
    _complain(complain, script.cleanup(run.definition, run.context))
end

-- the definition the script decided on
function _applydefine(run, value)
    run.definition = value
    run.context.agent = value
end

-- the tools it decided on
function _applytools(run, value)
    run.definition = table.clone(run.definition)
    run.definition.tools = value
    run.context.agent = run.definition
end

-- what it adds to its own instructions
function _applyprompt(run, value)
    run.definition = table.clone(run.definition)
    run.definition.prompt = string.format("%s\n\n%s", run.definition.prompt or "", value)
    run.context.agent = run.definition
end

-- what it has already found out, added to the task
function _applybefore(run, value)
    run.prompt = string.format("%s\n\n%s", run.prompt or "", value)
end

-- say what went wrong, if anybody is listening
function _complain(complain, errors)
    if errors and complain then
        complain(errors)
    end
end
