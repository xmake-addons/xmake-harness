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
-- @file        files.lua
--

--
-- the files of the project, for the `@` completion
--
-- typing `@` in the box should offer the files the way an editor does, which
-- means answering while somebody is still typing. so the list is taken once and
-- kept for a short while: a repository does not change much between two
-- keystrokes, and walking twenty thousand paths for each of them would make the
-- completion slower than typing the name out.
--
-- `git ls-files` when there is a repository, because it is fast and it already
-- knows what is ignored; the walker otherwise.
--

-- imports
import("harness.fs.fs")
import("harness.web.git", {alias = "webgit"})

-- how long a listing is worth keeping, and how much of one we take
local TTL = 20000
local MAXFILES = 20000

-- the cached listings, one per project
function _cache()
    _g.listings = _g.listings or {}
    return _g.listings
end

-- forget what we know, e.g. the project was changed
function forget()
    _g.listings = {}
end

-- every file of the project, relative to it
function listing(rootdir)
    local cache = _cache()
    local entry = cache[rootdir]
    if entry and os.mclock() - entry.time < TTL then
        return entry.files
    end

    local files = _fromgit(rootdir) or _fromwalk(rootdir)
    cache[rootdir] = {files = files, time = os.mclock()}
    return files
end

-- what git is tracking, plus what it does not know about yet
function _fromgit(rootdir)
    if not webgit.root(rootdir) then
        return nil
    end
    local out
    try {
        function ()
            out = os.iorunv("git", {"-c", "core.quotepath=false", "ls-files", "--cached",
                                    "--others", "--exclude-standard"}, {curdir = rootdir})
        end
    }
    if not out then
        return nil
    end
    local files = {}
    for _, line in ipairs(out:split("\n", {plain = true})) do
        local filepath = webgit.unquote(line:trim())
        if filepath ~= "" then
            table.insert(files, filepath)
            if #files >= MAXFILES then
                break
            end
        end
    end
    return files
end

-- everything under the project which is not obviously not wanted
function _fromwalk(rootdir)
    local files = {}
    for _, filepath in ipairs(fs.walk(rootdir, {maxcount = MAXFILES})) do
        -- the parentheses matter: `gsub` returns the count as well, and
        -- `table.insert` would take it for the position to insert at
        table.insert(files, (path.relative(filepath, rootdir):gsub("\\", "/")))
    end
    return files
end

-- the files which match what has been typed so far
--
-- the ranking is what an editor does and what everybody expects from it: the
-- name you are typing first, then a name which contains it, then a path which
-- does, and the shorter of two matches before the longer one
--
-- @return  {{path = "src/main.c", name = "main.c", dir = "src"}, ..}
--
function search(rootdir, query, opt)
    opt = opt or {}
    local limit = opt.limit or 12
    local files = listing(rootdir)
    query = (query or ""):trim():gsub("\\", "/"):lower()

    local scored = {}
    for _, filepath in ipairs(files) do
        local score = _score(filepath:lower(), query)
        if score then
            table.insert(scored, {path = filepath, score = score})
        end
    end
    table.sort(scored, function (a, b)
        if a.score ~= b.score then
            return a.score < b.score
        end
        if #a.path ~= #b.path then
            return #a.path < #b.path
        end
        return a.path < b.path
    end)

    local results = {}
    for index, entry in ipairs(scored) do
        if index > limit then
            break
        end
        local dir = path.directory(entry.path)
        table.insert(results, {
            path = entry.path,
            name = path.filename(entry.path),
            dir = (dir and dir ~= "." ) and dir or ""
        })
    end
    return results
end

-- how well one path matches, lower is better, nil is not at all
function _score(filepath, query)
    if query == "" then
        return 4
    end
    local name = path.filename(filepath)
    if name:startswith(query) then
        return 1
    end
    if name:find(query, 1, true) then
        return 2
    end
    if filepath:find(query, 1, true) then
        return 3
    end
    return nil
end
