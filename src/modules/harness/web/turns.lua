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
-- @file        turns.lua
--

--
-- one turn of a conversation, whatever started it
--
-- three things reach the model or the machine from a browser, and they all
-- arrive through the same box:
--
--   a message      the model answers it, @see harness.core.agent
--   /a command     it runs here, and only a prompt it returns reaches a model
--   !a command     the shell runs it, and the model is told what it printed
--
-- what they have in common is a turn: it says it started, it reports what
-- happens, and it says it ended. the page draws all three the same way because
-- they are the same thing.
--

-- imports
import("core.base.scheduler")
import("harness.util.text")
import("harness.util.references")
import("harness.core.agent")
import("harness.web.ask")
import("harness.web.looper")
import("harness.web.events")
import("harness.web.commands")
import("harness.web.session", {alias = "websession"})

-- send a prompt and let the turn run
--
-- it returns as soon as the turn has started, not when it ends: the browser is
-- told what happens through the event stream, and a request which waited for
-- the whole turn would time out long before a build does
--
-- @return  true, or nil and the reason
--
function send(state, prompt)
    if state.working then
        return nil, "the agent is still working on the last message"
    end
    if not prompt or prompt:trim() == "" then
        return nil, "there is nothing to send"
    end

    -- a slash command is not a message to the model: it runs here, and only
    -- what it hands back as a prompt reaches one, @see harness.web.commands
    prompt = prompt:trim()
    if commands.iscommand(prompt) then
        return command(state, prompt)
    end

    -- `!xmake build` runs a command, as it does in the terminal. what it
    -- printed goes into the conversation for the model to read afterwards,
    -- because the reason to run one is usually the question which follows it
    if prompt:startswith("!") and prompt:trim() ~= "!" then
        return shell(state, prompt:sub(2):trim())
    end

    scheduler.co_start(function ()
        turn(state, prompt)
    end)
    return true
end

-- one turn, in the coroutine which is already running
--
-- `send` starts one of these and returns; the loop runs one and waits for it,
-- because the next iteration is scheduled from the moment this one ended,
-- @see harness.core.loop.finished
--
-- @return  the turn result
--
function turn(state, prompt)
    state.working = true
    state.signal.aborted = false
    websession.push(state, "turn.start", {prompt = prompt})

    -- `@src/main.c` is a file somebody meant to show the model, in a browser
    -- exactly as in a terminal, @see harness.util.references.expand
    local expanded = references.expand(prompt, state.harness:rootdir())

    local result
    try {
        function ()
            result = agent.run(state.harness, {
                session = state.session,
                prompt = expanded,
                mode = state.mode,
                signal = state.signal,
                ui = ui(state)})
        end,
        catch {
            function (errs)
                result = {errors = tostring(errs)}
                websession.push(state, "error", {text = tostring(errs)})
            end
        }
    }
    state.working = false
    websession.push(state, "turn.end", {
        stop = (result or {}).stop,
        steps = (result or {}).steps,
        usage = state.session:usage()})

    websession.push(state, "jobs", {jobs = websession.running(state)})

    -- an armed loop is waiting for exactly this, @see harness.web.looper
    websession.wake(state)
    return result or {}
end

-- stop what is running
--
-- a turn which is sitting on a question is not going to notice a flag, so the
-- questions are answered for it: refused, which is what a user pressing stop
-- while a sheet is open means
--
function abort(state)
    local asked = false
    for id, _ in pairs(state.pending) do
        asked = ask.answer(state, id, "deny") or asked
    end
    if not state.working then
        return asked
    end
    state.signal.aborted = true
    return true
end

-- run a slash command
--
-- it runs in a coroutine of its own for the same reason a turn does: `/compact`
-- calls a model and `/xmake` runs a build, and a request which waited for
-- either would be timed out long before it finished
--
function command(state, line)
    state.working = true
    state.signal.aborted = false
    websession.push(state, "turn.start", {prompt = line, command = true})

    scheduler.co_start(function ()
        local result
        try {
            function ()
                result = commands.run(state, line, _hooks(state))
            end,
            catch {
                function (errs)
                    result = {kind = "message", text = tostring(errs), iserror = true}
                end
            }
        }
        result = result or {kind = "none"}
        if result.kind == "message" and (result.text or "") ~= "" then
            websession.push(state, result.iserror and "error" or "notice", {text = result.text})
        end
        state.working = false
        websession.push(state, "turn.end", {stop = {code = "command"}, usage = state.session:usage()})

        -- a command which expands to a prompt sends it, which is the whole
        -- point of the markdown commands: `/review` is a prompt with a name
        if result.kind == "prompt" and (result.text or "") ~= "" then
            send(state, result.text)
        end
    end)
    return true
end

-- run a shell command the user typed
function shell(state, commandline)
    state.working = true
    state.signal.aborted = false
    websession.push(state, "turn.start", {prompt = "!" .. commandline, command = true})

    scheduler.co_start(function ()
        local tool = state.harness:service("tools"):get("run_command")
        local result
        if not tool then
            result = {output = "this harness has no shell tool", iserror = true}
        else
            -- the same context the terminal builds for it, and the same mode:
            -- the user typed this command themselves, so there is nobody left
            -- to ask about it, @see harness.ui.app
            local context = {harness = state.harness, config = state.harness:config(),
                             cwd = state.harness:rootdir(), session = state.session,
                             ui = ui(state), signal = state.signal, mode = "bypass"}
            try {
                function ()
                    result = tool.run(context, {command = commandline})
                end,
                catch {
                    function (errs)
                        result = {output = tostring(errs), iserror = true}
                    end
                }
            }
        end
        result = result or {}
        websession.push(state, "tool.result", {name = "run_command", title = commandline,
                                    kind = "output", output = text.strip(result.output),
                                    iserror = result.iserror or false})

        -- the model was not watching, so it is told what happened, exactly as
        -- the terminal ui does it, @see harness.ui.app
        state.session:append("user", {text = string.format(
            "I ran `%s` in the terminal, the output was:\n\n%s", commandline, result.output or "")})
        try { function () state.session:save() end }

        state.working = false
        websession.push(state, "turn.end", {stop = {code = "command"}, usage = state.session:usage()})
    end)
    return true
end

-- what a command may do to the page
function _hooks(state)
    return {
        notify = function (text, iserror)
            websession.push(state, iserror and "error" or "notice", {text = text})
        end,
        ask = function (request)
            return ask.question(state, request)
        end,
        changed = function (what)
            if what == "session" then
                websession.push(state, "session", {id = state.session:id()})
            else
                websession.push(state, "mode", {mode = state.mode})
            end
        end,
        captured = function (program, argv, opt)
            return _captured(state, program, argv, opt)
        end,
        loop = function (armed)
            if armed then
                looper.arm(state, turn)
            elseif state.loopwake then
                websession.wake(state)
            end
            websession.push(state, "loop", websession.loopstate(state))
        end
    }
end

-- run a program and put what it printed into the conversation
function _captured(state, program, argv, opt)
    local code, output
    try {
        function ()
            local outdata, errdata = os.iorunv(program, argv, table.join(opt or {}, {try = true}))
            output = (outdata or "") .. (errdata or "")
            code = 0
        end,
        catch {
            function (errs)
                output = tostring(errs)
                code = 1
            end
        }
    }
    -- a program writes for a terminal and colours what it says: the escape
    -- codes are noise in a document, and the page is not a terminal
    websession.push(state, "tool.result", {
        name = program and path.filename(program) or "command",
        title = table.concat(table.join({path.filename(program or "")}, argv or {}), " "),
        kind = "output",
        output = text.strip(output),
        iserror = code ~= 0
    })
    return code
end

-- the callbacks one turn reports through
function ui(state)
    local handlers = events.handlers(function (name, payload)
        websession.push(state, name, payload)
    end)
    handlers.confirm = function (request)
        return ask.confirm(state, request)
    end

    -- the window as well as what was pruned from it: a page which showed the
    -- prunings alone would be reporting the housekeeping and not the room left
    local pushcontext = handlers.on_context
    handlers.on_context = function (stats)
        pushcontext(table.join(stats or {}, websession.context(state)))
    end

    -- the mode is kept here as well as in the configuration, because the turn
    -- is started with it: a mode which changed mid-turn and was not written
    -- back would last exactly one turn, @see harness.tools.pipeline
    local pushmode = handlers.on_mode
    handlers.on_mode = function (mode)
        state.mode = mode
        pushmode(mode)
    end
    return handlers
end
