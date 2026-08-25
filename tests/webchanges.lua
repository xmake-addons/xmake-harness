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
-- @file        webchanges.lua
--

-- imports
import("harness.core.session", {alias = "sessions"})
import("harness.core.checkpoint")
import("harness.web.changes", {alias = "webchanges"})

-- a conversation which has edited some files, exactly as `harness.fs.fs` does it
function _state()
    local rootdir = os.tmpfile() .. ".project"
    os.mkdir(path.join(rootdir, "src"))
    local session = sessions.new({cwd = rootdir})
    return {
        harness = {rootdir = function () return rootdir end},
        session = session,
        kept = {}
    }
end

-- write a file the way the agent does: keep what it replaced, then replace it
function _write(state, relative, content)
    local filepath = path.join(state.harness:rootdir(), relative)
    local record = checkpoint.save(state.session, filepath)
    if record then
        state.session:append("edit", {record = record})
    end
    io.writefile(filepath, content)
    return filepath
end

function _paths(files)
    local paths = {}
    for _, file in ipairs(files) do
        table.insert(paths, file.path)
    end
    return paths
end

---------------------------------------------------------------------------------
-- the list is the conversation's own, and not the working tree
---------------------------------------------------------------------------------

function test_a_conversation_which_changed_nothing()
    local state = _state()
    local answer = webchanges.list(state)
    assert(#answer.files == 0, tostring(#answer.files))
end

function test_only_the_files_this_conversation_wrote()
    local state = _state()

    -- something which was already in the tree, which the agent never touched:
    -- `git status` would show it, and it is not what "what did it change" means
    io.writefile(path.join(state.harness:rootdir(), "untouched.txt"), "not ours\n")

    _write(state, "xmake.lua", "target(\"demo\")\n")
    _write(state, path.join("src", "main.c"), "int main() {}\n")

    local files = webchanges.list(state).files
    assert(#files == 2, table.concat(_paths(files), ", "))
    local paths = table.concat(_paths(files), ",")
    assert(paths:find("xmake.lua", 1, true), paths)
    assert(paths:find("src/main.c", 1, true), paths)
    assert(not paths:find("untouched", 1, true), paths)
end

function test_a_file_which_was_written_twice_is_listed_once()
    local state = _state()
    _write(state, "notes.md", "one\n")
    _write(state, "notes.md", "one\ntwo\n")
    _write(state, "notes.md", "one\ntwo\nthree\n")

    local files = webchanges.list(state).files
    assert(#files == 1, tostring(#files))

    -- and the diff is against what it held before the *first* edit, not before
    -- the last one: three writes are one change, seen from outside
    assert(files[1].created, "it did not exist before")
    assert(files[1].added == 3, tostring(files[1].added))
end

function test_the_counts_of_a_change()
    local state = _state()
    local filepath = path.join(state.harness:rootdir(), "xmake.lua")
    io.writefile(filepath, "target(\"demo\")\n    set_kind(\"binary\")\n")

    _write(state, "xmake.lua", "target(\"demo\")\n    set_kind(\"static\")\n    add_files(\"*.c\")\n")
    local files = webchanges.list(state).files
    assert(#files == 1)
    assert(files[1].created == false, "the file was already there")
    assert(files[1].added == 2 and files[1].removed == 1,
           string.format("+%d -%d", files[1].added, files[1].removed))
end

function test_a_relative_path_is_what_a_page_shows()
    local state = _state()
    _write(state, path.join("src", "main.c"), "int main() {}\n")
    local file = webchanges.list(state).files[1]
    assert(file.path == "src/main.c", file.path)
    assert(file.name == "main.c", file.name)
    assert(file.dir == "src", file.dir)
end

---------------------------------------------------------------------------------
-- the diff of one of them
---------------------------------------------------------------------------------

function test_the_diff_knows_where_its_lines_are()
    local state = _state()
    local filepath = path.join(state.harness:rootdir(), "xmake.lua")
    io.writefile(filepath, "target(\"demo\")\n    set_kind(\"binary\")\n    set_default(true)\n")
    _write(state, "xmake.lua", "target(\"demo\")\n    set_kind(\"static\")\n    set_default(true)\n")

    local result = webchanges.filediff(state, "xmake.lua")
    assert(result, "there must be a diff")
    assert(result.language == "lua", result.language)

    local kinds = {}
    for _, line in ipairs(result.lines) do
        kinds[line.kind] = (kinds[line.kind] or 0) + 1
    end
    assert(kinds.add == 1 and kinds.del == 1, string.format("+%d -%d",
        kinds.add or 0, kinds.del or 0))
    assert(kinds.hunk == 1, "the hunk header is a line of its own")

    -- the code is coloured by the harness's own highlighter
    local styles = {}
    for _, line in ipairs(result.lines) do
        for _, token in ipairs(line.tokens or {}) do
            styles[token.style] = true
        end
    end
    assert(styles["string"], "the strings must be coloured")
end

function test_a_new_file_is_all_new()
    local state = _state()
    _write(state, "notes.md", "# notes\nand more\n")
    local result = webchanges.filediff(state, "notes.md")
    assert(result.created, "it did not exist before")
    local adds = 0
    for _, line in ipairs(result.lines) do
        if line.kind == "add" then
            adds = adds + 1
        end
    end
    assert(adds == 2, tostring(adds))
end

function test_a_file_this_conversation_never_touched()
    local state = _state()
    _write(state, "notes.md", "# notes\n")
    local result, errors = webchanges.filediff(state, "somewhere/else.c")
    assert(not result and errors:find("did not change", 1, true), tostring(errors))
end

---------------------------------------------------------------------------------
-- what a command did
---------------------------------------------------------------------------------

-- record what a command wrote, the way `harness.fs.observe` does
function _bycommand(state, relative, opt)
    opt = opt or {}
    local filepath = path.join(state.harness:rootdir(), relative)
    state.session:append("edit", {record = table.join({path = filepath, bycommand = true},
        opt.existed and {existed = true, nocopy = true} or {existed = false})})
    if not opt.removed then
        io.writefile(filepath, opt.content or "made by a command\n")
    end
    return filepath
end

function test_a_file_a_command_created_is_a_change()
    -- `xmake create` writes eleven files and says nothing about any of them,
    -- and to somebody looking at "what changed" those files are the answer
    local state = _state()
    _bycommand(state, "xmake.lua", {content = "target(\"demo\")\n"})

    local files = webchanges.list(state).files
    assert(#files == 1, tostring(#files))
    assert(files[1].created, "it did not exist before")
    assert(files[1].bycommand, "and the row says who wrote it")
    assert(files[1].added == 1, tostring(files[1].added))

    -- it was created, so there is a way back and it is removing it
    assert(webchanges.revert(state, "xmake.lua"))
    assert(not os.isfile(path.join(state.harness:rootdir(), "xmake.lua")))
end

function test_a_file_a_command_changed_has_no_before()
    local state = _state()
    _bycommand(state, "xmake.lua", {existed = true, content = "target(\"other\")\n"})

    local file = webchanges.list(state).files[1]
    assert(file.nodiff, "there is nothing to diff against")
    assert(file.bycommand)

    local result, errors = webchanges.filediff(state, "xmake.lua")
    assert(not result and errors:find("no copy", 1, true), tostring(errors))

    local ok, reverterrors = webchanges.revert(state, "xmake.lua")
    assert(not ok and reverterrors:find("nothing to put back", 1, true), tostring(reverterrors))
end

---------------------------------------------------------------------------------
-- keeping one, or putting it back
---------------------------------------------------------------------------------

function test_putting_one_back()
    local state = _state()
    local filepath = path.join(state.harness:rootdir(), "xmake.lua")
    io.writefile(filepath, "target(\"demo\")\n")
    _write(state, "xmake.lua", "target(\"other\")\n")
    assert(io.readfile(filepath) == "target(\"other\")\n")

    assert(webchanges.revert(state, "xmake.lua"))
    assert(io.readfile(filepath) == "target(\"demo\")\n", "the file must hold what it held before")
end

function test_putting_back_a_file_which_was_created_removes_it()
    local state = _state()
    local filepath = _write(state, "notes.md", "# notes\n")
    assert(os.isfile(filepath))
    assert(webchanges.revert(state, "notes.md"))
    assert(not os.isfile(filepath), "a file which was created is removed again")
end

function test_keeping_one_is_only_a_decision()
    local state = _state()
    local filepath = _write(state, "notes.md", "# notes\n")
    assert(webchanges.keep(state, "notes.md", true))
    assert(webchanges.list(state).files[1].kept, "the list remembers it")
    assert(io.readfile(filepath) == "# notes\n", "keeping writes nothing")

    assert(webchanges.keep(state, "notes.md", false))
    assert(not webchanges.list(state).files[1].kept)
    assert(webchanges.list(state).files[1].undecided)
end

function test_a_decision_is_kept_with_the_conversation()
    -- a decision which lived in this process would be lost the next time the
    -- harness restarted, and the list would ask again about a change somebody
    -- had already looked at
    local state = _state()
    _write(state, "notes.md", "# notes\n")
    webchanges.keep(state, "notes.md", true)
    state.session:save()

    local reopened = {harness = state.harness, session = sessions.load(state.session:id(),
        state.harness:rootdir())}
    assert(reopened.session, "the conversation must load again")
    assert(webchanges.list(reopened).files[1].kept, "and remember what was decided")
end

function test_a_change_which_is_edited_again_is_undecided_again()
    local state = _state()
    _write(state, "notes.md", "# notes\n")
    webchanges.keep(state, "notes.md", true)
    assert(webchanges.list(state).files[1].kept)

    -- the agent wrote it again: that is a new change, and asking about it again
    -- is exactly the point of the list
    _write(state, "notes.md", "# notes\nand more\n")
    assert(webchanges.list(state).files[1].undecided, "a new edit undoes the decision")
end

function test_a_reverted_file_says_so()
    local state = _state()
    _write(state, "notes.md", "# notes\n")
    assert(webchanges.revert(state, "notes.md"))
    local file = webchanges.list(state).files[1]
    assert(file.reverted, "the row says what happened to it")
    assert(not file.undecided, "and it is not waiting for a decision")
end

function test_a_file_which_is_not_ours_cannot_be_reverted()
    local state = _state()
    _write(state, "notes.md", "# notes\n")
    local ok, errors = webchanges.revert(state, "../outside.c")
    assert(not ok and errors, tostring(errors))
end

---------------------------------------------------------------------------------
-- all of them at once
---------------------------------------------------------------------------------

function test_keeping_all_of_them()
    local state = _state()
    _write(state, "one.md", "one\n")
    _write(state, "two.md", "two\n")
    webchanges.keep(state, "one.md", true)

    -- the one which was already kept is not decided twice
    local decided = webchanges.all(state, "keep")
    assert(decided == 1, tostring(decided))
    for _, file in ipairs(webchanges.list(state).files) do
        assert(file.kept, file.path)
    end
end

function test_reverting_all_of_them()
    local state = _state()
    local one = _write(state, "one.md", "one\n")
    local two = _write(state, "two.md", "two\n")

    local decided, failed = webchanges.all(state, "revert")
    assert(decided == 2, tostring(decided))
    assert(#failed == 0, tostring(#failed))
    assert(not os.isfile(one) and not os.isfile(two), "both were created, so both are gone")
    for _, file in ipairs(webchanges.list(state).files) do
        assert(file.reverted, file.path)
    end
end

function test_what_cannot_be_reverted_is_left_alone()
    local state = _state()
    _write(state, "mine.md", "mine\n")
    _bycommand(state, "theirs.md", {existed = true})

    -- a file a command overwrote has no copy to go back to, and reverting the
    -- rest must not stop at it
    local decided, failed = webchanges.all(state, "revert")
    assert(decided == 1, tostring(decided))
    assert(#failed == 0, "it is skipped rather than failed")
    for _, file in ipairs(webchanges.list(state).files) do
        if file.path == "mine.md" then
            assert(file.reverted, "the one which could be put back was")
        else
            assert(not file.reverted, "and the one which could not be, was not")
        end
    end
end
