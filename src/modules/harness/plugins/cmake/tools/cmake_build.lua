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
-- @file        cmake_build.lua
--

-- imports
import("harness.plugins.cmake.cmakecmd")

-- get the arguments of the given call
function _argv(args)
    local argv = {"--build", args.builddir or "build"}
    if args.target and args.target ~= "" then
        table.insert(argv, "--target")
        table.insert(argv, args.target)
    end
    return argv
end

-- define the tool
function define()
    return {
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
        commandline = function (args)
            return cmakecmd.commandline("cmake", _argv(args))
        end
    }
end

-- run the tool
function run(context, args)
    return cmakecmd.run(context, "cmake", _argv(args), {timeout = 1800000})
end
