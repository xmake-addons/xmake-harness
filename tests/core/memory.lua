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
-- @file        memory.lua
--

-- imports
import("harness.harness")
import("harness.core.memory")
import("harness.config.config", {alias = "harnessconfig"})
import("harness.core.remember")
import("harness.prompt.system", {alias = "systemprompt"})

-- a project to remember things about
--
-- the user memory lives in the harness home, which the runner has already
-- pointed at a directory of its own: a test which wrote to the real one would
-- be a test which edits the person running it, @see tests/run.lua
function _harness()
    local rootdir = os.tmpfile() .. ".memory"
    os.mkdir(rootdir)
    local home = harnessconfig.homedir()
    io.writefile(path.join(home, "MEMORY.md"), "")
    return harness.bootstrap({rootdir = rootdir, trusted = true}), rootdir, home
end

---------------------------------------------------------------------------------
-- the list, and the file under it
---------------------------------------------------------------------------------

function test_nothing_is_remembered_to_begin_with()
    local instance = _harness()
    assert(#memory.entries(instance, "project") == 0)
    assert(#memory.all(instance) == 0)
    assert(memory.prompt(instance) == nil)
end

function test_one_thing_is_remembered()
    local instance = _harness()
    assert(memory.remember(instance, "project", "the tests are run with `xmake test`"))
    local kept = memory.entries(instance, "project")
    assert(#kept == 1, tostring(#kept))
    assert(kept[1] == "the tests are run with `xmake test`", kept[1])
end

function test_it_is_written_where_a_person_can_edit_it()
    local instance, rootdir = _harness()
    memory.remember(instance, "project", "never use exceptions")
    local file = memory.filepath(instance, "project")
    assert(file == path.join(rootdir, ".xmake-harness", "MEMORY.md"), file)

    -- and the file says what it is, because somebody will open it
    local content = io.readfile(file)
    assert(content:find("# Memory", 1, true), content)
    assert(content:find("- never use exceptions", 1, true), content)
    assert(content:find("Edit it", 1, true), "it says it may be edited")
end

function test_the_two_scopes_are_two_files()
    local instance, rootdir, home = _harness()
    memory.remember(instance, "project", "the project one")
    memory.remember(instance, "user", "the personal one")

    assert(memory.filepath(instance, "user"):startswith(home), memory.filepath(instance, "user"))
    assert(#memory.entries(instance, "project") == 1)
    assert(#memory.entries(instance, "user") == 1)
    assert(#memory.all(instance) == 2)
end

function test_a_scope_which_is_not_one()
    local instance = _harness()
    local ok, errors = memory.remember(instance, "everywhere", "a fact")
    assert(not ok)
    assert(errors:find("not a scope", 1, true), errors)
end

function test_the_same_thing_twice_is_one_thing()
    -- the fact worth writing down once is the fact which keeps coming up, and
    -- a list of it twenty times is a list nobody reads
    local instance = _harness()
    assert(memory.remember(instance, "project", "never use exceptions"))
    local ok, errors = memory.remember(instance, "project", "Never Use Exceptions")
    assert(not ok)
    assert(errors:find("already", 1, true), errors)
    assert(#memory.entries(instance, "project") == 1)
end

function test_a_bullet_the_model_typed_is_not_part_of_the_fact()
    local instance = _harness()
    memory.remember(instance, "project", "- the build is out of tree")
    assert(memory.entries(instance, "project")[1] == "the build is out of tree",
           memory.entries(instance, "project")[1])
end

function test_there_is_nothing_to_remember()
    local instance = _harness()
    assert(not memory.remember(instance, "project", "   "))
    assert(not memory.remember(instance, "project", nil))
end

---------------------------------------------------------------------------------
-- taking one back
---------------------------------------------------------------------------------

function test_forgetting_one_by_its_place()
    local instance = _harness()
    memory.remember(instance, "project", "first")
    memory.remember(instance, "project", "second")
    assert(memory.forget(instance, "project", 1) == "first")
    assert(#memory.entries(instance, "project") == 1)
    assert(memory.entries(instance, "project")[1] == "second")
end

function test_forgetting_one_by_what_it_says()
    local instance = _harness()
    memory.remember(instance, "project", "the tests are run with `xmake test`")
    assert(memory.forget(instance, "project", "xmake test"))
    assert(#memory.entries(instance, "project") == 0)
end

function test_forgetting_one_which_is_not_there()
    local instance = _harness()
    local gone, errors = memory.forget(instance, "project", "something else")
    assert(gone == nil)
    assert(errors:find("nothing like", 1, true), errors)
end

function test_forgetting_all_of_them()
    local instance = _harness()
    memory.remember(instance, "project", "one")
    memory.remember(instance, "project", "two")
    assert(memory.clear(instance, "project"))
    assert(#memory.entries(instance, "project") == 0)
end

---------------------------------------------------------------------------------
-- and where it ends up
---------------------------------------------------------------------------------

function test_it_reaches_the_system_prompt()
    local instance = _harness()
    memory.remember(instance, "project", "the tests are run with `xmake test -g unit`")
    memory.remember(instance, "user", "prefers the comment above the function")

    local prompt = systemprompt.build(instance, {mode = "default"})
    assert(prompt:find("xmake test %-g unit"), "the project one is there")
    assert(prompt:find("comment above the function", 1, true), "and the personal one")
end

function test_a_subagent_is_not_given_them()
    -- it was given one task with everything it needs in it, and the habits of
    -- this project are not what it was asked about
    local instance = _harness()
    memory.remember(instance, "project", "the tests are run with `xmake test -g unit`")
    local prompt = systemprompt.build(instance,
        {mode = "default", agent = {name = "explorer", prompt = "Look around."}})
    assert(not prompt:find("xmake test %-g unit"), "a subagent does not carry them")
end

---------------------------------------------------------------------------------
-- what is worth asking about at all
---------------------------------------------------------------------------------

function test_a_turn_which_wrote_something_is_worth_asking_about()
    assert(remember.worthasking({changed = true, messages = {}}))
end

function test_a_question_and_an_answer_teach_nothing()
    -- and asking anyway is a tax on every question anybody asks
    assert(not remember.worthasking({changed = false, messages = {
        {role = "user", content = "what does this build?"},
        {role = "assistant", content = "one binary."}}}))
end

function test_being_corrected_is_worth_asking_about()
    assert(remember.worthasking({changed = false, messages = {
        {role = "user", content = "no, we never use exceptions here"}}}))
    assert(remember.worthasking({changed = false, messages = {
        {role = "user", content = "不要用 std::regex"}}}))
end

function test_it_can_be_turned_off()
    assert(remember.enabled({}))
    assert(remember.enabled({memory = {}}))
    assert(not remember.enabled({memory = {auto = false}}))
end

function test_where_the_automatic_ones_go()
    assert(remember.scope({}) == "project")
    assert(remember.scope({memory = {scope = "user"}}) == "user")
    assert(remember.scope({memory = {scope = "nonsense"}}) == "project")
end

function test_it_does_nothing_when_it_is_off()
    local instance = _harness()
    local written = remember.run(instance, nil, {changed = true, messages = {}})
    assert(#written == 0, tostring(#written))

    instance:config().memory = {auto = false}
    assert(#remember.run(instance, nil, {changed = true,
        messages = {{role = "user", content = "no, never do that"}}}) == 0)
end

---------------------------------------------------------------------------------
-- the bytes it writes
---------------------------------------------------------------------------------

function _valid(str)
    return utf8.len(str) ~= nil
end

function test_a_chinese_memory_survives_being_written()
    -- `gsub("%s+", " ")` was the obvious way to tidy a line and it is wrong for
    -- every language which needs more than a byte per character: `%s` is
    -- `isspace()`, 0xA0 is a space to it, and 0xA0 is the middle byte of 标 —
    -- so the tidying rewrote the inside of the character and the next request
    -- came back `400 invalid unicode code point`
    local instance = _harness()
    local said = "该项目用 xmake 构建和运行，C++ 标准设为 c++17。"
    assert(memory.remember(instance, "project", said))

    local kept = memory.entries(instance, "project")
    assert(kept[1] == said, kept[1])
    assert(_valid(kept[1]), "it is still utf-8")
    assert(kept[1]:find("标准", 1, true), kept[1])
end

function test_the_file_it_wrote_is_utf8()
    local instance = _harness()
    memory.remember(instance, "project", "类型不匹配返回默认值，缺 key 返回静态 null 值")
    local content = io.readfile(memory.filepath(instance, "project"))
    assert(_valid(content), "the file is utf-8")
    assert(content:find("不匹配", 1, true), content)
end

function test_a_memory_too_long_is_cut_between_characters()
    -- and not through one: `sub` on a byte offset lands in the middle of a
    -- character and what is left is not utf-8 either
    local instance = _harness()
    local long = string.rep("标准的中文句子，", 200)
    assert(memory.remember(instance, "project", long))
    local kept = memory.entries(instance, "project")[1]
    assert(_valid(kept), "it is still utf-8")
    assert(#kept <= 400, tostring(#kept))
    assert(kept:startswith("标准的中文"), kept)
end

function test_a_file_somebody_broke_by_hand_does_not_break_the_turn()
    -- the file is one a person is invited to edit, with whatever editor and
    -- from whatever paste. a stray byte in it must cost a mangled word and not
    -- the whole conversation
    local instance = _harness()
    local file = memory.filepath(instance, "project")
    os.mkdir(path.directory(file))
    io.writefile(file, "# Memory\n\n- the tests are run with \xe6 \x87xmake test\n- and this one is fine\n")

    local kept = memory.entries(instance, "project")
    assert(#kept == 2, tostring(#kept))
    for _, entry in ipairs(kept) do
        assert(_valid(entry), entry)
    end
    assert(_valid(memory.prompt(instance)), "and so is the prompt it builds")
end
