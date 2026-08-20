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
-- @file        editor.lua
--

-- imports
import("harness.util.text")
import("harness.ui.editor")

function test_insert()
    local instance = editor.new()
    instance:insert("hello")
    assert(instance:text() == "hello")
    instance:insert(" world")
    assert(instance:text() == "hello world")
end

function test_cjk()
    local instance = editor.new()
    instance:insert("你好")
    assert(instance:text() == "你好")
    instance:backspace()
    assert(instance:text() == "你", instance:text())
end

function test_newline()
    local instance = editor.new()
    instance:insert("a")
    instance:newline()
    instance:insert("b")
    assert(instance:text() == "a\nb")
end

function test_move()
    local instance = editor.new()
    instance:insert("hello")
    instance:move("home")
    instance:insert(">")
    assert(instance:text() == ">hello")
    instance:move("end")
    instance:insert("<")
    assert(instance:text() == ">hello<")
end

function test_deleteword()
    local instance = editor.new()
    instance:insert("hello world")
    instance:deleteword()
    assert(instance:text() == "hello ", "[" .. instance:text() .. "]")
end

function test_history()
    local instance = editor.new()
    instance:insert("first")
    instance:addhistory("first")
    instance:clear()
    instance:insert("second")
    instance:addhistory("second")
    instance:clear()
    instance:browsehistory("prev")
    assert(instance:text() == "second")
    instance:browsehistory("prev")
    assert(instance:text() == "first")
end

function test_render()
    local instance = editor.new()
    instance:insert("hello")
    local lines, row, col = instance:render({width = 40, prompt = "> "})
    assert(#lines == 1 and row == 1)
    assert(col == 7, "col: " .. col)
end

function test_render_wrap()
    local instance = editor.new()
    instance:insert(string.rep("x", 100))
    local lines = instance:render({width = 40, prompt = "> "})
    assert(#lines >= 3, "lines: " .. #lines)
    for _, line in ipairs(lines) do
        assert(text.width(line) <= 40)
    end
end

function test_wordbefore()
    local instance = editor.new()
    instance:insert("open @src/ma")
    local word = instance:wordbefore()
    assert(word == "@src/ma", tostring(word))
    instance:replaceword("@src/main.c")
    assert(instance:text() == "open @src/main.c")
end
