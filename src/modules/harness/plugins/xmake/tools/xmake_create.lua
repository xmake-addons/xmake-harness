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
-- @file        xmake_create.lua
--

--
-- start a project from a template rather than from a blank file
--
-- left to itself a model writes the first file of a new project in its own house
-- style: its brace placement, its layout, its idea of what an `xmake.lua` looks
-- like. xmake already ships the answer — around seventy templates across the
-- languages it supports, and more from the template addons — so the scaffold is
-- something to fetch and not something to invent.
--

-- imports
import("harness.plugins.xmake.xmakecmd")

-- get the arguments of the given call
function _argv(args)
    if args.list or ((not args.name or args.name == "") and (not args.dir or args.dir == "")) then
        local argv = {"create", "--list"}
        if args.language and args.language ~= "" then
            table.insert(argv, "-l")
            table.insert(argv, args.language)
        end
        return argv
    end

    local argv = {"create"}
    if args.language and args.language ~= "" then
        table.insert(argv, "-l")
        table.insert(argv, args.language)
    end
    if args.template and args.template ~= "" then
        table.insert(argv, "-t")
        table.insert(argv, args.template)
    end
    if args.force then
        table.insert(argv, "-f")
    end

    -- an existing directory is `-P <dir>` and not a positional: `xmake create .`
    -- answers "you should specify -P instead of directly using ."
    if args.dir and args.dir ~= "" then
        table.insert(argv, "-P")
        table.insert(argv, args.dir)
    end
    if args.name and args.name ~= "" then
        table.insert(argv, args.name)
    end
    return argv
end

-- define the tool
function define()
    return {
        name = "xmake_create",
        group = "xmake",
        permission = "write",
        description = [[Create a new xmake project from a template, it is `xmake create`.
Prefer it over writing the first `xmake.lua` and the first source file by hand.

- Scaffold into the current directory with `dir` as `.` and `force`. Pass `name`
  only when the project gets a subdirectory of its own.
- With neither of them it lists the templates instead of creating anything.
- The `xmake-templates` skill has the catalogue and the third-party ones.]],
        parameters = {
            type = "object",
            properties = {
                name     = {type = "string",  description = "The subdirectory to create the project in, e.g. `hello`. It is also the target name."},
                dir      = {type = "string",  description = "Create into this existing directory instead, e.g. `.` for the current one. Needs `force` if it is not empty."},
                language = {type = "string",  description = "The project language, e.g. `c`, `c++`, `rust`, `go`. c++ by default."},
                template = {type = "string",  description = "The template of that language, e.g. `console`, `static`, `shared`, `qt.widgetapp`. console by default."},
                list     = {type = "boolean", description = "List the templates instead of creating a project."},
                force    = {type = "boolean", description = "Create it even though the directory is not empty."}
            }
        },
        commandline = function (args)
            return xmakecmd.commandline(_argv(args))
        end
    }
end

-- run the tool
function run(context, args)
    return xmakecmd.run(context, _argv(args), {timeout = 600000})
end
