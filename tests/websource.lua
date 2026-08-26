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
-- @file        websource.lua
--

-- imports
import("harness.fs.fs")
import("harness.core.session", {alias = "sessions"})
import("harness.web.source", {alias = "websource"})
import("harness.web.files", {alias = "webfiles"})

-- a project with a file in it, and a conversation about it
function _state()
    local rootdir = os.tmpfile() .. ".project"
    os.mkdir(path.join(rootdir, "src"))
    io.writefile(path.join(rootdir, "xmake.lua"),
        "target(\"demo\")\n    set_kind(\"binary\")\n    add_files(\"src/*.c\")\n")
    io.writefile(path.join(rootdir, "src", "main.c"), "int main() {}\n")

    local session = sessions.new({cwd = rootdir})
    local state = {harness = {rootdir = function () return rootdir end}, session = session}
    state.context = {session = session, cwd = rootdir, harness = state.harness}
    return state
end

-- the text of what was read back
function _text(source)
    local lines = {}
    for _, line in ipairs(source.lines) do
        local text = ""
        for _, token in ipairs(line.tokens) do
            text = text .. token.text
        end
        table.insert(lines, text)
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------------
-- reading one file
---------------------------------------------------------------------------------

function test_a_file_arrives_as_its_lines()
    local state = _state()
    local source = websource.read(state, "xmake.lua")
    assert(source, "the file must open")
    assert(source.path == "xmake.lua", source.path)
    assert(source.language == "lua", source.language)
    assert(#source.lines == 3, tostring(#source.lines))
    assert(source.lines[1].number == 1)

    -- a file which ends with a newline does not gain an empty line by being read
    assert(_text(source) == "target(\"demo\")\n    set_kind(\"binary\")\n    add_files(\"src/*.c\")",
           _text(source))
end

function test_the_code_is_coloured()
    local state = _state()
    local source = websource.read(state, "xmake.lua")
    local styles = {}
    for _, line in ipairs(source.lines) do
        for _, token in ipairs(line.tokens) do
            styles[token.style] = true
        end
    end
    assert(styles["string"], "the strings are coloured")
    assert(styles["func"] or styles["keyword"], "and the code is tokenized")
end

function test_a_file_outside_the_project()
    local state = _state()
    local source, errors = websource.read(state, "../../etc/passwd")
    assert(not source and errors, tostring(errors))
end

function test_a_file_which_is_not_there()
    local state = _state()
    local source, errors = websource.read(state, "nowhere.lua")
    assert(not source and errors:find("no such file", 1, true), tostring(errors))
end

function test_a_file_of_bytes()
    local state = _state()
    local filepath = path.join(state.harness:rootdir(), "blob.bin")
    io.writefile(filepath, "abc\0def")
    local source, errors = websource.read(state, "blob.bin")
    assert(not source and errors:find("binary", 1, true), tostring(errors))
end

---------------------------------------------------------------------------------
-- what changed in it, in the margin
---------------------------------------------------------------------------------

function test_the_changed_lines_are_marked()
    local state = _state()
    fs.writetext(path.join(state.harness:rootdir(), "xmake.lua"),
        "target(\"demo\")\n    -- what it builds\n    set_kind(\"static\")\n    add_files(\"src/*.c\")\n",
        state.context)

    local source = websource.read(state, "xmake.lua")
    assert(#source.lines == 4, tostring(#source.lines))

    -- the two new lines are marked, and the line the old one was on says that
    -- something was taken out after it
    -- lists of line numbers, because a table keyed by them is a sparse array to
    -- json and json refuses to write one
    assert(table.concat(source.marks.added, ",") == "2,3", table.concat(source.marks.added, ","))
    -- and the line which went comes with the text of it, so the page can show
    -- it where it was, in red, as the terminal does
    assert(#source.marks.removed == 1, tostring(#source.marks.removed))
    local gap = source.marks.removed[1]
    assert(gap.after == 1, tostring(gap.after))
    assert(#gap.lines == 1, tostring(#gap.lines))
    local text = ""
    for _, token in ipairs(gap.lines[1].tokens) do
        text = text .. token.text
    end
    assert(text:find("set_kind", 1, true), text)
end

function test_a_file_this_conversation_created_is_not_painted_over()
    -- everything in it is new, so marking every line would be a page of green
    -- which says nothing about the line somebody is looking for. the header
    -- says "new file" in one word instead
    local state = _state()
    fs.writetext(path.join(state.harness:rootdir(), "src", "extra.c"),
        "int extra() { return 1; }\nint more() { return 2; }\n", state.context)

    local source = websource.read(state, "src/extra.c")
    assert(#source.lines == 2, tostring(#source.lines))
    assert(source.marks.wholenew, "it says the whole file is new")
    assert(#source.marks.added == 0, string.format("%d lines were painted", #source.marks.added))
end

function test_a_file_created_and_then_edited_marks_the_edit()
    -- the last write is the change somebody is looking at, and it is a line of
    -- it and not all of it
    local state = _state()
    local filepath = path.join(state.harness:rootdir(), "src", "extra.c")
    fs.writetext(filepath, "int extra() {\n    return 1;\n}\n", state.context)
    fs.writetext(filepath, "int extra() {\n    // why\n    return 1;\n}\n", state.context)

    local source = websource.read(state, "src/extra.c")
    assert(not source.marks.wholenew, "there is a change to point at now")
    assert(#source.marks.added == 1 and source.marks.added[1] == 2,
           table.concat(source.marks.added, ","))
end

function test_a_file_nothing_touched_has_no_marks()
    local state = _state()
    local source = websource.read(state, "src/main.c")
    assert(#source.marks.added == 0 and #source.marks.removed == 0,
           string.format("+%d -%d", #source.marks.added, #source.marks.removed))
end

---------------------------------------------------------------------------------
-- writing it back
---------------------------------------------------------------------------------

function test_a_write_from_the_page_is_a_change_like_any_other()
    local state = _state()
    assert(websource.write(state, "src/main.c", "int main() { return 0; }\n"))
    assert(io.readfile(path.join(state.harness:rootdir(), "src", "main.c"))
           == "int main() { return 0; }\n")

    -- it went through the same door the agent writes through, so it kept a copy
    -- of what it replaced and it is in the conversation's changes
    local records = 0
    for _, event in ipairs(state.session:events()) do
        if event.kind == "edit" then
            records = records + 1
            assert(event.record.existed, "the file was there before")
            assert(event.record.copy and os.isfile(event.record.copy), "and a copy was kept")
        end
    end
    assert(records == 1, tostring(records))

    local source = websource.read(state, "src/main.c")
    assert(#source.marks.added > 0, "the line somebody typed is marked as changed")
end

function test_a_write_outside_the_project_is_refused()
    local state = _state()
    local ok, errors = websource.write(state, "../escape.txt", "no")
    assert(not ok and errors, tostring(errors))
    assert(not os.isfile(path.join(path.directory(state.harness:rootdir()), "escape.txt")))
end

function test_colouring_something_which_is_not_written_yet()
    local answer = websource.colour("x.lua", "local value = 1\n-- a comment")
    assert(answer.language == "lua", answer.language)
    assert(#answer.lines == 2, tostring(#answer.lines))
    local styles = {}
    for _, line in ipairs(answer.lines) do
        for _, token in ipairs(line.tokens) do
            styles[token.style] = true
        end
    end
    assert(styles["comment"], "a comment is a comment before it is saved too")
end

---------------------------------------------------------------------------------
-- the tree
---------------------------------------------------------------------------------

function test_the_tree_of_one_directory()
    local state = _state()
    local tree = webfiles.tree(state, "")
    assert(tree.dir == "", tree.dir)

    local byname = {}
    for _, entry in ipairs(tree.entries) do
        byname[entry.name] = entry
    end
    assert(byname["src"] and byname["src"].kind == "dir", "the directory is there")
    assert(byname["xmake.lua"] and byname["xmake.lua"].kind == "file")
    assert(tree.entries[1].kind == "dir", "the directories come first")

    -- and one branch of it, by the path the page was given
    local inside = webfiles.tree(state, "src")
    assert(#inside.entries == 1 and inside.entries[1].path == "src/main.c",
           inside.entries[1] and inside.entries[1].path)
end

function test_the_tree_says_what_this_conversation_changed()
    local state = _state()
    fs.writetext(path.join(state.harness:rootdir(), "xmake.lua"),
        "target(\"other\")\n", state.context)

    local marked = nil
    for _, entry in ipairs(webfiles.tree(state, "").entries) do
        if entry.name == "xmake.lua" then
            marked = entry
        end
    end
    assert(marked and marked.changed, "the file this conversation wrote is marked")
    assert(marked.undecided, "and it is waiting for a decision")
    assert(marked.removed and marked.removed > 0, "with what it did to it")
end

function test_the_tree_says_what_was_decided()
    -- the tree and the file's own header show the same fact, so the two never
    -- disagree about whether somebody has looked at a change
    local state = _state()
    local webchanges = import("harness.web.changes", {anonymous = true})
    fs.writetext(path.join(state.harness:rootdir(), "xmake.lua"),
        "target(\"other\")\n", state.context)

    local function entry()
        for _, one in ipairs(webfiles.tree(state, "").entries) do
            if one.name == "xmake.lua" then
                return one
            end
        end
    end

    assert(entry().undecided and not entry().kept, "it is waiting for a decision")
    webchanges.keep(state, "xmake.lua", true)
    assert(entry().kept and not entry().undecided, "and then it is kept")

    webchanges.revert(state, "xmake.lua")
    assert(entry().reverted, "or put back")
end

function test_the_tree_leaves_the_machinery_out()
    local state = _state()
    os.mkdir(path.join(state.harness:rootdir(), ".git"))
    os.mkdir(path.join(state.harness:rootdir(), "build"))
    for _, entry in ipairs(webfiles.tree(state, "").entries) do
        assert(entry.name ~= ".git" and entry.name ~= "build", entry.name)
    end
end

function test_a_branch_outside_the_project()
    local state = _state()
    assert(#webfiles.tree(state, "../..").entries == 0, "there is nothing to show there")
end

function test_the_directories_a_file_lives_in()
    assert(#webfiles.branches("src/main.c") == 1)
    assert(webfiles.branches("src/main.c")[1] == "src")
    assert(table.concat(webfiles.branches("a/b/c/d.lua"), ",") == "a,a/b,a/b/c")
    assert(#webfiles.branches("xmake.lua") == 0)
end
