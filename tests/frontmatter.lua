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
-- @file        frontmatter.lua
--

-- imports
import("harness.util.frontmatter")

function test_parse()
    local attributes, body = frontmatter.parse([[---
name: my-skill
description: Use when testing the parser
tools: read_file, search_text
---

# The body

hello]])
    assert(attributes.name == "my-skill")
    assert(attributes.description == "Use when testing the parser")
    assert(body:startswith("# The body"))
    local tools = frontmatter.list(attributes.tools)
    assert(#tools == 2 and tools[1] == "read_file")
end

function test_nofrontmatter()
    local attributes, body = frontmatter.parse("# hello\n\nworld")
    assert(type(attributes) == "table")
    assert(body == "# hello\n\nworld")
end

function test_inline_list()
    local attributes = frontmatter.parse("---\ntools: [a, b, c]\n---\nbody")
    assert(type(attributes.tools) == "table" and #attributes.tools == 3)
end

function test_block_list()
    local attributes = frontmatter.parse("---\ntools:\n  - a\n  - b\n---\nbody")
    assert(type(attributes.tools) == "table" and #attributes.tools == 2)
end

function test_quoted()
    local attributes = frontmatter.parse("---\nname: \"my name\"\n---\nbody")
    assert(attributes.name == "my name")
end

function test_boolean()
    local attributes = frontmatter.parse("---\nenabled: true\n---\nbody")
    assert(attributes.enabled == true)
end
