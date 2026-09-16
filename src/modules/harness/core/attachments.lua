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
-- @file        attachments.lua
--

--
-- what a message carries besides the words
--
-- two things arrive too big to type. a file somebody named with `@`, and a
-- paste — a stack trace, a build log, a diff copied out of a browser. neither
-- belongs in the input box: three thousand pasted lines are three thousand
-- lines to redraw on every keystroke, and nobody can read them there anyway.
--
-- so a paste is put aside and a label goes in the text instead. the label is
-- what the person sees and edits and deletes; the content is attached when the
-- message is sent. `[Pasted text #1, 2413 lines]` is a thing you can move
-- around a sentence. the sentence with 2413 lines in the middle of it is not.
--
-- the other half is what happens when it is too big to send at all. it used to
-- be dropped in silence: `@big.json` matched, the file was read, the size was
-- over a limit, and nothing went out — no content, no mention, no way for
-- anybody to tell. now it goes out as what it is, with its path: the model has
-- `read_file` and can open it in pieces, and a file it knows about and must
-- read is worth more than a file nobody said anything about.
--
-- nothing here knows about a terminal or a browser. both front ends put their
-- pastes in the same store and send the same expanded text.
--

-- imports
import("harness.fs.fs")
import("harness.util.util")

-- how much of one attachment goes into the message itself
--
-- past this it is named rather than quoted. sixty four kilobytes is somewhere
-- around twenty thousand tokens: large enough that nothing anybody actually
-- pastes hits it, small enough that hitting it twice does not end the turn
local INLINE_MAX = 64 * 1024

-- and how much of them together
local TOTAL_MAX = 192 * 1024

-- how much of a file which is only named is shown anyway
--
-- enough to see what it is — the header of a log, the first object of a json,
-- the columns of a csv — so that the model can decide what to read rather than
-- reading a megabyte to find out it wanted the last page
local PREVIEW_LINES = 40

-- what is big enough to be worth putting aside rather than typing
--
-- a two line paste is a two line paste. by a dozen it is a thing with a shape,
-- which somebody wants to refer to and not look at
local PASTE_MIN_LINES = 12
local PASTE_MIN_BYTES = 2048

-- a store of what this conversation has pasted
--
-- @param opt   - dir   where the ones too big to keep in memory are written
--
function new(opt)
    opt = opt or {}
    return {dir = opt.dir, entries = {}, count = 0}
end

-- is this paste worth putting aside?
--
-- the answer for a short one is no: replacing three words with a label is
-- taking something away from the person who pasted them
--
function worthkeeping(content)
    if type(content) ~= "string" then
        return false
    end
    if #content >= PASTE_MIN_BYTES then
        return true
    end
    return _lines(content) >= PASTE_MIN_LINES
end

-- put one aside, and say what to write in its place
--
-- @param opt   - kind      "paste" by default
--              - name      what to call it, optional
--
-- @return      the entry, and the label to type in its place
--
function capture(store, content, opt)
    opt = opt or {}
    store.count = store.count + 1
    local entry = {
        ref = store.count,
        kind = opt.kind or "paste",
        name = opt.name,
        bytes = #content,
        lines = _lines(content)
    }

    -- the big ones go to disk rather than staying in this process: a session
    -- which pasted six logs should not be carrying six logs around, and the
    -- one place which needs the content again is the expansion
    if #content > INLINE_MAX and store.dir then
        entry.filepath = path.join(store.dir, string.format("paste-%d.txt", entry.ref))
        if try { function () io.writefile(entry.filepath, content) return true end } then
            entry.spilled = true
        end
    end
    if not entry.spilled then
        entry.content = content
    end
    store.entries[entry.ref] = entry
    return entry, label(entry)
end

-- what stands for it in the text
function label(entry)
    if entry.kind == "file" then
        return string.format("[File %s]", entry.name or "?")
    end
    return string.format("[Pasted text #%d, %d line%s]",
        entry.ref, entry.lines, entry.lines == 1 and "" or "s")
end

-- the pattern which finds a label again
--
-- it is matched and not remembered by position, because between the paste and
-- the send the person edits the line: they move the label, they type around
-- it, and they delete it when they change their mind. a label which is gone is
-- an attachment which is not sent, and that is the point of it being text
--
function _labelpattern()
    return "%[Pasted text #(%d+), %d+ lines?%]"
end

-- which of them the text still refers to, in the order they appear
function referenced(store, text)
    local refs = {}
    local seen = {}
    for ref in tostring(text or ""):gmatch(_labelpattern()) do
        local entry = store.entries[tonumber(ref)]
        if entry and not seen[entry.ref] then
            seen[entry.ref] = true
            table.insert(refs, entry)
        end
    end
    return refs
end

-- everything put aside so far
function all(store)
    local entries = {}
    for index = 1, store.count do
        if store.entries[index] then
            table.insert(entries, store.entries[index])
        end
    end
    return entries
end

-- the message to send
--
-- the words the person wrote, then the attachments they still refer to: the
-- pastes whose labels survived the editing, and the files they named with `@`.
--
-- @param opt   - rootdir   what the `@` paths are relative to
--
-- @return      the text to send
--
function expand(text, opt)
    opt = opt or {}
    if type(text) ~= "string" or text == "" then
        return text
    end

    local budget = {left = TOTAL_MAX}
    local parts = {}
    for _, entry in ipairs(opt.store and referenced(opt.store, text) or {}) do
        table.insert(parts, _pasted(entry, budget))
    end
    for _, entry in ipairs(_files(text, opt.rootdir)) do
        table.insert(parts, _file(entry, budget))
    end
    if #parts == 0 then
        return text
    end
    return text .. "\n\n" .. table.concat(parts, "\n\n")
end

-- the files named with `@`, in the order they appear and each of them once
function _files(text, rootdir)
    local entries = {}
    local seen = {}
    for reference in text:gmatch("@([%w%._%-/\\]+)") do
        local filepath = path.absolute(reference, rootdir or os.curdir())
        if not seen[filepath] and os.isfile(filepath) then
            seen[filepath] = true
            table.insert(entries, {name = reference, filepath = filepath,
                                   bytes = os.filesize(filepath) or 0})
        end
    end
    return entries
end

-- one pasted thing, quoted or named
function _pasted(entry, budget)
    local content = entry.content
    if not content and entry.filepath then
        content = _read(entry.filepath)
    end
    if not content then
        return string.format("### Pasted text #%d\n\n(it could not be read back)", entry.ref)
    end
    local header = string.format("### Pasted text #%d (%d lines, %s)",
        entry.ref, entry.lines, util.filesize(entry.bytes))
    if #content <= budget.left then
        budget.left = budget.left - #content
        return string.format("%s\n\n```\n%s\n```", header, content)
    end

    -- it did not fit. the file it was spilled to is the one thing which can
    -- still show all of it, so the model is told where that is
    local note = entry.filepath
        and string.format("It is too large to include. It is written in full at `%s`, "
                          .. "read it with `read_file`.", entry.filepath)
        or "It is too large to include in full."
    return string.format("%s\n\n%s\n\n%s", header, note, _preview(content))
end

-- one named file, quoted or named
function _file(entry, budget)
    local header = string.format("### %s (%s)", entry.name, util.filesize(entry.bytes))
    if fs.isbinary(entry.filepath) then
        return string.format("%s\n\nIt is a binary file, at `%s`.", header, entry.filepath)
    end
    if entry.bytes <= INLINE_MAX and entry.bytes <= budget.left then
        local content = _read(entry.filepath)
        if content then
            budget.left = budget.left - #content
            return string.format("%s\n\n```\n%s\n```", header, content)
        end
    end

    -- too big to quote, and unlike a paste it is already a file: the model has
    -- `read_file`, and being told which one beats being told nothing, which is
    -- what used to happen to anything over a limit
    return string.format(
        "%s\n\nIt is too large to include. Read it at `%s` with `read_file`, "
        .. "which takes a line range.\n\n%s",
        header, entry.filepath, _preview(_read(entry.filepath, PREVIEW_LINES * 400) or ""))
end

-- the head of something, so the model can tell what it is looking at
function _preview(content)
    local lines = {}
    for line in tostring(content):gmatch("([^\n]*)\n?") do
        if #lines >= PREVIEW_LINES then
            break
        end
        table.insert(lines, line)
    end
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    if #lines == 0 then
        return "It begins empty."
    end
    return string.format("It begins:\n\n```\n%s\n```", table.concat(lines, "\n"))
end

-- read a file, or as much of one as was asked for
--
-- the count is clamped to the size first: asking for more bytes than the file
-- holds reads none of them, which would turn a small file into an empty one
--
function _read(filepath, maxbytes)
    local size = os.filesize(filepath) or 0
    if maxbytes and maxbytes >= size then
        maxbytes = nil
    end
    return try {
        function ()
            local file = io.open(filepath, "rb")
            if not file then
                return nil
            end
            local content = maxbytes and file:read(maxbytes) or file:read("a")
            file:close()
            return content
        end
    }
end

-- how many lines something has
function _lines(content)
    local count = 1
    for _ in tostring(content):gmatch("\n") do
        count = count + 1
    end
    return count
end
