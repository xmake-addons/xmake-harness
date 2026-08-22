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
-- @file        ctest.lua
--

-- imports
import("harness.plugins.cmake.cmakecmd")

-- get the arguments of the given call
function _argv(args)
    return table.join({"--test-dir", args.builddir or "build", "--output-on-failure"},
        cmakecmd.splitargs(args.args))
end

-- define the tool
function define()
    return {
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
        commandline = function (args)
            return cmakecmd.commandline("ctest", _argv(args))
        end
    }
end

-- run the tool
function run(context, args)
    return cmakecmd.run(context, "ctest", _argv(args), {timeout = 1800000})
end
