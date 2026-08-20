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
-- @file        diff.lua
--

-- imports
import("harness.ui.diff")

function test_insert()
    local result = diff.compute("a\nb\nc\n", "a\nb\nx\nc\n")
    assert(result.added == 1, "added: " .. result.added)
    assert(result.removed == 0)
    assert(#result.hunks == 1)
end

function test_replace()
    local result = diff.compute("a\nb\nc\n", "a\nB\nc\n")
    assert(result.added == 1 and result.removed == 1)
end

function test_nochange()
    local result = diff.compute("a\nb\n", "a\nb\n")
    assert(result.added == 0 and result.removed == 0)
    assert(diff.summary(result) == "No changes")
end

function test_multiple_hunks()
    local old = {}
    local new = {}
    for idx = 1, 40 do
        table.insert(old, "line" .. idx)
        table.insert(new, "line" .. idx)
    end
    new[2] = "changed2"
    new[35] = "changed35"
    local result = diff.compute(table.concat(old, "\n"), table.concat(new, "\n"))
    assert(result.added == 2 and result.removed == 2)
    assert(#result.hunks == 2, "hunks: " .. #result.hunks)
end

function test_summary()
    local result = diff.compute("a\n", "a\nb\n")
    assert(diff.summary(result) == "Added 1 line", diff.summary(result))
end

function test_render()
    local result = diff.compute("a\nb\n", "a\nB\n")
    local lines = diff.render(result, {width = 60, filepath = "test.lua"})
    assert(#lines >= 2)
end
