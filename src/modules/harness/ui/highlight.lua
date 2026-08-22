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
-- the syntax highlighter
--
-- it is a small hand written tokenizer driven by a per-language table, which is
-- enough to colorize the code blocks and the diffs the way an editor does,
-- without shipping a grammar engine.
--
-- it is line based and keeps its state outside, so the streaming output can be
-- highlighted line by line while the model is still writing, and a block
-- comment or a multi-line string spanning several lines still works.
--
-- the token styles: keyword, control, type, func, property, variable, constant,
-- string, number, comment, operator, punct, text
--

-- imports
import("harness.ui.theme")
import("harness.ui.languages")

-- get the language of the given file path
function language(filepath)
    if not filepath then
        return nil
    end
    local names = {
        ["xmake.lua"] = "lua", ["makefile"] = "makefile", ["gnumakefile"] = "makefile",
        ["cmakelists.txt"] = "cmake", ["dockerfile"] = "shell"
    }
    local byname = names[path.filename(filepath):lower()]
    if byname then
        return byname
    end
    local extension = path.extension(filepath):lower():sub(2)
    if extension == "" then
        return nil
    end
    return languages.has(extension) and extension or nil
end

-- create a new highlighting state
function newstate()
    return {}
end

-- tokenize one line
--
-- @param str       the line
-- @param lang      the language name, e.g. "lua"
-- @param state     the state, it carries the block comments and strings across the lines
-- @return          the tokens, e.g. {{text = "local", style = "keyword"}, ..}
--
function tokenize(str, lang, state)
    state = state or {}
    local language = languages.get(lang)
    if not language or str == "" then
        return {{text = str, style = "text"}}
    end

    local tokens = _newtokens()
    local idx = _continue(str, language, state, tokens)
    while idx <= #str do
        idx = _scan(str, idx, language, state, tokens)
    end
    return tokens:finish()
end

-- the token collector, it keeps the plain characters together
function _newtokens()
    local tokens = {}
    local plain = {}
    return {
        emit = function (self, text, style)
            if #plain > 0 then
                table.insert(tokens, {text = table.concat(plain), style = "text"})
                plain = {}
            end
            table.insert(tokens, {text = text, style = style})
        end,
        plain = function (self, ch)
            table.insert(plain, ch)
        end,
        finish = function (self)
            if #plain > 0 then
                table.insert(tokens, {text = table.concat(plain), style = "text"})
            end
            return tokens
        end
    }
end

-- continue a block comment or a multi-line string of the previous line
--
-- @return  where the scanning starts on this line
--
function _continue(str, language, state, tokens)
    local pending = state.blockcomment and {mark = state.blockcomment, style = "comment"}
        or state.longstring and {mark = state.longstring, style = "string"} or nil
    if not pending then
        return 1
    end
    local _, endpos = str:find(pending.mark, 1, true)
    if not endpos then
        tokens:emit(str, pending.style)
        return #str + 1
    end
    tokens:emit(str:sub(1, endpos), pending.style)
    state.blockcomment = nil
    state.longstring = nil
    return endpos + 1
end

-- scan one token
--
-- @return  where the next token starts
--
function _scan(str, idx, language, state, tokens)
    local ch = str:sub(idx, idx)
    local rest = str:sub(idx)

    -- the comments and the multi-line strings, they may span several lines
    local span = _scanspan(rest, language)
    if span then
        return idx + _emitspan(rest, span, state, tokens)
    end

    -- the quoted string
    if language.quotes and language.quotes[ch] then
        local endidx = _findquote(str, idx, ch)
        tokens:emit(str:sub(idx, endidx), "string")
        return endidx + 1
    end

    -- the preprocessor, decorator or attribute line, e.g. `#include`, `@property`
    if _isdirective(str, idx, ch, language) then
        local word = rest:match("^[#@!%[]?[%w_%.%[%]]*") or ch
        tokens:emit(word, "keyword")
        return idx + #word
    end

    -- the number
    if ch:match("%d") and not _isidentchar(str:sub(idx - 1, idx - 1)) then
        local number = _scannumber(rest)
        tokens:emit(number, "number")
        return idx + #number
    end

    -- the identifier
    if ch:match("[%a_]") then
        local word = rest:match("^[%w_]+")
        tokens:emit(word, _wordstyle(str, idx, word, language))
        return idx + #word
    end

    -- the operator
    if ch:match("[%+%-%*/%%=<>!&|%^~%?:%.]") then
        local operator = rest:match("^[%+%-%*/%%=<>!&|%^~%?:%.]+") or ch
        tokens:emit(operator, "operator")
        return idx + #operator
    end

    -- the punctuation
    if ch:match("[%(%)%[%]{},;]") then
        tokens:emit(ch, "punct")
        return idx + 1
    end
    tokens:plain(ch)
    return idx + 1
end

-- which multi-line construct starts here, if any?
function _scanspan(rest, language)
    -- a lua block comment starts with the line comment prefix, so it wins
    if language.blockcomment and rest:startswith(language.blockcomment[1]) then
        return {open = language.blockcomment[1], close = language.blockcomment[2],
                style = "comment", key = "blockcomment"}
    end
    if language.linecomment and rest:startswith(language.linecomment) then
        return {line = true, style = "comment"}
    end
    if language.longstring and rest:startswith(language.longstring[1]) then
        return {open = language.longstring[1], close = language.longstring[2],
                style = "string", key = "longstring"}
    end
end

-- emit a comment or a multi-line string
--
-- @return  how many characters it consumed
--
function _emitspan(rest, span, state, tokens)
    if span.line then
        tokens:emit(rest, span.style)
        return #rest
    end
    local _, endpos = rest:find(span.close, #span.open + 1, true)
    if endpos then
        tokens:emit(rest:sub(1, endpos), span.style)
        return endpos
    end
    tokens:emit(rest, span.style)
    state[span.key] = span.close
    return #rest
end

-- is a preprocessor/decorator/attribute line starting here?
function _isdirective(str, idx, ch, language)
    if language.preprocessor and ch == "#" and str:sub(1, idx - 1):trim() == "" then
        return true
    end
    if language.attribute and ch == "#" and str:sub(idx + 1, idx + 1) == "[" then
        return true
    end
    return (language.decorator and ch == language.decorator)
        or (language.annotation and ch == language.annotation)
end

-- scan a number, e.g. `0xff`, `1.5e-3`, `10u`
function _scannumber(rest)
    local number = rest:match("^0[xX]%x+") or rest:match("^0[bB][01]+")
        or rest:match("^%d+%.?%d*[eE][%+%-]?%d+") or rest:match("^%d+%.?%d*")
    return number .. (rest:sub(#number + 1):match("^[%a_]*") or "")
end

-- classify an identifier
function _wordstyle(str, idx, word, language)
    if language._constants[word] then
        return "constant"
    elseif language._control[word] then
        return "control"
    elseif language._keywords[word] then
        return "keyword"
    elseif language._types[word] then
        return "type"
    end

    local nextch = _nextchar(str, idx + #word)
    if nextch == "(" then
        return "func"
    elseif nextch == ":" and str:sub(idx + #word + 1, idx + #word + 1) ~= ":" then
        return "property"
    elseif word:match("^%u") and word:match("%l") then
        -- a capitalized name is a type in most languages
        return "type"
    elseif word:match("^%u[%u%d_]*$") and #word > 1 then
        return "constant"
    end
    return "text"
end

-- find the end of the quoted string
function _findquote(str, startidx, quote)
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

-- get the next non-space character after the given position
function _nextchar(str, idx)
    local rest = str:sub(idx):match("^%s*(.)")
    return rest
end

-- is the given character part of an identifier?
function _isidentchar(ch)
    return ch ~= "" and ch:match("[%w_]") ~= nil
end

-- highlight one line
--
-- @param str       the line
-- @param lang      the language name
-- @param state     the state, @see newstate()
-- @param opt       the options, e.g. {background = "${on#22}"}
--                  - background    the escape sequence of the background, the foreground
--                                  colors are then reset with `\27[39m` instead of a full
--                                  reset, so the background survives the whole line
--
function line(str, lang, state, opt)
    opt = opt or {}
    if theme.isplain() or not lang then
        return opt.background and (opt.background .. str) or str
    end
    local tokens = tokenize(str, lang, state)
    local results = {}
    local default = opt.background and theme.fgreset() or theme.reset()
    for _, token in ipairs(tokens) do
        local code = theme.get("code." .. token.style)
        -- inside a colored background we must never emit a full reset, it would
        -- clear the background for the rest of the line
        if code == "" or (opt.background and code == theme.reset()) then
            code = default
        end
        table.insert(results, code .. token.text)
    end
    if opt.background then
        return opt.background .. table.concat(results)
    end
    return table.concat(results) .. theme.reset()
end

-- highlight the whole code block
function code(str, lang)
    local state = newstate()
    local results = {}
    for _, str_line in ipairs(import("harness.util.text", {anonymous = true}).lines(str)) do
        table.insert(results, line(str_line, lang, state))
    end
    return results
end
