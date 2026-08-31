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
import("harness.util.tokens")
import("harness.prompt.system")
import("harness.core.guards")
import("harness.shell.jobs")
import("harness.tools.runner")
import("harness.context.window")
import("harness.context.invariant")
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
        local more = _step(harness, turn)
        _persist(harness, turn)
        if not more then
            break
        end
    end
    harness:emit("turn/end", {session = turn.session, agent = turn.agent, steps = turn.steps})

    _persist(harness, turn)
    return {
        text = turn.lasttext,
        stop = turn.stop,
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
        steps = 0,
        guards = guards.new(config),
        tried = {}
    }
end

-- tell the model about the background jobs which finished
--
-- a job settles whenever it settles, which is usually while the model is busy
-- with something else. nobody is watching it then, so the next step begins by
-- saying so — a result nobody is told about is a result nobody uses
--
function _announcejobs(harness, turn)
    local store = harness:service("jobs")
    if not store then
        return
    end
    for _, job in ipairs(jobs.pending(store)) do
        jobs.reported(job)
        local notice = string.format("Background job %s (%s) finished: %s.\n"
            .. "Read what it printed with job_output(%s).", job.id, job.label, jobs.status(job), job.id)
        turn.session:append("user", {text = notice, kind = "notice"})
        if turn.ui.on_notice then
            turn.ui.on_notice(string.format("background job %s finished: %s", job.id, jobs.status(job)))
        end
    end
end

-- write the session out
--
-- after every step, not only at the end of the turn. a turn which repairs a
-- build can run for twenty steps, and if anything takes the session down before
-- it finishes — a crash, a kill, a laptop lid — all of it is gone. the file is
-- small and the step just spent seconds talking to a model, so the write costs
-- nothing worth measuring
--
-- a subagent has its own throwaway session and nothing to keep
--
function _persist(harness, turn)
    if turn.agent or (harness:config().session or {}).save == false then
        return
    end
    turn.session:save()
end

-- run one step
--
-- @return  true to continue with another step
--
function _step(harness, turn)
    _announcejobs(harness, turn)
    _compact(harness, turn)

    local req = _request(harness, turn)
    if turn.ui.on_step_start then
        turn.ui.on_step_start({step = turn.steps, model = turn.model, messages = #req.messages})
    end

    -- what we think we are sending, so the estimator can be calibrated against
    -- what the provider really counted
    turn.sent = tokens.estimate_messages(req.messages) + tokens.estimate(req.system)
        + tokens.estimate_tools(req.tools)

    local result = _complete(harness, turn, req)
    if result.aborted or turn.signal.aborted then
        turn.session:append("notice", {text = "the request is interrupted by the user", level = "warn"})
        turn.signal.aborted = true
        _setstop(turn, "aborted", "the request is interrupted by the user")
        return false
    end
    if result.errors then
        turn.errors = result.errors
        _setstop(turn, "error", result.errors)
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
        -- "of the window" and not "used", because it goes past a hundred: what
        -- is measured is the whole conversation against what fits, and the
        -- reason to compact is precisely that the first is bigger than the
        -- second. what is *sent* never goes over, @see harness.context.window
        turn.ui.on_notice(string.format("compacting the context (%.0f%% of the window) ..",
                                        ratio * 100))
    end
    local summary, errors = compact.run(harness, turn.session, {ontick = turn.ui.ontick})
    if not summary and turn.ui.on_notice then
        turn.ui.on_notice("the compaction failed: " .. tostring(errors))
    end
end

-- ask the model, and ask somebody else if the first one cannot answer
--
-- one provider having a bad afternoon should not end the conversation. the
-- retries inside `llm.complete` cover a cut stream or a moment of throttling on
-- the same service; this covers the service itself being unreachable, out of
-- quota, or holding a key which no longer works.
--
-- only failures another provider could plausibly do better on are worth moving
-- for. a request the service rejected as malformed is our mistake and will be
-- rejected identically everywhere, so it is reported rather than repeated,
-- @see harness.llm.llm.isretryable
--
-- the fallback provider brings its own models: the tier is resolved again
-- against it, because `deepseek-chat` means nothing to anthropic
--
function _complete(harness, turn, req)
    local result = llm.complete(turn.provider, req, _handlers(turn))
    if not result.errors or turn.signal.aborted or not llm.isretryable(result.errorcode) then
        return result
    end

    for _, name in ipairs(_fallbacks(turn)) do
        local provider = harnessconfig.provider(turn.config, name)
        if provider then
            local text = string.format("the provider(%s) failed: %s\ntrying %s instead ..",
                turn.provider.name or "?", result.errorcode, name)
            turn.session:append("notice", {text = text, level = "warn", code = "provider-failover"})
            if turn.ui.on_notice then
                turn.ui.on_notice(text)
            end

            req.model = _model(provider, turn.agent, {})
            local next_result = llm.complete(provider, req, _handlers(turn))
            if not next_result.errors or not llm.isretryable(next_result.errorcode) then
                -- from here on this turn belongs to whoever answered
                turn.provider = provider
                turn.model = req.model
                return next_result
            end
            result = next_result
        end
    end
    return result
end

-- the providers to try when the current one cannot answer
--
-- they are named by the user, never guessed: a key the user configured for one
-- service is not permission to spend it on another
--
function _fallbacks(turn)
    local names = {}
    for _, name in ipairs(turn.provider.fallback or turn.config.fallback or {}) do
        if name ~= (turn.provider.name or "") and not turn.tried[name] then
            turn.tried[name] = true
            table.insert(names, name)
        end
    end
    return names
end

-- is what we are about to send still a conversation?
--
-- the projection is four transformations away from the log — pruned, compacted,
-- truncated, and sometimes cut off at the front — and each of them can produce
-- something which is no longer well formed. the model does not complain about
-- that: it answers about work it cannot see, and we read it as the model
-- getting worse, @see harness.context.invariant
--
-- it is said out loud and the request goes anyway. refusing to send would turn
-- a bug of ours into a dead session, and the provider will reject it by itself
-- if it is fatal
--
function _checkprojection(turn, messages)
    local violations = invariant.check(messages)
    if #violations == 0 then
        return
    end
    local text = invariant.describe(violations)
    turn.session:append("notice", {text = text, level = "error", code = violations[1].code})
    if turn.ui.on_notice then
        turn.ui.on_notice(text)
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
    _checkprojection(turn, messages)
    local req = {
        model = turn.model,
        system = system.build(harness, {agent = turn.agent, mode = turn.mode, session = turn.session}),
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
            -- the real prompt tokens tighten the estimator, @see harness.util.tokens
            if usage.input and turn.sent then
                tokens.observe(turn.model, turn.sent, usage.input)
            end
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
            -- a retry says nothing about the work and everything about the
            -- line, and it repeats: five of them printed one after another is
            -- five lines of the answer somebody wanted pushed off the screen.
            -- so it goes to whatever the front end uses for "what is happening
            -- right now", which is replaced rather than appended
            if ui.on_retry then
                ui.on_retry(count, response)
            elseif ui.on_notice then
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
    -- nothing more was asked for: the model considers itself finished
    if #result.toolcalls == 0 then
        _setstop(turn, "done", "the model has nothing more to do")
        return false
    end

    -- the same round of calls again and again means it is stuck
    local stuck = guards.repeated(turn.guards, result.toolcalls)

    local failures = 0
    local count = 0
    local results = {}
    runner.run(harness, _toolcontext(harness, turn), result.toolcalls, turn.ui, function (call, toolresult)
        count = count + 1
        if toolresult.iserror then
            failures = failures + 1
        end
        table.insert(results, {name = call.name, output = toolresult.output,
                               iserror = toolresult.iserror})
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
        _setstop(turn, "aborted", "the user interrupted the tool calls")
        return false
    end
    if stuck then
        return _stop(turn, stuck)
    end
    local failing = guards.progressing(turn.guards, count, failures)
    if failing then
        return _stop(turn, failing)
    end
    -- a search which finds nothing, rephrased and tried again, is a loop the
    -- repeat guard cannot see: every round is different, @see harness.core.guards
    local empty = guards.fruitless(turn.guards, results)
    if empty then
        return _stop(turn, empty)
    end
    -- there is still work in hand, we simply ran out of steps to do it in
    if turn.steps == turn.maxsteps then
        local text = string.format("the step limit of %d is reached with work still to do", turn.maxsteps)
        turn.session:append("notice", {text = text, level = "warn", code = "step-budget"})
        _setstop(turn, "step-budget", text)
    end
    return true
end

-- why did this turn end?
--
-- every ending gets a code as well as a sentence. the sentence is for whoever
-- reads the screen; the code is for whatever decides what to do next — a
-- repeating task which should keep going after a step budget but not after the
-- model said it was finished, a report which counts how often the agent gets
-- stuck, a test which asserts the reason rather than matching prose
--
-- the codes:
--
--   done                  the model asked for nothing more, the ordinary ending
--   step-budget           it ran out of steps with work still in hand
--   repeated-tool-calls   it asked for the same thing until a guard stopped it
--   all-tools-failed      nothing it tried worked, three rounds running
--   aborted               the user interrupted it
--   error                 the request itself failed
--
function _setstop(turn, code, text)
    turn.stop = {code = code, text = text}
    return turn.stop
end

-- stop the turn and tell the model why
--
-- the reason goes into the log as a notice and into the next request as a user
-- message, so a session which continues afterwards knows what happened
--
function _stop(turn, stop)
    _setstop(turn, stop.code, stop.text)
    turn.session:append("notice", {text = stop.text, level = "warn", code = stop.code})
    turn.session:append("user", {text = "[the harness stopped this turn] " .. stop.text})
    if turn.ui.on_notice then
        turn.ui.on_notice(stop.text)
    end
    return false
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
--
-- the tiers exist to spend the big model where it matters: an agent which only
-- reads and reports (an explorer, a summarizer) does its job with the small one
-- and costs a fraction, while the agent which writes the code gets the main one
--
function _model(provider, agent, opt)
    if opt.model then
        return opt.model
    end
    local models = provider.models or {}
    if not agent then
        return models.main
    end
    if agent.model then
        return models[agent.model] or agent.model
    end
    return models[_tier(agent)] or models.main
end

-- the default tier of an agent
--
-- an agent which cannot change anything is a reader: it explores, it searches,
-- it reports back. that is what the small model is for
--
function _tier(agent)
    for _, name in ipairs(agent.tools or {}) do
        if not _isreadonly(name) then
            return "main"
        end
    end
    return (agent.tools and #agent.tools > 0) and "small" or "main"
end

-- is the given tool read-only?
function _isreadonly(name)
    local readonly = {
        read_file = true, list_dir = true, glob_files = true, search_text = true,
        use_skill = true, fetch_url = true, xmake_show = true, xmake_docs = true
    }
    return readonly[name] or false
end

-- get the tool filter of the given agent
function _toolfilter(config, agent)
    local filter = {without = (config.tools or {}).disabled}
    if agent and agent.tools and #agent.tools > 0 and not table.contains(agent.tools, "*") then
        filter.only = agent.tools
    end
    return filter
end
