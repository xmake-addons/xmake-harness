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
-- @file        html.lua
--

--
-- markdown, as html
--
-- the terminal renderer turns markdown into escape sequences because that is
-- what a terminal has. a browser has a document, so the same shapes — headings,
-- lists, fences, tables, emphasis — become tags instead.
--
-- it is written here rather than in the page for one reason: a parser in
-- javascript would be a *second* parser, and the two would drift. the harness
-- already decides what a line of markdown means; this only decides what to call
-- the result. the page receives html and does no parsing at all.
--
-- everything which came from the model or from a file is escaped on the way in.
-- an answer which quotes `<script>` is quoting it, and a tool which prints one
-- is printing it — neither is asking for it to run.
--

-- the characters which would otherwise be markup
local ESCAPES = {["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;"}

-- escape a string so it can only ever be text
function escape(str)
    return (tostring(str or ""):gsub("[&<>\"']", ESCAPES))
end

-- render a markdown document
--
-- @return  the html
--
-- where the last finished block of an unfinished answer ends
--
-- an answer arrives a few characters at a time, and rendering the whole of it
-- on every one of them is work thrown away. but leaving it all as plain text
-- until it is finished means a long answer with code in it looks unformatted
-- for as long as it takes to write — which is exactly when somebody is reading
-- it.
--
-- so the finished part is rendered and the tail is not. a part is finished when
-- a blank line ends it, or when a fence closes; anything inside an open fence
-- is not finished however many blank lines it contains.
--
-- @return  the number of characters which are safe to render, 0 for none yet
--
function complete(text)
    if not text or text == "" then
        return 0
    end
    local at = 0
    local upto = 0
    local infence = false
    while at < #text do
        local stop = text:find("\n", at + 1, true)
        if not stop then
            break
        end
        local line = text:sub(at + 1, stop - 1)
        if line:trim():startswith("```") then
            infence = not infence
            if not infence then
                upto = stop
            end
        elseif not infence and line:trim() == "" then
            upto = stop
        end
        at = stop
    end
    return upto
end

function render(text)
    local out = {}
    local lines = _lines(text or "")
    local idx = 1
    while idx <= #lines do
        idx = _block(lines, idx, out)
    end
    return table.concat(out)
end

-- split into lines, without inventing a trailing empty one
function _lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

-- render one block, whatever it turns out to be
--
-- @return  the line to carry on from
--
function _block(lines, idx, out)
    local line = lines[idx]

    if line:match("^%s*$") then
        return idx + 1
    elseif line:match("^```") then
        return _fence(lines, idx, out)
    elseif line:match("^#+%s") then
        return _heading(line, idx, out)
    elseif line:match("^%s*[%-%*%+]%s") or line:match("^%s*%d+%.%s") then
        return _list(lines, idx, out)
    elseif line:match("^%s*>%s?") then
        return _quote(lines, idx, out)
    elseif line:match("^%s*|.*|%s*$") and _isseparator(lines[idx + 1]) then
        return _table(lines, idx, out)
    elseif line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") then
        table.insert(out, "<hr>")
        return idx + 1
    end
    return _paragraph(lines, idx, out)
end

-- ``` a fenced block ```
--
-- an unclosed fence still renders: the model is streaming and the closing one
-- has simply not arrived yet, which must not make the answer disappear
--
function _fence(lines, idx, out)
    local language = lines[idx]:match("^```%s*([%w_+%-]*)")
    local body = {}
    local at = idx + 1
    while at <= #lines and not lines[at]:match("^```") do
        table.insert(body, lines[at])
        at = at + 1
    end
    table.insert(out, string.format("<pre><code%s>%s</code></pre>",
        (language and language ~= "") and string.format(" class=\"language-%s\"", escape(language)) or "",
        escape(table.concat(body, "\n"))))
    return at + 1
end

-- # a heading
function _heading(line, idx, out)
    local hashes, content = line:match("^(#+)%s+(.*)$")
    local level = math.min(#hashes, 6)
    table.insert(out, string.format("<h%d>%s</h%d>", level, inline(content), level))
    return idx + 1
end

-- a list, of either kind, with the nesting it happens to have
function _list(lines, idx, out)
    local ordered = lines[idx]:match("^%s*%d+%.%s") ~= nil
    local indent = #(lines[idx]:match("^(%s*)"))
    table.insert(out, ordered and "<ol>" or "<ul>")

    local at = idx
    while at <= #lines do
        local line = lines[at]
        local spaces = line:match("^(%s*)")
        local content = line:match("^%s*[%-%*%+]%s+(.*)$") or line:match("^%s*%d+%.%s+(.*)$")
        if not content or #spaces < indent then
            break
        end
        if #spaces > indent then
            -- a deeper list belongs inside the item just opened
            at = _list(lines, at, out)
        else
            local checked, rest = content:match("^%[([ xX])%]%s+(.*)$")
            if checked then
                table.insert(out, string.format("<li class=\"task\"><span class=\"box\">%s</span>%s</li>",
                    checked:lower() == "x" and "✔" or "○", inline(rest)))
            else
                table.insert(out, string.format("<li>%s</li>", inline(content)))
            end
            at = at + 1
        end
    end
    table.insert(out, ordered and "</ol>" or "</ul>")
    return at
end

-- > a quote
function _quote(lines, idx, out)
    local body = {}
    local at = idx
    while at <= #lines and lines[at]:match("^%s*>%s?") do
        table.insert(body, (lines[at]:gsub("^%s*>%s?", "")))
        at = at + 1
    end
    table.insert(out, string.format("<blockquote>%s</blockquote>", render(table.concat(body, "\n"))))
    return at
end

-- is this the `|---|---|` line which makes the row above a header?
function _isseparator(line)
    return line ~= nil and line:match("^%s*|[%s%-:|]+|%s*$") ~= nil
end

-- | a | table |
function _table(lines, idx, out)
    table.insert(out, "<table><thead>")
    table.insert(out, _row(lines[idx], "th"))
    table.insert(out, "</thead><tbody>")
    local at = idx + 2
    while at <= #lines and lines[at]:match("^%s*|.*|%s*$") do
        table.insert(out, _row(lines[at], "td"))
        at = at + 1
    end
    table.insert(out, "</tbody></table>")
    return at
end

-- one row of cells
--
-- the outer pipes are fences, not separators: `| a | b |` has two cells, and
-- splitting on the pipe alone invents a third one out of the nothing which
-- follows the last of them
--
function _row(line, tag)
    local inner = line:trim():gsub("^|", ""):gsub("|$", "")
    local cells = {"<tr>"}
    for cell in (inner .. "|"):gmatch("([^|]*)|") do
        table.insert(cells, string.format("<%s>%s</%s>", tag, inline(cell:trim()), tag))
    end
    table.insert(cells, "</tr>")
    return table.concat(cells)
end

-- an ordinary paragraph, which runs until a blank line or another block
function _paragraph(lines, idx, out)
    local body = {}
    local at = idx
    while at <= #lines do
        local line = lines[at]
        if line:match("^%s*$") or line:match("^```") or line:match("^#+%s")
            or line:match("^%s*[%-%*%+]%s") or line:match("^%s*%d+%.%s") or line:match("^%s*>%s?") then
            break
        end
        table.insert(body, line)
        at = at + 1
    end
    table.insert(out, string.format("<p>%s</p>", inline(table.concat(body, "\n"))))
    return at
end

-- the spans inside a line
--
-- the order matters: the code spans are taken out first and put back last, so
-- that a `**` inside backticks stays two asterisks
--
function inline(text)
    local kept = {}
    local str = tostring(text or ""):gsub("`([^`]+)`", function (code)
        table.insert(kept, string.format("<code>%s</code>", escape(code)))
        return string.format("\1%d\1", #kept)
    end)

    str = escape(str)
    str = str:gsub("%[([^%]]*)%]%(([^%)]+)%)", function (title, url)
        return string.format("<a href=\"%s\" rel=\"noreferrer noopener\" target=\"_blank\">%s</a>",
            _safeurl(url), title ~= "" and title or escape(url))
    end)
    str = str:gsub("%*%*([^%*]+)%*%*", "<strong>%1</strong>")
    str = str:gsub("__([^_]+)__", "<strong>%1</strong>")
    str = str:gsub("~~([^~]+)~~", "<del>%1</del>")
    str = str:gsub("%*([^%*\n]+)%*", "<em>%1</em>")
    str = str:gsub("\n", "<br>")

    return (str:gsub("\1(%d+)\1", function (index)
        return kept[tonumber(index)]
    end))
end

-- a link which cannot be a way to run something
--
-- `javascript:` in an href is a script the page runs on click, and the model
-- writes the hrefs
--
function _safeurl(url)
    local clean = escape(url:trim())
    if clean:lower():match("^%a[%w+%.%-]*:") and not clean:lower():match("^https?:")
        and not clean:lower():match("^mailto:") then
        return "#"
    end
    return clean
end
