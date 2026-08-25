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
-- @file        webgit.lua
--

-- imports
import("harness.web.git", {alias = "webgit"})

---------------------------------------------------------------------------------
-- reading what git says
---------------------------------------------------------------------------------

function test_the_states_of_the_working_tree()
    local entries = webgit.porcelain(table.concat({
        " M src/main.c",
        "?? notes.md",
        "A  added.lua",
        " D gone.txt",
        "M  staged.lua"
    }, "\n"))
    assert(#entries == 5, tostring(#entries))
    assert(entries[1].path == "src/main.c", entries[1].path)
    assert(entries[1].status == "modified", entries[1].status)
    assert(entries[1].staged == false)
    assert(entries[2].untracked and entries[2].status == "added")
    assert(entries[3].staged and entries[3].status == "added")
    assert(entries[4].deleted and entries[4].status == "deleted")
    assert(entries[5].staged and entries[5].status == "modified")
end

function test_a_rename_keeps_where_it_came_from()
    local entries = webgit.porcelain("R  old/name.lua -> new/name.lua")
    assert(#entries == 1)
    assert(entries[1].path == "new/name.lua", entries[1].path)
    assert(entries[1].renamedfrom == "old/name.lua", tostring(entries[1].renamedfrom))
    assert(entries[1].status == "renamed")
end

function test_a_quoted_path_is_unquoted()
    -- git quotes a path which carries a quote, a backslash or a control
    -- character, and the page needs the path and not the quoting
    assert(webgit.unquote([["a b.lua"]]) == "a b.lua")
    assert(webgit.unquote([["say \"hi\".lua"]]) == [[say "hi".lua]])
    assert(webgit.unquote([["tab\there.lua"]]) == "tab\there.lua")
    assert(webgit.unquote("plain.lua") == "plain.lua")
end

function test_an_empty_status_is_a_clean_tree()
    assert(#webgit.porcelain("") == 0)
    assert(#webgit.porcelain(nil) == 0)
end

---------------------------------------------------------------------------------
-- reading a diff
---------------------------------------------------------------------------------

local DIFF = table.concat({
    "diff --git a/xmake.lua b/xmake.lua",
    "index 1111111..2222222 100644",
    "--- a/xmake.lua",
    "+++ b/xmake.lua",
    "@@ -10,6 +10,7 @@ target(\"demo\")",
    "     set_kind(\"binary\")",
    "-    add_files(\"src/old.c\")",
    "+    add_files(\"src/new.c\")",
    "+    add_deps(\"other\")",
    "     set_default(true)",
    "\\ No newline at end of file"
}, "\n")

function test_the_lines_of_a_diff_know_where_they_are()
    local lines = webgit.parsediff(DIFF, "lua")
    local kinds = {}
    for _, line in ipairs(lines) do
        table.insert(kinds, line.kind)
    end
    assert(table.concat(kinds, ",") == "hunk,ctx,del,add,add,ctx", table.concat(kinds, ","))

    -- the numbering is the point of a diff view: an added line has a new number
    -- and no old one, and a removed line the other way round
    assert(lines[2].oldline == 10 and lines[2].newline == 10)
    assert(lines[3].oldline == 11 and lines[3].newline == nil)
    assert(lines[4].newline == 11 and lines[4].oldline == nil)
    assert(lines[5].newline == 12)
    assert(lines[6].oldline == 12 and lines[6].newline == 13)
end

function test_the_headers_of_a_diff_are_not_lines()
    -- `--- a/x` and `+++ b/x` begin with the same characters as a removed and an
    -- added line, and a parser which took them for one would show them
    local lines = webgit.parsediff(DIFF, "lua")
    for _, line in ipairs(lines) do
        local text = ""
        for _, token in ipairs(line.tokens or {}) do
            text = text .. token.text
        end
        assert(not text:startswith("-- a/"), text)
        assert(not text:startswith("++ b/"), text)
    end
end

function test_the_code_of_a_diff_is_coloured()
    local lines = webgit.parsediff(DIFF, "lua")
    local styles = {}
    for _, line in ipairs(lines) do
        for _, token in ipairs(line.tokens or {}) do
            styles[token.style] = true
        end
    end
    assert(styles["string"], "the strings must be coloured")
    assert(styles["func"] or styles["keyword"], "the code must be tokenized at all")
end

function test_a_diff_of_nothing()
    assert(#webgit.parsediff("", "lua") == 0)
end

---------------------------------------------------------------------------------
-- what a page may ask for
---------------------------------------------------------------------------------

function test_a_path_may_not_leave_the_repository()
    -- the page sends back a path it was given, but a page is a thing anybody
    -- may send a request to
    assert(webgit.safepath("/repo", "src/main.c") == "src/main.c")
    assert(webgit.safepath("/repo", "src\\main.c") == "src/main.c")
    assert(webgit.safepath("/repo", "../../etc/passwd") == nil)
    assert(webgit.safepath("/repo", "/etc/passwd") == nil)
    assert(webgit.safepath("/repo", "C:/windows") == nil)
    assert(webgit.safepath("/repo", "") == nil)
    assert(webgit.safepath("/repo", nil) == nil)
end

---------------------------------------------------------------------------------
-- and against a real repository
---------------------------------------------------------------------------------

-- make a repository with one commit in it, or nil when there is no git here
function _repo()
    local ok = try { function () os.iorunv("git", {"--version"}) return true end }
    if not ok then
        return nil
    end
    local repodir = os.tmpfile() .. ".repo"
    os.mkdir(repodir)
    local function git(...)
        os.iorunv("git", table.pack(...), {curdir = repodir})
    end
    git("init", "--quiet")
    git("config", "user.email", "tests@xmake.io")
    git("config", "user.name", "tests")
    git("config", "commit.gpgsign", "false")
    io.writefile(path.join(repodir, "xmake.lua"), "target(\"demo\")\n    set_kind(\"binary\")\n")
    git("add", ".")
    git("commit", "--quiet", "-m", "first")
    return repodir
end

function test_a_directory_which_is_not_a_repository()
    local plain = os.tmpfile() .. ".plain"
    os.mkdir(plain)
    local status = webgit.status(plain)
    assert(status.isrepo == false, "a plain directory is not a repository")
    os.rmdir(plain)
end

function test_a_change_shows_up_and_can_be_put_back()
    local repodir = _repo()
    if not repodir then
        return
    end

    -- nothing has changed yet
    local status = webgit.status(repodir)
    assert(status.isrepo, "it is a repository")
    assert(#status.files == 0, tostring(#status.files))

    -- change one file and add another
    io.writefile(path.join(repodir, "xmake.lua"),
        "target(\"demo\")\n    set_kind(\"static\")\n    add_files(\"src/*.c\")\n")
    io.writefile(path.join(repodir, "notes.md"), "# notes\n")

    status = webgit.status(repodir)
    assert(#status.files == 2, tostring(#status.files))
    local byname = {}
    for _, file in ipairs(status.files) do
        byname[file.path] = file
    end
    assert(byname["xmake.lua"].status == "modified", byname["xmake.lua"].status)
    assert(byname["xmake.lua"].added == 2 and byname["xmake.lua"].removed == 1,
           string.format("+%d -%d", byname["xmake.lua"].added, byname["xmake.lua"].removed))
    assert(byname["notes.md"].untracked, "the new file is untracked")
    assert(byname["notes.md"].added == 1, tostring(byname["notes.md"].added))

    -- the diff of the changed one has both halves of the change
    local diff = webgit.filediff(repodir, "xmake.lua")
    local kinds = {}
    for _, line in ipairs(diff.lines) do
        kinds[line.kind] = (kinds[line.kind] or 0) + 1
    end
    assert(kinds.add == 2 and kinds.del == 1, string.format("+%d -%d",
        kinds.add or 0, kinds.del or 0))
    assert(diff.language == "lua", diff.language)

    -- a file git never knew about is shown whole
    local whole = webgit.filediff(repodir, "notes.md")
    assert(whole.created, "an untracked file is all new")
    assert(#whole.lines == 1, tostring(#whole.lines))

    -- and putting them back is git's own doing
    assert(webgit.revert(repodir, "xmake.lua"))
    assert(webgit.revert(repodir, "notes.md"))
    assert(not os.isfile(path.join(repodir, "notes.md")), "an untracked file is removed")
    assert(#webgit.status(repodir).files == 0, "the tree is clean again")

    os.rmdir(repodir)
end

function test_a_file_which_is_not_there()
    local repodir = _repo()
    if not repodir then
        return
    end
    local ok, errors = webgit.revert(repodir, "nowhere.lua")
    assert(not ok and errors, tostring(errors))
    os.rmdir(repodir)
end
