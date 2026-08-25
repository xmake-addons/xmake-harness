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
-- @file        changes.lua
--

--
-- what the agent changed in this conversation
--
-- not `git status`: a working tree holds whatever was already in it — the
-- half-finished work of the morning, the build directory, the temporary file
-- somebody forgot — and none of that is what the question "what did it change"
-- means. so the list is the conversation's own: the files this session wrote,
-- and nothing else.
--
-- the before is not kept here either. every write already keeps a copy of what
-- it replaced, because that is what `/rewind` puts back, @see
-- harness.core.checkpoint — so the diff of a file is the copy taken before the
-- **first** edit of this session against what the file holds now, and reverting
-- one is restoring that copy. one mechanism, two things built on it.
--

-- imports
import("harness.ui.diff")
import("harness.ui.highlight")
import("harness.core.checkpoint")

-- how much of a file we are willing to read back
local MAXBYTES = 2 * 1024 * 1024

-- the counts of a file, remembered while neither side of it has changed
--
-- the list is asked for again every time the agent saves a file, and a project
-- with forty changed files would otherwise diff all forty of them on every
-- save — four hundred and sixty milliseconds of it, measured; with this, three.
--
-- the stamp is the pair of files the diff is *of*, so anything which changes
-- either of them changes the answer and the answer is computed again. it is a
-- modification time and a size, so a file rewritten to the same size within the
-- same second keeps its old counts for a moment: it is a number beside a
-- filename, and the diff itself is never cached — that is read from the two
-- files every time it is asked for.
--
function _cache()
    _g.counts = _g.counts or {}
    return _g.counts
end

-- forget what we know, e.g. the tests want a clean slate
function forget()
    _g.counts = {}
end

-- what the two sides of one change look like right now
function _stamp(record)
    return string.format("%s:%s|%s:%s",
        tostring(record.copy and os.mtime(record.copy) or 0),
        tostring(record.copy and os.filesize(record.copy) or 0),
        tostring(os.mtime(record.path) or 0),
        tostring(os.filesize(record.path) or 0))
end

-- the first thing this session did to each file, in order
--
-- the earliest record holds what the file had before the session touched it;
-- the later ones hold the versions in between, which nobody is asking about
--
-- the decisions — kept, reverted — are read here too, and only count when they
-- came *after* the last edit of that file: a change you kept and the agent then
-- edited again is a new change, and asking about it again is the point
--
-- @return  {{path = .., record = .., lastedit = 12, decision = "kept"}, ..}
--
function _firsts(session)
    local order = {}
    local byname = {}
    for _, event in ipairs(session and session:events() or {}) do
        local filepath = event.kind == "edit" and event.record and event.record.path
            or (event.kind == "keep" or event.kind == "revert") and event.path
        if filepath then
            if event.kind == "edit" then
                if not byname[filepath] then
                    byname[filepath] = {path = filepath, record = event.record, edits = 0}
                    table.insert(order, byname[filepath])
                end

                -- the last write as well as the first: the first answers "what
                -- has this conversation done to the file", the last answers
                -- "what did it just do", and both are things people ask
                byname[filepath].last = event.record
                byname[filepath].edits = byname[filepath].edits + 1
                byname[filepath].lastedit = event.seq or 0
                byname[filepath].decision = nil
            elseif byname[filepath] then
                byname[filepath].decision = event.kind == "revert" and "reverted"
                    or (event.kept ~= false and "kept" or nil)
            end
        end
    end
    return order, byname
end

-- what this conversation changed
--
-- @param state  the web conversation, @see harness.web.session
-- @return       {files = {{path, name, dir, added, removed, created, gone, kept}}}
--
function list(state)
    local rootdir = state.harness:rootdir()
    local files = {}
    local waiting, settled = 0, 0
    for _, entry in ipairs((_firsts(state.session))) do
        local change = _describe(entry, rootdir)
        change.kept = entry.decision == "kept"
        change.reverted = entry.decision == "reverted"
        change.undecided = entry.decision == nil
        if change.undecided then
            waiting = waiting + 1
        else
            settled = settled + 1
        end
        table.insert(files, change)
    end

    -- the two numbers the page is really asking for: how much is waiting for
    -- somebody, and how much has been dealt with. a list which only ever grew
    -- would never reach the state a working tree reaches after a commit
    return {files = files, root = rootdir, waiting = waiting, settled = settled}
end

-- one file, as the list shows it
function _describe(entry, rootdir)
    local filepath = entry.path
    local relative = _relative(filepath, rootdir)
    local change = {
        path = relative,
        fullpath = filepath,
        edits = entry.edits or 1,
        name = path.filename(filepath),
        dir = path.directory(relative) ~= "." and path.directory(relative) or "",
        created = entry.record.existed == false,
        gone = not os.isfile(filepath),
        bycommand = entry.record.bycommand or false,
        toobig = entry.record.toobig or false,
        nodiff = entry.record.nocopy or entry.record.toobig or false
    }

    -- a command wrote this one, and nobody knew which files it was about to
    -- write: there is no copy of the before, so there is no diff and no way
    -- back, @see harness.fs.observe
    if change.nodiff then
        return change
    end

    local counts = _counts(entry.record)
    change.added = counts.added
    change.removed = counts.removed
    change.unchanged = counts.added == 0 and counts.removed == 0
    return change
end

-- how much one file changed, computed once per version of it
function _counts(record)
    local cache = _cache()
    local stamp = _stamp(record)
    local known = cache[record.path]
    if known and known.stamp == stamp then
        return known
    end

    local before, after = _contents(record)
    local result = diff.compute(before or "", after or "")
    local counts = {stamp = stamp, added = result.added or 0, removed = result.removed or 0}
    cache[record.path] = counts
    return counts
end

-- the file as it was, and as it is
function _contents(record)
    local before = ""
    if record.existed and record.copy and os.isfile(record.copy) then
        before = _read(record.copy)
    end
    local after = os.isfile(record.path) and _read(record.path) or ""
    return before, after
end

-- read a file, unless it is unreasonable
function _read(filepath)
    if (os.filesize(filepath) or 0) > MAXBYTES then
        return nil
    end
    return try { function () return io.readfile(filepath) end } or ""
end

-- a path as somebody reads it, relative to the project when it is inside one
function _relative(filepath, rootdir)
    if not rootdir then
        return filepath
    end
    local relative = path.relative(filepath, rootdir)
    if relative and not relative:startswith("..") then
        return (relative:gsub("\\", "/"))
    end
    return filepath
end

-- the diff of one file, as lines a page can lay out
--
-- the same shape the terminal renders from — `diff.compute` — turned into rows
-- with their line numbers and their code already tokenized, so the page only
-- has to colour what it is given
--
-- @return  {path, language, lines = {{kind, oldline, newline, tokens}}}, or nil and why
--
-- @param opt   - base   what to compare against:
--                       "session" (the default) what the file held before this
--                       conversation first touched it, and "last" what it held
--                       before the most recent write
--
--                       a file this conversation created is entirely new
--                       against the first base, however small the last change
--                       to it was — which is right, and not what somebody who
--                       just asked for one comment is looking for
--
function filediff(state, filepath, opt)
    opt = opt or {}
    local entry = _find(state, filepath)
    if not entry then
        return nil, "this conversation did not change that file"
    end

    local record = entry.record
    if opt.base == "last" and entry.last then
        record = entry.last
    end
    if record.toobig then
        return nil, "the file was too big to keep a copy of"
    end
    if record.nocopy then
        return nil, record.removed
            and "a command removed this file, and no copy of it was kept"
            or "a command changed this file, and no copy of what it held before was kept"
    end

    local before, after = _contents(record)
    if before == nil or after == nil then
        return nil, "the file is too big to diff"
    end

    local language = highlight.language(record.path) or "text"
    local result = diff.compute(before, after)
    return {
        path = _relative(record.path, state.harness:rootdir()),
        language = language,
        base = opt.base == "last" and "last" or "session",
        edits = entry.edits or 1,
        created = record.existed == false,
        gone = not os.isfile(record.path),
        lines = _rows(result, language)
    }
end

-- the hunks, as flat rows
function _rows(result, language)
    local rows = {}
    local state = highlight.newstate()
    for _, hunk in ipairs(result.hunks or {}) do
        table.insert(rows, {kind = "hunk", text = string.format("@@ -%d +%d @@",
            hunk.oldstart or 0, hunk.newstart or 0)})
        local oldline = hunk.oldstart or 1
        local newline = hunk.newstart or 1
        for _, line in ipairs(hunk.lines or {}) do
            if line.kind == "add" then
                table.insert(rows, {kind = "add", newline = newline,
                                    tokens = _tokens(line.text, language, state)})
                newline = newline + 1
            elseif line.kind == "del" then
                table.insert(rows, {kind = "del", oldline = oldline,
                                    tokens = _tokens(line.text, language, state)})
                oldline = oldline + 1
            else
                table.insert(rows, {kind = "ctx", oldline = oldline, newline = newline,
                                    tokens = _tokens(line.text, language, state)})
                oldline = oldline + 1
                newline = newline + 1
            end
        end
    end
    return rows
end

-- one line, coloured by the harness's own highlighter
--
-- it happens here and not in the browser for the same reason the markdown does:
-- there is a highlighter in this process already, it knows the languages the
-- terminal knows, and a second one written in javascript would drift from it
--
function _tokens(text, language, state)
    local tokens = {}
    for _, token in ipairs(highlight.tokenize(text or "", language, state) or {}) do
        table.insert(tokens, {text = token.text, style = token.style})
    end
    return tokens
end

-- put one file back the way it was before this conversation touched it
--
-- @return  true, or nil and the reason
--
function revert(state, filepath)
    local entry = _find(state, filepath)
    if not entry then
        return nil, "this conversation did not change that file"
    end
    if entry.record.toobig then
        return nil, "no copy was kept of that file, it was too big"
    end
    if entry.record.nocopy then
        return nil, "a command changed this file and no copy was kept, there is nothing to put back"
    end

    local result = {restored = {}, removed = {}, failed = {}, skipped = {}}
    checkpoint.restoreone(entry.record, result)
    if #result.failed > 0 then
        return nil, "the file could not be put back"
    end
    _decide(state, entry.record.path, "revert")
    return true
end

-- keep one change, which only means stopping asking about it
--
-- there is nothing to write: the file already holds what the agent wrote. what
-- changes is the list, which is a list of decisions still to make
--
function keep(state, filepath, iskept)
    local entry = _find(state, filepath)
    if not entry then
        return nil, "this conversation did not change that file"
    end
    _decide(state, entry.record.path, "keep", iskept ~= false)
    return true
end

-- write the decision down where the conversation keeps everything else
--
-- in the log and not in this process: a decision which lived in the server's
-- memory would be lost the next time the harness restarted, and the list would
-- ask again about changes somebody had already looked at. the log ignores what
-- it does not know, so none of this reaches a model, @see harness.core.session
--
function _decide(state, filepath, kind, kept)
    state.session:append(kind, {path = filepath, kept = kept})
    try { function () state.session:save() end }
end

-- decide about all of them at once
--
-- the list is a list of decisions, and a list of twelve decisions which are all
-- the same decision is a chore. what it does not do is hide what it did: every
-- file is decided one by one and the failures come back named
--
-- @param what   "keep" or "revert"
-- @return       the number decided, and the ones which could not be
--
function all(state, what)
    local decided = 0
    local failed = {}
    for _, file in ipairs(list(state).files) do
        if what == "revert" then
            -- a change which was already put back has nothing left to undo,
            -- and one a command made has nothing to put back
            if not file.reverted and not file.nodiff then
                local ok, errors = revert(state, file.path)
                if ok then
                    decided = decided + 1
                else
                    table.insert(failed, {path = file.path, errors = errors})
                end
            end
        elseif not file.reverted and not file.kept then
            if keep(state, file.path, true) then
                decided = decided + 1
            end
        end
    end
    return decided, failed
end

-- find the change of the given path, by either of its names
function _find(state, filepath)
    if type(filepath) ~= "string" or filepath:trim() == "" then
        return nil
    end
    filepath = filepath:trim():gsub("\\", "/")
    local rootdir = state.harness:rootdir()
    local order = _firsts(state.session)
    for _, entry in ipairs(order) do
        if entry.path == filepath or _relative(entry.path, rootdir) == filepath then
            return entry
        end
    end
    return nil
end
