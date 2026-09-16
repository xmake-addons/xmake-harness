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
-- @file        subagent.lua
--

--
-- spawn one subagent
--
-- a subagent is the same agent loop with another identity: its own system
-- prompt, its own tools, its own context window, and its own session. only its
-- final report comes back, which is the whole point — a wide search costs the
-- caller one paragraph instead of forty file reads.
--
-- both the `run_agent` tool and the agent graph come through here, so the depth
-- limit, the abort signal and the ui nesting are decided in one place.
--

-- imports
import("harness.agents.lifecycle")

-- how many times an agent which rejected its own report may try again
--
-- only an agent which exports `validate` can reject one, and only once: a
-- second answer it also refuses is an agent arguing with itself at full price,
-- @see harness.agents.lifecycle
--
local MAXRETRY = 1

-- how deep the delegation may go
--
-- an agent which delegates to an agent which delegates is usually a plan the
-- model has lost track of, and every level multiplies the cost
--
local MAXDEPTH = 3

-- resolve an agent by name
--
-- @return  the definition, or nil and the message which lists what does exist
--
function resolve(harness, name)
    local agents = harness:service("agents")
    local definition = agents and agents:get(name)
    if definition then
        return definition
    end
    local names = {}
    for _, item in ipairs(agents and agents:all() or {}) do
        table.insert(names, item.name)
    end
    return nil, string.format("the agent(%s) does not exist! the available agents: %s",
        tostring(name), table.concat(names, ", "))
end

-- spawn a subagent and wait for its report
--
-- @param opt   - agent         the agent definition, @see resolve()
--              - prompt        the complete task
--              - description   a short label for the ui
--
-- @return      {text, usage, steps, errors}
--
function spawn(context, opt)
    local depth = (context.depth or 0) + 1
    if depth > MAXDEPTH then
        raise("the subagent nesting is too deep, do this task yourself.")
    end

    local ui = context.ui and context.ui.subagent
        and context.ui.subagent(opt.agent, {description = opt.description}) or nil

    -- an agent may be more than a prompt, @see harness.agents.lifecycle: it can
    -- decide its own tools, add to its own instructions, do the work its first
    -- three steps would always have done anyway, and refuse its own report
    local run = lifecycle.new({
        definition = opt.agent,
        prompt = opt.prompt,
        context = _context(opt.agent, opt, context, ui, depth)})

    local function complain(errors)
        if errors and ui and ui.on_notice then
            ui.on_notice(errors)
        end
    end

    local result, errors
    try {
        function ()
            lifecycle.prepare(run, complain)
            result = _attempt(context, run, depth, ui, complain)
            lifecycle.finish(run, result, complain)
        end,
        catch {
            -- caught only so that the cleanup can run before it carries on up:
            -- `try` without a `catch` swallows it, and a subagent which failed
            -- silently is one the caller reports as having said nothing
            function (errs)
                errors = errs
            end
        },
        finally {
            -- whether it finished, failed or was interrupted: a `before` which
            -- made a temporary directory has to be able to rely on this
            function ()
                lifecycle.cleanup(run, complain)
            end
        }
    }
    if errors then
        raise(errors)
    end
    return result
end

-- run it, and run it again if it says its own answer will not do
function _attempt(context, run, depth, ui, complain)
    local result = _runloop(context, run, depth, ui)
    for _ = 1, MAXRETRY do
        local reason = lifecycle.review(run, result, complain)
        if not reason then
            break
        end
        lifecycle.retry(run, reason)
        result = _runloop(context, run, depth, ui)
    end
    return result
end

-- one turn of the agent loop, with the identity the run settled on
function _runloop(context, run, depth, ui)
    local agentloop = import("harness.core.agent", {anonymous = true})
    return agentloop.run(context.harness, {
        agent = run.definition,
        prompt = run.prompt,
        depth = depth,
        parent = context,
        signal = context.signal,
        ui = ui})
end

-- what an agent's own lua is given
function _context(definition, opt, context, ui, depth)
    return {
        harness = context.harness,
        agent = definition,
        prompt = opt.prompt,
        description = opt.description,
        cwd = context.cwd,
        progress = ui and ui.progress or nil,
        depth = depth
    }
end

-- how many tokens a report cost
function tokensof(result)
    local usage = (result or {}).usage or {}
    return (usage.input or 0) + (usage.output or 0)
end
