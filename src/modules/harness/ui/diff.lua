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
-- @file        diff.lua
--

--
-- the line diff, it is used by the file editing tools
--
-- we compute the diff in two steps: the common prefix/suffix are trimmed
-- first, then a small lcs is run on the rest, so the typical edits produce
-- exactly the hunks a human would expect, without any heavy algorithm.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.highlight")

-- the maximum lines of the lcs window
local MAX_LCS_LINES = 400

-- compute the diff of the two texts
--
-- @return  {added = 2, removed = 1, hunks = {{oldstart = .., newstart = .., lines = {{kind = "add"/"del"/"keep", text = ..}}}}}
--
function compute(oldtext, newtext)
    local oldlines = text.lines(oldtext or "")
    local newlines = text.lines(newtext or "")
    local prefix = 0
    while prefix < #oldlines and prefix < #newlines and oldlines[prefix + 1] == newlines[prefix + 1] do
        prefix = prefix + 1
    end
    local suffix = 0
    while suffix < (#oldlines - prefix) and suffix < (#newlines - prefix)
        and oldlines[#oldlines - suffix] == newlines[#newlines - suffix] do
        suffix = suffix + 1
    end

    local oldmid = {}
    for idx = prefix + 1, #oldlines - suffix do
        table.insert(oldmid, oldlines[idx])
    end
    local newmid = {}
    for idx = prefix + 1, #newlines - suffix do
        table.insert(newmid, newlines[idx])
    end

    local ops
    if #oldmid <= MAX_LCS_LINES and #newmid <= MAX_LCS_LINES then
        ops = _lcsdiff(oldmid, newmid)
    else
        ops = {}
        for _, line in ipairs(oldmid) do
            table.insert(ops, {kind = "del", text = line})
        end
        for _, line in ipairs(newmid) do
            table.insert(ops, {kind = "add", text = line})
        end
    end

    -- rebuild the whole operation list with the trimmed parts
    local all = {}
    for idx = 1, prefix do
        table.insert(all, {kind = "keep", text = oldlines[idx]})
    end
    for _, op in ipairs(ops) do
        table.insert(all, op)
    end
    for idx = #oldlines - suffix + 1, #oldlines do
        table.insert(all, {kind = "keep", text = oldlines[idx]})
    end
    return _makehunks(all)
end

-- compute the diff operations with the lcs algorithm
function _lcsdiff(a, b)
    local n, m = #a, #b
    local matrix = {}
    for i = 0, n do
        matrix[i] = {}
        for j = 0, m do
            matrix[i][j] = 0
        end
    end
    for i = 1, n do
        for j = 1, m do
            if a[i] == b[j] then
                matrix[i][j] = matrix[i - 1][j - 1] + 1
            elseif matrix[i - 1][j] >= matrix[i][j - 1] then
                matrix[i][j] = matrix[i - 1][j]
            else
                matrix[i][j] = matrix[i][j - 1]
            end
        end
    end
    local ops = {}
    local i, j = n, m
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and a[i] == b[j] then
            table.insert(ops, 1, {kind = "keep", text = a[i]})
            i = i - 1
            j = j - 1
        elseif j > 0 and (i == 0 or matrix[i][j - 1] >= matrix[i - 1][j]) then
            table.insert(ops, 1, {kind = "add", text = b[j]})
            j = j - 1
        else
            table.insert(ops, 1, {kind = "del", text = a[i]})
            i = i - 1
        end
    end
    return ops
end

-- group the operations into the hunks with the context lines
function _makehunks(ops, contextsize)
    contextsize = contextsize or 3
    local added, removed = 0, 0
    local changed = {}
    for idx, op in ipairs(ops) do
        if op.kind == "add" then
            added = added + 1
            changed[idx] = true
        elseif op.kind == "del" then
            removed = removed + 1
            changed[idx] = true
        end
    end

    -- mark the lines which are kept in the hunks
    local keep = {}
    for idx, _ in pairs(changed) do
        for offset = -contextsize, contextsize do
            local pos = idx + offset
            if pos >= 1 and pos <= #ops then
                keep[pos] = true
            end
        end
    end

    -- assign the line numbers
    local oldno, newno = 0, 0
    for _, op in ipairs(ops) do
        if op.kind == "keep" then
            oldno = oldno + 1
            newno = newno + 1
            op.oldno = oldno
            op.newno = newno
        elseif op.kind == "add" then
            newno = newno + 1
            op.newno = newno
        else
            oldno = oldno + 1
            op.oldno = oldno
        end
    end

    -- collect the hunks
    local hunks = {}
    local current = nil
    for idx, op in ipairs(ops) do
        if keep[idx] then
            if not current then
                current = {lines = {}, oldstart = op.oldno or oldno, newstart = op.newno or newno}
                table.insert(hunks, current)
            end
            table.insert(current.lines, op)
        else
            current = nil
        end
    end
    return {added = added, removed = removed, hunks = hunks, total = #ops}
end

-- get the summary of the diff, e.g. "Added 2 lines, removed 1 line"
function summary(diff)
    local parts = {}
    if diff.added > 0 then
        table.insert(parts, string.format("Added %d line%s", diff.added, diff.added > 1 and "s" or ""))
    end
    if diff.removed > 0 then
        table.insert(parts, string.format("%s %d line%s", #parts > 0 and "removed" or "Removed",
            diff.removed, diff.removed > 1 and "s" or ""))
    end
    if #parts == 0 then
        return "No changes"
    end
    return table.concat(parts, ", ")
end

-- render the diff to the terminal lines
--
-- the changed lines are drawn on a colored background which spans the whole
-- width, and the code inside them keeps its syntax colors, exactly like the
-- editors do
--
-- @param opt   the options, e.g. {width = 100, filepath = "src/main.lua", maxlines = 40}
--
function render(diff, opt)
    opt = opt or {}
    local width = opt.width or 100
    local maxlines = opt.maxlines or 60
    local results = {}
    local language = opt.language or (opt.filepath and highlight.language(opt.filepath)) or nil

    -- measure the line number column
    local numwidth = 3
    for _, hunk in ipairs(diff.hunks or {}) do
        for _, line in ipairs(hunk.lines) do
            numwidth = math.max(numwidth, #tostring(line.newno or line.oldno or 0))
        end
    end

    local count = 0
    local total = 0
    for _, hunk in ipairs(diff.hunks or {}) do
        total = total + #hunk.lines
    end

    for hunkidx, hunk in ipairs(diff.hunks or {}) do
        if hunkidx > 1 then
            table.insert(results, theme.styled("diff.lineno", string.rep(" ", numwidth) .. " ⋮"))
        end

        -- every hunk is highlighted on its own, the state cannot span a gap
        local state = highlight.newstate()
        for _, line in ipairs(hunk.lines) do
            if count >= maxlines then
                table.insert(results, theme.styled("dim", string.format("%s   … %d more lines",
                    string.rep(" ", numwidth), total - count)))
                return results
            end
            count = count + 1
            local lineno = line.kind == "del" and line.oldno or line.newno
            local numtext = text.pad(tostring(lineno or ""), numwidth, "right")
            local content = text.expandtabs(line.text or "")
            content = text.truncate(content, math.max(20, width - numwidth - 4))

            if line.kind == "keep" then
                table.insert(results, theme.styled("diff.lineno", numtext) .. "   "
                    .. highlight.line(content, language, state))
            else
                local background = theme.get(line.kind == "add" and "diff.addline" or "diff.delline")
                local marker = line.kind == "add" and "+" or "-"
                local body = highlight.line(content, language, state, {background = background})
                local padding = math.max(0, width - numwidth - 3 - text.width(content))
                -- the whole row lives on one background, so the segments only
                -- switch the foreground color, never reset it
                table.insert(results, table.concat({
                    background,
                    theme.get("diff.lineno"), numtext,
                    theme.get(line.kind == "add" and "diff.addmark" or "diff.delmark"), " " .. marker .. " ",
                    body, string.rep(" ", padding), theme.reset()}))
            end
        end
    end
    return results
end
