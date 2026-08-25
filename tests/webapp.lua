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
-- @file        webapp.lua
--

-- imports
import("core.base.json")
import("harness.harness")
import("harness.web.events")
import("harness.web.browser")
import("harness.web.session", {alias = "websession"})
import("harness.web.settings", {alias = "websettings"})
import("harness.llm.providers.replay")
import("harness.tools.registry", {alias = "toolregistry"})

-- a harness which answers from a recording and has one tool
function _harness(turns, opt)
    opt = opt or {}
    local cassette = os.tmpfile() .. ".json"
    json.savefile(cassette, {turns = turns})
    replay.rewind(cassette)

    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local config = instance:config()
    config.provider = "replay"
    config.providers = config.providers or {}
    config.providers.replay = {kind = "replay", cassette = cassette, contextsize = 131072,
                               models = {main = "recorded", small = "recorded"}}

    local tools = toolregistry.new()
    tools:add({
        name = "probe",
        permission = opt.permission or "read",
        description = "a tool for the tests",
        parameters = {type = "object", properties = {path = {type = "string"}}},
        run = function (context, args)
            return {output = "the file says hello"}
        end
    })
    instance:service("tools", tools)
    return instance
end

-- a state with a listener which keeps everything it is pushed
function _state(instance, opt)
    local state = websession.new(instance, opt)
    local seen = {}
    websession.listen(state, {
        open = true,
        send = function (self, name, data)
            table.insert(seen, {name = name, data = json.decode(data)})
            return true
        end,
        close = function () end
    })
    return state, seen
end

-- the events of one name
function _events(seen, name)
    local found = {}
    for _, event in ipairs(seen) do
        if event.name == name then
            table.insert(found, event.data)
        end
    end
    return found
end

---------------------------------------------------------------------------------
-- what crosses the wire
---------------------------------------------------------------------------------

function test_an_empty_list_stays_a_list()
    -- lua has one table type and json has two: a conversation with nothing in
    -- it used to cross as `{}`, and `for (const m of {})` is a TypeError which
    -- takes the whole page with it
    local encoded = events.encode({messages = {}, sessions = {}})
    assert(encoded:find('"messages":[]', 1, true), encoded)
    assert(encoded:find('"sessions":[]', 1, true), encoded)
end

function test_a_list_of_things_stays_a_list()
    local encoded = events.encode({lines = {{kind = "add"}, {kind = "del"}}})
    assert(encoded:find('"lines":[{', 1, true), encoded)
end

function test_a_map_stays_a_map()
    local encoded = events.encode({usage = {input = 10}})
    assert(encoded:find('"usage":{"input":10}', 1, true), encoded)
end

function test_an_event_which_carries_nothing_is_an_object()
    -- `ping` and `ready` carry nothing, and nothing is `{}` and never `[]`
    assert(events.encode({}) == "{}", events.encode({}))
end

function test_a_confirmation_as_the_page_gets_it()
    local payload = events.ask("7", {
        tool = {name = "run_command", group = "shell", commandline = function () return "xmake build" end},
        args = {command = "xmake build"},
        reason = "it builds"})
    assert(payload.id == "7")
    assert(payload.title == "xmake build", payload.title)
    assert(payload.reason == "it builds")
    assert(#payload.options >= 2, tostring(#payload.options))
    assert(payload.options[1].value == "allow")
    assert(payload.options[#payload.options].value == "deny")
end

---------------------------------------------------------------------------------
-- one conversation, and whoever is watching it
---------------------------------------------------------------------------------

function test_a_turn_reaches_everyone_watching()
    local instance = _harness({{content = "it builds one target."}})
    local state, seen = _state(instance, {mode = "bypass"})

    assert(websession.send(state, "what does it build?"))
    assert(#_events(seen, "turn.start") == 1)
    local assistant = _events(seen, "assistant")
    assert(#assistant > 0, "no answer arrived")
    assert(assistant[#assistant].text == "it builds one target.", assistant[#assistant].text)

    -- the markdown is rendered here and not in the browser, so there is no
    -- third-party renderer to keep up to date
    assert(assistant[#assistant].html:find("<p>", 1, true), assistant[#assistant].html)
    assert(#_events(seen, "turn.end") == 1)
    assert(state.working == false)
end

function test_a_second_message_while_it_works_is_refused()
    local instance = _harness({{content = "one moment."}})
    local state = _state(instance, {mode = "bypass"})
    state.working = true
    local ok, errors = websession.send(state, "and another thing")
    assert(not ok and errors:find("working", 1, true), tostring(errors))
end

function test_an_empty_message_is_refused()
    local instance = _harness({{content = "nothing to say."}})
    local state = _state(instance, {mode = "bypass"})
    assert(not websession.send(state, "   "))
end

function test_the_snapshot_is_what_a_late_tab_draws()
    local instance = _harness({{content = "it builds one target."}})
    local state = _state(instance, {mode = "bypass"})
    websession.send(state, "what does it build?")

    local snapshot = websession.snapshot(state)
    assert(snapshot.cwd == instance:rootdir(), snapshot.cwd)
    assert(snapshot.working == false)
    assert(#snapshot.messages >= 2, tostring(#snapshot.messages))
    assert(snapshot.messages[1].role == "user", snapshot.messages[1].role)
end

function test_a_listener_which_went_away_is_dropped()
    local instance = _harness({{content = "hello."}})
    local state = websession.new(instance)
    websession.listen(state, {open = true, send = function () return false end, close = function () end})
    assert(websession.watchers(state) == 1)
    websession.push(state, "notice", {text = "anybody there?"})
    assert(websession.watchers(state) == 0)
end

---------------------------------------------------------------------------------
-- the confirmations
---------------------------------------------------------------------------------

function test_a_tool_which_must_be_confirmed_asks_the_page()
    -- the turn runs in a coroutine of its own and waits there, so the ask is
    -- already out by the time `send` has returned
    local instance = _harness({{toolcalls = {{name = "probe", arguments = {path = "xmake.lua"}}}},
                               {content = "done."}}, {permission = "exec"})
    local state, seen = _state(instance, {mode = "default"})
    assert(websession.send(state, "run it"))

    local asks = _events(seen, "ask")
    assert(#asks == 1, tostring(#asks))
    assert(asks[1].id, "an ask must be answerable")
    assert(state.pending[asks[1].id], "the turn must be waiting for it")

    -- and answering it lets the turn finish
    assert(websession.answer(state, asks[1].id, "deny"))
    assert(#_events(seen, "ask.done") == 1)
    assert(state.pending[asks[1].id] == nil)
    assert(#_events(seen, "turn.end") == 1)
    assert(state.working == false)
end

function test_an_answer_to_nothing_is_not_an_error()
    local instance = _harness({{content = "hello."}})
    local state = _state(instance)
    assert(websession.answer(state, "nope", "allow") == false)
end

function test_stopping_answers_the_question_which_is_open()
    local instance = _harness({{toolcalls = {{name = "probe", arguments = {path = "xmake.lua"}}}},
                               {content = "stopped."}}, {permission = "exec"})
    local state, seen = _state(instance, {mode = "default"})
    websession.send(state, "run it")
    assert(#_events(seen, "ask") == 1)

    -- a turn sitting on a question would never notice a flag, so stopping has
    -- to answer it, and the answer is no
    assert(websession.abort(state))
    assert(#_events(seen, "turn.end") == 1)
end

---------------------------------------------------------------------------------
-- the conversations of a project
---------------------------------------------------------------------------------

function test_a_new_conversation_replaces_the_one_before_it()
    local instance = _harness({{content = "hello."}})
    local state = _state(instance)
    local first = state.session:id()
    assert(websession.fresh(state))
    assert(state.session:id() ~= first)
end

function test_nothing_is_swapped_while_it_works()
    local instance = _harness({{content = "hello."}})
    local state = _state(instance)
    state.working = true
    assert(not websession.fresh(state))
    assert(not websession.resume(state, "whatever"))
    assert(not websession.chdir(state, os.tmpdir()))
end

function test_a_conversation_which_is_not_there()
    local instance = _harness({{content = "hello."}})
    local state = _state(instance)
    local ok, errors = websession.resume(state, "6a8c0000-0000-0000")
    assert(not ok and errors, tostring(errors))
end

function test_changing_the_project_takes_the_harness_with_it()
    local instance = _harness({{content = "hello."}})
    local state = _state(instance)
    local other = path.join(os.tmpdir(), "harness-web-" .. tostring(os.time()))
    os.mkdir(other)

    assert(websession.chdir(state, other), "the directory exists")
    assert(path.normalize(state.harness:rootdir()) == path.normalize(other), state.harness:rootdir())
    assert(state.session:cwd() == state.harness:rootdir())

    local ok, errors = websession.chdir(state, path.join(other, "nowhere"))
    assert(not ok and errors:find("not a directory", 1, true), tostring(errors))
end

---------------------------------------------------------------------------------
-- the settings a browser may change
---------------------------------------------------------------------------------

function test_the_settings_describe_themselves()
    local instance = _harness({{content = "hello."}})
    local described = websettings.describe(instance)
    assert(#described.groups >= 3, tostring(#described.groups))

    local titles = {}
    for _, group in ipairs(described.groups) do
        titles[group.title] = group
    end
    assert(titles["Model"], "there must be a model group")
    assert(titles["API keys"], "there must be a keys group")
    assert(#titles["API keys"].fields > 0, "one field per provider")
end

function test_a_key_never_comes_back()
    local instance = _harness({{content = "hello."}})
    instance:config().providers = {deepseek = {apikey = "sk-the-real-thing"}}
    local described = websettings.describe(instance)
    for _, group in ipairs(described.groups) do
        for _, field in ipairs(group.fields) do
            assert(field.value ~= "sk-the-real-thing", "a key must never be sent back")
            if field.key == "providers.deepseek.apikey" then
                assert(field.secret, "a key field must say it is one")
                assert(field.placeholder:find("configured", 1, true), field.placeholder)
            end
        end
    end
end

function test_only_the_settings_of_the_page_may_be_set()
    local instance = _harness({{content = "hello."}})
    local ok, errors = websettings.set(instance, "permission.rules", {"*"})
    assert(not ok and errors:find("not a setting", 1, true), tostring(errors))
    assert(not websettings.set(instance, nil, "x"))
end

function test_an_empty_key_leaves_the_one_which_is_there()
    -- the page sends every field back when one of them changes, and a blank key
    -- box must not wipe a key which is already configured
    local instance = _harness({{content = "hello."}})
    assert(websettings.set(instance, "providers.deepseek.apikey", ""))
end

---------------------------------------------------------------------------------
-- opening a browser
---------------------------------------------------------------------------------

function test_the_url_is_handed_over_as_an_argument()
    local ran = {}
    local opened = browser.open("http://127.0.0.1:9736/?token=a&b=c", {
        launchers = {{name = "opener", argv = {"--new"}}},
        run = function (program, argv)
            ran = {program = program, argv = argv}
        end})
    assert(opened == "opener", tostring(opened))
    assert(ran.program == "opener")
    assert(ran.argv[1] == "--new")
    assert(ran.argv[2] == "http://127.0.0.1:9736/?token=a&b=c", ran.argv[2])
end

function test_the_next_launcher_is_tried()
    local tried = {}
    local opened = browser.open("http://127.0.0.1:9736/", {
        launchers = {{name = "missing"}, {name = "works"}},
        run = function (program)
            table.insert(tried, program)
            if program == "missing" then
                raise("no such program")
            end
        end})
    assert(opened == "works", tostring(opened))
    assert(#tried == 2, tostring(#tried))
end

function test_failing_to_open_is_not_an_error()
    local opened, errors = browser.open("http://127.0.0.1:9736/", {
        launchers = {{name = "missing"}},
        run = function () raise("no such program") end})
    assert(opened == nil)
    assert(errors:find("missing", 1, true), tostring(errors))
end
