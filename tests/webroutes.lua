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
-- @file        webroutes.lua
--

--
-- the routes, over a real socket
--
-- the modules behind them are tested on their own; this is about what actually
-- crosses the wire. the bug which made the page draw nothing was not in any
-- module — every one of them was right — it was an empty lua table arriving as
-- `{}` where the page expected `[]`, and nothing but a request could have
-- caught it.
--

-- imports
import("core.base.json")
import("core.base.bytes")
import("core.base.socket")
import("harness.harness")
import("harness.core.checkpoint")
import("harness.core.session", {alias = "sessions"})
import("harness.web.app", {alias = "webapp"})
import("harness.web.session", {alias = "websession"})
import("harness.http.server", {alias = "httpserver"})

-- one harness, one server, a fresh conversation for each test
--
-- bootstrapping a harness reads the skills, the agents and the tools of the
-- machine, which is two seconds — fourteen times over it is the slowest thing
-- in the suite by an order of magnitude, and none of these tests is about
-- bootstrapping. the conversation is what they are about, and that is new every
-- time.
--
function _serve()
    local shared = _g.shared
    if not shared then
        local rootdir = os.tmpfile() .. ".project"
        os.mkdir(path.join(rootdir, "src"))
        io.writefile(path.join(rootdir, "xmake.lua"),
                     "target(\"demo\")\n    set_kind(\"binary\")\n")

        local instance = harness.bootstrap({rootdir = rootdir})
        local state = websession.new(instance, {mode = "bypass"})
        local server = httpserver.new({port = 39800 + math.random(0, 90), token = "s3cret"})
        webapp.mount(server, state)
        local port, errors = httpserver.start(server)
        assert(port, tostring(errors))
        shared = {server = server, port = port, state = state, rootdir = rootdir}
        _g.shared = shared
    end

    -- a conversation of its own, and the file back the way the project has it
    shared.state.session = sessions.new({cwd = shared.rootdir})
    shared.state.mode = "bypass"
    shared.state.working = false
    io.writefile(path.join(shared.rootdir, "xmake.lua"),
                 "target(\"demo\")\n    set_kind(\"binary\")\n")
    return shared.server, shared.port, shared.state
end

-- the server stays up for the next test, so a test does not stop it
function _stop()
end

-- but the file does, when it is done
--
-- a listener nobody closed keeps its accept coroutine alive, and a coroutine
-- which is alive keeps the process running: the suite would pass and then hang,
-- @see harness.http.server.stop
--
function teardown()
    if _g.shared then
        httpserver.stop(_g.shared.server)
        _g.shared = nil
    end
end

-- one request, and the whole answer
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

-- the status and the decoded body of a GET
function _get(port, path)
    local answer = _request(port, string.format(
        "GET %s%stoken=s3cret HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        path, path:find("?", 1, true) and "&" or "?"))
    return _split(answer)
end

-- and of a POST
function _post(port, path, payload)
    local body = json.encode(payload or {})
    local answer = _request(port, string.format(
        "POST %s?token=s3cret HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
        .. "Content-Length: %d\r\nConnection: close\r\n\r\n", path, #body), body)
    return _split(answer)
end

-- the status, the raw body, and the body as a table
function _split(answer)
    local status = tonumber(answer:match("^HTTP/1%.1 (%d+)")) or 0
    local body = answer:match("\r\n\r\n(.*)$") or ""
    local decoded = try { function () return json.decode(body) end }
    return status, body, type(decoded) == "table" and decoded or {}
end

---------------------------------------------------------------------------------
-- what a page needs to draw itself
---------------------------------------------------------------------------------

function test_the_state_of_a_new_conversation()
    local server, port, state = _serve()
    local status, body, answer = _get(port, "/api/state")
    assert(status == 200, tostring(status))

    -- the one which used to break the page: an empty conversation is a list
    assert(body:find('"messages":[]', 1, true), body)
    assert(answer.cwd == state.harness:rootdir(), tostring(answer.cwd))
    assert(answer.working == false)
    assert(answer.mode == "bypass", tostring(answer.mode))
    assert(answer.context and answer.context.size > 0, "the window is measured")
    _stop()
end

function test_the_page_and_its_files()
    local server, port = _serve()
    local status, body = _split(_request(port,
        "GET /?token=s3cret HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))
    assert(status == 200, tostring(status))
    assert(body:find("<title>xmake ai</title>", 1, true), body:sub(1, 120))
    assert(not body:find("__HARNESS_TOKEN__", 1, true), "the token must be filled in")

    -- the files a page is made of carry no token, because an `import` cannot
    local assets = _split(_request(port,
        "GET /assets/app.js HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))
    assert(assets == 200, tostring(assets))
    _stop()
end

function test_the_page_hands_the_token_to_the_browser()
    -- the page can then take it out of the address bar and still be reloadable:
    -- a url with a live secret in it sits in the history and in every screenshot
    local server, port = _serve()
    local answer = _request(port,
        "GET /?token=s3cret HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    assert(answer:find("Set%-Cookie: harness%-token=s3cret"), answer:sub(1, 300))
    assert(answer:find("SameSite=Strict", 1, true), "and it does not travel to other sites")

    -- and the cookie is enough on its own afterwards
    local status, body = _split(_request(port, "GET /api/state HTTP/1.1\r\nHost: x\r\n"
        .. "Cookie: harness-token=s3cret\r\nConnection: close\r\n\r\n"))
    assert(status == 200, tostring(status))
    assert(body:find('"messages"', 1, true), body:sub(1, 120))

    -- a wrong one is no better than none
    local refused = _split(_request(port, "GET /api/state HTTP/1.1\r\nHost: x\r\n"
        .. "Cookie: harness-token=guess; other=1\r\nConnection: close\r\n\r\n"))
    assert(refused == 403, tostring(refused))
    _stop()
end

function test_a_request_from_another_site_is_refused()
    -- the cookie is SameSite=Strict so a browser will not attach it to one of
    -- these, but a page can still make the request, and the check costs nothing
    local server, port = _serve()
    local status = _split(_request(port, string.format(
        "GET /api/state?token=s3cret HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\n"
        .. "Connection: close\r\n\r\n")))
    assert(status == 403, tostring(status))

    -- and the page's own requests are not
    local ours = _split(_request(port, string.format(
        "GET /api/state?token=s3cret HTTP/1.1\r\nHost: x\r\nOrigin: http://127.0.0.1:%d\r\n"
        .. "Connection: close\r\n\r\n", port)))
    assert(ours == 200, tostring(ours))
    _stop()
end

function test_nothing_answers_without_the_token()
    local server, port = _serve()
    for _, path in ipairs({"/api/state", "/api/changes", "/api/commands", "/api/files"}) do
        local status = _split(_request(port, string.format(
            "GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", path)))
        assert(status == 403, string.format("%s answered %d", path, status))
    end
    _stop()
end

---------------------------------------------------------------------------------
-- the lists, which must arrive as lists
---------------------------------------------------------------------------------

function test_the_lists_are_lists_even_when_empty()
    local server, port = _serve()
    for _, probe in ipairs({{path = "/api/changes", key = "files"},
                            {path = "/api/sessions", key = "sessions"},
                            {path = "/api/commands", key = "commands"},
                            {path = "/api/files?q=nothingmatchesthis", key = "files"}}) do
        local status, body = _get(port, probe.path)
        assert(status == 200, string.format("%s answered %d", probe.path, status))
        assert(body:find(string.format('"%s":[', probe.key), 1, true),
               string.format("%s: %s", probe.path, body:sub(1, 160)))
    end
    _stop()
end

function test_the_commands_are_the_ones_the_terminal_has()
    local server, port = _serve()
    local _, _, answer = _get(port, "/api/commands")
    local names = {}
    for _, command in ipairs(answer.commands) do
        names[command.name] = true
    end
    assert(names["compact"] and names["model"] and names["permissions"], "the builtins are there")
    _stop()
end

function test_the_files_of_the_project()
    local server, port = _serve()
    local _, _, answer = _get(port, "/api/files?q=xmake")
    assert(#answer.files >= 1, tostring(#answer.files))
    assert(answer.files[1].path == "xmake.lua", answer.files[1].path)
    _stop()
end

---------------------------------------------------------------------------------
-- the changes
---------------------------------------------------------------------------------

-- write a file the way the agent does, so the conversation knows about it
function _write(state, relative, content)
    local filepath = path.join(state.harness:rootdir(), relative)
    local record = checkpoint.save(state.session, filepath)
    if record then
        state.session:append("edit", {record = record})
    end
    io.writefile(filepath, content)
    return filepath
end

function test_a_change_and_its_diff_cross_the_wire()
    local server, port, state = _serve()
    _write(state, "xmake.lua", "target(\"demo\")\n    set_kind(\"static\")\n")

    local _, _, changes = _get(port, "/api/changes")
    assert(#changes.files == 1, tostring(#changes.files))
    assert(changes.files[1].path == "xmake.lua", changes.files[1].path)
    assert(changes.files[1].undecided, "it is waiting for a decision")

    local status, body, diff = _get(port, "/api/changes/diff?path=xmake.lua")
    assert(status == 200, tostring(status))
    assert(diff.language == "lua", tostring(diff.language))
    assert(#diff.lines > 0, body:sub(1, 160))

    -- the tokens are what the page colours with, and they are a list of lists
    local coloured = false
    for _, line in ipairs(diff.lines) do
        for _, token in ipairs(line.tokens or {}) do
            coloured = coloured or token.style == "string"
        end
    end
    assert(coloured, "the code must arrive tokenized")
    _stop()
end

function test_a_decision_crosses_the_wire()
    local server, port, state = _serve()
    _write(state, "xmake.lua", "target(\"demo\")\n    set_kind(\"static\")\n")

    local status = _post(port, "/api/changes/keep", {path = "xmake.lua", kept = true})
    assert(status == 200, tostring(status))
    local _, _, changes = _get(port, "/api/changes")
    assert(changes.files[1].kept, "the decision is remembered")

    -- and all of them at once
    _write(state, path.join("src", "main.c"), "int main() {}\n")
    local _, _, answer = _post(port, "/api/changes/all", {what = "keep"})
    assert(answer.decided == 1, tostring(answer.decided))
    _stop()
end

function test_a_path_which_is_not_ours_is_refused()
    local server, port = _serve()
    local status, _, answer = _get(port, "/api/changes/diff?path=../../etc/passwd")
    assert(status == 400, tostring(status))
    assert(answer.errors, "it says why")
    _stop()
end

---------------------------------------------------------------------------------
-- the conversation itself
---------------------------------------------------------------------------------

function test_an_empty_message_is_refused()
    local server, port = _serve()
    local status, _, answer = _post(port, "/api/send", {prompt = "   "})
    assert(status == 400, tostring(status))
    assert(answer.errors, "it says why")
    _stop()
end

function test_a_command_runs_over_the_wire()
    local server, port, state = _serve()
    local status = _post(port, "/api/send", {prompt = "/cost"})
    assert(status == 200, tostring(status))
    assert(state.working == false, "a command which is over is over")
    _stop()
end

function test_the_mode_can_be_changed()
    local server, port, state = _serve()
    local status, _, answer = _post(port, "/api/mode", {mode = "plan"})
    assert(status == 200 and answer.mode == "plan", tostring(answer.mode))
    assert(state.mode == "plan")

    local bad = _post(port, "/api/mode", {mode = "whatever"})
    assert(bad == 400, tostring(bad))
    _stop()
end

function test_a_new_conversation_over_the_wire()
    local server, port, state = _serve()
    local first = state.session:id()
    local status, _, answer = _post(port, "/api/session", {fresh = true})
    assert(status == 200, tostring(status))
    assert(answer.id ~= first, "it is a new one")
    assert(state.session:id() == answer.id)
    _stop()
end

function test_the_settings_never_send_a_key_back()
    local server, port, state = _serve()
    state.harness:config().providers = {deepseek = {apikey = "sk-the-real-thing"}}
    local _, body = _get(port, "/api/settings")
    assert(not body:find("sk-the-real-thing", 1, true), "a key must never cross the wire")
    assert(body:find("providers.deepseek.apikey", 1, true), "but the field is there to set")

    local status = _post(port, "/api/settings", {key = "permission.rules", value = "*"})
    assert(status == 400, "only the settings of the page may be set")
    _stop()
end
