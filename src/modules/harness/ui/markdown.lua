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
-- a small markdown renderer for the terminal
--
-- it renders the assistant messages: the headings, the lists, the code blocks,
-- the inline code, the bold text, the block quotes and the rules.
--
-- it is line based and keeps its state outside, so the streaming output can be
-- rendered line by line while the model is still writing.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.highlight")

-- create a new render state
function newstate()
    return {incode = false, codelang = nil}
end

-- render one markdown line with the given state
--
-- @param line      the markdown line
-- @param state     the render state, @see newstate()
-- @param opt       the options, e.g. {width = 100}
-- @return          the rendered lines
--
function renderline(line, state, opt)
    opt = opt or {}
    local width = opt.width or 100

    -- the code fence
    local fence = line:match("^%s*```(.*)$")
    if fence ~= nil then
        if state.incode then
            state.incode = false
            state.codelang = nil
        else
            state.incode = true
            local lang = fence:trim()
            state.codelang = lang ~= "" and lang or nil
        end
        return {theme.styled("dim", "  ────")}
    end

    -- inside the code block
    if state.incode then
        local content = text.expandtabs(line)
        content = text.truncate(content, math.max(20, width - 2))
        return {"  " .. (state.codelang and highlight.line(content, state.codelang) or theme.styled("md.code", content))}
    end
    return _renderline(line, width)
end

-- render the whole markdown text to the terminal lines
--
-- @param str   the markdown text
-- @param opt   the options, e.g. {width = 100, indent = ""}
--
function render(str, opt)
    opt = opt or {}
    local indent = opt.indent or ""
    local state = newstate()
    local results = {}
    for _, line in ipairs(text.lines(str or "")) do
        for _, rendered in ipairs(renderline(line, state, {width = (opt.width or 100) - #indent})) do
            table.insert(results, indent .. rendered)
        end
    end
    return results
end

-- render one markdown line
function _renderline(line, width)
    local results = {}

    -- the horizontal rule
    if line:match("^%s*[%-%*_][%-%*_][%-%*_]+%s*$") then
        return {theme.styled("dim", string.rep("─", math.min(width, 40)))}
    end

    -- the heading
    local level, title = line:match("^(#+)%s+(.*)$")
    if level then
        local style = #level <= 2 and "md.heading" or "title"
        return {theme.styled(style, _inline(title))}
    end

    -- the block quote
    local quote = line:match("^%s*>%s?(.*)$")
    if quote then
        return {theme.styled("md.quote", "│ " .. _inline(quote))}
    end

    -- the list item
    local spaces, bullet, content = line:match("^(%s*)([%-%*%+])%s+(.*)$")
    if bullet then
        local prefix = spaces .. theme.styled("md.bullet", "•") .. " "
        for idx, wrapped in ipairs(text.wrap(content, math.max(20, width - #spaces - 2))) do
            table.insert(results, idx == 1 and (prefix .. _inline(wrapped)) or (spaces .. "  " .. _inline(wrapped)))
        end
        return results
    end

    -- the ordered list item
    local ospaces, number, ocontent = line:match("^(%s*)(%d+%.)%s+(.*)$")
    if number then
        local prefix = ospaces .. theme.styled("md.bullet", number) .. " "
        for idx, wrapped in ipairs(text.wrap(ocontent, math.max(20, width - #ospaces - #number - 1))) do
            table.insert(results, idx == 1 and (prefix .. _inline(wrapped))
                or (ospaces .. string.rep(" ", #number + 1) .. _inline(wrapped)))
        end
        return results
    end

    -- the plain paragraph
    if line:trim() == "" then
        return {""}
    end
    for _, wrapped in ipairs(text.wrap(line, width)) do
        table.insert(results, _inline(wrapped))
    end
    return results
end

-- render the inline markup
function _inline(str)
    if theme.current().plain then
        return str
    end

    -- the inline code
    str = str:gsub("`([^`]+)`", function (code)
        return theme.styled("md.code", code)
    end)

    -- the bold text
    str = str:gsub("%*%*([^%*]+)%*%*", function (content)
        return theme.styled("md.bold", content)
    end)

    -- the link
    str = str:gsub("%[([^%]]+)%]%(([^%)]+)%)", function (title, url)
        return theme.styled("md.link", title) .. theme.styled("dim", "(" .. url .. ")")
    end)
    return str
end
