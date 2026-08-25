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
-- @file        html.lua
--

-- imports
import("harness.web.html")

function test_a_paragraph()
    assert(html.render("hello there") == "<p>hello there</p>", html.render("hello there"))
end

function test_the_headings()
    assert(html.render("# one") == "<h1>one</h1>")
    assert(html.render("### three") == "<h3>three</h3>")
    assert(html.render("####### too deep"):find("<h6>", 1, true), html.render("####### too deep"))
end

function test_a_fenced_block_keeps_its_language()
    local out = html.render("```lua\nlocal x = 1\n```")
    assert(out:find('class="language-lua"', 1, true), out)
    assert(out:find("local x = 1", 1, true), out)
end

function test_an_unclosed_fence_still_renders()
    -- the model is still streaming and the closing fence has not arrived: the
    -- answer must not vanish until it does
    local out = html.render("```\nhalf a block")
    assert(out:find("half a block", 1, true), out)
end

function test_the_lists()
    local out = html.render("- one\n- two")
    assert(out == "<ul><li>one</li><li>two</li></ul>", out)
    assert(html.render("1. one\n2. two"):startswith("<ol>"))
end

function test_a_task_list()
    local out = html.render("- [x] done\n- [ ] not")
    assert(out:find("✔", 1, true) and out:find("○", 1, true), out)
end

function test_a_table()
    local out = html.render("| a | b |\n| --- | --- |\n| 1 | 2 |")
    assert(out:find("<thead><tr><th>a</th><th>b</th></tr>", 1, true), out)
    assert(out:find("<td>1</td><td>2</td>", 1, true), out)
end

function test_a_quote()
    assert(html.render("> quoted"):find("<blockquote><p>quoted</p></blockquote>", 1, true))
end

function test_the_inline_spans()
    assert(html.inline("**bold**") == "<strong>bold</strong>")
    assert(html.inline("*italic*") == "<em>italic</em>")
    assert(html.inline("~~gone~~") == "<del>gone</del>")
    assert(html.inline("`code`") == "<code>code</code>")
end

function test_code_wins_over_emphasis()
    -- `**` inside backticks is two asterisks, not a request for bold
    assert(html.inline("`a ** b`") == "<code>a ** b</code>", html.inline("`a ** b`"))
end

function test_the_markup_in_the_text_is_escaped()
    -- an answer which quotes a script tag is quoting it
    local out = html.render("use <script>alert(1)</script> carefully")
    assert(not out:find("<script>", 1, true), out)
    assert(out:find("&lt;script&gt;", 1, true), out)
end

function test_the_code_is_escaped_too()
    local out = html.render("```html\n<img onerror=x>\n```")
    assert(not out:find("<img", 1, true), out)
    assert(out:find("&lt;img", 1, true), out)
end

function test_a_link()
    local out = html.inline("[xmake](https://xmake.io)")
    assert(out:find('href="https://xmake.io"', 1, true), out)
    assert(out:find(">xmake</a>", 1, true), out)
end

function test_a_javascript_link_is_defused()
    -- an href is something the page runs on click, and the model writes them
    local out = html.inline("[click](javascript:alert(1))")
    assert(not out:lower():find("javascript:", 1, true), out)
    assert(out:find('href="#"', 1, true), out)
end

function test_a_rule()
    assert(html.render("---") == "<hr>")
end

function test_nothing_at_all()
    assert(html.render("") == "")
    assert(html.render(nil) == "")
end

function test_a_whole_answer()
    -- the shapes a real answer mixes
    local out = html.render(table.concat({
        "It builds **one** target.",
        "",
        "- `src/main.cpp` is the only source",
        "- the target is a binary",
        "",
        "```lua",
        'target("hello")',
        "```",
        "",
        "See `xmake.lua:3`."
    }, "\n"))
    assert(out:find("<strong>one</strong>", 1, true), out)
    assert(out:find("<ul><li>", 1, true), out)
    assert(out:find("language-lua", 1, true), out)
    assert(out:find("<code>xmake.lua:3</code>", 1, true), out)
end
