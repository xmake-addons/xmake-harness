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
-- @file        regex.lua
--

--
-- a small regex to lua-pattern translator
--
-- the models usually write the search patterns in the regex syntax, but the
-- xmake runtime only provides the lua patterns, so we translate the common
-- subset here, and split the top-level alternations into several patterns.
--
-- the supported syntax:
--
--   . * + ? ^ $ [] [^] \d \w \s \b () |
--
-- it is not a full regex engine, the unsupported constructs fall back to the
-- plain text search.
--

-- the character class mappings
local CLASSES = {
    d = "%d", D = "%D", w = "[%w_]", W = "%W",
    s = "%s", S = "%S", n = "\n", t = "\t", r = "\r"
}

-- translate the regex to the lua patterns
--
-- @return  the patterns list, or nil if it cannot be translated
--
function translate(regex)
    if not regex or regex == "" then
        return nil
    end
    local alternatives = _split_alternation(regex)
    local patterns = {}
    for _, alternative in ipairs(alternatives) do
        local pattern = _translate_one(alternative)
        if not pattern then
            return nil
        end
        table.insert(patterns, pattern)
    end
    return patterns
end

-- split the top-level alternations, e.g. "foo|bar" -> {"foo", "bar"}
function _split_alternation(regex)
    local results = {}
    local depth = 0
    local start = 1
    local idx = 1
    while idx <= #regex do
        local ch = regex:sub(idx, idx)
        if ch == "\\" then
            idx = idx + 1
        elseif ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
        elseif ch == "|" and depth == 0 then
            table.insert(results, regex:sub(start, idx - 1))
            start = idx + 1
        end
        idx = idx + 1
    end
    table.insert(results, regex:sub(start))
    return results
end

-- translate one alternative
function _translate_one(regex)
    local results = {}
    local idx = 1
    while idx <= #regex do
        local piece, nextidx = _translate_at(regex, idx)
        if not piece then
            return nil
        end
        table.insert(results, piece)
        idx = nextidx
    end
    return table.concat(results)
end

-- translate the construct at the given position
--
-- @return  the lua pattern piece and the next position, or nil when the regex
--          uses something we cannot express as a lua pattern
--
function _translate_at(regex, idx)
    local ch = regex:sub(idx, idx)
    if ch == "\\" then
        return _translate_escape(regex, idx)
    elseif ch == "[" then
        return _translate_class(regex, idx)
    elseif ch == "(" then
        -- the groups are only used for the alternation, we drop them
        return "", idx + (regex:sub(idx, idx + 2) == "(?:" and 3 or 1)
    elseif ch == ")" then
        return "", idx + 1
    elseif ch == "{" then
        -- the repetition counts are not supported
        return nil
    elseif ch == "?" then
        return "?", idx + 1
    elseif ch == "-" then
        return "%-", idx + 1
    elseif ch == "%" then
        return "%%", idx + 1
    elseif ch == "+" or ch == "*" or ch == "." or ch == "^" or ch == "$" then
        return ch, idx + 1
    elseif ch:match("[%(%)%[%]%.%+%-%*%?%^%$%%]") then
        return "%" .. ch, idx + 1
    end
    return ch, idx + 1
end

-- translate an escaped character, e.g. `\d`, `\b`, `\.`
function _translate_escape(regex, idx)
    local ch = regex:sub(idx + 1, idx + 1)
    if CLASSES[ch] then
        return CLASSES[ch], idx + 2
    elseif ch == "b" then
        -- the word boundary is not supported by the lua patterns
        return "%f[%w_]", idx + 2
    elseif ch:match("%w") then
        return nil
    end
    return "%" .. ch, idx + 2
end

-- translate the character class, e.g. "[a-z0-9_]"
function _translate_class(regex, idx)
    local endidx = nil
    local search = idx + 1
    if regex:sub(search, search) == "^" then
        search = search + 1
    end
    if regex:sub(search, search) == "]" then
        search = search + 1
    end
    while search <= #regex do
        local ch = regex:sub(search, search)
        if ch == "\\" then
            search = search + 1
        elseif ch == "]" then
            endidx = search
            break
        end
        search = search + 1
    end
    if not endidx then
        return nil
    end
    local body = regex:sub(idx + 1, endidx - 1)
    body = body:gsub("\\(%a)", function (name)
        local class = CLASSES[name]
        if class and class:startswith("%") then
            return class
        end
        return "%" .. name
    end)
    body = body:gsub("%%%[", "["):gsub("%%%]", "]")
    return "[" .. body .. "]", endidx + 1
end

-- match the given text with the regex
--
-- @return  the matched start and end position, or nil
--
function find(text, regex, opt)
    opt = opt or {}
    if opt.plain then
        return text:find(regex, 1, true)
    end
    local patterns = translate(regex)
    if not patterns then
        return text:find(regex, 1, true)
    end
    for _, pattern in ipairs(patterns) do
        local s, e = try { function () return text:find(pattern) end }
        if s then
            return s, e
        end
    end
end
