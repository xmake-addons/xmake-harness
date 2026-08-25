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
import("harness.ui.dialog")
import("harness.web.html")
import("harness.web.events")
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

    state.working = true
    state.signal.aborted = false
    push(state, "turn.start", {prompt = prompt})

    scheduler.co_start(function ()
        local result
        try {
            function ()
                result = agent.run(state.harness, {
                    session = state.session,
                    prompt = prompt,
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

-- the callbacks one turn reports through
function _ui(state)
    local ui = events.handlers(function (name, payload)
        push(state, name, payload)
    end)
    ui.confirm = function (request)
        return _confirm(state, request)
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
    state.asked = state.asked + 1
    local id = tostring(state.asked)

    -- a semaphore and not `co_suspend`/`co_resume`: waiting on one costs
    -- nothing until it is posted, and posting it is something another
    -- coroutine may do — which is the whole point, because the answer arrives
    -- on a different connection than the one the turn is running on
    local waiting = {semaphore = scheduler.co_semaphore("harness/web/ask/" .. id, 0)}
    state.pending[id] = waiting

    push(state, "ask", events.ask(id, request))
    waiting.semaphore:wait(-1)
    local value = waiting.answer
    state.pending[id] = nil
    push(state, "ask.done", {id = id})

    if value == "always" then
        local info = dialog.confirminfo(request.tool or {}, request.args or {})
        return {answer = "always", rule = info.rule}
    elseif value == "allow" then
        return "allow"
    end
    return "the user rejected this tool call, ask them how to continue instead of retrying."
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
        title = state.session:title(),
        id = state.session:id(),
        cwd = state.harness:rootdir()
    }
end

-- one logged event, as the page wants it
function _message(event)
    if event.kind == "user" then
        return {role = "user", text = event.text}
    elseif event.kind == "assistant" and (event.text or "") ~= "" then
        return {role = "assistant", text = event.text, html = html.render(event.text)}
    elseif event.kind == "tool" then
        return {role = "tool", name = event.name, iserror = event.iserror,
                output = event.output, path = (event.arguments or {}).path}
    elseif event.kind == "notice" then
        return {role = "notice", text = event.text, code = event.code}
    end
end
