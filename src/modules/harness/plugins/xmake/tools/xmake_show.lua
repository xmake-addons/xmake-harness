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
-- @file        xmake_show.lua
--

-- imports
import("harness.plugins.xmake.xmakecmd")

-- get the arguments of the given call
function _argv(args)
    local what = args.what or "info"
    local argv = xmakecmd.inproject({"show"}, args.dir)
    if what == "targets" then
        table.insert(argv, "-l")
        table.insert(argv, "targets")
    elseif what:startswith("target:") then
        table.insert(argv, "-t")
        table.insert(argv, what:sub(8))
    elseif what ~= "info" and what ~= "" then
        table.insert(argv, "-l")
        table.insert(argv, what)
    end
    return argv
end

-- define the tool
function define()
    return {
        name = "xmake_show",
        group = "xmake",
        permission = "read",
        description = [[Inspect the xmake project and the xmake installation.

- `targets`       list the targets
- `target:<name>` show one target: the files, the deps, the flags
- `options`       list the options
- `toolchains`    list the toolchains
- `info`          show the project information
- `envs`          show the xmake environment variables]],
        parameters = {
            type = "object",
            properties = {
                dir      = {type = "string",  description = "The project directory, when it is not the one you are working in."},
                what = {type = "string", description = "One of `targets`, `target:<name>`, `options`, `toolchains`, `info`, `envs`."}
            },
            required = {"what"}
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
