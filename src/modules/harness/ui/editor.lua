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
-- @file        editor.lua
--

--
-- the multi-line input editor
--
-- it holds the text the user is typing, the cursor, the input history and the
-- kill ring, and it renders itself into the lines of the given width, so the
-- application only needs to draw them and place the cursor.
--
-- the text is stored as the utf8 strings and the cursor is a character index,
-- so the cjk input works as expected.
--

-- imports
import("core.base.object")
import("harness.util.text")

-- define the editor class
local editor = editor or object {_init = {"_lines", "_row", "_col", "_history", "_historyidx", "_killed"}}

-- create a new editor
function new()
    return editor {{""}, 1, 0, {}, 0, ""}
end

-- get the whole text
function editor:text()
    return table.concat(self._lines, "\n")
end

-- set the whole text
function editor:settext(str)
    self._lines = text.lines(str or "")
    if #self._lines == 0 then
        self._lines = {""}
    end
    self._row = #self._lines
    self._col = _len(self._lines[self._row])
    return self
end

-- is the editor empty?
function editor:isempty()
    return self:text():trim() == ""
end

-- clear the text
function editor:clear()
    self._lines = {""}
    self._row = 1
    self._col = 0
    self._historyidx = 0
    return self
end

-- get the number of the characters of the given string
function _len(str)
    local len = try { function () return utf8.len(str) end }
    if len then
        return len
    end
    return #str
end

-- get the sub string by the character index
function _sub(str, i, j)
    local result = try { function () return utf8.sub(str, i, j) end }
    if result then
        return result
    end
    return str:sub(i, j)
end

-- insert the text at the cursor
function editor:insert(str)
    if not str or str == "" then
        return self
    end
    str = str:gsub("\r\n", "\n"):gsub("\r", "\n")
    local pieces = text.lines(str)
    local line = self._lines[self._row]
    local left = _sub(line, 1, self._col)
    local right = _sub(line, self._col + 1)
    if #pieces == 1 then
        self._lines[self._row] = left .. pieces[1] .. right
        self._col = self._col + _len(pieces[1])
    else
        self._lines[self._row] = left .. pieces[1]
        for idx = 2, #pieces do
            table.insert(self._lines, self._row + idx - 1, pieces[idx])
        end
        self._row = self._row + #pieces - 1
        self._col = _len(pieces[#pieces])
        self._lines[self._row] = self._lines[self._row] .. right
    end
    return self
end

-- insert a new line at the cursor
function editor:newline()
    local line = self._lines[self._row]
    local left = _sub(line, 1, self._col)
    local right = _sub(line, self._col + 1)
    self._lines[self._row] = left
    table.insert(self._lines, self._row + 1, right)
    self._row = self._row + 1
    self._col = 0
    return self
end

-- delete the character before the cursor
function editor:backspace()
    if self._col > 0 then
        local line = self._lines[self._row]
        self._lines[self._row] = _sub(line, 1, self._col - 1) .. _sub(line, self._col + 1)
        self._col = self._col - 1
    elseif self._row > 1 then
        local line = table.remove(self._lines, self._row)
        self._row = self._row - 1
        self._col = _len(self._lines[self._row])
        self._lines[self._row] = self._lines[self._row] .. line
    end
    return self
end

-- delete the character at the cursor
function editor:delete()
    local line = self._lines[self._row]
    if self._col < _len(line) then
        self._lines[self._row] = _sub(line, 1, self._col) .. _sub(line, self._col + 2)
    elseif self._row < #self._lines then
        local next = table.remove(self._lines, self._row + 1)
        self._lines[self._row] = line .. next
    end
    return self
end

-- delete the word before the cursor
function editor:deleteword()
    local line = self._lines[self._row]
    local left = _sub(line, 1, self._col)
    local trimmed = left:gsub("%s+$", "")
    local stripped = trimmed:gsub("[%w_%.%-/]+$", "")
    if stripped == left then
        stripped = _sub(left, 1, math.max(0, self._col - 1))
    end
    self._killed = left:sub(#stripped + 1)
    self._lines[self._row] = stripped .. _sub(line, self._col + 1)
    self._col = _len(stripped)
    return self
end

-- delete to the beginning of the line
function editor:deletelinestart()
    local line = self._lines[self._row]
    self._killed = _sub(line, 1, self._col)
    self._lines[self._row] = _sub(line, self._col + 1)
    self._col = 0
    return self
end

-- delete to the end of the line
function editor:deletelineend()
    local line = self._lines[self._row]
    self._killed = _sub(line, self._col + 1)
    self._lines[self._row] = _sub(line, 1, self._col)
    return self
end

-- yank the killed text
function editor:yank()
    return self:insert(self._killed)
end

-- move the cursor
function editor:move(direction, opt)
    opt = opt or {}
    if direction == "left" then
        if opt.word then
            local line = _sub(self._lines[self._row], 1, self._col)
            local stripped = line:gsub("%s+$", ""):gsub("[%w_%.%-/]+$", "")
            self._col = _len(stripped)
        elseif self._col > 0 then
            self._col = self._col - 1
        elseif self._row > 1 then
            self._row = self._row - 1
            self._col = _len(self._lines[self._row])
        end
    elseif direction == "right" then
        local line = self._lines[self._row]
        if opt.word then
            local rest = _sub(line, self._col + 1)
            local skipped = rest:match("^%s*[%w_%.%-/]*") or ""
            self._col = math.min(_len(line), self._col + _len(skipped))
        elseif self._col < _len(line) then
            self._col = self._col + 1
        elseif self._row < #self._lines then
            self._row = self._row + 1
            self._col = 0
        end
    elseif direction == "up" then
        if self._row > 1 then
            self._row = self._row - 1
            self._col = math.min(self._col, _len(self._lines[self._row]))
            return true
        end
        return false
    elseif direction == "down" then
        if self._row < #self._lines then
            self._row = self._row + 1
            self._col = math.min(self._col, _len(self._lines[self._row]))
            return true
        end
        return false
    elseif direction == "home" then
        self._col = 0
    elseif direction == "end" then
        self._col = _len(self._lines[self._row])
    end
    return true
end

-- add the given text to the history
function editor:addhistory(str)
    if str and str:trim() ~= "" then
        if self._history[#self._history] ~= str then
            table.insert(self._history, str)
        end
        local maxhistory = 200
        while #self._history > maxhistory do
            table.remove(self._history, 1)
        end
    end
    self._historyidx = 0
    return self
end

-- get the history
function editor:history()
    return self._history
end

-- set the history
function editor:sethistory(history)
    self._history = history or {}
    return self
end

-- browse the history
--
-- @param direction "prev" or "next"
-- @return          true if the history is applied
--
function editor:browsehistory(direction)
    if #self._history == 0 then
        return false
    end
    if direction == "prev" then
        if self._historyidx == 0 then
            self._draft = self:text()
            self._historyidx = #self._history
        elseif self._historyidx > 1 then
            self._historyidx = self._historyidx - 1
        else
            return true
        end
        self:settext(self._history[self._historyidx])
        return true
    else
        if self._historyidx == 0 then
            return false
        end
        if self._historyidx < #self._history then
            self._historyidx = self._historyidx + 1
            self:settext(self._history[self._historyidx])
        else
            self._historyidx = 0
            self:settext(self._draft or "")
        end
        return true
    end
end

-- get the word before the cursor, it is used by the completion
--
-- @return  the word and its start column
--
function editor:wordbefore()
    local line = _sub(self._lines[self._row], 1, self._col)
    local word = line:match("([^%s]+)$")
    return word, word and (self._col - _len(word)) or self._col
end

-- replace the word before the cursor
function editor:replaceword(newword)
    local word, startcol = self:wordbefore()
    if not word then
        return self:insert(newword)
    end
    local line = self._lines[self._row]
    self._lines[self._row] = _sub(line, 1, startcol) .. newword .. _sub(line, self._col + 1)
    self._col = startcol + _len(newword)
    return self
end

-- render the editor to the lines
--
-- @param opt   the options, e.g. {width = 100, prompt = "› ", continuation = "  "}
-- @return      the lines, the cursor row(1-based) and the cursor column(0-based)
--
function editor:render(opt)
    opt = opt or {}
    local width = math.max(20, opt.width or 80)
    local prompt = opt.prompt or "› "
    local continuation = opt.continuation or string.rep(" ", text.width(prompt))
    local lines = {}
    local cursorrow, cursorcol = 1, 0
    for row, line in ipairs(self._lines) do
        local prefix = row == 1 and prompt or continuation
        local avail = width - text.width(prefix)
        local wrapped = _hardwrap(line, avail)
        for idx, piece in ipairs(wrapped) do
            table.insert(lines, (idx == 1 and prefix or continuation) .. piece)
        end
        if row == self._row then
            -- locate the cursor in the wrapped lines
            local remaining = self._col
            local offset = 0
            for idx, piece in ipairs(wrapped) do
                local piecelen = _len(piece)
                if remaining <= piecelen or idx == #wrapped then
                    offset = idx - 1
                    cursorcol = text.width(idx == 1 and prefix or continuation) + text.width(_sub(piece, 1, remaining))
                    break
                end
                remaining = remaining - piecelen
            end
            cursorrow = #lines - #wrapped + 1 + offset
        end
    end
    return lines, cursorrow, cursorcol
end

-- hard wrap the line by the display width
function _hardwrap(line, width)
    if line == "" then
        return {""}
    end
    local results = {}
    local rest = line
    while text.width(rest) > width do
        local head = text.subwidth(rest, width)
        if head == "" then
            break
        end
        table.insert(results, head)
        rest = rest:sub(#head + 1)
    end
    table.insert(results, rest)
    return results
end
