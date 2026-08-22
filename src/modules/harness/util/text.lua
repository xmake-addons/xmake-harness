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
-- @file        text.lua
--

-- imports
import("core.base.text")
import("core.base.colors")

-- the ansi escape sequence pattern
local ANSI_PATTERN = "\027%[[%d;?]*[a-zA-Z]"

-- strip the ansi escape sequences
function strip(str)
    if str == nil then
        return ""
    end
    return (tostring(str):gsub(ANSI_PATTERN, ""))
end

-- get the display width of the given string, it is cjk/emoji aware
--
-- @note we sum the width of every code point instead of calling `utf8.width`
--       on the whole string: that function takes a code point when it gets a
--       number, and lua happily converts a numeric string into one, so the
--       width of "9" would be the width of a tab
--
function width(str)
    if str == nil or str == "" then
        return 0
    end
    str = strip(str)
    local total = 0
    local ok = try {
        function ()
            for _, code in utf8.codes(str) do
                total = total + math.max(0, utf8.width(code))
            end
            return true
        end
    }
    if ok then
        return total
    end
    return #str
end

-- get the sub string by the display width
--
-- @param str       the string
-- @param maxwidth  the maximum display width
-- @return          the sub string and its real display width
--
function subwidth(str, maxwidth)
    if maxwidth <= 0 then
        return "", 0
    end
    local result = {}
    local total = 0
    for _, code in utf8.codes(str) do
        local ch = utf8.char(code)
        local w = width(ch)
        if total + w > maxwidth then
            break
        end
        table.insert(result, ch)
        total = total + w
    end
    return table.concat(result), total
end

-- truncate the string to the given display width with the ellipsis
function truncate(str, maxwidth, ellipsis)
    str = tostring(str or "")
    if width(str) <= maxwidth then
        return str
    end
    ellipsis = ellipsis or "…"
    local reserved = width(ellipsis)
    local result = subwidth(str, math.max(0, maxwidth - reserved))
    return result .. ellipsis
end

-- pad the string to the given display width
function pad(str, maxwidth, align)
    str = tostring(str or "")
    local w = width(str)
    if w >= maxwidth then
        return str
    end
    local spaces = string.rep(" ", maxwidth - w)
    if align == "right" then
        return spaces .. str
    elseif align == "center" then
        local left = math.floor((maxwidth - w) / 2)
        return string.rep(" ", left) .. str .. string.rep(" ", maxwidth - w - left)
    end
    return str .. spaces
end

-- wrap the text to the given display width
--
-- it is display width aware and cjk aware: the latin words are kept together,
-- and the cjk text can break between any two characters.
--
-- @param str       the text
-- @param maxwidth  the maximum display width
-- @return          the wrapped lines
--
function wrap(str, maxwidth)
    maxwidth = math.max(8, maxwidth or 80)
    local results = {}
    for _, line in ipairs(lines(str)) do
        if line == "" then
            table.insert(results, "")
        elseif width(line) <= maxwidth then
            table.insert(results, line)
        else
            for _, wrapped in ipairs(_wrapline(line, maxwidth)) do
                table.insert(results, wrapped)
            end
        end
    end
    return results
end

-- wrap one line
function _wrapline(line, maxwidth)
    local results = {}
    local current = {}          -- the characters of the current line
    local currentwidth = 0
    local breakpos = nil        -- the last break opportunity in `current`
    local breakwidth = 0

    for _, code in utf8.codes(line) do
        local ch = utf8.char(code)
        local chwidth = width(ch)

        -- a break opportunity: after a space, or before/after a wide character
        if ch == " " or ch == "\t" then
            breakpos = #current + 1
            breakwidth = currentwidth + chwidth
        elseif chwidth > 1 then
            breakpos = #current
            breakwidth = currentwidth
        end

        if currentwidth + chwidth > maxwidth and #current > 0 then
            if breakpos and breakpos > 0 and breakpos < #current then
                local head = table.concat(current, "", 1, breakpos)
                table.insert(results, (head:gsub("%s+$", "")))
                local rest = {}
                for idx = breakpos + 1, #current do
                    table.insert(rest, current[idx])
                end
                current = rest
                currentwidth = currentwidth - breakwidth
            else
                table.insert(results, (table.concat(current):gsub("%s+$", "")))
                current = {}
                currentwidth = 0
            end
            breakpos = nil
            breakwidth = 0
        end
        table.insert(current, ch)
        currentwidth = currentwidth + chwidth
    end
    if #current > 0 then
        table.insert(results, (table.concat(current):gsub("%s+$", "")))
    end
    return results
end

-- split the text to lines, it does not strip the empty lines
function lines(str)
    local results = {}
    str = tostring(str or "")
    str = str:gsub("\r\n", "\n"):gsub("\r", "\n")
    local pos = 1
    while true do
        local e = str:find("\n", pos, true)
        if not e then
            table.insert(results, str:sub(pos))
            break
        end
        table.insert(results, str:sub(pos, e - 1))
        pos = e + 1
    end
    return results
end

-- expand the tabs to spaces
function expandtabs(str, tabstop)
    tabstop = tabstop or 4
    return (tostring(str or ""):gsub("\t", string.rep(" ", tabstop)))
end

-- escape the lua pattern characters
function escape(str)
    return (tostring(str or ""):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

-- translate the color tags, e.g. "${bright red}hello${clear}"
function color(str)
    return colors.translate(str)
end

-- indent every line of the text
function indent(str, prefix)
    local results = {}
    for _, line in ipairs(lines(str)) do
        table.insert(results, prefix .. line)
    end
    return table.concat(results, "\n")
end
