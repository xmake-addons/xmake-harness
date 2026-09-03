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

-- imports
import("harness.ui.theme")
import("harness.ui.highlight")

function _styles(str, lang, state)
    local results = {}
    for _, token in ipairs(highlight.tokenize(str, lang, state)) do
        if token.text:trim() ~= "" then
            table.insert(results, token.style .. ":" .. token.text)
        end
    end
    return table.concat(results, " ")
end

function test_lua()
    local result = _styles('local x = 1 -- note', "lua")
    assert(result:find("keyword:local", 1, true), result)
    assert(result:find("number:1", 1, true), result)
    assert(result:find("comment:-- note", 1, true), result)
end

function test_string()
    local result = _styles('print("hello \\"world\\"")', "lua")
    assert(result:find('string:"hello \\"world\\""', 1, true), result)
end

function test_function_and_type()
    local result = _styles('const p = createProvider(cfg); const m = new Map();', "javascript")
    assert(result:find("func:createProvider", 1, true), result)
    assert(result:find("type:Map", 1, true), result)
    assert(result:find("keyword:const", 1, true), result)
end

function test_blockcomment_state()
    local state = highlight.newstate()
    local first = _styles("/* the start", "c", state)
    assert(first:find("comment:", 1, true), first)
    assert(state.blockcomment ~= nil)
    local second = _styles("still a comment", "c", state)
    assert(second:startswith("comment:"), second)
    local third = _styles("done */ int x;", "c", state)
    assert(third:find("keyword:int", 1, true), third)
    assert(state.blockcomment == nil)
end

function test_language_detection()
    assert(highlight.language("src/main.c") == "c")
    assert(highlight.language("xmake.lua") == "lua")
    assert(highlight.language("app.tsx") == "tsx")
    assert(highlight.language("notes.unknownext") == nil)
end

function test_plain_theme()
    theme.load({ui = {theme = "plain"}})
    assert(highlight.line("local x = 1", "lua") == "local x = 1")
    theme.load({})
end

function test_background_keeps_no_full_reset()
    theme.load({})
    local result = highlight.line("local x = 1", "lua", nil, {background = "\027[48;5;22m"})
    assert(not result:find("\027%[0m"), "a full reset would clear the background")
end
