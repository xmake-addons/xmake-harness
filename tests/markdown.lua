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
-- @file        markdown.lua
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.markdown")

function _plain(lines)
    local results = {}
    for _, line in ipairs(lines) do
        table.insert(results, text.strip(line))
    end
    return results
end

function test_heading_and_paragraph()
    local lines = _plain(markdown.render("# Title\n\nsome text", {width = 60}))
    assert(lines[1] == "Title", lines[1])
    assert(lines[3] == "some text", lines[3])
end

function test_list()
    local lines = _plain(markdown.render("- one\n- two\n  - nested", {width = 60}))
    assert(lines[1] == "• one", lines[1])
    assert(lines[3]:find("◦ nested"), lines[3])
end

function test_tasklist()
    local lines = _plain(markdown.render("- [x] done\n- [ ] todo", {width = 60}))
    assert(lines[1]:find("✔ done"), lines[1])
    assert(lines[2]:find("○ todo"), lines[2])
end

function test_codeblock()
    local lines = _plain(markdown.render("```lua\nlocal x = 1\n```", {width = 60}))
    assert(lines[1]:find("╭", 1, true), lines[1])
    assert(lines[2]:find("local x = 1", 1, true), lines[2])
    assert(lines[3]:find("╰", 1, true), lines[3])
end

function test_table()
    local doc = "| a | b |\n| --- | ---: |\n| 1 | 2 |"
    local lines = _plain(markdown.render(doc, {width = 60}))
    assert(lines[1]:find("╭", 1, true), lines[1])
    assert(lines[2]:find("a", 1, true) and lines[2]:find("b", 1, true))
    assert(lines[3]:find("├", 1, true), lines[3])
    assert(lines[5]:find("╰", 1, true), lines[5])
end

function test_streaming_state()
    local state = markdown.newstate()
    local lines = markdown.renderline("```lua", state, {width = 60})
    assert(#lines == 1 and state.incode)
    lines = markdown.renderline("local x = 1", state, {width = 60})
    assert(text.strip(lines[1]):find("local x = 1", 1, true))
    lines = markdown.renderline("```", state, {width = 60})
    assert(not state.incode)
end

function test_flush_unclosed_fence()
    local state = markdown.newstate()
    markdown.renderline("```", state, {width = 60})
    local lines = markdown.flush(state, {width = 60})
    assert(#lines == 1 and not state.incode)
end

function test_inline()
    theme.load({})
    local lines = markdown.render("a **bold** and `code` here", {width = 60})
    assert(lines[1]:find("\027", 1, true), "the inline markup should be styled")
    assert(text.strip(lines[1]) == "a bold and code here", text.strip(lines[1]))
end
