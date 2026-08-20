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

-- the language definitions
function _languages()
    local languages = _g.languages
    if languages then
        return languages
    end
    languages = {
        lua = {
            keywords  = "and break do else elseif end for function goto if in local not or repeat return then until while",
            control   = "break do else elseif end for goto if in repeat return then until while",
            constants = "true false nil self _G _ENV",
            types     = "string table math io os coroutine debug utf8",
            linecomment = "--",
            blockcomment = {"--[[", "]]"},
            longstring = {"[[", "]]"},
            quotes = {["\""] = true, ["'"] = true}
        },
        c = {
            keywords  = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while",
            control   = "break case continue default do else for goto if return switch while",
            constants = "NULL true false",
            types     = "char double float int long short signed unsigned void size_t bool int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            preprocessor = true,
            quotes = {["\""] = true, ["'"] = true}
        },
        cpp = {
            keywords  = "alignas alignof auto bool break case catch char class concept const consteval constexpr continue co_await co_return co_yield decltype default delete do double else enum explicit export extern final float for friend goto if import inline int long module mutable namespace new noexcept operator override private protected public register requires return short signed sizeof static static_assert struct switch template this throw try typedef typeid typename union unsigned using virtual void volatile while",
            control   = "break case catch continue default do else for goto if return switch throw try while",
            constants = "true false nullptr NULL",
            types     = "bool char double float int long short signed unsigned void auto size_t string vector map set pair shared_ptr unique_ptr",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            preprocessor = true,
            quotes = {["\""] = true, ["'"] = true}
        },
        python = {
            keywords  = "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
            control   = "break continue elif else finally for if raise return try while with yield",
            constants = "True False None self cls",
            types     = "int str float bool list dict set tuple bytes object type",
            linecomment = "#",
            longstring = {"\"\"\"", "\"\"\""},
            decorator = "@",
            quotes = {["\""] = true, ["'"] = true}
        },
        javascript = {
            keywords  = "as async await break case catch class const continue debugger default delete do else enum export extends finally for from function get if implements import in instanceof interface let new of package private protected public readonly return set static super switch this throw try type typeof var void while with yield satisfies keyof infer declare namespace abstract",
            control   = "break case catch continue default do else finally for if return switch throw try while",
            constants = "true false null undefined NaN Infinity this super",
            types     = "string number boolean object symbol bigint any unknown never void Array Promise Map Set Record Partial Object JSON Math Date RegExp Error React",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            quotes = {["\""] = true, ["'"] = true, ["`"] = true}
        },
        rust = {
            keywords  = "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while",
            control   = "break continue else for if loop match return while",
            constants = "true false None Some Ok Err self Self",
            types     = "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box Rc Arc HashMap",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            attribute = "#",
            quotes = {["\""] = true, ["'"] = true}
        },
        go = {
            keywords  = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
            control   = "break case continue default else fallthrough for goto if return select switch",
            constants = "true false nil iota",
            types     = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            quotes = {["\""] = true, ["'"] = true, ["`"] = true}
        },
        shell = {
            keywords  = "case do done elif else esac fi for function if in local return select then time until while export readonly declare source alias unset shift eval exec trap",
            control   = "case do done elif else esac fi for if then until while",
            constants = "true false",
            types     = "echo cd ls cp mv rm mkdir cat grep sed awk find xargs curl git make cmake xmake",
            linecomment = "#",
            quotes = {["\""] = true, ["'"] = true}
        },
        json = {
            keywords  = "",
            constants = "true false null",
            quotes = {["\""] = true}
        },
        yaml = {
            keywords  = "",
            constants = "true false null yes no on off",
            linecomment = "#",
            quotes = {["\""] = true, ["'"] = true}
        },
        toml = {
            keywords  = "",
            constants = "true false",
            linecomment = "#",
            quotes = {["\""] = true, ["'"] = true}
        },
        java = {
            keywords  = "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try var void volatile while record sealed",
            control   = "break case catch continue default do else finally for if return switch throw try while",
            constants = "true false null this super",
            types     = "boolean byte char double float int long short String List Map Set Object Integer Boolean Double",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            annotation = "@",
            quotes = {["\""] = true, ["'"] = true}
        },
        swift = {
            keywords  = "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var where guard defer break case continue default do else fallthrough for if in repeat return switch while as catch is super throw throws try async await",
            control   = "break case continue default do else fallthrough for guard if repeat return switch while",
            constants = "true false nil self Self",
            types     = "Int Double Float String Bool Array Dictionary Set Optional Any AnyObject Void",
            linecomment = "//",
            blockcomment = {"/*", "*/"},
            quotes = {["\""] = true}
        },
        ruby = {
            keywords  = "alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor",
            control   = "break case else elsif end for if next return unless until when while",
            constants = "true false nil self",
            types     = "String Array Hash Symbol Integer Float Object Module Class",
            linecomment = "#",
            quotes = {["\""] = true, ["'"] = true}
        },
        cmake = {
            keywords  = "if else elseif endif foreach endforeach while endwhile function endfunction macro endmacro return break continue set unset list string file find_package include add_executable add_library target_link_libraries target_include_directories project cmake_minimum_required option",
            control   = "if else elseif endif foreach endforeach while endwhile",
            constants = "TRUE FALSE ON OFF YES NO",
            linecomment = "#",
            quotes = {["\""] = true}
        },
        makefile = {
            keywords  = "ifeq ifneq ifdef ifndef else endif include define endef export unexport override",
            constants = "",
            linecomment = "#",
            quotes = {["\""] = true, ["'"] = true}
        }
    }

    -- the aliases
    languages.h = languages.c
    languages.hpp = languages.cpp
    languages.cxx = languages.cpp
    languages.cc = languages.cpp
    languages.typescript = languages.javascript
    languages.ts = languages.javascript
    languages.tsx = languages.javascript
    languages.jsx = languages.javascript
    languages.js = languages.javascript
    languages.py = languages.python
    languages.rs = languages.rust
    languages.sh = languages.shell
    languages.bash = languages.shell
    languages.zsh = languages.shell
    languages.console = languages.shell
    languages.kotlin = languages.swift
    languages.csharp = languages.java
    languages.cs = languages.java
    languages.make = languages.makefile

    -- expand the word lists into the lookup sets
    for _, language in pairs(languages) do
        if not language._words then
            language._words = {}
            for _, kind in ipairs({"keywords", "control", "constants", "types"}) do
                local words = {}
                for word in (language[kind] or ""):gmatch("%S+") do
                    words[word] = true
                end
                language["_" .. kind] = words
            end
            language._words = true
        end
    end
    _g.languages = languages
    return languages
end

-- get the language of the given file path
function language(filepath)
    if not filepath then
        return nil
    end
    local filename = path.filename(filepath):lower()
    local names = {
        ["xmake.lua"] = "lua", ["makefile"] = "makefile", ["gnumakefile"] = "makefile",
        ["cmakelists.txt"] = "cmake", ["dockerfile"] = "shell"
    }
    if names[filename] then
        return names[filename]
    end
    local extension = path.extension(filepath):lower():sub(2)
    if extension == "" then
        return nil
    end
    return _languages()[extension] and extension or nil
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
    local language = _languages()[lang or ""]
    if not language or str == "" then
        return {{text = str, style = "text"}}
    end

    local tokens = {}
    local plain = {}
    local function _flush()
        if #plain > 0 then
            table.insert(tokens, {text = table.concat(plain), style = "text"})
            plain = {}
        end
    end
    local function _emit(text, style)
        _flush()
        table.insert(tokens, {text = text, style = style})
    end

    local idx = 1
    local length = #str

    -- continue a block comment from the previous line
    if state.blockcomment then
        local endmark = state.blockcomment
        local s, e = str:find(endmark, 1, true)
        if s then
            _emit(str:sub(1, e), "comment")
            idx = e + 1
            state.blockcomment = nil
        else
            return {{text = str, style = "comment"}}
        end
    end

    -- continue a multi-line string from the previous line
    if state.longstring then
        local endmark = state.longstring
        local s, e = str:find(endmark, 1, true)
        if s then
            _emit(str:sub(1, e), "string")
            idx = e + 1
            state.longstring = nil
        else
            return {{text = str, style = "string"}}
        end
    end

    while idx <= length do
        local ch = str:sub(idx, idx)
        local rest = str:sub(idx)

        -- the line comment
        if language.linecomment and rest:startswith(language.linecomment) then
            -- a lua block comment starts with the line comment prefix
            if language.blockcomment and rest:startswith(language.blockcomment[1]) then
                local s, e = rest:find(language.blockcomment[2], #language.blockcomment[1] + 1, true)
                if s then
                    _emit(rest:sub(1, e), "comment")
                    idx = idx + e
                else
                    _emit(rest, "comment")
                    state.blockcomment = language.blockcomment[2]
                    idx = length + 1
                end
            else
                _emit(rest, "comment")
                idx = length + 1
            end

        -- the block comment
        elseif language.blockcomment and rest:startswith(language.blockcomment[1]) then
            local s, e = rest:find(language.blockcomment[2], #language.blockcomment[1] + 1, true)
            if s then
                _emit(rest:sub(1, e), "comment")
                idx = idx + e
            else
                _emit(rest, "comment")
                state.blockcomment = language.blockcomment[2]
                idx = length + 1
            end

        -- the long string, e.g. lua [[..]] and python """..."""
        elseif language.longstring and rest:startswith(language.longstring[1]) then
            local s, e = rest:find(language.longstring[2], #language.longstring[1] + 1, true)
            if s then
                _emit(rest:sub(1, e), "string")
                idx = idx + e
            else
                _emit(rest, "string")
                state.longstring = language.longstring[2]
                idx = length + 1
            end

        -- the quoted string
        elseif language.quotes and language.quotes[ch] then
            local endidx = _findquote(str, idx, ch)
            _emit(str:sub(idx, endidx), "string")
            idx = endidx + 1

        -- the preprocessor/decorator/attribute line, e.g. `#include`, `@property`
        elseif (language.preprocessor and ch == "#" and str:sub(1, idx - 1):trim() == "")
            or (language.decorator and ch == language.decorator)
            or (language.annotation and ch == language.annotation)
            or (language.attribute and ch == "#" and str:sub(idx + 1, idx + 1) == "[") then
            local word = rest:match("^[#@!%[]?[%w_%.%[%]]*") or ch
            _emit(word, "keyword")
            idx = idx + #word

        -- the number
        elseif ch:match("%d") and not _isidentchar(str:sub(idx - 1, idx - 1)) then
            local number = rest:match("^0[xX]%x+") or rest:match("^0[bB][01]+")
                or rest:match("^%d+%.?%d*[eE][%+%-]?%d+") or rest:match("^%d+%.?%d*")
            number = number .. (rest:sub(#number + 1):match("^[%a_]*") or "")
            _emit(number, "number")
            idx = idx + #number

        -- the identifier
        elseif ch:match("[%a_]") then
            local word = rest:match("^[%w_]+")
            local nextch = _nextchar(str, idx + #word)
            local style = "text"
            if language._constants[word] then
                style = "constant"
            elseif language._control[word] then
                style = "control"
            elseif language._keywords[word] then
                style = "keyword"
            elseif language._types[word] then
                style = "type"
            elseif nextch == "(" then
                style = "func"
            elseif nextch == ":" and str:sub(idx + #word + 1, idx + #word + 1) ~= ":" then
                style = "property"
            elseif word:match("^%u") and word:match("%l") then
                -- a capitalized name is a type in most languages
                style = "type"
            elseif word:match("^%u[%u%d_]*$") and #word > 1 then
                style = "constant"
            end
            _emit(word, style)
            idx = idx + #word

        -- the operator
        elseif ch:match("[%+%-%*/%%=<>!&|%^~%?:%.]") then
            local operator = rest:match("^[%+%-%*/%%=<>!&|%^~%?:%.]+") or ch
            _emit(operator, "operator")
            idx = idx + #operator

        -- the punctuation
        elseif ch:match("[%(%)%[%]{},;]") then
            _emit(ch, "punct")
            idx = idx + 1
        else
            table.insert(plain, ch)
            idx = idx + 1
        end
    end
    _flush()
    return tokens
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
