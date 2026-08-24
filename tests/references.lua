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
-- @file        references.lua
--

-- imports
import("harness.util.references")

-- a project with one known file
function _project()
    local dir = os.tmpfile() .. ".proj"
    os.tryrm(dir)
    os.mkdir(path.join(dir, "src"))
    io.writefile(path.join(dir, "src", "main.cpp"), "one\ntwo\nthree\nfour\nfive\n")
    io.writefile(path.join(dir, "xmake.lua"), "target(\"x\")\n")
    references.setproject(dir)
    references.forget()
    return dir
end

function test_it_finds_a_reference()
    local found = references.find("the bug is in src/main.cpp:3, look there")
    assert(#found == 1, tostring(#found))
    assert(found[1].path == "src/main.cpp" and found[1].line == 3)
end

function test_it_finds_several()
    local found = references.find("see xmake.lua:1 and src/main.cpp:42")
    assert(#found == 2)
end

function test_a_url_is_not_a_reference()
    -- `//host.com:8080` is a port, not a line
    assert(#references.find("open http://example.com:8080/x") == 0)
    assert(#references.find("see https://xmake.io:443")== 0)
end

function test_a_version_is_not_a_reference()
    assert(#references.find("upgrade to 1.2:3") == 0, "a version is not a file")
end

function test_a_real_line_checks_out()
    local dir = _project()
    assert(references.check("src/main.cpp", 3) == "ok")
    assert(references.check("xmake.lua", 1) == "ok")
    os.tryrm(dir)
end

function test_a_missing_file_is_caught()
    local dir = _project()
    assert(references.check("src/nowhere.cpp", 1) == "missing")
    os.tryrm(dir)
end

function test_a_line_past_the_end_is_caught()
    -- the file has five lines, so line 900 was never read by anybody
    local dir = _project()
    assert(references.check("src/main.cpp", 900) == "outofrange")
    os.tryrm(dir)
end

function test_the_last_line_is_in_range()
    local dir = _project()
    assert(references.check("src/main.cpp", 5) == "ok")
    os.tryrm(dir)
end

function test_marking_leaves_the_text_intact()
    -- the references are colored after the wrapping, so nothing may be added:
    -- one extra character and the line is one too wide
    local dir = _project()
    local marked = references.mark("the bug is in src/main.cpp:3 there")
    local plain = marked:gsub("\027%[[%d;]*m", "")
    assert(plain == "the bug is in src/main.cpp:3 there", plain)
    os.tryrm(dir)
end

function test_a_broken_reference_is_marked_differently()
    local dir = _project()
    local good = references.mark("src/main.cpp:3")
    local bad = references.mark("src/main.cpp:900")
    assert(good ~= bad, "a reference which points at nothing must not look the same")
    os.tryrm(dir)
end

function test_the_counts_are_forgotten_on_demand()
    local dir = _project()
    assert(references.check("src/main.cpp", 5) == "ok")
    io.writefile(path.join(dir, "src", "main.cpp"), "one\n")
    -- the count is remembered until something says the file changed
    assert(references.check("src/main.cpp", 5) == "ok")
    references.forget()
    assert(references.check("src/main.cpp", 5) == "outofrange")
    os.tryrm(dir)
end

function test_a_reference_at_the_very_start()
    -- inside backticks a citation always begins the string, and a pattern which
    -- looks at the character before it would eat the first letter of the path
    local dir = _project()
    local found = references.find("src/main.cpp:3 is where it is")
    assert(#found == 1 and found[1].path == "src/main.cpp", found[1] and found[1].path)
    assert(references.mark("src/main.cpp:3") ~= references.mark("src/main.cpp:900"),
        "a valid citation at the start must not be judged broken")
    os.tryrm(dir)
end
