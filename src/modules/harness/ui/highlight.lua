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
-- @file        highlight.lua
--

--
-- a lightweight syntax highlighter
--
-- it is intentionally simple: we only colorize the strings, the comments, the
-- numbers and the keywords, which is enough to make the diffs and the code
-- blocks readable in the terminal.
--

-- imports
import("harness.ui.theme")

-- the keywords of the supported languages
local KEYWORDS = {
    lua = "and break do else elseif end false for function goto if in local nil not or repeat return then true until while",
    c = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while",
    cpp = "alignas alignof auto bool break case catch char class concept const constexpr continue decltype default delete do double else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator private protected public register requires return short signed sizeof static static_assert struct switch template this throw true try typedef typeid typename union unsigned using virtual void volatile while",
    python = "and as assert async await break class continue def del elif else except finally for from global if import in is lambda none nonlocal not or pass raise return true false try while with yield",
    javascript = "async await break case catch class const continue default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof var void while yield",
    rust = "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while",
    go = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
    shell = "if then else elif fi for while do done case esac function return export local source"
}

-- the language of the given file
function language(filepath)
    local extension = path.extension(filepath or ""):lower()
    local languages = {
        [".lua"] = "lua", [".c"] = "c", [".h"] = "c",
        [".cpp"] = "cpp", [".cc"] = "cpp", [".cxx"] = "cpp", [".hpp"] = "cpp", [".mpp"] = "cpp",
        [".py"] = "python", [".js"] = "javascript", [".ts"] = "javascript", [".tsx"] = "javascript",
        [".rs"] = "rust", [".go"] = "go", [".sh"] = "shell", [".bash"] = "shell", [".zsh"] = "shell"
    }
    local result = languages[extension]
    if not result and path.filename(filepath or "") == "xmake.lua" then
        result = "lua"
    end
    return result
end

-- the comment prefixes of the given language
function _commentprefix(lang)
    local prefixes = {
        lua = "%-%-", python = "#", shell = "#",
        c = "//", cpp = "//", javascript = "//", rust = "//", go = "//"
    }
    return prefixes[lang]
end

-- highlight one line of the given language
function line(str, lang)
    if not lang or not str or str == "" or theme.current().plain then
        return str
    end

    -- the whole line comment
    local prefix = _commentprefix(lang)
    if prefix then
        local pos = str:find("^%s*" .. prefix)
        if pos then
            return theme.styled("code.comment", str)
        end
    end

    local keywords = {}
    for word in (KEYWORDS[lang] or ""):gmatch("%S+") do
        keywords[word] = true
    end

    local results = {}
    local idx = 1
    while idx <= #str do
        local ch = str:sub(idx, idx)
        if ch == '"' or ch == "'" then
            local endidx = _findstring(str, idx, ch)
            table.insert(results, theme.styled("code.string", str:sub(idx, endidx)))
            idx = endidx + 1
        elseif ch:match("[%a_]") then
            local word = str:match("^[%w_]+", idx)
            local nextch = str:sub(idx + #word, idx + #word)
            if keywords[word] then
                table.insert(results, theme.styled("code.keyword", word))
            elseif nextch == "(" then
                table.insert(results, theme.styled("code.func", word))
            else
                table.insert(results, word)
            end
            idx = idx + #word
        elseif ch:match("%d") then
            local num = str:match("^[%w%.]+", idx)
            table.insert(results, theme.styled("code.number", num))
            idx = idx + #num
        else
            table.insert(results, ch)
            idx = idx + 1
        end
    end
    return table.concat(results)
end

-- find the end of the string literal
function _findstring(str, startidx, quote)
    local idx = startidx + 1
    while idx <= #str do
        local ch = str:sub(idx, idx)
        if ch == "\\" then
            idx = idx + 2
        elseif ch == quote then
            return idx
        else
            idx = idx + 1
        end
    end
    return #str
end

-- highlight the whole code block
function code(str, lang)
    local results = {}
    for _, str_line in ipairs(import("harness.util.text", {anonymous = true}).lines(str)) do
        table.insert(results, line(str_line, lang))
    end
    return results
end
