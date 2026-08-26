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
-- @file        source.lua
--

--
-- one file, as the page reads and writes it
--
-- the middle of the workspace is the file itself — all of it, coloured, with
-- what this conversation changed marked in the margin — and not a diff of it.
-- a diff answers "what moved"; the file answers "what does it say now", and
-- after deciding about a change the second question is the one left standing.
--
-- it is editable, so the same module writes it back. a write from the page goes
-- through the same door as a write from the agent, @see harness.fs.fs: it is
-- checked against the workspace, it keeps a copy of what it replaced, and it
-- lands in the conversation's list of changes like any other.
--

-- imports
import("harness.fs.fs")
import("harness.ui.diff")
import("harness.ui.highlight")
import("harness.web.changes", {alias = "webchanges"})

-- the biggest file worth opening in a browser
local MAXBYTES = 2 * 1024 * 1024

-- read one file of the project
--
-- @return  {path, language, lines = {{number, tokens}}, marks = {..}}, or nil and why
--
function read(state, filepath)
    local rootdir = state.harness:rootdir()
    local full, errors = _resolve(state, filepath)
    if not full then
        return nil, errors
    end
    if not os.isfile(full) then
        return nil, "there is no such file"
    end
    if (os.filesize(full) or 0) > MAXBYTES then
        return nil, "the file is too big to open here"
    end

    local text = try { function () return io.readfile(full) end }
    if text == nil then
        return nil, "the file could not be read"
    end
    if _isbinary(text) then
        return nil, "this is a binary file"
    end

    local language = highlight.language(full) or "text"
    local lines = _lines(text, language)
    return {
        path = _relative(full, rootdir),
        language = language,
        lines = lines,
        marks = marks(state, full, {lines = #lines}),
        bytes = #text
    }
end

-- what this conversation changed about this file, by line
--
-- the page draws the file and marks the margin, so what it needs is not a diff
-- but the lines a diff would have coloured: which of the lines it is showing
-- are new, and where lines were taken out from between them
--
-- @return  {added = {[12] = true}, removed = {[11] = 3}, base = "session"}
--
function marks(state, filepath, opt)
    opt = opt or {}

    -- what was added, and what was taken out *with the text of it*
    --
    -- a file view which only says "two lines went here" is telling somebody
    -- about a hole and refusing to say what was in it. the terminal shows the
    -- removed lines themselves, in red, above the ones which replaced them,
    -- @see harness.ui.diff — so the page is given the same thing to draw.
    --
    -- the added lines are a list of numbers and the removed ones a list of
    -- {after, lines}: a table keyed by line number is a map to lua and a sparse
    -- array to json, and json refuses to write one of those
    --
    local result = {added = {}, removed = {}, edits = 0}
    local answer = webchanges.filediff(state, filepath, {base = opt.base or "last"})
    if not answer then
        return result
    end
    result.edits = answer.edits or 1
    result.created = answer.created or false

    -- against the last write, not against the start of the conversation: a file
    -- the conversation created is entirely new against the start of it, so
    -- every line would be marked, @see harness.web.changes.filediff
    local gaps = {}
    local order = {}
    local previous = 0
    for _, line in ipairs(answer.lines) do
        if line.kind == "add" and line.newline then
            table.insert(result.added, line.newline)
            previous = line.newline
        elseif line.kind == "del" then
            if not gaps[previous] then
                gaps[previous] = {after = previous, lines = {}}
                table.insert(order, gaps[previous])
            end
            table.insert(gaps[previous].lines, {tokens = line.tokens or {}})
        elseif line.kind == "ctx" and line.newline then
            previous = line.newline
        end
    end
    for _, gap in ipairs(order) do
        table.insert(result.removed, gap)
    end
    table.sort(result.removed, function (a, b) return a.after < b.after end)

    -- and when even the last write is the whole file — it was created by the
    -- one write there has been — the marks say nothing the header does not
    -- already say with one word, so they are dropped rather than painted over
    -- everything
    if result.created and #result.added >= (opt.lines or 0) and #result.added > 0 then
        result.added = {}
        result.wholenew = true
    end
    return result
end

-- the lines of a file, coloured
function _lines(text, language)
    local lines = {}
    local state = highlight.newstate()
    local number = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        table.insert(lines, {number = number, tokens = _tokens(line, language, state)})
    end

    -- a file which ends with a newline has one empty line too many this way,
    -- and an editor which shows it teaches everybody a wrong thing about the
    -- file. an empty line is one token holding nothing, not no tokens
    if #lines > 1 and text:endswith("\n") and _isempty(lines[#lines]) then
        table.remove(lines)
    end
    return lines
end

-- is there anything on this line?
function _isempty(line)
    for _, token in ipairs(line.tokens or {}) do
        if (token.text or "") ~= "" then
            return false
        end
    end
    return true
end

-- one line, as tokens
function _tokens(text, language, state)
    local tokens = {}
    for _, token in ipairs(highlight.tokenize(text or "", language, state) or {}) do
        table.insert(tokens, {text = token.text, style = token.style})
    end
    return tokens
end

-- colour a piece of text which has not been written yet
--
-- the page re-colours what somebody is typing by asking for it, rather than
-- carrying a second highlighter of its own which would drift from this one
--
function colour(filepath, text)
    local language = highlight.language(filepath or "") or "text"
    return {language = language, lines = _lines(text or "", language)}
end

-- write one file back
--
-- @return  true, or nil and the reason
--
function write(state, filepath, content)
    local rootdir = state.harness:rootdir()
    local full, errors = _resolve(state, filepath)
    if not full then
        return nil, errors
    end
    if type(content) ~= "string" then
        return nil, "there is nothing to write"
    end

    -- the same door the agent writes through: the workspace check, the copy of
    -- what it replaced, and the entry in the conversation's changes
    local context = _context(state)
    local ok, writeerrors
    try {
        function ()
            fs.writetext(full, content, context)
            ok = true
        end,
        catch {
            function (errs)
                writeerrors = tostring(errs)
            end
        }
    }
    if not ok then
        return nil, writeerrors or "the file could not be written"
    end
    try { function () state.session:save() end }
    return true
end

-- what the filesystem layer expects of whoever calls it
--
-- the configuration is part of it: the workspace boundary is the project plus
-- whatever the sandbox settings allow, @see harness.fs.fs.inworkspace
--
function _context(state)
    return {
        session = state.session,
        cwd = state.harness:rootdir(),
        harness = state.harness,
        config = state.harness.config and state.harness:config() or {}
    }
end

-- a path inside the project, and nothing else
function _resolve(state, filepath)
    if type(filepath) ~= "string" or filepath:trim() == "" then
        return nil, "no file was named"
    end
    filepath = filepath:trim():gsub("\\", "/")
    local full = path.absolute(filepath, state.harness:rootdir())
    if not fs.inworkspace(_context(state), full) then
        return nil, "that file is outside the project"
    end
    return full
end

-- a path as somebody reads it
function _relative(filepath, rootdir)
    local relative = path.relative(filepath, rootdir)
    if relative and not relative:startswith("..") then
        return (relative:gsub("\\", "/"))
    end
    return filepath
end

-- is this a file of bytes rather than of lines?
function _isbinary(text)
    return text:find("\0", 1, true) ~= nil
end
