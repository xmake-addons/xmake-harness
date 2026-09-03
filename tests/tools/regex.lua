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
-- @file        regex.lua
--

-- imports
import("harness.util.regex")

function test_plain()
    local patterns = regex.translate("hello")
    assert(#patterns == 1 and patterns[1] == "hello")
end

function test_classes()
    local patterns = regex.translate("\\d+")
    assert(patterns and ("abc123"):find(patterns[1]))
end

function test_alternation()
    local patterns = regex.translate("foo|bar")
    assert(#patterns == 2)
    assert(("xxbar"):find(patterns[2]))
end

function test_escape()
    local patterns = regex.translate("a%.b")
    assert(patterns ~= nil)
end

function test_find()
    assert(regex.find("local foo = 1", "foo\\s*="))
    assert(regex.find("add_requires(\"zlib\")", "add_requires"))
    assert(not regex.find("hello", "\\d+"))
end

function test_charclass()
    local patterns = regex.translate("[a-z]+_test")
    assert(patterns and ("my_test"):find(patterns[1]))
end
