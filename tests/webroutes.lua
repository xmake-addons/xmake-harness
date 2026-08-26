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
import("harness.web.events")
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
    --
    -- what the origin is compared against is the `Host` of the request itself:
    -- a page served from `192.168.0.6:9736` says so in both headers, and a
    -- server listening on every interface has no single name of its own
    local server, port = _serve()
    local status = _split(_request(port, string.format(
        "GET /api/state?token=s3cret HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"
        .. "Origin: https://evil.example\r\nConnection: close\r\n\r\n", port)))
    assert(status == 403, tostring(status))

    -- and the page's own requests are not, whatever name it reached us by
    for _, name in ipairs({"127.0.0.1", "localhost", "192.168.0.6"}) do
        local ours = _split(_request(port, string.format(
            "GET /api/state?token=s3cret HTTP/1.1\r\nHost: %s:%d\r\nOrigin: http://%s:%d\r\n"
            .. "Connection: close\r\n\r\n", name, port, name, port)))
        assert(ours == 200, string.format("%s answered %d", name, ours))
    end
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
-- the tree, and one file of it
---------------------------------------------------------------------------------

function test_a_branch_of_the_tree_crosses_the_wire()
    local server, port = _serve()
    local status, body, answer = _get(port, "/api/tree")
    assert(status == 200, tostring(status))
    assert(body:find('"entries":[', 1, true), body:sub(1, 120))

    local names = {}
    for _, entry in ipairs(answer.entries) do
        names[entry.name] = entry.kind
    end
    assert(names["xmake.lua"] == "file", tostring(names["xmake.lua"]))
    assert(names["src"] == "dir", tostring(names["src"]))
    _stop()
end

function test_a_file_crosses_as_its_lines()
    local server, port = _serve()
    local status, _, answer = _get(port, "/api/source?path=xmake.lua")
    assert(status == 200, tostring(status))
    assert(answer.language == "lua", tostring(answer.language))
    assert(#answer.lines == 2, tostring(#answer.lines))
    assert(answer.lines[1].number == 1)
    assert(answer.marks, "the marks come with it")

    -- and the tokens are what the page colours with
    local coloured = false
    for _, line in ipairs(answer.lines) do
        for _, token in ipairs(line.tokens or {}) do
            coloured = coloured or token.style == "string"
        end
    end
    assert(coloured, "the code arrives tokenized")
    _stop()
end

function test_a_file_with_scattered_changes_still_arrives()
    -- the marks used to be a table keyed by line number, which is a map to lua
    -- and a *sparse array* to json — and json refuses to write one of those.
    -- the answer came back empty and the page said the file was empty, which it
    -- was not, @see harness.web.source.marks
    local server, port, state = _serve()
    io.writefile(path.join(state.harness:rootdir(), "wide.lua"), table.concat({
        "local one = 1", "local two = 2", "local three = 3", "local four = 4",
        "local five = 5", "local six = 6", "local seven = 7", "local eight = 8",
        "local nine = 9", "local ten = 10", ""}, "\n"))

    -- a change on line 2 and another on line 9: nothing in between
    _write(state, "wide.lua", table.concat({
        "local one = 1", "local two = 22", "local three = 3", "local four = 4",
        "local five = 5", "local six = 6", "local seven = 7", "local eight = 8",
        "local nine = 99", "local ten = 10", ""}, "\n"))

    local status, body, answer = _get(port, "/api/source?path=wide.lua")
    assert(status == 200, tostring(status))
    assert(not answer.errors, tostring(answer.errors))
    assert(#answer.lines == 10, string.format("%d lines: %s", #answer.lines, body:sub(1, 120)))

    -- and the marks are lists of line numbers, which json can write
    assert(#answer.marks.added == 2, tostring(#answer.marks.added))
    assert(answer.marks.added[1] == 2 and answer.marks.added[2] == 9,
           table.concat(answer.marks.added, ","))
    _stop()
end

function test_something_which_cannot_be_encoded_says_so()
    -- an answer which cannot be written used to come back as `{}`, and a page
    -- given `{}` draws an empty everything and says nothing about why
    local encoded = events.encode({marks = {added = {[9] = true, [40] = true}}})
    assert(encoded:find('"errors"', 1, true) or encoded:find('"added"', 1, true), encoded)
    if encoded:find('"errors"', 1, true) then
        assert(not encoded:find("stack traceback", 1, true), "the reason, not the traceback")
    end
end

function test_a_file_can_be_written_from_the_page()
    local server, port, state = _serve()
    local status = _post(port, "/api/source",
        {path = "xmake.lua", content = "target(\"typed\")\n"})
    assert(status == 200, tostring(status))
    assert(io.readfile(path.join(state.harness:rootdir(), "xmake.lua"))
           == "target(\"typed\")\n")

    -- and it is a change of this conversation, like any other
    local _, _, changes = _get(port, "/api/changes")
    assert(#changes.files == 1, tostring(#changes.files))
    assert(changes.files[1].path == "xmake.lua", changes.files[1].path)
    _stop()
end

function test_a_file_outside_the_project_is_refused()
    local server, port = _serve()
    local status, _, answer = _get(port, "/api/source?path=../../etc/passwd")
    assert(status == 400, tostring(status))
    assert(answer.errors, "it says why")

    local written = _post(port, "/api/source", {path = "../escape.txt", content = "no"})
    assert(written == 400, tostring(written))
    _stop()
end

function test_colouring_what_is_being_typed()
    local server, port = _serve()
    local status, _, answer = _post(port, "/api/colour",
        {path = "x.lua", content = "-- half a thought"})
    assert(status == 200, tostring(status))
    assert(#answer.lines == 1, tostring(#answer.lines))
    assert(answer.lines[1].tokens[1].style == "comment", answer.lines[1].tokens[1].style)
    _stop()
end

---------------------------------------------------------------------------------
-- the skills, as the settings page manages them
---------------------------------------------------------------------------------

function test_the_skills_describe_themselves()
    local server, port = _serve()
    local status, body, answer = _get(port, "/api/skills")
    assert(status == 200, tostring(status))
    assert(body:find('"skills":[', 1, true), body:sub(1, 120))
    assert(body:find('"installed":[', 1, true), body:sub(1, 120))
    assert(body:find('"available":[', 1, true), body:sub(1, 120))
    assert(answer.dir and answer.dir ~= "", tostring(answer.dir))

    -- every skill says where it came from and whether it is in use
    for _, skill in ipairs(answer.skills) do
        assert(skill.name and skill.name ~= "", "a skill has a name")
        assert(skill.source and skill.source ~= "", skill.name)
        assert(skill.enabled ~= nil, skill.name)
    end
    _stop()
end

function test_a_skill_can_be_switched_off_and_on()
    local server, port, state = _serve()
    local _, _, before = _get(port, "/api/skills")
    if #before.skills == 0 then
        _stop()
        return
    end
    local name = before.skills[1].name

    assert(_post(port, "/api/skills/enable", {name = name, enabled = false}) == 200)
    local _, _, after = _get(port, "/api/skills")
    for _, skill in ipairs(after.skills) do
        if skill.name == name then
            assert(skill.enabled == false, name .. " must be off")
        end
    end

    -- it is written where the terminal reads it, and not held in the server
    local disabled = (state.harness:config().skills or {}).disabled or {}
    assert(table.contains(disabled, name), "the setting is in the configuration")

    assert(_post(port, "/api/skills/enable", {name = name, enabled = true}) == 200)
    local _, _, again = _get(port, "/api/skills")
    for _, skill in ipairs(again.skills) do
        if skill.name == name then
            assert(skill.enabled ~= false, name .. " must be on again")
        end
    end
    _stop()
end

function test_a_pack_which_cannot_be_resolved_says_why()
    local server, port = _serve()
    local status, _, answer = _post(port, "/api/skills/install", {spec = "nothing-like-this"})
    assert(status == 400, tostring(status))
    assert(answer.errors and answer.errors:find("cannot resolve", 1, true), tostring(answer.errors))

    local removed = _post(port, "/api/skills/remove", {name = "nothing-like-this"})
    assert(removed == 400, tostring(removed))
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
