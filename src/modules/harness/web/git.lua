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
-- @file        git.lua
--

--
-- the working tree, as git sees it
--
-- the changes view is not the agent's memory of what it did: it is `git status`
-- and `git diff`, read fresh every time it is asked for. an edit somebody made
-- in their editor shows up beside the ones the agent made, reverting one is
-- `git checkout` and not an undo stack of our own, and closing the browser
-- loses nothing — because none of it was ever ours to lose.
--
-- everything here is one process away: `git` is not a dependency we ship, it is
-- the thing the user already has and already trusts with this repository.
--

-- imports
import("core.base.json")
import("harness.ui.highlight")

-- how much of one file we are willing to read
local MAXBYTES = 2 * 1024 * 1024

-- run git in the given directory
--
-- @return  the stdout, or nil and the reason
--
function _git(rootdir, argv, opt)
    opt = opt or {}
    local outdata, errdata
    local errors
    try {
        function ()
            outdata, errdata = os.iorunv("git", argv, {curdir = rootdir})
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    if outdata == nil then
        return nil, errors or "git could not be run"
    end
    return outdata
end

-- where the repository starts, or nil when there is none
function root(rootdir)
    local out = _git(rootdir, {"rev-parse", "--show-toplevel"})
    if not out then
        return nil
    end
    out = out:trim()
    return out ~= "" and path.normalize(out) or nil
end

-- is there a commit to compare against?
--
-- a repository which has just been created has no HEAD, and every command
-- which names one fails in it. it is a real state and not an error: everything
-- in it is simply new
--
function _hashead(rootdir)
    return _git(rootdir, {"rev-parse", "--verify", "--quiet", "HEAD"}) ~= nil
end

-- what has changed
--
-- @return  {isrepo = true, root = "..", files = {..}}, or {isrepo = false}
--
function status(rootdir)
    local repodir = root(rootdir)
    if not repodir then
        return {isrepo = false, root = rootdir}
    end

    -- `core.quotepath=false` keeps a utf-8 path readable instead of octal
    local out = _git(repodir, {"-c", "core.quotepath=false", "status", "--porcelain",
                               "--untracked-files=all"})
    if not out then
        return {isrepo = true, root = repodir, files = {}}
    end

    local counts = _numstat(repodir)
    local files = {}
    for _, entry in ipairs(porcelain(out)) do
        local count = counts[entry.path]
        if entry.untracked then
            count = _countlines(path.join(repodir, entry.path))
        end
        table.insert(files, {
            path = entry.path,
            name = path.filename(entry.path),
            dir = path.directory(entry.path) ~= "." and path.directory(entry.path) or "",
            status = entry.status,
            staged = entry.staged,
            untracked = entry.untracked,
            deleted = entry.deleted,
            renamedfrom = entry.renamedfrom,
            added = (count or {}).added or 0,
            removed = (count or {}).removed or 0,
            binary = (count or {}).binary or false
        })
    end
    table.sort(files, function (a, b) return a.path < b.path end)
    return {isrepo = true, root = repodir, files = files}
end

-- parse `git status --porcelain`
--
-- public because it is a parser: it is pure, it is where the mistakes live, and
-- a test which has to make a repository to check a string split is a test
-- nobody runs
--
-- each line is `XY path`, and a rename is `XY old -> new`. a path which
-- contains a quote, a backslash or a control character arrives quoted in the c
-- style, and that is the one case which has to be undone.
--
-- not `-z`, tempting as it is: `os.iorunv` reads the output through
-- `io.readfile`, which guesses the encoding, and a stream full of nul bytes
-- guesses utf-16. the text comes back as mojibake and the parse finds nothing,
-- @see xmake/core/base/io.lua
--
function porcelain(out)
    local entries = {}
    for _, line in ipairs((out or ""):split("\n", {plain = true})) do
        if #line > 3 then
            local index = line:sub(1, 1)
            local worktree = line:sub(2, 2)
            local rest = line:sub(4)
            local record = {
                status = _statusname(index, worktree),
                staged = index ~= " " and index ~= "?",
                untracked = index == "?" and worktree == "?",
                deleted = index == "D" or worktree == "D"
            }
            local from, to = rest:match("^(.+)%s+%->%s+(.+)$")
            if from and (index == "R" or index == "C" or worktree == "R") then
                record.renamedfrom = unquote(from)
                record.path = unquote(to)
            else
                record.path = unquote(rest)
            end
            table.insert(entries, record)
        end
    end
    return entries
end

-- undo git's c-style quoting, when it used it
function unquote(str)
    if not str:startswith("\"") then
        return str
    end
    local body = str:sub(2, #str - 1)
    local out = {}
    local idx = 1
    while idx <= #body do
        local ch = body:sub(idx, idx)
        if ch == "\\" then
            local next = body:sub(idx + 1, idx + 1)
            local escapes = {n = "\n", t = "\t", r = "\r", ["\""] = "\"", ["\\"] = "\\"}
            local octal = body:match("^(%d%d%d)", idx + 1)
            if octal then
                table.insert(out, string.char(tonumber(octal, 8)))
                idx = idx + 4
            else
                table.insert(out, escapes[next] or next)
                idx = idx + 2
            end
        else
            table.insert(out, ch)
            idx = idx + 1
        end
    end
    return table.concat(out)
end

-- what to call this state, in one word
function _statusname(index, worktree)
    if index == "?" then
        return "added"
    elseif index == "R" or worktree == "R" then
        return "renamed"
    elseif index == "D" or worktree == "D" then
        return "deleted"
    elseif index == "A" then
        return "added"
    elseif index == "U" or worktree == "U" then
        return "conflicted"
    end
    return "modified"
end

-- how much each tracked file changed, in one call
function _numstat(repodir)
    local argv = {"diff", "--numstat", "--no-color"}
    if _hashead(repodir) then
        table.insert(argv, "HEAD")
    else
        table.insert(argv, "--cached")
    end
    local out = _git(repodir, argv)
    local counts = {}
    for _, line in ipairs((out or ""):split("\n", {plain = true})) do
        local added, removed, filepath = line:match("^(%S+)%s+(%S+)%s+(.+)$")
        if filepath then
            counts[filepath] = {
                added = tonumber(added) or 0,
                removed = tonumber(removed) or 0,
                binary = added == "-" and removed == "-"
            }
        end
    end
    return counts
end

-- how many lines a new file has
function _countlines(filepath)
    if not os.isfile(filepath) then
        return {added = 0, removed = 0}
    end
    local size = os.filesize(filepath)
    if size and size > MAXBYTES then
        return {added = 0, removed = 0, binary = true}
    end
    local count = 0
    local ok = try {
        function ()
            for _ in io.lines(filepath) do
                count = count + 1
            end
            return true
        end
    }
    return {added = ok and count or 0, removed = 0, binary = not ok}
end

-- the diff of one file, as lines a page can lay out
--
-- @return  {path = .., language = .., lines = {{kind, oldline, newline, tokens}}}
--
function filediff(rootdir, filepath)
    local repodir = root(rootdir)
    if not repodir then
        return nil, "this is not a git repository"
    end
    local safe, errors = safepath(repodir, filepath)
    if not safe then
        return nil, errors
    end

    local language = highlight.language(safe) or "text"
    local text
    if _istracked(repodir, safe) then
        local argv = {"diff", "--no-color", "--unified=3"}
        if _hashead(repodir) then
            table.insert(argv, "HEAD")
        end
        table.insert(argv, "--")
        table.insert(argv, safe)
        text = _git(repodir, argv)
    else
        -- an untracked file has nothing to be compared against, so it is shown
        -- as what it is: a file which is entirely new
        return _wholefile(repodir, safe, language)
    end
    if not text or text:trim() == "" then
        return {path = safe, language = language, lines = {}, unchanged = true}
    end
    return {path = safe, language = language, lines = parsediff(text, language)}
end

-- is git tracking this file?
function _istracked(repodir, filepath)
    local out = _git(repodir, {"ls-files", "--error-unmatch", "--", filepath})
    return out ~= nil
end

-- a new file, as one long addition
function _wholefile(repodir, filepath, language)
    local fullpath = path.join(repodir, filepath)
    if not os.isfile(fullpath) then
        return {path = filepath, language = language, lines = {}, missing = true}
    end
    if (os.filesize(fullpath) or 0) > MAXBYTES then
        return {path = filepath, language = language, lines = {}, binary = true}
    end

    local lines = {}
    local state = highlight.newstate()
    local number = 0
    local ok = try {
        function ()
            for line in io.lines(fullpath) do
                number = number + 1
                table.insert(lines, {kind = "add", newline = number,
                                     tokens = _tokens(line, language, state)})
            end
            return true
        end
    }
    if not ok then
        return {path = filepath, language = language, lines = {}, binary = true}
    end
    return {path = filepath, language = language, lines = lines, created = true}
end

-- parse a unified diff, the same reason as above
--
-- only what a diff of one file can contain: the hunk headers and the three
-- kinds of line. the file headers are skipped, because the page already knows
-- which file it asked for
--
function parsediff(text, language)
    local lines = {}
    local state = highlight.newstate()
    local oldline, newline = 0, 0
    local inhunk = false
    for _, line in ipairs(text:split("\n", {plain = true})) do
        local from, to = line:match("^@@%s+%-(%d+)[,%d]*%s+%+(%d+)[,%d]*%s+@@")
        if from then
            oldline = tonumber(from)
            newline = tonumber(to)
            inhunk = true
            table.insert(lines, {kind = "hunk", text = line})
        elseif not inhunk then
            -- the `diff --git`, `index`, `---` and `+++` headers
        elseif line:startswith("+") then
            table.insert(lines, {kind = "add", newline = newline,
                                 tokens = _tokens(line:sub(2), language, state)})
            newline = newline + 1
        elseif line:startswith("-") then
            table.insert(lines, {kind = "del", oldline = oldline,
                                 tokens = _tokens(line:sub(2), language, state)})
            oldline = oldline + 1
        elseif line:startswith("\\") then
            -- "\ No newline at end of file"
        elseif line:startswith(" ") or line == "" then
            table.insert(lines, {kind = "ctx", oldline = oldline, newline = newline,
                                 tokens = _tokens(line:sub(2), language, state)})
            oldline = oldline + 1
            newline = newline + 1
        end
    end
    return lines
end

-- one line, coloured by the harness's own highlighter
--
-- it happens here and not in the browser for the same reason the markdown does:
-- there is a highlighter in this process already, it knows the languages the
-- terminal knows, and a second one written in javascript would drift from it
--
function _tokens(text, language, state)
    local tokens = highlight.tokenize(text, language, state)
    local result = {}
    for _, token in ipairs(tokens or {}) do
        table.insert(result, {text = token.text, style = token.style})
    end
    return result
end

-- put one file back the way it was
--
-- @return  true, or nil and the reason
--
function revert(rootdir, filepath)
    local repodir = root(rootdir)
    if not repodir then
        return nil, "this is not a git repository"
    end
    local safe, errors = safepath(repodir, filepath)
    if not safe then
        return nil, errors
    end

    -- a file git never knew about cannot be checked out of anything: reverting
    -- it means removing it, which is what it means in every git ui too
    if not _istracked(repodir, safe) then
        local fullpath = path.join(repodir, safe)
        if not os.isfile(fullpath) then
            return nil, "there is no such file"
        end
        os.rm(fullpath)
        return true
    end
    if not _hashead(repodir) then
        return nil, "there is no commit to go back to yet"
    end

    -- both halves: the index and the working tree, so a staged change is
    -- reverted as completely as an unstaged one
    if not _git(repodir, {"reset", "--quiet", "HEAD", "--", safe}) then
        return nil, "the change could not be unstaged"
    end
    if not _git(repodir, {"checkout", "--", safe}) then
        return nil, "the file could not be restored"
    end
    return true
end

-- a path inside the repository, and nothing else
--
-- the page sends back a path it was given, but a page is a thing anybody may
-- send a request to, @see harness.http.server
--
function safepath(repodir, filepath)
    if type(filepath) ~= "string" or filepath:trim() == "" then
        return nil, "no file was named"
    end
    filepath = filepath:trim():gsub("\\", "/")
    if filepath:startswith("/") or filepath:find("..", 1, true) or filepath:find(":", 1, true) then
        return nil, "the path leaves the repository"
    end
    return filepath
end
