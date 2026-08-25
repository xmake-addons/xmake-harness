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
-- @file        app.lua
--

--
-- the web application
--
-- it is only the wiring: a route reads a request and calls the conversation,
-- and that is all it does. the http lives in `harness.http.server`, the
-- conversation in `harness.web.session`, the events in `harness.web.events`,
-- the files in `harness.web.assets` — each of them testable without the others.
--
-- the routes:
--
--   GET  /               the page
--   GET  /assets/*       its files
--   GET  /api/state      everything a tab needs to draw itself
--   GET  /api/events     the event stream, held open
--   POST /api/send       a message from the user
--   POST /api/abort      stop what is running
--   GET  /api/sessions   the conversations of this project
--   POST /api/session    start a new one, or go back to an old one
--   GET  /api/commands   the slash commands this harness has
--   GET  /api/files      the project files, for the `@` completion
--   POST /api/session/remove   forget one conversation
--   GET  /api/settings   what the settings page draws
--   POST /api/settings   change one of them
--   POST /api/answer     the answer to a confirmation
--   POST /api/chdir      work on another project
--   POST /api/mode       change the permission mode
--   GET  /api/git        the working tree, as git sees it
--   GET  /api/git/diff   one file's diff, highlighted
--   POST /api/git/revert put one file back
--

-- imports
import("core.base.json")
import("harness.web.assets")
import("harness.web.events")
import("harness.web.session", {alias = "websession"})
import("harness.web.settings", {alias = "websettings"})
import("harness.web.git", {alias = "webgit"})
import("harness.web.commands", {alias = "webcommands"})
import("harness.web.files", {alias = "webfiles"})
import("harness.core.session", {alias = "sessions"})
import("harness.http.server", {alias = "httpserver"})

-- mount the application on a server
function mount(server, state)
    httpserver.route(server, "GET", "/", function (request)
        return assets.page(request, server)
    end)
    -- the files a page is made of are the same for everybody and carry nothing,
    -- and a token on them would have to be threaded through every `import` a
    -- module makes, @see harness.http.server.route
    httpserver.route(server, "GET", "/assets/*", function (request)
        return assets.file(request.path)
    end, {public = true})
    httpserver.route(server, "GET", "/api/sessions", function ()
        return _json({sessions = sessions.list({cwd = state.harness:rootdir(), limit = 50})})
    end)
    httpserver.route(server, "POST", "/api/session", function (request)
        return _session(state, _decode(request.body))
    end)
    httpserver.route(server, "GET", "/api/commands", function ()
        return _json({commands = webcommands.describe(state.harness)})
    end)
    httpserver.route(server, "GET", "/api/files", function (request)
        return _json({files = webfiles.search(state.harness:rootdir(), request.query.q,
                                              {limit = 12})})
    end)
    httpserver.route(server, "GET", "/api/settings", function ()
        return _json(websettings.describe(state.harness))
    end)
    httpserver.route(server, "POST", "/api/settings", function (request)
        local body = _decode(request.body)
        local ok, errors = websettings.set(state.harness, body.key, body.value)
        return _json(ok and {ok = true} or {errors = errors}, ok and 200 or 400)
    end)
    httpserver.route(server, "POST", "/api/answer", function (request)
        local body = _decode(request.body)
        return _json({ok = websession.answer(state, body.id, body.value)})
    end)
    httpserver.route(server, "POST", "/api/mode", function (request)
        local body = _decode(request.body)
        local ok, errors = websession.mode(state, body.mode)
        if not ok then
            return _json({errors = errors}, 400)
        end
        websession.push(state, "mode", {mode = state.mode})
        return _json({ok = true, mode = state.mode})
    end)
    httpserver.route(server, "POST", "/api/chdir", function (request)
        local body = _decode(request.body)
        local ok, errors = websession.chdir(state, body.dir and tostring(body.dir) or nil)
        if not ok then
            return _json({errors = errors}, 400)
        end
        websession.push(state, "session", {id = state.session:id(), cwd = state.harness:rootdir()})
        return _json({ok = true, cwd = state.harness:rootdir()})
    end)
    -- the working tree, as git sees it: nothing here is the agent's memory of
    -- what it did, @see harness.web.git
    httpserver.route(server, "GET", "/api/git", function ()
        return _json(webgit.status(state.harness:rootdir()))
    end)
    httpserver.route(server, "GET", "/api/git/diff", function (request)
        local diff, errors = webgit.filediff(state.harness:rootdir(), request.query.path)
        if not diff then
            return _json({errors = errors}, 400)
        end
        return _json(diff)
    end)
    httpserver.route(server, "POST", "/api/git/revert", function (request)
        local body = _decode(request.body)
        local ok, errors = webgit.revert(state.harness:rootdir(), body.path)
        if not ok then
            return _json({errors = errors}, 400)
        end
        return _json({ok = true})
    end)
    httpserver.route(server, "POST", "/api/session/remove", function (request)
        local body = _decode(request.body)
        local ok, errors = websession.remove(state, body.id and tostring(body.id) or nil)
        if not ok then
            return _json({errors = errors}, 400)
        end
        return _json({ok = true, id = state.session:id()})
    end)
    httpserver.route(server, "GET", "/api/state", function ()
        return _json(websession.snapshot(state))
    end)
    httpserver.route(server, "GET", "/api/events", function (request, response)
        return _events(state, response)
    end)
    httpserver.route(server, "POST", "/api/send", function (request)
        return _send(state, request)
    end)
    httpserver.route(server, "POST", "/api/abort", function ()
        return _json({aborted = websession.abort(state)})
    end)
    return server
end

-- hold the connection open and push events down it
--
-- the handler returns nothing, which tells the http layer that this connection
-- is no longer its business, @see harness.http.server
--
function _events(state, response)
    local stream = httpserver.stream(response.client)
    local id = websession.listen(state, stream)

    -- say hello, so the page knows the stream is live rather than merely
    -- connected, and can stop showing itself as reconnecting
    stream:send("ready", "{}")

    -- the connection is kept by holding this coroutine: the browser going away
    -- is only visible as a write which fails, so it is a write which finds out
    while stream.open and state.listeners[id] do
        os.sleep(15000)
        -- a comment line keeps the connection warm through anything in the
        -- middle which times out an idle socket, and is ignored by EventSource
        if not stream:send("ping", "{}") then
            break
        end
    end
    websession.forget(state, id)
    return nil
end

-- a message from the user
function _send(state, request)
    local body = _decode(request.body)
    local ok, errors = websession.send(state, body.prompt)
    if not ok then
        return _json({errors = errors}, 400)
    end
    return _json({ok = true})
end

-- start a new conversation, or go back to an old one
--
-- the page is told to redraw rather than sent the new state in the answer: the
-- other tabs are looking at the same conversation and have to move with it
--
function _session(state, body)
    local ok, errors
    if body.fresh then
        ok, errors = websession.fresh(state)
    elseif body.id then
        ok, errors = websession.resume(state, tostring(body.id))
    else
        return _json({errors = "which conversation?"}, 400)
    end
    if not ok then
        return _json({errors = errors}, 400)
    end
    websession.push(state, "session", {id = state.session:id()})
    return _json({ok = true, id = state.session:id()})
end

-- a json response
-- it goes out through the event encoder and not through `json.encode`, so an
-- answer and an event agree about what a list is, @see harness.web.events.encode
function _json(payload, status)
    return {status = status or 200, contenttype = "application/json; charset=utf-8",
            content = events.encode(payload)}
end

-- a json request body, whatever arrives
function _decode(body)
    local payload = try { function () return json.decode(body or "") end }
    return type(payload) == "table" and payload or {}
end
