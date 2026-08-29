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
-- @file        sanitize.lua
--

-- imports
import("harness.util.sanitize")

function test_plain_text_is_untouched()
    assert(sanitize.clean("hello world") == "hello world")
    assert(sanitize.clean("line1\nline2\ttabbed") == "line1\nline2\ttabbed")
    assert(sanitize.clean("你好，世界") == "你好，世界")
end

function test_ansi_is_stripped()
    assert(sanitize.clean("\027[31mred\027[0m") == "red")
    assert(sanitize.clean("\027[1;38;5;42mgreen\027[m done") == "green done")
    -- the cursor movements too, they repaint what the user sees
    assert(sanitize.clean("a\027[2Kb\027[1Ac") == "abc")
end

function test_osc_is_stripped()
    -- an osc sequence can set the window title or open a link
    assert(sanitize.clean("\027]0;pwned\007ok") == "ok")
end

function test_control_characters_are_stripped()
    assert(sanitize.clean("a\000b\001c\008d") == "abcd")
    assert(sanitize.clean("keep\ttab\nand newline") == "keep\ttab\nand newline")
end

function test_bidi_overrides_are_stripped()
    -- the trojan-source trick: the text reads differently than it is
    local trojan = "if (admin) {\226\128\174 // safe"
    local cleaned = sanitize.clean(trojan)
    assert(not cleaned:find("\226\128\174", 1, true), "the override survived")
    assert(cleaned:find("if (admin)", 1, true))
end

function test_zero_width_is_stripped()
    assert(sanitize.clean("ad\226\128\139min") == "admin")
end

function test_carriage_returns_become_newlines()
    assert(sanitize.clean("progress\rdone") == "progress\ndone")
    assert(sanitize.clean("a\r\nb") == "a\nb")
end

function test_keepansi()
    assert(sanitize.clean("\027[31mred\027[0m", {keepansi = true}) == "\027[31mred\027[0m")
end

function test_isdirty()
    assert(sanitize.isdirty("\027[31mred"))
    assert(not sanitize.isdirty("plain"))
end

function test_nil_and_empty()
    assert(sanitize.clean(nil) == nil)
    assert(sanitize.clean("") == "")
end

function test_what_is_not_utf8_does_not_reach_the_model()
    -- a compiler writing in the system encoding, a file of bytes read as text:
    -- one stray byte is answered with `invalid unicode code point`, and that
    -- fails the whole request rather than the one line it arrived in
    local dirty = "error: \200\201 in 主函数\n"
    local clean = sanitize.clean(dirty)
    assert(utf8.len(clean), string.format("%q is still not utf-8", clean))
    assert(clean:find("主函数", 1, true), clean)
    assert(clean:find("error:", 1, true), clean)
end

function test_valid_text_is_left_exactly_as_it_is()
    local said = "编译失败了，看看是哪个目标 · 100%"
    assert(sanitize.clean(said) == said, sanitize.clean(said))
end
