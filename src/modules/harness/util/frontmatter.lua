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
-- @file        frontmatter.lua
--

--
-- the yaml frontmatter parser
--
-- the skills and the agents are plain markdown files with a small yaml header,
-- exactly like the claude code skills, so the existing skill repositories can
-- be used as is:
--
--   ---
--   name: xmake-packages
--   description: Use when adding third-party dependencies ..
--   tools: read_file, search_text
--   ---
--
--   the markdown body ..
--
-- we only support the flat subset which the skills actually use: the scalars,
-- the inline lists and the block lists.
--

-- parse the frontmatter of the given text
--
-- @return  the attributes table and the body text
--
function parse(content)
    content = content or ""
    if not content:startswith("---") then
        return {}, content
    end
    local lines = {}
    local body = {}
    local state = "start"
    local first = true
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if state == "start" then
            if first and line:trim() == "---" then
                state = "header"
            else
                return {}, content
            end
            first = false
        elseif state == "header" then
            if line:trim() == "---" then
                state = "body"
            else
                table.insert(lines, line)
            end
        else
            table.insert(body, line)
        end
    end
    if state ~= "body" then
        return {}, content
    end
    return _parse_attributes(lines), table.concat(body, "\n"):trim()
end

-- parse the attribute lines
function _parse_attributes(lines)
    local attributes = {}
    local currentkey = nil
    for _, line in ipairs(lines) do
        local item = line:match("^%s*%-%s+(.*)$")
        if item and currentkey then
            if type(attributes[currentkey]) ~= "table" then
                attributes[currentkey] = {}
            end
            table.insert(attributes[currentkey], _value(item))
        else
            local key, value = line:match("^([%w_%-%.]+)%s*:%s*(.*)$")
            if key then
                currentkey = key
                value = value:trim()
                if value == "" then
                    attributes[key] = ""
                else
                    attributes[key] = _value(value)
                end
            elseif currentkey and line:match("^%s+%S") and type(attributes[currentkey]) == "string" then
                -- the folded multi-line scalar
                attributes[currentkey] = attributes[currentkey] .. " " .. line:trim()
            end
        end
    end
    return attributes
end

-- parse one scalar value
function _value(value)
    value = value:trim()

    -- strip the quotes
    if (value:startswith("\"") and value:endswith("\"")) or (value:startswith("'") and value:endswith("'")) then
        return value:sub(2, #value - 1)
    end

    -- the inline list, e.g. [a, b, c]
    if value:startswith("[") and value:endswith("]") then
        local results = {}
        for item in value:sub(2, #value - 1):gmatch("[^,]+") do
            table.insert(results, _value(item))
        end
        return results
    end
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    return value
end

-- get the list value of the given attribute, e.g. "a, b" -> {"a", "b"}
function list(value)
    if value == nil then
        return nil
    end
    if type(value) == "table" then
        return value
    end
    local results = {}
    for item in tostring(value):gmatch("[^,]+") do
        item = item:trim()
        if item ~= "" then
            table.insert(results, item)
        end
    end
    return results
end
