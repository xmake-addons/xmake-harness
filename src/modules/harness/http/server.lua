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
-- @file        server.lua
--

--
-- a small http server
--
-- enough of http to put a browser in front of the harness and nothing more: a
-- request line, headers, a body, a response, and a held connection for the
-- events which arrive while the agent works. no third party, no build step —
-- the same runtime which runs the agent serves the page.
--
-- three things about the sockets, each learned the hard way:
--
--   accept is blocking and never polled. calling it with a timeout in a loop
--   re-registers the listening socket on the poller every time round, and the
--   connections stop arriving. one coroutine sits in `accept()` and waits.
--
--   reading is a non-blocking `recv` plus a wait on EV_RECV, which is how
--   xmake's own service reads a socket, @see private/service/stream.lua. it is
--   not a matter of taste: `recv` with `block = true` waits for *exactly* the
--   size asked for, and a request is however long it happens to be.
--
--   every connection gets its own coroutine. a held event stream must not stop
--   the next request from being served, and the scheduler is what makes that
--   free rather than a thread.
--
-- it binds to the loopback and demands a token. a server which can edit files
-- and run commands is not something to leave open on a shared machine, and a
-- page in another tab can reach `127.0.0.1` just as well as the user can.
--

-- imports
import("core.base.bytes")
import("core.base.socket")
import("core.base.scheduler")

-- how long one request may take to arrive
local READTIMEOUT = 10000

-- the most a request body may carry
local MAXBODY = 8 * 1024 * 1024

-- the types we serve
local MIMETYPES = {
    html = "text/html; charset=utf-8", js = "text/javascript; charset=utf-8",
    css = "text/css; charset=utf-8", json = "application/json; charset=utf-8",
    svg = "image/svg+xml", png = "image/png", ico = "image/x-icon",
    woff2 = "font/woff2", map = "application/json"
}

-- create a server
--
-- @param opt   - addr    where to bind, the loopback by default
--              - port    the port, the first free one from here
--              - token   the secret every request must carry
--
function new(opt)
    opt = opt or {}
    return {
        addr = opt.addr or "127.0.0.1",
        port = opt.port or 9736,
        token = opt.token,
        routes = {},
        running = false
    }
end

-- answer `method path` with `handler(request)`
--
-- the handler returns `{status = 200, content = "..", contenttype = ".."}`, or
-- takes over the connection itself for an event stream, @see stream()
--
-- @param opt   - public   no token required, for the files a page is made of
--
function route(server, method, path, handler, opt)
    table.insert(server.routes, {method = method:upper(), path = path, handler = handler,
                                 public = (opt or {}).public})
    return server
end

-- start listening
--
-- @return  the port it took, or nil and the reason
--
function start(server)
    local listener, port = _bind(server)
    if not listener then
        return nil, port
    end
    server.listener = listener
    server.port = port
    server.running = true

    scheduler.co_start(function ()
        while server.running do
            -- blocking, never polled: see the note at the top
            local client = listener:accept()
            if not client then
                break
            end
            -- the knock which woke us, @see stop(): it is not a request and
            -- reading one out of it would hold the process open until it timed
            -- out, which is the very thing stopping is supposed to end
            if not server.running then
                try { function () client:close() end }
                break
            end
            scheduler.co_start(function ()
                try { function () _serve(server, client) end }
                try { function () client:close() end }
            end)
        end
        try { function () listener:close() end }
    end)
    return port
end

-- stop listening
--
-- the connections which are still open are left to finish: an event stream cut
-- off mid-answer looks to the browser exactly like a crash
--
function stop(server)
    server.running = false
    local listener = server.listener
    if not listener then
        return true
    end
    server.listener = nil

    -- knock on our own door
    --
    -- the accept coroutine is suspended inside the poller, and neither killing
    -- the socket nor closing it under the coroutine reliably surfaces there —
    -- it sits waiting, and a process does not exit while a coroutine of its own
    -- is still waiting on something. a connection always surfaces, so we make
    -- one: accept returns it, the loop sees that we have stopped, and both the
    -- connection and the listener are closed on the way out
    local knocked = try {
        function ()
            local knock = socket.tcp()
            local connected = knock:connect(server.addr, server.port, {timeout = 1000})
            knock:close()
            return connected and connected > 0
        end
    }

    -- nobody answered the door, so there is nothing waiting on it either
    if not knocked then
        try { function () listener:kill() end }
        try { function () listener:close() end }
    end
    return true
end

-- take the first free port from the one asked for
function _bind(server)
    local errors = nil
    for port = server.port, server.port + 32 do
        local listener = try { function () return socket.bind(server.addr, port) end }
        if listener then
            local ok = try { function () listener:listen(64) return true end }
            if ok then
                return listener, port
            end
            try { function () listener:close() end }
        end
        errors = string.format("cannot bind %s:%d", server.addr, port)
    end
    return nil, errors or "cannot bind"
end

-- serve one connection
function _serve(server, client)
    local request = _read(client)
    if not request then
        return _respond(client, 400, "text/plain", "bad request")
    end

    local handler, entry = _match(server, request)
    if not handler then
        return _respond(client, 404, "text/plain", "not found")
    end

    -- the stylesheet and the scripts are the same for everybody and carry
    -- nothing: asking them for a token would mean threading one through every
    -- `import` a module makes, and buy nothing for it. everything which can
    -- read or change something is behind the check
    -- a request which says where it came from, and it was not from here
    --
    -- the cookie is `SameSite=Strict`, so a browser does not attach it to a
    -- request another site made — but a page can still *make* the request, and
    -- a check which costs one string comparison is worth having behind the one
    -- which relies on every browser getting a rule right
    if not _sameorigin(server, request) then
        return _respond(client, 403, "text/plain", "forbidden")
    end
    if server.token and not entry.public and not _authorized(server, request) then
        -- say as little as possible: this is the one answer an unwelcome caller
        -- gets, and it should not describe what is behind it
        return _respond(client, 403, "text/plain", "forbidden")
    end

    local result = handler(request, {client = client, server = server})
    if result == nil then
        -- the handler took the connection over, e.g. an event stream
        return
    end
    return _respond(client, result.status or 200, result.contenttype or "text/plain",
        result.content or "", result.headers)
end

-- did this request come from the page we serve?
--
-- `Origin` is set by the browser itself and cannot be forged by the page which
-- sends it. it is absent on an ordinary navigation and on anything which is not
-- a browser, and absent is not suspicious: the token is what actually guards
-- this, @see _authorized
--
-- what it is compared against is the `Host` of this very request and not the
-- address we bound to: a page loaded from `192.168.0.6:9736` says so in both
-- headers, and a server listening on every interface has no single name of its
-- own to compare with
--
function _sameorigin(server, request)
    local origin = request.headers["origin"]
    if not origin or origin == "" or origin == "null" then
        return true
    end
    local host = origin:match("^https?://(.+)$")
    if not host then
        return false
    end
    local target = request.headers["host"]
    if target and target ~= "" then
        return host:lower() == target:lower()
    end

    -- no `Host` to compare with, which no browser does: fall back to the
    -- address we are listening on
    local name, port = host:match("^([^:]+):?(%d*)$")
    if name ~= server.addr and name ~= "localhost" and name ~= "127.0.0.1" then
        return false
    end
    return port == "" or tonumber(port) == server.port
end

-- may this request be answered?
--
-- three ways to carry the token, in the order they matter:
--
--   the query string   the url which was printed in the terminal, once
--   a header           what the page's own `fetch` sends
--   a cookie           what the browser sends by itself afterwards
--
-- the cookie is what makes it possible for the page to take the token out of
-- its address bar: a url with a live secret in it sits in the history, in the
-- title bar and in every screenshot, and it only ever needed to be there for
-- the first request, @see harness.web.assets.page
--
function _authorized(server, request)
    if request.query.token == server.token then
        return true
    end
    if request.headers["x-harness-token"] == server.token then
        return true
    end
    for pair in (request.headers["cookie"] or ""):gmatch("[^;]+") do
        local name, value = pair:match("^%s*([^=]+)=(.*)$")
        if name == "harness-token" and value == server.token then
            return true
        end
    end
    return false
end

-- find the handler of this request
function _match(server, request)
    for _, entry in ipairs(server.routes) do
        if entry.method == request.method then
            if entry.path == request.path then
                return entry.handler, entry
            end
            -- a trailing `*` matches everything below it, for the static files
            if entry.path:endswith("*") and request.path:startswith(entry.path:sub(1, -2)) then
                return entry.handler, entry
            end
        end
    end
end

-- read one request
--
-- @return  {method = "GET", path = "/", query = {..}, headers = {..}, body = ".."}
--
function _read(client)
    local data, headerend = _readheaders(client)
    if not data then
        return nil
    end
    local request = parse(data:sub(1, headerend + 1))
    if not request then
        return nil
    end

    local length = tonumber(request.headers["content-length"] or "0") or 0
    if length > MAXBODY then
        return nil
    end
    request.body = data:sub(headerend + 4)
    while #request.body < length do
        local more = _readsome(client)
        if not more then
            break
        end
        request.body = request.body .. more
    end
    return request
end

-- read until the headers are complete
function _readheaders(client)
    local data = ""
    local deadline = os.mclock() + READTIMEOUT
    while os.mclock() < deadline do
        local headerend = data:find("\r\n\r\n", 1, true)
        if headerend then
            return data, headerend
        end
        local more = _readsome(client)
        if not more then
            return nil
        end
        data = data .. more
        if #data > 256 * 1024 then
            return nil
        end
    end
    return nil
end

-- read whatever has arrived
--
-- the shape is xmake's own, @see xmake/modules/private/service/stream.lua: a
-- non-blocking read, and a wait on EV_RECV only when it came back empty. the
-- `waited` flag is the part worth copying — without it a socket which reports
-- readable and then yields nothing sends us round the wait twice in a row, and
-- the loop turns into a spin
--
-- `{block = true}` is the wrong tool here whatever the flag says: it waits for
-- exactly the size asked for, and a request is however long it happens to be
--
function _readsome(client)
    local buff = bytes(16384)
    local waited = false
    while true do
        local real = client:recv(buff, 16384, {block = false})
        if real and real > 0 then
            return buff:str(1, real)
        elseif real == 0 and not waited then
            if client:wait(socket.EV_RECV, READTIMEOUT) ~= socket.EV_RECV then
                return nil
            end
            waited = true
        else
            return nil
        end
    end
end

-- parse the head of a request
--
-- it is a plain function over a string so that the shape of a request can be
-- tested without a socket anywhere near it
--
function parse(head)
    local method, target = head:match("^(%u+) (%S+) HTTP/1%.[01]\r\n")
    if not method then
        return nil
    end
    local path, querystring = target:match("^([^?]*)%??(.*)$")
    local request = {method = method, path = path, query = _query(querystring), headers = {}}
    for name, value in head:gmatch("\r\n([%w%-]+):%s*([^\r\n]*)") do
        request.headers[name:lower()] = value
    end
    return request
end

-- the query string as a table, with the escapes undone
function _query(querystring)
    local query = {}
    for name, value in (querystring or ""):gmatch("([^&=?]+)=([^&=?]*)") do
        query[_unescape(name)] = _unescape(value)
    end
    return query
end

-- `%20` and friends
function _unescape(str)
    return (str:gsub("+", " "):gsub("%%(%x%x)", function (hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- write a whole response
function _respond(client, status, contenttype, content, headers)
    local lines = {string.format("HTTP/1.1 %d %s", status, _reason(status)),
                   string.format("Content-Type: %s", contenttype),
                   string.format("Content-Length: %d", #content),
                   "Connection: close"}
    for name, value in pairs(headers or {}) do
        table.insert(lines, string.format("%s: %s", name, value))
    end
    return _write(client, table.concat(lines, "\r\n") .. "\r\n\r\n" .. content)
end

-- take the connection over for an event stream
--
-- @return  a stream: `:send(name, data)` and `:close()`
--
function stream(client)
    _write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
        .. "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n")
    return {
        client = client,
        open = true,
        send = _streamsend,
        close = _streamclose
    }
end

-- push one event
--
-- @return  false once the browser has gone away, which is how a held stream
--          ends: there is no other signal, and every later write would raise
--
function _streamsend(self, name, data)
    if not self.open then
        return false
    end
    local payload = string.format("event: %s\ndata: %s\n\n", name, (data or ""):gsub("\n", "\ndata: "))
    if not _write(self.client, payload) then
        self.open = false
        return false
    end
    return true
end

-- end the stream
function _streamclose(self)
    if self.open then
        self.open = false
        try { function () _write(self.client, "event: close\ndata: bye\n\n") end }
        try { function () self.client:close() end }
    end
    return true
end

-- write to a client, saying whether it is still there
function _write(client, str)
    return try { function () return client:send(str, {block = true}) end } ~= nil
end

-- the reason phrase of a status
function _reason(status)
    local reasons = {[200] = "OK", [204] = "No Content", [400] = "Bad Request",
                     [403] = "Forbidden", [404] = "Not Found", [500] = "Internal Server Error"}
    return reasons[status] or "OK"
end

-- the content type of a file
function mimetype(filepath)
    return MIMETYPES[path.extension(filepath):sub(2):lower()] or "application/octet-stream"
end
