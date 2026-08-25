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
-- what git tells us about a project
---------------------------------------------------------------------------------

function test_a_quoted_path_is_unquoted()
    -- git quotes a path which carries a quote, a backslash or a control
    -- character, and the listing needs the path and not the quoting
    assert(webgit.unquote([["a b.lua"]]) == "a b.lua")
    assert(webgit.unquote([["say \"hi\".lua"]]) == [[say "hi".lua]])
    assert(webgit.unquote([["tab\there.lua"]]) == "tab\there.lua")
    assert(webgit.unquote("plain.lua") == "plain.lua")
end

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
    io.writefile(path.join(repodir, "xmake.lua"), "target(\"demo\")\n")
    io.writefile(path.join(repodir, ".gitignore"), "build/\n")
    git("add", ".")
    git("commit", "--quiet", "-m", "first")
    return repodir
end

function test_a_directory_which_is_not_a_repository()
    local plain = os.tmpfile() .. ".plain"
    os.mkdir(plain)
    assert(webgit.root(plain) == nil, "a plain directory has no repository")
    assert(webgit.lsfiles(plain) == nil, "and nothing to list")
    os.rmdir(plain)
end

function test_the_files_of_a_repository()
    local repodir = _repo()
    if not repodir then
        return
    end
    assert(webgit.root(repodir), "it is a repository")

    -- a file which is not committed yet is still one of the project's files,
    -- and one which is ignored is not
    io.writefile(path.join(repodir, "notes.md"), "# notes\n")
    os.mkdir(path.join(repodir, "build"))
    io.writefile(path.join(repodir, "build", "artifact.o"), "junk\n")

    local files = webgit.lsfiles(repodir)
    local seen = {}
    for _, filepath in ipairs(files) do
        seen[filepath] = true
    end
    assert(seen["xmake.lua"], "the tracked file is listed")
    assert(seen["notes.md"], "the new file is listed")
    assert(not seen["build/artifact.o"], "what git ignores stays out of the way")
    os.rmdir(repodir)
end

function test_the_listing_can_be_limited()
    local repodir = _repo()
    if not repodir then
        return
    end
    assert(#webgit.lsfiles(repodir, {limit = 1}) == 1)
    os.rmdir(repodir)
end
