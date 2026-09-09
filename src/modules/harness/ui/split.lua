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
-- @file        split.lua
--

--
-- the changes, in a column beside the conversation
--
-- reading what an agent changed by scrolling back through the transcript is
-- reading it twice: once as it went past and once to find it again. a column
-- which holds the diff still, while the conversation goes on next to it, is the
-- difference between watching the work and following it.
--
-- it is off by default and it only opens where there is room. eighty columns
-- split in two is two columns too narrow to read either, so below a threshold
-- `/diff` says so rather than making the terminal worse. the same is true when
-- the window is made smaller with it open: it closes itself and says why.
--
-- how it is drawn, given that the transcript is the terminal's own scrollback:
--
--   the transcript is told a narrower width, so every line it writes stays in
--   the left column and the right one is never touched by it
--
--   the pane is painted over the right column of the *visible* screen after
--   anything is written, from row one down. the text scrolls; the pane does
--   not, because it is drawn again each time
--
-- so there is no alternate screen and no managed scrollback: selecting text,
-- scrolling back and copying out of the terminal all keep working, which is
-- most of why anybody uses a terminal.
--

-- imports
import("core.base.tty")
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.terminal")
import("harness.core.changes")

-- the narrowest terminal this is worth opening in
--
-- the pane needs about fifty columns to show a line of code without wrapping
-- every one of them, and the conversation needs seventy to be prose rather than
-- a ladder. below that the answer is no
local MINWIDTH = 120

-- how much of the width the pane takes, and what it is allowed to be
local SHARE = 0.44
local MINPANE = 46
local MAXPANE = 96

-- may it open at all, at this width?
function available(width)
    return width >= MINWIDTH
end

-- why not, in a sentence
function unavailable(width)
    return string.format("the terminal is %d columns and the split needs %d: "
        .. "the diff would be too narrow to read and so would the conversation.",
        width, MINWIDTH)
end

-- create the state of an open pane
function new(opt)
    opt = opt or {}
    return {
        file = opt.file,
        top = 0,
        base = opt.base or "session",

        -- which row of the pane drew which file, filled in as it is drawn: the
        -- mouse arrives as a row and a column and has to be told what is there
        hits = {}
    }
end

-- how wide the pane is on a terminal of this width
function panewidth(width)
    return math.max(MINPANE, math.min(MAXPANE, math.floor(width * SHARE)))
end

-- how wide everything else is
--
-- the separator column belongs to the pane, so the transcript never writes into
-- the column the border is drawn in
--
function leftwidth(width)
    return width - panewidth(width) - 1
end

-- the lines of the pane, top to bottom
--
-- @param state   the pane state, @see new()
-- @param opt     {harness = .., session = .., width = .., height = ..}
-- @return        the lines, already styled and padded to the width
--
function render(state, opt)
    local width = opt.width
    local height = math.max(1, opt.height)
    local lines = {}

    -- the list is drawn again every time, so what is where is worked out again
    -- every time: a row which held a file a moment ago may hold another one now
    state.hits = {}

    local ok, listing = _list(opt)
    if not ok then
        return _pad({theme.styled("error", listing)}, width, height)
    end

    _summary(lines, listing, width)
    _files(lines, listing, state, width)
    table.insert(lines, theme.styled("border", string.rep("─", width)))

    -- and the file itself, which is what the pane is for
    local file = _selected(state, listing)
    if file then
        _diff(lines, state, opt, file, width, height - #lines)
    elseif #listing.files == 0 then
        table.insert(lines, "")
        table.insert(lines, theme.styled("dim", "  nothing has been changed yet"))
    end
    return _pad(lines, width, height)
end

-- what this conversation changed, or why it could not be read
function _list(opt)
    local listing
    local errors
    try {
        function ()
            listing = changes.list({harness = opt.harness, session = opt.session})
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    if not listing then
        return false, errors or "the changes could not be read"
    end
    return true, listing
end

-- the line at the top: how much changed
function _summary(lines, listing, width)
    local added, removed = 0, 0
    for _, file in ipairs(listing.files) do
        added = added + (file.added or 0)
        removed = removed + (file.removed or 0)
    end
    local count = #listing.files
    local left = string.format("%d file%s changed", count, count == 1 and "" or "s")
    local right = string.format("%s %s", theme.styled("diff.add", "+" .. added),
                                theme.styled("diff.del", "-" .. removed))
    table.insert(lines, _row(theme.styled("title", left), right, width))
    table.insert(lines, "")
end

-- the files, one line each
function _files(lines, listing, state, width)
    local selected = _selected(state, listing)
    for index, file in ipairs(listing.files) do
        if index > 8 then
            table.insert(lines, theme.styled("dim", string.format("  and %d more",
                                                                  #listing.files - 8)))
            break
        end
        local mark = " "
        if selected and file.path == selected.path then
            mark = theme.styled("diff.add", "▸")
        end
        local name = text.truncate(file.path, width - 16)
        local style = file.undecided and "text" or "dim"
        if selected and file.path == selected.path then
            style = "title"
        end
        table.insert(lines, _row(
            string.format("%s %s", mark, theme.styled(style, name)),
            string.format("%s %s", theme.styled("diff.add", "+" .. (file.added or 0)),
                          theme.styled("diff.del", "-" .. (file.removed or 0))),
            width))

        -- `paint` puts line n on row n, so the index is the row it lands on
        state.hits[#lines] = file.path
    end
end

-- which file was drawn on this row of the pane, if any
function at(state, row)
    return state.hits and state.hits[row] or nil
end

-- put a file in the pane, from the top of it
function show(state, filepath)
    if not filepath or state.file == filepath then
        return false
    end
    state.file = filepath
    state.top = 0
    return true
end

-- does this column of the terminal belong to the pane?
--
-- the border column does: a click on the edge of the pane is a click in it,
-- and nobody aims for the column beside the one they meant
--
function inside(width, col)
    return (col or 0) > leftwidth(width)
end

-- move the diff by a few lines
--
-- it is not clamped here: how far down it may go depends on how many rows the
-- file has and how many of them fit, which only the drawing knows, @see _diff
--
function scroll(state, delta)
    state.top = math.max(0, (state.top or 0) + delta)
end

-- which file the pane is showing
--
-- whatever was asked for, or the one which changed last: a pane which showed
-- the first file of the conversation would be showing the oldest thing in it
--
function _selected(state, listing)
    if #listing.files == 0 then
        return nil
    end
    if state.file then
        for _, file in ipairs(listing.files) do
            if file.path == state.file then
                return file
            end
        end
    end
    return listing.files[#listing.files]
end

-- the diff of one file
function _diff(lines, state, opt, file, width, room)
    local result, errors
    try {
        function ()
            result, errors = changes.filediff({harness = opt.harness, session = opt.session},
                                              file.path, {base = state.base})
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }

    local header = text.truncate(file.path, width - 12)
    table.insert(lines, _row(theme.styled("title", header),
        theme.styled("dim", state.base == "last" and "last" or "all"), width))

    if not result then
        table.insert(lines, "")
        table.insert(lines, theme.styled("dim", "  " .. tostring(errors or "no diff")))
        return
    end

    local rows = result.lines or {}
    -- what is on screen, and how far down it starts
    local visible = math.max(1, room - 1)
    local top = math.max(0, math.min(state.top, math.max(0, #rows - visible)))
    state.top = top
    if top > 0 then
        table.insert(lines, theme.styled("dim", string.format("  ↑ %d more above", top)))
    end

    local shown = 0
    for index = top + 1, #rows do
        if shown >= visible then
            local left = #rows - index + 1
            if left > 0 then
                lines[#lines] = theme.styled("dim", string.format("  ↓ %d more below", left + 1))
            end
            break
        end
        table.insert(lines, _line(rows[index], width))
        shown = shown + 1
    end
end

-- one row of the diff
--
-- the same shape the terminal already uses for a change: a red bar for what
-- went, a green one for what came, and the untouched lines quiet between them
--
function _line(row, width)
    if row.kind == "hunk" then
        return theme.styled("dim", text.truncate(" " .. (row.text or ""), width))
    end

    local number = row.kind == "del" and row.oldline or row.newline
    local sign = row.kind == "add" and "+" or (row.kind == "del" and "-" or " ")
    local body = _text(row)

    local gutter = string.format("%4s %s ", number and tostring(number) or "", sign)
    local room = math.max(1, width - text.width(gutter))
    local content = text.truncate(body, room)
    local padded = gutter .. content .. string.rep(" ", math.max(0, room - text.width(content)))

    if row.kind == "add" then
        return theme.styled("diff.addline", padded)
    elseif row.kind == "del" then
        return theme.styled("diff.delline", padded)
    end
    return theme.styled("diff.lineno", gutter) .. content
end

-- the text of a row, from its highlighted tokens
function _text(row)
    if row.text then
        return row.text
    end
    local pieces = {}
    for _, token in ipairs(row.tokens or {}) do
        table.insert(pieces, token.text or "")
    end
    return table.concat(pieces)
end

-- a line with something on the left and something on the right
function _row(left, right, width)
    local room = width - text.width(left) - text.width(right)
    if room < 1 then
        return text.truncate(left, width)
    end
    return left .. string.rep(" ", room) .. right
end

-- every line the pane owns, to the height it owns
function _pad(lines, width, height)
    local out = {}
    for index = 1, height do
        local line = lines[index]
        if line == nil then
            table.insert(out, "")
        else
            table.insert(out, line)
        end
    end
    return out
end

-- paint the pane over the right of the visible screen
--
-- it is drawn again after anything is written, because anything written may
-- have scrolled what was there before
--
-- @param opt   {width = .., height = .., liveheight = .., harness = .., session = ..}
--
function paint(state, opt)
    local width = opt.width
    local pane = panewidth(width)
    local column = leftwidth(width) + 1
    local height = math.max(1, opt.rows or 1)

    local lines = render(state, {harness = opt.harness, session = opt.session,
                                 width = pane, height = height})

    terminal.synchronized(true)
    tty.cursor_hide()
    terminal.cursor_save()

    -- the window was resized: the border was drawn down a column which is not
    -- the border's any more, and nothing else is going to take it off the
    -- screen. widening leaves it stranded in the transcript, which is the one
    -- direction the painting below would not cover on its own
    _stale(state, column, height)

    for index = 1, height do
        terminal.moveto(index, column)
        -- the border, then the pane
        terminal.write(theme.styled("border", "│") .. (lines[index] or "") .. theme.reset())
        tty.erase_line_to_end()
    end

    state.column = column
    state.rows = height
    terminal.cursor_restore()
    tty.cursor_show()
    terminal.synchronized(false)
    terminal.flush()
end

-- what a previous size left behind, if anything
--
-- narrowing is covered by the painting itself: the pane moves left and every
-- row it draws erases to the end of the line behind it. widening is not — the
-- old border ends up to the *left* of the new one, in the transcript, where
-- nothing is going to write over it
--
-- @return  the column to wipe from and how many rows, or nil if it has not moved
--
function staleregion(state, column, height)
    if not state.column or state.column == column then
        return nil
    end
    return math.min(state.column, column), math.max(height, state.rows or 0)
end

-- wipe what a previous size left behind
function _stale(state, column, height)
    local from, rows = staleregion(state, column, height)
    if not from then
        return
    end
    for index = 1, rows do
        terminal.moveto(index, from)
        tty.erase_line_to_end()
    end
end

-- take the pane off the screen again
function clear(opt)
    local column = math.min(opt.column or math.huge, leftwidth(opt.width) + 1)
    terminal.synchronized(true)
    tty.cursor_hide()
    terminal.cursor_save()
    for index = 1, opt.height do
        terminal.moveto(index, column)
        tty.erase_line_to_end()
    end
    terminal.cursor_restore()
    tty.cursor_show()
    terminal.synchronized(false)
    terminal.flush()
end
