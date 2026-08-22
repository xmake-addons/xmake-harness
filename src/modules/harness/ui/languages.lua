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
-- the language definitions of the syntax highlighter
--
-- every language describes what its tokenizer needs: the words which are
-- keywords, the comment markers, the string delimiters and the few one-off
-- rules like the c preprocessor or the python decorators.
--

-- the languages
function _definitions()
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
    return languages
end

-- get the definition of the given language
--
-- @param name  the language name, e.g. "lua", "cpp"
--
function get(name)
    local languages = _g.languages
    if not languages then
        languages = _definitions()
        _aliases(languages)
        for _, language in pairs(languages) do
            _expand(language)
        end
        _g.languages = languages
    end
    return languages[name or ""]
end

-- is the given language known?
function has(name)
    return get(name) ~= nil
end

-- the aliases, they share the definition of their language
function _aliases(languages)
    local aliases = {
        h = "c", hpp = "cpp", cxx = "cpp", cc = "cpp",
        typescript = "javascript", ts = "javascript", tsx = "javascript",
        jsx = "javascript", js = "javascript",
        py = "python", rs = "rust",
        sh = "shell", bash = "shell", zsh = "shell", console = "shell",
        kotlin = "swift", csharp = "java", cs = "java", make = "makefile"
    }
    for alias, name in pairs(aliases) do
        languages[alias] = languages[name]
    end
end

-- expand the word lists of one language into the lookup sets
function _expand(language)
    if language._expanded then
        return
    end
    for _, kind in ipairs({"keywords", "control", "constants", "types"}) do
        local words = {}
        for word in (language[kind] or ""):gmatch("%S+") do
            words[word] = true
        end
        language["_" .. kind] = words
    end
    language._expanded = true
end
