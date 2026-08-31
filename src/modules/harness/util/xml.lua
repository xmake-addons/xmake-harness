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
-- @file        xml.lua
--

--
-- enough xml to read a project file
--
-- `.vcxproj`, `.csproj` and `.props` are xml, and reading them with patterns
-- works until the first attribute which contains a `>` or the first element
-- split across lines. this is a real parser and a small one: elements,
-- attributes, text, comments, CDATA, the five predefined entities and the
-- numeric ones. it is not a validating parser and it does not want to be —
-- namespaces are kept as part of the name, the prolog and the doctype are
-- skipped, and a document which is not well formed is an error and not a guess.
--
-- a node is `{name = "ClCompile", attrs = {Include = "src/main.c"}, children = {..}, text = ".."}`
--

-- the entities every document may use without declaring them
local ENTITIES = {lt = "<", gt = ">", amp = "&", quot = "\"", apos = "'"}

-- resolve the entities of a piece of text
function unescape(str)
    if not str or not str:find("&", 1, true) then
        return str or ""
    end
    return (str:gsub("&(#?%w+);", function (name)
        if ENTITIES[name] then
            return ENTITIES[name]
        end
        local code = name:match("^#(%d+)$")
        if code then
            return utf8.char(tonumber(code))
        end
        code = name:match("^#[xX](%x+)$")
        if code then
            return utf8.char(tonumber(code, 16))
        end
        return "&" .. name .. ";"
    end))
end

-- parse the attributes of a start tag
function _attributes(str)
    local attrs = {}
    local order = {}
    for name, quote, value in str:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
        if attrs[name] == nil then
            table.insert(order, name)
        end
        attrs[name] = unescape(value)
    end
    return attrs, order
end

-- parse a document
--
-- @param content   the whole file
-- @return          the root node, or nil and the reason
--
function parse(content)
    content = tostring(content or "")

    -- the byte order mark is not part of the document
    if content:startswith("\239\187\191") then
        content = content:sub(4)
    end

    local root = nil
    local stack = {}
    local pos = 1
    local length = #content

    while pos <= length do
        local open = content:find("<", pos, true)
        if not open then
            break
        end

        -- the text between the last element and this one belongs to whatever
        -- is open, and only when there is something in it besides layout
        if open > pos and #stack > 0 then
            local text = unescape(content:sub(pos, open - 1))
            if text:trim() ~= "" then
                local top = stack[#stack]
                top.text = (top.text or "") .. text
            end
        end

        local next = content:sub(open + 1, open + 1)
        if next == "!" then
            -- a comment, a CDATA section or a doctype
            if content:sub(open, open + 3) == "<!--" then
                local stop = content:find("-->", open + 4, true)
                if not stop then
                    return nil, "an unterminated comment"
                end
                pos = stop + 3
            elseif content:sub(open, open + 8) == "<![CDATA[" then
                local stop = content:find("]]>", open + 9, true)
                if not stop then
                    return nil, "an unterminated CDATA section"
                end
                if #stack > 0 then
                    local top = stack[#stack]
                    top.text = (top.text or "") .. content:sub(open + 9, stop - 1)
                end
                pos = stop + 3
            else
                local stop = content:find(">", open, true)
                if not stop then
                    return nil, "an unterminated declaration"
                end
                pos = stop + 1
            end
        elseif next == "?" then
            -- the prolog, and the processing instructions
            local stop = content:find("?>", open + 2, true)
            if not stop then
                return nil, "an unterminated processing instruction"
            end
            pos = stop + 2
        elseif next == "/" then
            local stop = content:find(">", open, true)
            if not stop then
                return nil, "an unterminated end tag"
            end
            local name = content:sub(open + 2, stop - 1):trim()
            local top = table.remove(stack)
            if not top then
                return nil, string.format("</%s> closes nothing", name)
            end
            if top.name ~= name then
                return nil, string.format("<%s> is closed by </%s>", top.name, name)
            end
            pos = stop + 1
        else
            -- a start tag: find its end, minding the quotes, because an
            -- attribute value is allowed to hold a `>` and often does
            local scan = open + 1
            local stop = nil
            while scan <= length do
                local ch = content:sub(scan, scan)
                if ch == "\"" or ch == "'" then
                    local close = content:find(ch, scan + 1, true)
                    if not close then
                        return nil, "an unterminated attribute value"
                    end
                    scan = close + 1
                elseif ch == ">" then
                    stop = scan
                    break
                else
                    scan = scan + 1
                end
            end
            if not stop then
                return nil, "an unterminated start tag"
            end

            local body = content:sub(open + 1, stop - 1)
            local selfclosing = body:endswith("/")
            if selfclosing then
                body = body:sub(1, -2)
            end
            local name = body:match("^([%w_:%-%.]+)") or ""
            if name == "" then
                return nil, "a tag without a name"
            end
            local node = {name = name, attrs = _attributes(body:sub(#name + 1)), children = {}}
            if #stack > 0 then
                table.insert(stack[#stack].children, node)
            elseif root then
                return nil, "a second root element"
            else
                root = node
            end
            if not selfclosing then
                table.insert(stack, node)
            end
            pos = stop + 1
        end
    end

    if #stack > 0 then
        return nil, string.format("<%s> is never closed", stack[#stack].name)
    end
    if not root then
        return nil, "there is no element in it"
    end
    return root
end

-- read a document from a file
function loadfile(filepath)
    if not os.isfile(filepath) then
        return nil, string.format("%s does not exist", filepath)
    end
    return parse(io.readfile(filepath))
end

-- every direct child of the given name
function children(node, name)
    local results = {}
    for _, child in ipairs((node or {}).children or {}) do
        if not name or child.name == name then
            table.insert(results, child)
        end
    end
    return results
end

-- the first direct child of the given name
function child(node, name)
    return children(node, name)[1]
end

-- every descendant of the given name, at any depth
function find(node, name)
    local results = {}
    local function walk(one)
        for _, item in ipairs(one.children or {}) do
            if item.name == name then
                table.insert(results, item)
            end
            walk(item)
        end
    end
    walk(node or {})
    return results
end

-- the text of a node, trimmed
function text(node)
    return node and (node.text or ""):trim() or ""
end
