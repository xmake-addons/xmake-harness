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
-- @file        box.lua
--

--
-- the box widget
--
-- it draws the framed dialogs of the live region: the permission prompts, the
-- welcome panel and the selection lists.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")

-- the border characters
local BORDERS = {
    round  = {tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│"},
    sharp  = {tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│"},
    double = {tl = "╔", tr = "╗", bl = "╚", br = "╝", h = "═", v = "║"}
}

-- draw a box around the given lines
--
-- @param lines the content lines, they may contain the escape sequences
-- @param opt   the options
--              - width     the total width of the box
--              - title     the title drawn into the top border
--              - style     the border style name of the theme, e.g. "box"
--              - border    the border shape, e.g. "round", "sharp"
--              - indent    the left indentation
--              - padding   the horizontal padding inside the box, 1 by default
--
-- @return      the drawn lines
--
function draw(lines, opt)
    opt = opt or {}
    local shape = BORDERS[opt.border or "round"] or BORDERS.round
    local style = opt.style or "box"
    local indent = opt.indent or ""
    local padding = opt.padding == nil and 1 or opt.padding
    local width = math.max(20, (opt.width or 80) - #indent)
    local inner = width - 2 - padding * 2

    local results = {}
    local top = shape.tl
    if opt.title then
        local title = text.truncate(opt.title, math.max(4, inner - 2))
        top = top .. shape.h .. theme.styled(opt.titlestyle or "title", " " .. title .. " ")
            .. theme.get(style) .. string.rep(shape.h, math.max(0, width - 4 - text.width(title) - 2))
    else
        top = top .. string.rep(shape.h, width - 2)
    end
    table.insert(results, indent .. theme.get(style) .. top .. shape.tr .. theme.reset())

    local pad = string.rep(" ", padding)
    for _, line in ipairs(lines) do
        local visible = text.width(line)
        local fill = math.max(0, inner - visible)
        table.insert(results, indent .. theme.styled(style, shape.v) .. pad .. line
            .. string.rep(" ", fill) .. pad .. theme.styled(style, shape.v))
    end
    table.insert(results, indent .. theme.styled(style, shape.bl .. string.rep(shape.h, width - 2) .. shape.br))
    return results
end

-- draw a horizontal separator inside a box
function separator(opt)
    opt = opt or {}
    local width = math.max(20, (opt.width or 80) - #(opt.indent or ""))
    return (opt.indent or "") .. theme.styled(opt.style or "box", "├" .. string.rep("─", width - 2) .. "┤")
end
