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
-- @file        xmake_test.lua
--

-- imports
import("harness.plugins.xmake.xmakecmd")

-- get the arguments of the given call
function _argv(args)
    local argv = {"test"}
    if args.name and args.name ~= "" then
        table.insert(argv, args.name)
    end
    return argv
end

-- define the tool
function define()
    return {
        name = "xmake_test",
        group = "xmake",
        permission = "exec",
        description = "Run the tests of the xmake project, it is `xmake test [name]`.",
        parameters = {
            type = "object",
            properties = {
                name = {type = "string", description = "The test name or the pattern, all the tests by default."}
            }
        },
        commandline = function (args)
            return xmakecmd.commandline(_argv(args))
        end
    }
end

-- run the tool
function run(context, args)
    return xmakecmd.run(context, _argv(args), {timeout = 1800000})
end
