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
-- @file        session.lua
--

--
-- one conversation, and whoever is watching it
--
-- a browser is not a terminal: the page can be closed and reopened, a second
-- tab can be opened beside the first, and neither of those should disturb the
-- agent. so the conversation lives here and the listeners come and go around
-- it, every one of them getting the same events.
--
-- the log stays the source of truth, exactly as in the terminal. a tab which
-- joins halfway through replays what happened from the session rather than
-- from anything kept for it here, so there is one history and not two.
--

-- imports
import("core.base.scheduler")
import("harness.harness")
import("harness.core.agent")
import("harness.context.compact")
import("harness.ui.dialog")
import("harness.permission.policy")
import("harness.web.html")
import("harness.util.text")
import("harness.util.references")
import("harness.web.events")
import("harness.web.commands")
import("harness.core.session", {alias = "sessions"})

-- create the state of one web conversation
function new(harness, opt)
    opt = opt or {}
    return {
        harness = harness,
        session = opt.session or sessions.new({cwd = harness:rootdir()}),
        mode = opt.mode or "acceptedits",
        listeners = {},
        signal = {aborted = false},
        working = false,
        pending = {},
        asked = 0,
        seq = 0
    }
end

-- somebody opened the page
--
-- @param stream  the event stream to push to, @see harness.http.server.stream
-- @return        the id to forget it by
--
function listen(state, stream)
    state.seq = state.seq + 1
    local id = state.seq
    state.listeners[id] = stream
    return id
end

-- and closed it again
function forget(state, id)
    local stream = state.listeners[id]
    state.listeners[id] = nil
    if stream then
        try { function () stream:close() end }
    end
    return true
end

-- push one event to everyone watching
--
-- a listener which has gone away is dropped rather than retried: a browser
-- closes its connection by simply going, and there is no other notice
--
function push(state, name, payload)
    local gone = {}
    for id, stream in pairs(state.listeners) do
        if not stream:send(name, events.encode(payload)) then
            table.insert(gone, id)
        end
    end
    for _, id in ipairs(gone) do
        state.listeners[id] = nil
    end
    return #gone
end

-- is anybody watching?
function watchers(state)
    local count = 0
    for _, _ in pairs(state.listeners) do
        count = count + 1
    end
    return count
end

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
        return _command(state, prompt)
    end

    state.working = true
    state.signal.aborted = false
    push(state, "turn.start", {prompt = prompt})

    -- `@src/main.c` is a file somebody meant to show the model, in a browser
    -- exactly as in a terminal, @see harness.util.references.expand
    local expanded = references.expand(prompt, state.harness:rootdir())

    scheduler.co_start(function ()
        local result
        try {
            function ()
                result = agent.run(state.harness, {
                    session = state.session,
                    prompt = expanded,
                    mode = state.mode,
                    signal = state.signal,
                    ui = _ui(state)})
            end,
            catch {
                function (errs)
                    result = {errors = tostring(errs)}
                    push(state, "error", {text = tostring(errs)})
                end
            }
        }
        state.working = false
        push(state, "turn.end", {
            stop = (result or {}).stop,
            steps = (result or {}).steps,
            usage = state.session:usage()})
    end)
    return true
end

-- run a slash command
--
-- it runs in a coroutine of its own for the same reason a turn does: `/compact`
-- calls a model and `/xmake` runs a build, and a request which waited for
-- either would be timed out long before it finished
--
function _command(state, line)
    state.working = true
    state.signal.aborted = false
    push(state, "turn.start", {prompt = line, command = true})

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
            push(state, result.iserror and "error" or "notice", {text = result.text})
        end
        state.working = false
        push(state, "turn.end", {stop = {code = "command"}, usage = state.session:usage()})

        -- a command which expands to a prompt sends it, which is the whole
        -- point of the markdown commands: `/review` is a prompt with a name
        if result.kind == "prompt" and (result.text or "") ~= "" then
            send(state, result.text)
        end
    end)
    return true
end

-- what a command may do to the page
function _hooks(state)
    return {
        notify = function (text, iserror)
            push(state, iserror and "error" or "notice", {text = text})
        end,
        ask = function (request)
            return _question(state, request)
        end,
        changed = function (what)
            if what == "session" then
                push(state, "session", {id = state.session:id()})
            else
                push(state, "mode", {mode = state.mode})
            end
        end,
        captured = function (program, argv, opt)
            return _captured(state, program, argv, opt)
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
    push(state, "tool.result", {
        name = program and path.filename(program) or "command",
        title = table.concat(table.join({path.filename(program or "")}, argv or {}), " "),
        kind = "output",
        output = text.strip(output),
        iserror = code ~= 0
    })
    return code
end

-- the callbacks one turn reports through
function _ui(state)
    local ui = events.handlers(function (name, payload)
        push(state, name, payload)
    end)
    ui.confirm = function (request)
        return _confirm(state, request)
    end

    -- the window as well as what was pruned from it: a page which showed the
    -- prunings alone would be reporting the housekeeping and not the room left
    local pushcontext = ui.on_context
    ui.on_context = function (stats)
        stats = table.join(stats or {}, context(state))
        pushcontext(stats)
    end

    -- the mode is kept here as well as in the configuration, because the turn
    -- is started with it: a mode which changed mid-turn and was not written
    -- back would last exactly one turn, @see harness.tools.pipeline
    local pushmode = ui.on_mode
    ui.on_mode = function (mode)
        state.mode = mode
        pushmode(mode)
    end
    return ui
end

-- ask the browser, and wait there until it answers
--
-- the turn runs in a coroutine of its own, so waiting for a click costs nothing
-- but that coroutine: it is suspended, and the answer resumes it exactly where
-- it stopped. nothing polls and nothing else in the process is held up — the
-- other tabs keep receiving events while this one has a sheet open.
--
function _confirm(state, request)
    local value = _await(state, function (id)
        return events.ask(id, request)
    end)
    if value == "always" then
        local info = dialog.confirminfo(request.tool or {}, request.args or {})
        return {answer = "always", rule = info.rule}
    elseif value == "allow" then
        return "allow"
    end
    return "the user rejected this tool call, ask them how to continue instead of retrying."
end

-- put a question to the browser and wait there for the answer
--
-- a semaphore and not `co_suspend`/`co_resume`: waiting on one costs nothing
-- until it is posted, and posting it is something another coroutine may do —
-- which is the whole point, because the answer arrives on a different
-- connection than the one the turn is running on
--
-- @param build   build(id) -> the event payload
-- @return        what the browser answered, as a string
--
function _await(state, build)
    state.asked = state.asked + 1
    local id = tostring(state.asked)
    local waiting = {semaphore = scheduler.co_semaphore("harness/web/ask/" .. id, 0)}
    state.pending[id] = waiting

    push(state, "ask", build(id))
    waiting.semaphore:wait(-1)
    state.pending[id] = nil
    push(state, "ask.done", {id = id})
    return waiting.answer
end

-- a question from a command, rather than from a tool call
--
-- the options of a command carry lua values — a session, a boolean, a table —
-- and none of those cross to a browser and back. so what crosses is the number
-- of the option, and the value it stands for is looked up here
--
function _question(state, request)
    local options = request.options or {{text = "Yes", value = true},
                                        {text = "No", value = false}}
    local answer = _await(state, function (id)
        return events.question(id, request, options)
    end)
    local chosen = options[tonumber(answer) or 0]
    return chosen and chosen.value or nil
end

-- somebody clicked
--
-- @return  true, or false when there is nothing waiting for this answer
--
function answer(state, id, value)
    local waiting = state.pending[tostring(id or "")]
    if not waiting then
        return false
    end
    state.pending[tostring(id)] = nil
    waiting.answer = tostring(value or "deny")
    waiting.semaphore:post(1)
    return true
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
        asked = answer(state, id, "deny") or asked
    end
    if not state.working then
        return asked
    end
    state.signal.aborted = true
    return true
end

-- start a new conversation
--
-- @return  true, or nil and the reason
--
function fresh(state)
    if state.working then
        return nil, "the agent is still working, stop it first"
    end
    state.session = sessions.new({cwd = state.harness:rootdir()})
    return true
end

-- forget one conversation
--
-- the one which is open cannot be removed from under itself, so removing it
-- starts a new one first: a page whose conversation had been deleted would be
-- showing a history which no longer exists anywhere
--
-- @return  true, or nil and the reason
--
function remove(state, id)
    if state.working then
        return nil, "the agent is still working, stop it first"
    end
    if not id or id == "" then
        return nil, "which conversation?"
    end
    if id == state.session:id() then
        local ok, errors = fresh(state)
        if not ok then
            return nil, errors
        end
    end
    local ok, errors = sessions.remove(id, state.harness:rootdir())
    if not ok then
        return nil, errors or "it could not be removed"
    end
    return true
end

-- change the permission mode
--
-- the same three the terminal cycles with shift+tab, and the same policy
-- decides what they mean, @see harness.permission.policy
--
-- @return  true, or nil and the reason
--
function mode(state, name)
    for _, known in ipairs(policy.modes()) do
        if known == name then
            state.mode = name
            state.harness:config().permission = state.harness:config().permission or {}
            state.harness:config().permission.mode = name
            return true
        end
    end
    return nil, string.format("`%s` is not a permission mode", tostring(name))
end

-- work on another project
--
-- the harness is bootstrapped again rather than pointed at a new directory: the
-- configuration, the skills and the project's own instructions all come from
-- there, and a harness which changed its mind about where it is halfway through
-- would keep the skills of the last project and the rules of the new one
--
-- @return  true, or nil and the reason
--
function chdir(state, dir)
    if state.working then
        return nil, "the agent is still working, stop it first"
    end
    if not dir or dir:trim() == "" then
        return nil, "there is no directory to change to"
    end
    dir = path.absolute(path.translate(dir:trim()))
    if not os.isdir(dir) then
        return nil, string.format("`%s` is not a directory", dir)
    end
    local instance, errors
    try {
        function ()
            instance = harness.bootstrap({rootdir = dir})
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    if not instance then
        return nil, errors or string.format("`%s` could not be opened", dir)
    end
    state.harness = instance
    state.session = sessions.new({cwd = instance:rootdir()})
    return true
end

-- go back to one which was saved
function resume(state, id)
    if state.working then
        return nil, "the agent is still working, stop it first"
    end
    local session, errors = sessions.load(id, state.harness:rootdir())
    if not session then
        return nil, errors or string.format("session(%s) not found", tostring(id))
    end
    state.session = session
    return true
end

-- what a page needs to draw itself from scratch
--
-- it is the session's own projection of itself, so a tab which joins late shows
-- the same conversation as the one which was there all along
--
function snapshot(state)
    local messages = {}
    for _, event in ipairs(state.session:events()) do
        local message = _message(event)
        if message then
            table.insert(messages, message)
        end
    end
    return {
        messages = messages,
        working = state.working,
        mode = state.mode,
        usage = state.session:usage(),
        context = context(state),
        todos = state.harness:service("todos") or {},
        title = state.session:title(),
        id = state.session:id(),
        cwd = state.harness:rootdir(),
        project = path.filename(state.harness:rootdir())
    }
end

-- how full the context window is
--
-- the same measure the auto-compaction uses, so what the page shows and what
-- the harness acts on are one number, @see harness.context.compact.ratio
--
function context(state)
    local used, size = compact.ratio(state.harness, state.session)
    return {ratio = used, used = math.floor(used * (size or 0)), size = size}
end

-- one logged event, as the page wants it
function _message(event)
    if event.kind == "user" then
        return {role = "user", text = event.text}
    elseif event.kind == "assistant" and (event.text or "") ~= "" then
        return {role = "assistant", text = event.text, html = html.render(event.text)}
    elseif event.kind == "tool" then
        -- the same shape a live tool result crosses in, so a resumed
        -- conversation draws the cards it drew the first time
        local payload = events.toolresult(event, {id = event.id, name = event.name})
        payload.role = "tool"
        return payload
    elseif event.kind == "notice" then
        return {role = "notice", text = event.text, code = event.code}
    end
end
