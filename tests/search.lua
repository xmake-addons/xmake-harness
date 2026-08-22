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
-- @file        search.lua
--

-- imports
import("harness.fs.search")

-- make a small project to search in
function _project()
    local rootdir = path.join(os.tmpdir(), "harness-search-test")
    os.tryrm(rootdir)
    os.mkdir(path.join(rootdir, "src"))
    io.writefile(path.join(rootdir, "src", "main.c"),
        "#include <stdio.h>\nint main(void) {\n    printf(\"hello\\n\");\n    return 0;\n}\n")
    io.writefile(path.join(rootdir, "src", "util.c"),
        "void helper(void) {\n    // hello again\n}\nvoid other(void) {}\n")
    io.writefile(path.join(rootdir, "xmake.lua"), "target(\"demo\")\n    add_files(\"src/*.c\")\n")
    return rootdir
end

function test_content()
    local rootdir = _project()
    local result = search.run({pattern = "hello", rootdir = rootdir})
    assert(result.total == 2, "total: " .. result.total)
    assert(result.files == 2, "files: " .. result.files)
    assert(result.matches[1].line ~= nil)
    assert(result.matches[1].text:find("hello", 1, true))
    os.tryrm(rootdir)
end

function test_files_mode()
    local rootdir = _project()
    local result = search.run({pattern = "hello", rootdir = rootdir, mode = "files"})
    assert(result.files == 2, "files: " .. result.files)
    for _, match in ipairs(result.matches) do
        assert(match.line == nil)
        assert(match.path:endswith(".c"))
    end
    os.tryrm(rootdir)
end

function test_count_mode()
    local rootdir = _project()
    local result = search.run({pattern = "void", rootdir = rootdir, mode = "count"})
    assert(result.total >= 3, "total: " .. result.total)
    for _, match in ipairs(result.matches) do
        assert(match.count ~= nil and match.count > 0)
    end
    os.tryrm(rootdir)
end

function test_include()
    local rootdir = _project()
    local result = search.run({pattern = "demo", rootdir = rootdir, include = "*.lua"})
    assert(result.files == 1, "files: " .. result.files)
    assert(result.matches[1].path:endswith("xmake.lua"))
    os.tryrm(rootdir)
end

function test_regex()
    -- the model writes the regex syntax, both backends must understand it
    local rootdir = _project()
    local result = search.run({pattern = "void\\s+\\w+\\(", rootdir = rootdir})
    assert(result.total >= 2, "total: " .. result.total)
    os.tryrm(rootdir)
end

function test_ignorecase()
    local rootdir = _project()
    assert(search.run({pattern = "HELLO", rootdir = rootdir}).total == 0)
    assert(search.run({pattern = "HELLO", rootdir = rootdir, ignorecase = true}).total == 2)
    os.tryrm(rootdir)
end

function test_context()
    local rootdir = _project()
    local result = search.run({pattern = "printf", rootdir = rootdir, context = 1})
    local hascontext = false
    for _, match in ipairs(result.matches) do
        if match.iscontext then
            hascontext = true
        end
    end
    assert(hascontext, "no context line was returned")
    os.tryrm(rootdir)
end

function test_limit()
    local rootdir = _project()
    local result = search.run({pattern = "e", rootdir = rootdir, limit = 2})
    assert(#result.matches <= 2, "matches: " .. #result.matches)
    os.tryrm(rootdir)
end

function test_nothing_found()
    local rootdir = _project()
    local result = search.run({pattern = "nosuchthinghere", rootdir = rootdir})
    assert(result.total == 0 and #result.matches == 0)
    os.tryrm(rootdir)
end
