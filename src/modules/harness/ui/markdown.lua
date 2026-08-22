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
-- @file        markdown.lua
--

--
-- the markdown renderer
--
-- it renders the assistant messages the way claude code does: the headings, the
-- lists, the fenced code blocks with the syntax highlighting, the tables, the
-- block quotes, the rules and the inline markup.
--
-- it is line based and keeps its state outside, so a message can be rendered
-- while it is still streaming. the constructs which need several lines (the
-- code fences and the tables) are buffered in the state and emitted when they
-- are complete, and `flush()` emits whatever is left at the end of a message.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.highlight")

-- create a new render state
function newstate()
    return {incode = false, codelang = nil, codestate = nil, table = nil}
end

-- render one markdown line
--
-- @param line      the markdown line
-- @param state     the render state, @see newstate()
-- @param opt       the options, e.g. {width = 100}
-- @return          the rendered lines, it can be empty while a table is buffered
--
function renderline(line, state, opt)
    opt = opt or {}
    local width = math.max(20, opt.width or 100)

    -- the code fence
    local fence, lang = line:match("^%s*(```+)%s*([%w%+%-#]*)")
    if not fence then
        fence, lang = line:match("^%s*(~~~+)%s*([%w%+%-#]*)")
    end
    if fence then
        if state.incode then
            state.incode = false
            state.codelang = nil
            state.codestate = nil
            return {theme.styled("code.gutter", "  ╰" .. string.rep("─", math.min(width - 4, 40)))}
        end
        state.incode = true
        state.codelang = (lang ~= "" and lang:lower() or nil)
        state.codestate = highlight.newstate()
        local title = state.codelang and (" " .. state.codelang .. " ") or ""
        return {theme.styled("code.gutter", "  ╭─" .. title .. string.rep("─", math.max(0, math.min(width - 5 - #title, 39))))}
    end

    -- inside a code block
    if state.incode then
        local content = text.expandtabs(line)
        content = text.truncate(content, math.max(20, width - 6))
        return {theme.styled("code.gutter", "  │ ") .. highlight.line(content, state.codelang, state.codestate)}
    end

    -- the table rows are buffered until the table ends
    if _istablerow(line) then
        state.table = state.table or {}
        table.insert(state.table, line)
        return {}
    end
    local results = {}
    if state.table then
        for _, rendered in ipairs(_rendertable(state.table, width)) do
            table.insert(results, rendered)
        end
        state.table = nil
    end
    for _, rendered in ipairs(_renderline(line, width)) do
        table.insert(results, rendered)
    end
    return results
end

-- flush the buffered constructs at the end of a message
function flush(state, opt)
    opt = opt or {}
    local results = {}
    if state.table then
        for _, rendered in ipairs(_rendertable(state.table, math.max(20, opt.width or 100))) do
            table.insert(results, rendered)
        end
        state.table = nil
    end
    if state.incode then
        table.insert(results, theme.styled("code.gutter", "  ╰" .. string.rep("─", 40)))
        state.incode = false
        state.codelang = nil
        state.codestate = nil
    end
    return results
end

-- render the whole markdown text
--
-- @param str   the markdown text
-- @param opt   the options, e.g. {width = 100, indent = ""}
--
function render(str, opt)
    opt = opt or {}
    local indent = opt.indent or ""
    local state = newstate()
    local results = {}
    local width = (opt.width or 100) - #indent
    for _, line in ipairs(text.lines(str or "")) do
        for _, rendered in ipairs(renderline(line, state, {width = width})) do
            table.insert(results, indent .. rendered)
        end
    end
    for _, rendered in ipairs(flush(state, {width = width})) do
        table.insert(results, indent .. rendered)
    end
    return results
end

-- render one plain markdown line
function _renderline(line, width)
    local results = {}

    -- the horizontal rule
    if line:match("^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%s%-%*_]*$") then
        return {theme.styled("md.rule", string.rep("─", math.min(width, 60)))}
    end

    -- the heading
    local level, title = line:match("^(#+)%s+(.*)$")
    if level then
        local style = #level == 1 and "md.h1" or (#level == 2 and "md.h2" or "md.h3")
        local prefix = #level <= 2 and "" or ""
        return {theme.styled(style, prefix .. _inline(title, true))}
    end

    -- the block quote
    local quote = line:match("^%s*>%s?(.*)$")
    if quote then
        for _, wrapped in ipairs(text.wrap(quote, width - 2)) do
            table.insert(results, theme.styled("md.quote", "│ ") .. theme.styled("md.quote", _inline(wrapped)))
        end
        return #results > 0 and results or {theme.styled("md.quote", "│")}
    end

    -- the task list item, e.g. "- [x] done"
    local tspaces, tmark, tcontent = line:match("^(%s*)[%-%*%+]%s+%[([ xX])%]%s+(.*)$")
    if tmark then
        local checked = tmark ~= " "
        local bullet = theme.styled(checked and "success" or "md.bullet", checked and "✔" or "○")
        return _bulletlines(tspaces, bullet, checked and theme.styled("dim", tcontent) or _inline(tcontent), width, 2)
    end

    -- the unordered list item
    local spaces, bullet, content = line:match("^(%s*)([%-%*%+])%s+(.*)$")
    if bullet then
        local marker = (#spaces >= 2) and "◦" or "•"
        return _bulletlines(spaces, theme.styled("md.bullet", marker), _inline(content), width, 2)
    end

    -- the ordered list item
    local ospaces, number, ocontent = line:match("^(%s*)(%d+[%.%)])%s+(.*)$")
    if number then
        return _bulletlines(ospaces, theme.styled("md.bullet", number), _inline(ocontent), width, #number + 1)
    end

    -- the definition-like line, e.g. "**Note:** ..", it is just a paragraph
    if line:trim() == "" then
        return {""}
    end
    for _, wrapped in ipairs(text.wrap(line, width)) do
        table.insert(results, _inline(wrapped))
    end
    return results
end

-- build the wrapped lines of a list item
function _bulletlines(spaces, marker, content, width, indentsize)
    local results = {}
    local prefix = spaces .. marker .. " "
    local hanging = spaces .. string.rep(" ", indentsize)
    for idx, wrapped in ipairs(text.wrap(content, math.max(20, width - #spaces - indentsize))) do
        table.insert(results, idx == 1 and (prefix .. wrapped) or (hanging .. wrapped))
    end
    if #results == 0 then
        table.insert(results, prefix)
    end
    return results
end

-- is the given line a table row?
function _istablerow(line)
    local trimmed = line:trim()
    return trimmed:startswith("|") and trimmed:endswith("|") and #trimmed > 2
end

-- is the given row the table separator, e.g. "|---|:--:|"
function _isseparator(cells)
    for _, cell in ipairs(cells) do
        if not cell:trim():match("^:?%-%-*:?$") then
            return false
        end
    end
    return #cells > 0
end

-- split one table row into its cells
function _cells(line)
    local trimmed = line:trim():sub(2, -2)
    local results = {}
    local current = {}
    local idx = 1
    while idx <= #trimmed do
        local ch = trimmed:sub(idx, idx)
        if ch == "\\" then
            table.insert(current, trimmed:sub(idx + 1, idx + 1))
            idx = idx + 2
        elseif ch == "|" then
            table.insert(results, table.concat(current):trim())
            current = {}
            idx = idx + 1
        else
            table.insert(current, ch)
            idx = idx + 1
        end
    end
    table.insert(results, table.concat(current):trim())
    return results
end

-- render a buffered markdown table with the aligned columns
function _rendertable(rows, width)
    local matrix, aligns, headeridx = _tablecells(rows)
    if #matrix == 0 then
        return {}
    end
    local widths = _tablewidths(matrix, width)
    local columns = #widths

    local lines = {_tableborder(widths, "╭", "┬", "╮")}
    for index, cells in ipairs(matrix) do
        table.insert(lines, _tablerow(cells, widths, aligns, headeridx == index))
        if headeridx == index then
            table.insert(lines, _tableborder(widths, "├", "┼", "┤"))
        end
    end
    table.insert(lines, _tableborder(widths, "╰", "┴", "╯"))
    return lines
end

-- split the buffered rows into the cells, the alignments and the header index
function _tablecells(rows)
    local matrix = {}
    local aligns = {}
    local headeridx = nil
    for _, row in ipairs(rows) do
        local cells = _cells(row)
        if _isseparator(cells) and #matrix == 1 then
            headeridx = 1
            for index, cell in ipairs(cells) do
                cell = cell:trim()
                if cell:startswith(":") and cell:endswith(":") then
                    aligns[index] = "center"
                elseif cell:endswith(":") then
                    aligns[index] = "right"
                else
                    aligns[index] = "left"
                end
            end
        else
            table.insert(matrix, cells)
        end
    end
    return matrix, aligns, headeridx
end

-- measure the columns, and shrink them when the table is too wide
function _tablewidths(matrix, width)
    local columns = 0
    for _, cells in ipairs(matrix) do
        columns = math.max(columns, #cells)
    end

    local widths = {}
    local total = 1
    for index = 1, columns do
        local columnwidth = 0
        for _, cells in ipairs(matrix) do
            columnwidth = math.max(columnwidth, text.width(_stripmarkup(cells[index] or "")))
        end
        widths[index] = columnwidth
        total = total + columnwidth + 3
    end
    if total <= width then
        return widths
    end

    local scale = (width - 1 - columns * 3) / math.max(1, total - 1 - columns * 3)
    for index, columnwidth in ipairs(widths) do
        widths[index] = math.max(4, math.floor(columnwidth * scale))
    end
    return widths
end

-- render one border line of the table
function _tableborder(widths, left, middle, right)
    local parts = {}
    for _, columnwidth in ipairs(widths) do
        table.insert(parts, string.rep("─", columnwidth + 2))
    end
    return theme.styled("md.table", left .. table.concat(parts, middle) .. right)
end

-- render one row of the table
function _tablerow(cells, widths, aligns, isheader)
    local parts = {}
    for index, columnwidth in ipairs(widths) do
        local cell = text.truncate(_stripmarkup(cells[index] or ""), columnwidth)
        cell = text.pad(cell, columnwidth, aligns[index] or "left")
        table.insert(parts, " " .. (isheader and theme.styled("md.tablehead", cell) or _inline(cell)) .. " ")
    end
    local separator = theme.styled("md.table", "│")
    return separator .. table.concat(parts, separator) .. separator
end

-- strip the inline markup, it is used to measure the real cell width
function _stripmarkup(str)
    str = str:gsub("%*%*([^%*]+)%*%*", "%1")
    str = str:gsub("`([^`]+)`", "%1")
    str = str:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1")
    return str
end

-- render the inline markup
--
-- @param str       the text
-- @param inheading is it inside a heading? the styles are not reapplied there
--
function _inline(str, inheading)
    if theme.isplain() then
        return str
    end

    -- the inline code, it is protected from the other rules
    local protected = {}
    str = str:gsub("`([^`]+)`", function (code)
        table.insert(protected, theme.styled("md.code", code))
        return string.format("\1%d\1", #protected)
    end)

    -- the links
    str = str:gsub("%[([^%]]*)%]%(([^%)]+)%)", function (title, url)
        if title == "" then
            title = url
        end
        return theme.styled("md.link", title)
    end)

    if not inheading then
        -- the bold text
        str = str:gsub("%*%*([^%*]+)%*%*", function (content)
            return theme.styled("md.bold", content)
        end)
        str = str:gsub("__([^_]+)__", function (content)
            return theme.styled("md.bold", content)
        end)

        -- the strikethrough
        str = str:gsub("~~([^~]+)~~", function (content)
            return theme.styled("md.strike", content)
        end)

        -- the italic, only when it is clearly an emphasis
        str = str:gsub("(%f[%*])%*([^%*\n]+)%*(%f[^%*])", function (_, content)
            return theme.styled("md.italic", content)
        end)
    end

    -- restore the inline code
    str = str:gsub("\1(%d+)\1", function (index)
        return protected[tonumber(index)] or ""
    end)
    return str
end
