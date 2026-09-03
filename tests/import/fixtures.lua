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
-- @file        fixtures.lua
--

--
-- the same project, written in every build system this can read
--
-- `tests/fixtures/import/<name>` is one small project — a static library and a
-- binary which uses it — described the way that build system describes it, with
-- real sources beside it. so a reader is not checked against a snippet somebody
-- wrote to make it pass: it is checked against a project, and the conversion is
-- built and run.
--
-- the library matters. a conversion which loses the dependency compiles the
-- binary and fails to link, and a conversion which loses the include directory
-- fails to compile — both of which a test on the model alone would miss.
--
-- adding a build system means adding a directory here, and this file covers it.
--

-- imports
import("harness.harness")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})
import("harness.plugins.xmake.import.verify")

-- what every one of them describes
--
-- `builds` says whether the conversion can be built on the machine running the
-- tests. one which describes another platform cannot be, and `why` says so:
-- skipping it silently would look like the reader was not covered
--
local EXAMPLES = {
    {name = "cmake",     reader = "cmake",     targets = "demo,greet",     builds = true},
    {name = "autotools", reader = "autotools", targets = "demo,libgreet",  builds = true},
    {name = "qmake",     reader = "qmake",     targets = "demo",           builds = true},
    {name = "meson",     reader = "meson",     targets = "demo,greet",     builds = true},
    {name = "scons",     reader = "scons",     targets = "demo,greet",     builds = true},
    {name = "bazel",     reader = "bazel",     targets = "demo,greet",     builds = true},
    {name = "vcxproj",   reader = "vcxproj",   targets = "demo,greet",     builds = true},
    {name = "ndkbuild",  reader = "ndkbuild",  targets = "demo,greet",     builds = false,
     why = "an Android.mk is an android build: it links the ndk's `log`, which is not here"},
    {name = "makefile",  reader = "makefile",  targets = "demo",           builds = true},
    {name = "compiledb", reader = "compiledb", targets = nil,              builds = false,
     why = "a compile database has no targets, so what it produces is named by guesswork"}
}

-- a copy of one example, because converting writes into it
function _copy(name)
    local source = path.join(_fixtures(), name)
    if not os.isdir(source) then
        return nil
    end
    local target = os.tmpfile() .. "." .. name
    os.mkdir(target)
    os.cp(path.join(source, "*"), target)

    -- the compile database records where it was built, which is here now
    local database = path.join(target, "compile_commands.json")
    if os.isfile(database) then
        io.writefile(database, (io.readfile(database):gsub("@ROOT@", target)))
    end
    return target
end

function _fixtures()
    local dir = os.scriptdir()
    for _ = 1, 5 do
        local found = path.join(dir, "fixtures", "import")
        if os.isdir(found) then
            return found
        end
        dir = path.directory(dir)
    end
    return path.join(os.scriptdir(), "..", "fixtures", "import")
end

function _names(list)
    local out = {}
    for _, one in ipairs(list) do
        table.insert(out, type(one) == "table" and one.name or one)
    end
    table.sort(out)
    return table.concat(out, ",")
end

---------------------------------------------------------------------------------
-- every one of them is detected as what it is
---------------------------------------------------------------------------------

function test_each_example_is_detected()
    for _, example in ipairs(EXAMPLES) do
        local rootdir = _copy(example.name)
        assert(rootdir, example.name .. " is not there")
        local found = projectimport.detect(rootdir)
        assert(#found > 0, example.name .. ": nothing was detected")

        local names = {}
        for _, one in ipairs(found) do
            table.insert(names, one.name)
        end
        assert(table.contains(names, example.reader),
               string.format("%s: detected %s", example.name, table.concat(names, ",")))
    end
end

function test_the_strongest_reader_wins_when_several_apply()
    -- a real project regularly carries more than one, and the one which says
    -- the most about it is the one to read
    local rootdir = _copy("cmake")
    io.writefile(path.join(rootdir, "Makefile"), "all:\n\techo hi\n")
    assert(projectimport.detect(rootdir)[1].name == "cmake",
           projectimport.detect(rootdir)[1].name)
end

---------------------------------------------------------------------------------
-- and read into the same project
---------------------------------------------------------------------------------

function test_each_example_reads_the_targets_it_declares()
    for _, example in ipairs(EXAMPLES) do
        if example.targets then
            local rootdir = _copy(example.name)
            local project, errors = projectimport.read(rootdir, {reader = example.reader})
            assert(project, string.format("%s: %s", example.name, tostring(errors)))
            assert(_names(project.targets) == example.targets,
                   string.format("%s: %s", example.name, _names(project.targets)))
        end
    end
end

function test_each_example_finds_the_sources_and_the_include()
    -- the include directory is what makes it compile and the library is what
    -- makes it link, so a reader which loses either has read nothing useful
    for _, example in ipairs(EXAMPLES) do
        if example.targets then
            local rootdir = _copy(example.name)
            local project = projectimport.read(rootdir, {reader = example.reader})
            local demo = model.get(project, "demo")
            assert(demo, example.name .. ": there is no `demo`")
            assert(#demo.files > 0, example.name .. ": `demo` has no sources")

            local said = table.concat(demo.files, " ")
            assert(said:find("main.c", 1, true), string.format("%s: %s", example.name, said))

            local includes = table.concat(demo.includedirs, " ")
                .. " " .. table.concat(demo.sysincludedirs, " ")
            assert(includes:find("include", 1, true),
                   string.format("%s: includes are %s", example.name, includes))
        end
    end
end

function test_the_ones_with_a_library_keep_the_dependency()
    for _, example in ipairs(EXAMPLES) do
        if example.targets and example.targets:find(",", 1, true) then
            local rootdir = _copy(example.name)
            local project = projectimport.read(rootdir, {reader = example.reader})
            local demo = model.get(project, "demo")
            assert(#demo.deps > 0, string.format(
                "%s: `demo` does not depend on the library, so it will not link",
                example.name))
        end
    end
end

---------------------------------------------------------------------------------
-- and the draft is written the same way for all of them
---------------------------------------------------------------------------------

function test_each_example_writes_an_xmake_lua()
    for _, example in ipairs(EXAMPLES) do
        local rootdir = _copy(example.name)
        local result, errors = projectimport.convert(rootdir, {reader = example.reader,
                                                               force = true})
        assert(result, string.format("%s: %s", example.name, tostring(errors)))
        assert(os.isfile(path.join(rootdir, "xmake.lua")), example.name)

        local text = io.readfile(path.join(rootdir, "xmake.lua"))
        assert(text:find("add_rules(\"mode.debug\", \"mode.release\")", 1, true),
               example.name .. ": " .. text)
        assert(text:find("target(", 1, true), example.name .. ": " .. text)

        -- nothing in a draft should be a path on the machine which wrote it
        assert(not text:find("/var/folders", 1, true), example.name .. ": " .. text)
        assert(not text:find("$(", 1, true), example.name .. ": an unexpanded variable\n" .. text)
    end
end

function test_a_draft_says_what_it_could_not_decide()
    -- the weaker readers should be the ones with more to decide, and all of
    -- them should be honest about having anything
    local rootdir = _copy("makefile")
    local result = projectimport.convert(rootdir, {reader = "makefile", force = true})
    assert(#result.project.notes > 0, "a makefile is read by shape and says so")
    local said = table.concat(result.project.notes, " ")
    assert(said:find("language", 1, true), said)
end

---------------------------------------------------------------------------------
-- and it builds
---------------------------------------------------------------------------------

function test_each_example_builds_after_it_is_converted()
    -- the whole point: a model which looks right and does not build is a
    -- conversion which has not been checked
    for _, example in ipairs(EXAMPLES) do
        if example.builds then
            local rootdir = _copy(example.name)
            local result, errors = projectimport.convert(rootdir, {reader = example.reader,
                                                                   force = true})
            assert(result, string.format("%s: %s", example.name, tostring(errors)))

            local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
            local checked = verify.check(rootdir, {
                build = true,
                reader = example.reader,
                context = {harness = instance, config = instance:config(), cwd = rootdir}
            })
            assert(checked.configured, string.format("%s does not configure:\n%s",
                example.name, tostring(checked.output)))
            assert(checked.built, string.format("%s does not build:\n%s\n--- the xmake.lua ---\n%s",
                example.name, tostring(checked.output),
                io.readfile(path.join(rootdir, "xmake.lua"))))
        end
    end
end


function test_the_ones_which_are_not_built_say_why()
    -- an example which is not built has to be a decision written down, not a
    -- reader which quietly has no coverage
    for _, example in ipairs(EXAMPLES) do
        if not example.builds then
            assert(example.why and example.why ~= "",
                   example.name .. " is not built and does not say why")
        end
    end
end

function test_an_android_project_says_it_is_one()
    -- it converts correctly and does not build here, and the difference
    -- between those two is worth stating in the file rather than in a bug report
    local rootdir = _copy("ndkbuild")
    local project = projectimport.read(rootdir, {reader = "ndkbuild"})
    local said = table.concat(project.notes, " ")
    assert(said:find("android", 1, true), said)
    assert(said:find("ndk", 1, true), said)
end
