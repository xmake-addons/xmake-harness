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
-- @file        text.lua
--

-- imports
import("harness.util.text")

function test_width()
    assert(text.width("hello") == 5)
    assert(text.width("你好") == 4)
    assert(text.width("你好world") == 9)
    assert(text.width("") == 0)
end

function test_strip()
    assert(text.strip("\027[31mred\027[0m") == "red")
    assert(text.width("\027[31mred\027[0m") == 3)
end

function test_truncate()
    assert(text.truncate("hello world", 8) == "hello w…")
    assert(text.truncate("hello", 8) == "hello")
    assert(text.width(text.truncate("你好世界你好世界", 8)) <= 8)
end

function test_wrap_ascii()
    local lines = text.wrap("hello world this is a long sentence which wraps", 20)
    assert(#lines > 1)
    for _, line in ipairs(lines) do
        assert(text.width(line) <= 20, line)
    end
end

function test_wrap_cjk()
    local lines = text.wrap("这是一段很长的中文文本，用来测试宽字符的换行是否正确。", 20)
    assert(#lines > 1)
    for _, line in ipairs(lines) do
        assert(text.width(line) <= 20, line)
    end
    assert(table.concat(lines) == "这是一段很长的中文文本，用来测试宽字符的换行是否正确。")
end

function test_lines()
    local lines = text.lines("a\nb\r\nc")
    assert(#lines == 3 and lines[1] == "a" and lines[3] == "c")
    assert(#text.lines("") == 1)
end

function test_pad()
    assert(text.pad("ab", 5) == "ab   ")
    assert(text.pad("ab", 5, "right") == "   ab")
    assert(text.width(text.pad("你好", 6)) == 6)
end

function test_width_of_numeric_strings()
    -- `utf8.width` takes a code point when it gets a number, and lua converts a
    -- numeric string into one: the width of "9" must not be the width of a tab
    for _, str in ipairs({"5", "9", "10", "0", "27"}) do
        assert(text.width(str) == #str, string.format("width(%s) = %d", str, text.width(str)))
    end
end

function test_pad_numeric()
    assert(text.pad("9", 3, "right") == "  9", "[" .. text.pad("9", 3, "right") .. "]")
    assert(text.pad("10", 3, "right") == " 10")
end
