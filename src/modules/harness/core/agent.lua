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
-- one `run()` is one turn: it repeats the steps until the model stops asking
-- for the tools.
--
--   turn
--     step
--       assemble the system prompt and the tool schemas
--       agent/request  (waterfall, the plugins may rewrite the request)
--       stream the model response
--       run the tool calls through the guarded pipeline
--     step (again if the tools were called)
--   turn end
--
-- everything the model sees is derived from the session log, so a turn can be
-- resumed, forked or replayed later.
--

-- imports
import("harness.llm.llm")
import("harness.prompt.system")
import("harness.tools.pipeline")
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
    local config = harness:config()
    local ui = opt.ui or {}
    local signal = opt.signal or {aborted = false}
    local mode = opt.mode or (config.permission or {}).mode or "default"
    local agent = opt.agent
    local session = opt.session

    -- the subagents always work in their own session
    if not session then
        session = sessions.new({cwd = harness:rootdir(), title = agent and agent.name or nil})
    end
    if opt.prompt and opt.prompt ~= "" then
        session:append("user", {text = opt.prompt})
    end

    local provider = harnessconfig.provider(config)
    local model = _model(provider, agent, opt)
    local maxsteps = opt.maxsteps or (agent and agent.maxsteps) or 60
    local usage = {input = 0, output = 0, cachehit = 0, cachemiss = 0}
    local lasttext = ""
    local steps = 0
    local errors = nil

    harness:emit("turn/start", {session = session, agent = agent})
    for step = 1, maxsteps do
        if signal.aborted then
            break
        end
        steps = step

        -- compact the context if it is nearly full
        local should, ratio = compact.should(harness, session)
        if should then
            if ui.on_notice then
                ui.on_notice(string.format("compacting the context (%.0f%% used) ..", ratio * 100))
            end
            local summary, compacterrors = compact.run(harness, session, {ontick = ui.ontick})
            if not summary and ui.on_notice then
                ui.on_notice("the compaction failed: " .. tostring(compacterrors))
            end
        end

        -- assemble the request
        local registry = harness:service("tools")
        local req = {
            model = model,
            system = system.build(harness, {agent = agent, mode = mode}),
            messages = session:messages(),
            tools = (opt.notools or config.notools) and {} or registry:schemas(_toolfilter(config, agent)),
            stream = config.stream ~= false,
            maxtokens = config.maxtokens,
            temperature = config.temperature
        }
        req = harness:waterfall("agent/request", req, {session = session, agent = agent, step = step})

        if ui.on_step_start then
            ui.on_step_start({step = step, model = model, messages = #req.messages})
        end

        -- stream the model response
        local result = llm.complete(provider, req, {
            ontext = ui.on_text,
            onreasoning = ui.on_reasoning,
            ontoolcall = ui.on_toolcall_delta,
            onusage = function (result_usage)
                usage.input = usage.input + (result_usage.input or 0)
                usage.output = usage.output + (result_usage.output or 0)
                usage.cachehit = usage.cachehit + (result_usage.cachehit or 0)
                usage.cachemiss = usage.cachemiss + (result_usage.cachemiss or 0)
                session:usage_update(result_usage)
                if ui.on_usage then
                    ui.on_usage(result_usage, session:usage())
                end
            end,
            onretry = function (count, response)
                if ui.on_notice then
                    ui.on_notice(string.format("the request was interrupted (http %d), retrying (%d) ..",
                        response.status or 0, count))
                end
            end,
            ontick = function ()
                if signal.aborted then
                    return false
                end
                if ui.ontick then
                    return ui.ontick()
                end
            end
        })

        if result.aborted or signal.aborted then
            session:append("notice", {text = "the request is interrupted by the user", level = "warn"})
            signal.aborted = true
            break
        end
        if result.errors then
            errors = result.errors
            session:append("notice", {text = errors, level = "error"})
            if ui.on_error then
                ui.on_error(errors)
            end
            break
        end

        -- append the assistant event
        local event = session:append("assistant", {
            text = result.content,
            reasoning = result.reasoning ~= "" and result.reasoning or nil,
            toolcalls = #result.toolcalls > 0 and result.toolcalls or nil,
            model = model
        })
        if result.content ~= "" then
            lasttext = result.content
        end
        if ui.on_assistant then
            ui.on_assistant(event)
        end

        -- no tool calls, the turn is done
        if #result.toolcalls == 0 then
            break
        end

        -- run the tool calls
        local context = {
            harness = harness,
            config = config,
            cwd = harness:rootdir(),
            session = session,
            ui = ui,
            signal = signal,
            mode = mode,
            depth = opt.depth or 0,
            ontick = ui.ontick
        }
        for _, call in ipairs(result.toolcalls) do
            if signal.aborted then
                break
            end
            if ui.on_tool_start then
                ui.on_tool_start(call)
            end
            local toolresult = pipeline.execute(context, call)
            session:append("tool", {
                id = call.id,
                name = call.name,
                arguments = toolresult.args,
                output = toolresult.output,
                iserror = toolresult.iserror,
                duration = toolresult.duration,
                display = toolresult.display
            })
            if ui.on_tool_result then
                ui.on_tool_result(toolresult, call)
            end
        end
        if signal.aborted then
            -- tell the model that the user interrupted it
            session:append("notice", {text = "the user interrupted the tool calls", level = "warn"})
            break
        end
        if steps == maxsteps then
            session:append("notice", {text = "the step limit is reached", level = "warn"})
        end
    end
    harness:emit("turn/end", {session = session, agent = agent, steps = steps})

    if (harness:config().session or {}).save ~= false and not agent then
        session:save()
    end
    return {
        text = lasttext,
        steps = steps,
        usage = usage,
        session = session,
        errors = errors,
        aborted = signal.aborted
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
    if models[name] then
        return models[name]
    end
    return name
end

-- get the tool filter of the given agent
function _toolfilter(config, agent)
    local filter = {without = (config.tools or {}).disabled}
    if agent and agent.tools and #agent.tools > 0 then
        if not table.contains(agent.tools, "*") then
            filter.only = agent.tools
        end
    end
    return filter
end
