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
-- @file        xmake_run.lua
--

-- imports
import("harness.plugins.xmake.xmakecmd")

-- get the arguments of the given call
function _argv(args)
    local argv = xmakecmd.inproject({"run"}, args.dir)
    if args.target and args.target ~= "" then
        table.insert(argv, args.target)
    end
    return table.join(argv, xmakecmd.splitargs(args.args or ""))
end

-- define the tool
function define()
    return {
        name = "xmake_run",
        group = "xmake",
        permission = "exec",
        description = "Run a target of the xmake project, it is `xmake run <target> <args>`.",
        parameters = {
            type = "object",
            properties = {
                dir      = {type = "string",  description = "The project directory, when it is not the one you are working in."},
                target = {type = "string", description = "The target name, the default target if it is empty."},
                args   = {type = "string", description = "The arguments passed to the program."}
            }
        },
        commandline = function (args)
            return xmakecmd.commandline(_argv(args))
        end
    }
end

-- run the tool
function run(context, args)
    return xmakecmd.run(context, _argv(args))
end
