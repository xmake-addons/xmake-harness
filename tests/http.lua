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
-- @file        http.lua
--

-- imports
import("core.base.bytes")
import("core.base.socket")
import("core.base.scheduler")
import("harness.http.server", {alias = "httpserver"})

---------------------------------------------------------------------------------
-- the shape of a request, without a socket anywhere near it
---------------------------------------------------------------------------------

function test_the_request_line()
    local request = httpserver.parse("GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n")
    assert(request.method == "GET", request.method)
    assert(request.path == "/index.html", request.path)
end

function test_the_headers_are_lowercased()
    -- a browser may send `Content-Type` or `content-type` as it pleases
    local request = httpserver.parse("POST / HTTP/1.1\r\nContent-Type: application/json\r\n"
        .. "X-Harness-Token: abc\r\n\r\n")
    assert(request.headers["content-type"] == "application/json", request.headers["content-type"])
    assert(request.headers["x-harness-token"] == "abc")
end

function test_the_query_string()
    local request = httpserver.parse("GET /events?token=s3cret&since=12 HTTP/1.1\r\n\r\n")
    assert(request.path == "/events", request.path)
    assert(request.query.token == "s3cret", tostring(request.query.token))
    assert(request.query.since == "12")
end

function test_the_escapes_are_undone()
    local request = httpserver.parse("GET /x?q=a%20b%2Fc&plus=a+b HTTP/1.1\r\n\r\n")
    assert(request.query.q == "a b/c", request.query.q)
    assert(request.query.plus == "a b", request.query.plus)
end

function test_a_request_which_is_not_one()
    assert(httpserver.parse("") == nil)
    assert(httpserver.parse("hello\r\n\r\n") == nil)
    assert(httpserver.parse("GET / HTTP/2\r\n\r\n") == nil)
end

function test_the_content_types()
    assert(httpserver.mimetype("app.js"):startswith("text/javascript"))
    assert(httpserver.mimetype("index.html"):startswith("text/html"))
    assert(httpserver.mimetype("x.png") == "image/png")
    assert(httpserver.mimetype("x.unknown") == "application/octet-stream")
end

---------------------------------------------------------------------------------
-- and against a real socket, in this process
---------------------------------------------------------------------------------

-- start a server with the given routes, on a port of its own
function _server(token)
    local instance = httpserver.new({port = 39400 + math.random(0, 60), token = token})
    httpserver.route(instance, "GET", "/hello", function ()
        return {status = 200, contenttype = "text/plain", content = "hello there"}
    end)
    httpserver.route(instance, "POST", "/echo", function (request)
        return {status = 200, contenttype = "text/plain", content = request.body or ""}
    end)
    httpserver.route(instance, "GET", "/static/*", function (request)
        return {status = 200, contenttype = "text/plain", content = "static:" .. request.path}
    end)
    httpserver.route(instance, "GET", "/events", function (request, response)
        local stream = httpserver.stream(response.client)
        for idx = 1, 3 do
            stream:send("tick", tostring(idx))
        end
        stream:close()
        return nil
    end)
    local port, errors = httpserver.start(instance)
    assert(port, tostring(errors))
    return instance, port
end

-- make one request and read the whole answer back
function _request(port, head, body)
    local client = socket.tcp()
    assert(client:connect("127.0.0.1", port, {timeout = 3000}) > 0, "cannot connect")
    client:send(head .. (body or ""), {block = true})

    local answer = ""
    local buff = bytes(16384)
    local deadline = os.mclock() + 5000
    while os.mclock() < deadline do
        local real = client:recv(buff, 16384, {block = false})
        if real and real > 0 then
            answer = answer .. buff:str(1, real)
        elseif real == 0 then
            if client:wait(socket.EV_RECV, 800) ~= socket.EV_RECV then
                break
            end
        else
            break
        end
    end
    client:close()
    return answer
end

-- a GET of one path
function _get(port, path)
    return _request(port, string.format("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", path))
end

function test_stopping_ends_the_accept_coroutine()
    -- a coroutine which is still waiting on something keeps the whole process
    -- alive: the harness would serve every request correctly and then never
    -- exit, which is how a test suite ends up hanging after it has passed
    local before = scheduler.co_count()
    local instance, port = _server()
    httpserver.stop(instance)
    scheduler.co_yield()
    assert(scheduler.co_count() <= before, string.format("%d coroutines were left behind",
        scheduler.co_count() - before))
end

function test_a_route_answers()
    local instance, port = _server()
    local answer = _get(port, "/hello")
    assert(answer:find("200 OK", 1, true), answer:sub(1, 80))
    assert(answer:find("hello there", 1, true), answer)
    httpserver.stop(instance)
end

function test_an_unknown_path_is_a_404()
    local instance, port = _server()
    assert(_get(port, "/nowhere"):find("404", 1, true) ~= nil)
    httpserver.stop(instance)
end

function test_a_prefix_route_matches_below_it()
    local instance, port = _server()
    local answer = _get(port, "/static/js/app.js")
    assert(answer:find("static:/static/js/app.js", 1, true), answer:sub(-60))
    httpserver.stop(instance)
end

function test_a_body_arrives()
    local instance, port = _server()
    local body = '{"prompt": "hello"}'
    local answer = _request(port, string.format(
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", #body), body)
    assert(answer:find(body, 1, true), answer:sub(-80))
    httpserver.stop(instance)
end

function test_the_events_arrive_as_a_stream()
    -- the shape matters: a browser's EventSource wants `event:` and `data:`
    local instance, port = _server()
    local answer = _get(port, "/events")
    assert(answer:find("text/event-stream", 1, true), answer:sub(1, 120))
    assert(answer:find("event: tick\ndata: 1", 1, true), answer)
    assert(answer:find("event: tick\ndata: 3", 1, true), answer)
    assert(answer:find("event: close", 1, true), answer)
    httpserver.stop(instance)
end

function test_a_request_without_the_token_is_refused()
    -- a page in another tab can reach 127.0.0.1 exactly as well as the user can
    local instance, port = _server("s3cret")
    local answer = _get(port, "/hello")
    assert(answer:find("403", 1, true), answer:sub(1, 80))
    assert(not answer:find("hello there", 1, true), "it must not answer at all")
    httpserver.stop(instance)
end

function test_the_token_in_the_query_is_accepted()
    local instance, port = _server("s3cret")
    assert(_get(port, "/hello?token=s3cret"):find("hello there", 1, true) ~= nil)
    httpserver.stop(instance)
end

function test_the_token_in_the_header_is_accepted()
    local instance, port = _server("s3cret")
    local answer = _request(port, "GET /hello HTTP/1.1\r\nHost: x\r\nX-Harness-Token: s3cret\r\n"
        .. "Connection: close\r\n\r\n")
    assert(answer:find("hello there", 1, true), answer:sub(1, 100))
    httpserver.stop(instance)
end

function test_a_wrong_token_is_refused()
    local instance, port = _server("s3cret")
    assert(_get(port, "/hello?token=guess"):find("403", 1, true) ~= nil)
    httpserver.stop(instance)
end

function test_several_requests_on_one_server()
    -- every connection gets its own coroutine, and a held one must not stop the
    -- next from being served
    local instance, port = _server()
    for _ = 1, 3 do
        assert(_get(port, "/hello"):find("hello there", 1, true) ~= nil)
    end
    assert(_get(port, "/events"):find("event: tick", 1, true) ~= nil)
    assert(_get(port, "/hello"):find("hello there", 1, true) ~= nil, "it must still serve after a stream")
    httpserver.stop(instance)
end
