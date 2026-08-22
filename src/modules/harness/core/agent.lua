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
-- @file        agent.lua
--

--
-- the agent loop
--
-- one `run()` is one turn, and a turn is one or more steps:
--
--   turn/start
--     step: compact -> assemble -> stream -> run the tool calls
--     step (again while the model keeps calling the tools)
--   turn/end
--
-- everything the model sees is derived from the session log, so a turn can be
-- resumed, forked or replayed later.
--

-- imports
import("harness.llm.llm")
import("harness.prompt.system")
import("harness.tools.runner")
import("harness.context.window")
import("harness.context.compact")
import("harness.core.session", {alias = "sessions"})
import("harness.config.config", {alias = "harnessconfig"})

-- run one turn
--
-- @param harness   the harness context
-- @param opt       the options
--                  - session   the session, a new one is created for the subagents
--                  - prompt    the user input
--                  - agent     the agent definition, for the subagents
--                  - ui        the ui handlers
--                  - signal    the abort signal, e.g. {aborted = false}
--                  - mode      the permission mode
--                  - depth     the subagent depth
--
-- @return          {text = "..", steps = 3, usage = {..}, errors = nil, aborted = false}
--
function run(harness, opt)
    opt = opt or {}
    local turn = _newturn(harness, opt)
    harness:emit("turn/start", {session = turn.session, agent = turn.agent})
    for step = 1, turn.maxsteps do
        if turn.signal.aborted then
            break
        end
        turn.steps = step
        if not _step(harness, turn) then
            break
        end
    end
    harness:emit("turn/end", {session = turn.session, agent = turn.agent, steps = turn.steps})

    if (harness:config().session or {}).save ~= false and not turn.agent then
        turn.session:save()
    end
    return {
        text = turn.lasttext,
        steps = turn.steps,
        usage = turn.usage,
        session = turn.session,
        errors = turn.errors,
        aborted = turn.signal.aborted
    }
end

-- create the state of one turn
function _newturn(harness, opt)
    local config = harness:config()
    local session = opt.session

    -- the subagents always work in their own session
    if not session then
        session = sessions.new({cwd = harness:rootdir(), title = opt.agent and opt.agent.name or nil})
    end
    if opt.prompt and opt.prompt ~= "" then
        session:append("user", {text = opt.prompt})
    end

    local provider = harnessconfig.provider(config)
    return {
        config = config,
        session = session,
        agent = opt.agent,
        ui = opt.ui or {},
        signal = opt.signal or {aborted = false},
        mode = opt.mode or (config.permission or {}).mode or "default",
        depth = opt.depth or 0,
        notools = opt.notools or config.notools,
        provider = provider,
        model = _model(provider, opt.agent, opt),
        maxsteps = opt.maxsteps or (opt.agent and opt.agent.maxsteps) or 60,
        usage = {input = 0, output = 0, cachehit = 0, cachemiss = 0},
        lasttext = "",
        steps = 0
    }
end

-- run one step
--
-- @return  true to continue with another step
--
function _step(harness, turn)
    _compact(harness, turn)

    local req = _request(harness, turn)
    if turn.ui.on_step_start then
        turn.ui.on_step_start({step = turn.steps, model = turn.model, messages = #req.messages})
    end

    local result = llm.complete(turn.provider, req, _handlers(turn))
    if result.aborted or turn.signal.aborted then
        turn.session:append("notice", {text = "the request is interrupted by the user", level = "warn"})
        turn.signal.aborted = true
        return false
    end
    if result.errors then
        turn.errors = result.errors
        turn.session:append("notice", {text = result.errors, level = "error"})
        if turn.ui.on_error then
            turn.ui.on_error(result.errors)
        end
        return false
    end
    return _handle(harness, turn, result)
end

-- compact the context if the window is nearly full
function _compact(harness, turn)
    local should, ratio = compact.should(harness, turn.session)
    if not should then
        return
    end
    if turn.ui.on_notice then
        turn.ui.on_notice(string.format("compacting the context (%.0f%% used) ..", ratio * 100))
    end
    local summary, errors = compact.run(harness, turn.session, {ontick = turn.ui.ontick})
    if not summary and turn.ui.on_notice then
        turn.ui.on_notice("the compaction failed: " .. tostring(errors))
    end
end

-- assemble the request of one step
--
-- the log keeps everything, but the model only sees the optimized projection:
-- the old tool outputs are pruned and the superseded file reads are dropped,
-- @see harness.context.window
--
function _request(harness, turn)
    local messages, stats = window.optimize(harness, turn.session, turn.session:messages())
    if turn.ui.on_context then
        turn.ui.on_context(stats)
    end
    local req = {
        model = turn.model,
        system = system.build(harness, {agent = turn.agent, mode = turn.mode}),
        messages = messages,
        tools = turn.notools and {} or harness:service("tools"):schemas(_toolfilter(turn.config, turn.agent)),
        stream = turn.config.stream ~= false,
        maxtokens = turn.config.maxtokens,
        temperature = turn.config.temperature
    }
    return harness:waterfall("agent/request", req,
        {session = turn.session, agent = turn.agent, step = turn.steps})
end

-- the streaming handlers of one step
function _handlers(turn)
    local ui = turn.ui
    return {
        ontext = ui.on_text,
        onreasoning = ui.on_reasoning,
        ontoolcall = ui.on_toolcall_delta,
        onusage = function (usage)
            turn.usage.input = turn.usage.input + (usage.input or 0)
            turn.usage.output = turn.usage.output + (usage.output or 0)
            turn.usage.cachehit = turn.usage.cachehit + (usage.cachehit or 0)
            turn.usage.cachemiss = turn.usage.cachemiss + (usage.cachemiss or 0)
            turn.session:usage_update(usage)
            if ui.on_usage then
                ui.on_usage(usage, turn.session:usage())
            end
        end,
        onretry = function (count, response)
            if ui.on_notice then
                ui.on_notice(string.format("the request was interrupted (http %d), retrying (%d) ..",
                    response.status or 0, count))
            end
        end,
        ontick = function ()
            if turn.signal.aborted then
                return false
            end
            if ui.ontick then
                return ui.ontick()
            end
        end
    }
end

-- handle the result of one step
--
-- @return  true when the tools were called and the model needs another step
--
function _handle(harness, turn, result)
    local event = turn.session:append("assistant", {
        text = result.content,
        reasoning = result.reasoning ~= "" and result.reasoning or nil,
        toolcalls = #result.toolcalls > 0 and result.toolcalls or nil,
        model = turn.model
    })
    if result.content ~= "" then
        turn.lasttext = result.content
    end
    if turn.ui.on_assistant then
        turn.ui.on_assistant(event)
    end
    if #result.toolcalls == 0 then
        return false
    end

    runner.run(harness, _toolcontext(harness, turn), result.toolcalls, turn.ui, function (call, toolresult)
        turn.session:append("tool", {
            id = call.id,
            name = call.name,
            arguments = toolresult.args,
            output = toolresult.output,
            iserror = toolresult.iserror,
            duration = toolresult.duration,
            display = toolresult.display
        })
        if turn.ui.on_tool_result then
            turn.ui.on_tool_result(toolresult, call)
        end
    end)

    if turn.signal.aborted then
        turn.session:append("notice", {text = "the user interrupted the tool calls", level = "warn"})
        return false
    end
    if turn.steps == turn.maxsteps then
        turn.session:append("notice", {text = "the step limit is reached", level = "warn"})
    end
    return true
end

-- the context which the tools run in
function _toolcontext(harness, turn)
    return {
        harness = harness,
        config = turn.config,
        cwd = harness:rootdir(),
        session = turn.session,
        ui = turn.ui,
        signal = turn.signal,
        mode = turn.mode,
        depth = turn.depth,
        ontick = turn.ui.ontick
    }
end

-- resolve the model of this run
function _model(provider, agent, opt)
    if opt.model then
        return opt.model
    end
    local models = provider.models or {}
    local name = agent and agent.model
    if not name then
        return models.main
    end
    return models[name] or name
end

-- get the tool filter of the given agent
function _toolfilter(config, agent)
    local filter = {without = (config.tools or {}).disabled}
    if agent and agent.tools and #agent.tools > 0 and not table.contains(agent.tools, "*") then
        filter.only = agent.tools
    end
    return filter
end
