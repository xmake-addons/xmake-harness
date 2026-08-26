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
-- @file        xmake_config.lua
--

-- imports
import("harness.plugins.xmake.xmakecmd")

-- get the arguments of the given call
function _argv(args)
    return table.join(xmakecmd.inproject({"f"}, args.dir), xmakecmd.splitargs(args.args or ""))
end

-- define the tool
function define()
    return {
        name = "xmake_config",
        group = "xmake",
        permission = "exec",
        description = [[Configure the xmake project, it is `xmake f <args>`.

e.g. `-m debug`, `-m release`, `--toolchain=clang`, `-p android --ndk=..`, `--myopt=true`.
Run it before building when the mode, the platform, the toolchain or an option changes.]],
        parameters = {
            type = "object",
            properties = {
                dir      = {type = "string",  description = "The project directory, when it is not the one you are working in."},
                args = {type = "string", description = "The configure arguments, e.g. `-m debug --toolchain=clang`."}
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
