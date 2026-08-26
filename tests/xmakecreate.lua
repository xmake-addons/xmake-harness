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
-- @file        xmakecreate.lua
--

-- imports
import("harness.harness")

function _tool()
    local dir = os.tmpfile() .. ".create"
    os.mkdir(dir)
    local instance = harness.bootstrap({rootdir = dir})
    local tool = instance:service("tools"):get("xmake_create")
    return tool, {harness = instance, cwd = dir}, dir
end

function _line(tool, args)
    return tool.commandline(args)
end

---------------------------------------------------------------------------------
-- the command line it builds
---------------------------------------------------------------------------------

function test_the_tool_is_registered()
    local tool = _tool()
    assert(tool, "the xmake plugin provides it")
    assert(tool.permission == "write", tostring(tool.permission))
end

function test_creating_one()
    local tool = _tool()
    assert(_line(tool, {name = "hello", language = "c", template = "console"})
           == "xmake create -l c -t console hello",
           _line(tool, {name = "hello", language = "c", template = "console"}))
end

function test_the_defaults_are_left_to_xmake()
    -- c++ and console are xmake's defaults, and repeating them here is one more
    -- place to have to change when they move
    local tool = _tool()
    assert(_line(tool, {name = "hello"}) == "xmake create hello", _line(tool, {name = "hello"}))
end

function test_scaffolding_into_the_directory_we_are_already_in()
    -- an existing directory is `-P <dir>`: `xmake create .` answers "you should
    -- specify -P instead of directly using ."
    local tool = _tool()
    assert(_line(tool, {dir = ".", force = true}) == "xmake create -f -P .",
           _line(tool, {dir = ".", force = true}))
end

function test_it_really_scaffolds_in_place()
    local tool, context, dir = _tool()
    io.writefile(path.join(dir, "readme.md"), "not empty\n")
    local result = tool.run(context, {dir = ".", force = true, language = "c"})
    assert(not result.iserror, result.output)
    assert(os.isfile(path.join(dir, "xmake.lua")), "it wrote an xmake.lua here")
    assert(os.isfile(path.join(dir, "src", "main.c")), "and a source file")
end

function test_a_project_which_lives_somewhere_else_can_be_built()
    -- every tool runs in the harness's own working directory, so without this
    -- the project which was just created is the one project which cannot be
    -- built without a shell and a `cd`
    local _, context, dir = _tool()
    local tools = context.harness:service("tools")
    assert(tools:get("xmake_build").commandline({dir = "hello"}) == "xmake build -P hello",
           tools:get("xmake_build").commandline({dir = "hello"}))
    assert(tools:get("xmake_run").commandline({dir = "hello", target = "hello"})
           == "xmake run -P hello hello")
    assert(tools:get("xmake_test").commandline({dir = "hello"}) == "xmake test -P hello")
    assert(tools:get("xmake_config").commandline({dir = "hello", args = "-m debug"})
           == "xmake f -P hello -m debug")

    local created = tools:get("xmake_create").run(context, {name = "hello", language = "c"})
    assert(not created.iserror, created.output)
    local built = tools:get("xmake_build").run(context, {dir = "hello"})
    assert(not built.iserror, built.output)
end

function test_no_name_lists_instead_of_creating()
    -- a model which guesses a template name gets an error and spends a turn on
    -- it, so asking is cheap and the tool answers without making anything
    local tool = _tool()
    assert(_line(tool, {}) == "xmake create --list", _line(tool, {}))
    assert(_line(tool, {language = "rust"}) == "xmake create --list -l rust",
           _line(tool, {language = "rust"}))
    assert(_line(tool, {name = "hello", list = true}) == "xmake create --list",
           _line(tool, {name = "hello", list = true}))
end

---------------------------------------------------------------------------------
-- and what xmake makes of it
---------------------------------------------------------------------------------

function test_it_really_scaffolds_a_project()
    local tool, context, dir = _tool()
    local result = tool.run(context, {name = "hello", language = "c", template = "console"})
    assert(not result.iserror, result.output)
    assert(os.isfile(path.join(dir, "hello", "xmake.lua")), "it wrote an xmake.lua")
    assert(os.isfile(path.join(dir, "hello", "src", "main.c")), "and a source file")
end

function test_the_templates_can_be_listed()
    local tool, context = _tool()
    local result = tool.run(context, {language = "c"})
    assert(not result.iserror, result.output)
    assert(result.output:find("console", 1, true), result.output)
end
