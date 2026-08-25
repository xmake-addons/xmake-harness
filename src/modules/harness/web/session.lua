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
-- this module is the state and nothing else. what is done *to* a conversation
-- lives beside it, so that none of it has to know about the rest:
--
--   harness.web.turns     a message, a /command, a !command — one turn each
--   harness.web.ask       the questions a turn stops to put to the browser
--   harness.web.looper    the armed /loop, and what makes it tick
--   harness.web.changes   what this conversation changed, and what to do about it
--

-- imports
import("harness.harness")
import("harness.web.events")
import("harness.web.html")
import("harness.shell.jobs")
import("harness.core.loop")
import("harness.context.compact")
import("harness.permission.policy")
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

-- the background jobs, as the page shows them
--
-- a build started with `background: true` runs on after the turn which started
-- it, and in a terminal it announces itself at the next step. a page can keep
-- the count in view, which is the difference between "it is quiet" and "there
-- are three things running"
--
function running(state)
    local store = state.harness:service("jobs")
    if not store then
        return {}
    end
    local running = {}
    for _, job in ipairs(jobs.list(store)) do
        if job.status == "running" then
            table.insert(running, {id = job.id, label = job.label})
        end
    end
    return running
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

-- wake whatever is waiting on this conversation
--
-- the armed loop waits for a turn to end, @see harness.web.looper. it is posted
-- from here rather than from either of them, so neither has to import the other
--
function wake(state)
    if state.loopwake then
        state.loopwake:post(1)
    end
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
        loop = loopstate(state),
        jobs = running(state),
        todos = state.harness:service("todos") or {},
        title = state.session:title(),
        id = state.session:id(),
        cwd = state.harness:rootdir(),
        project = path.filename(state.harness:rootdir())
    }
end

-- the armed loop, as the page shows it
--
-- it is described here and not by `harness.web.looper` for one reason: the
-- looper runs turns and a turn pushes events through this module, so an import
-- the other way would be a circle. three fields are not worth one.
--
function loopstate(state)
    if not state.loop then
        return {}
    end
    return {
        text = loop.describe(state.loop, os.time()),
        interval = state.loop.interval,
        runs = state.loop.runs,
        prompt = state.loop.prompt
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
