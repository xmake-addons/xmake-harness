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
-- @file        plugin.lua
--

--
-- the cmake enhancement plugin
--
-- it is intentionally small: it shows that the harness is not tied to xmake,
-- the same seams give a cmake project its own tools and prompt facts.
--

-- imports
import("harness.util.text")
import("harness.shell.exec")

-- describe the plugin
function define()
    return {
        name = "cmake",
        description = "The cmake support: configure, build and test a cmake project."
    }
end

-- apply the plugin to the harness
function apply(harness, definition)
    local settings = (harness:config().plugins or {}).cmake or {}
    if settings.enabled == false then
        return
    end

    -- this plugin only shows up in a cmake project
    if not os.isfile(path.join(harness:rootdir(), "CMakeLists.txt")) then
        return
    end

    local tools = harness:service("tools")
    tools:add({
        name = "cmake_configure",
        group = "cmake",
        permission = "exec",
        description = "Configure the cmake project into the build directory, it is `cmake -S . -B <builddir> <args>`.",
        parameters = {
            type = "object",
            properties = {
                builddir = {type = "string", description = "The build directory, `build` by default."},
                args     = {type = "string", description = "The extra arguments, e.g. `-DCMAKE_BUILD_TYPE=Debug`."}
            }
        },
        run = function (context, args)
            local builddir = args.builddir or "build"
            local argv = {"-S", ".", "-B", builddir}
            for item in (args.args or ""):gmatch("%S+") do
                table.insert(argv, item)
            end
            return _run(context, "cmake", argv, "Configure", builddir)
        end
    })
    tools:add({
        name = "cmake_build",
        group = "cmake",
        permission = "exec",
        description = "Build the cmake project, it is `cmake --build <builddir> [--target ..]`.",
        parameters = {
            type = "object",
            properties = {
                builddir = {type = "string", description = "The build directory, `build` by default."},
                target   = {type = "string", description = "The target to build, all by default."}
            }
        },
        run = function (context, args)
            local builddir = args.builddir or "build"
            local argv = {"--build", builddir}
            if args.target and args.target ~= "" then
                table.insert(argv, "--target")
                table.insert(argv, args.target)
            end
            return _run(context, "cmake", argv, "Build", args.target or builddir, 1800000)
        end
    })
    tools:add({
        name = "ctest",
        group = "cmake",
        permission = "exec",
        description = "Run the tests of the cmake project with ctest.",
        parameters = {
            type = "object",
            properties = {
                builddir = {type = "string", description = "The build directory, `build` by default."},
                args     = {type = "string", description = "The extra ctest arguments, e.g. `-R mytest`."}
            }
        },
        run = function (context, args)
            local argv = {"--test-dir", args.builddir or "build", "--output-on-failure"}
            for item in (args.args or ""):gmatch("%S+") do
                table.insert(argv, item)
            end
            return _run(context, "ctest", argv, "Test", args.args, 1800000)
        end
    })

    harness:on("prompt/environment", function (lines, opt)
        table.insert(lines, "cmake project: yes (CMakeLists.txt)")
        return lines
    end, {owner = "cmake"})
end

-- run a program and make the tool result
function _run(context, program, argv, title, subject, timeout)
    local tool = import("lib.detect.find_tool", {anonymous = true})(program)
    if not tool then
        raise("%s is not found!", program)
    end
    local result = exec.run(context, {program = tool.program, argv = argv, timeout = timeout})
    local output = result.output ~= "" and result.output or "(no output)"
    if result.exitcode ~= 0 then
        output = output .. string.format("\n\n[%s exited with %d]", program, result.exitcode)
    end
    return {
        output = output,
        iserror = result.exitcode ~= 0,
        display = {
            title = title,
            subject = subject,
            summary = string.format("%s · %d lines", result.exitcode == 0 and "ok" or "failed", #text.lines(output)),
            kind = "output",
            output = output
        }
    }
end
