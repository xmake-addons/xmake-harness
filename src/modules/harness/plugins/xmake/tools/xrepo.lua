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
-- @file        xrepo.lua
--

-- imports
import("harness.plugins.xmake.xmakecmd")

-- define the tool
function define()
    return {
        name = "xrepo",
        group = "xmake",
        permission = "exec",
        description = [[Search and inspect the c/c++ packages of the xmake package repository.

e.g. `search zlib`, `info zlib`, `install zlib`, `list`.
Use it before adding an `add_requires(..)` to check the real package name and version.]],
        parameters = {
            type = "object",
            properties = {
                command = {type = "string", description = "The xrepo command, e.g. `search zlib`."}
            },
            required = {"command"}
        },
        commandline = function (args)
            return "xrepo " .. (args.command or "")
        end
    }
end

-- run the tool
function run(context, args)
    local argv = table.join({"lua", "private.xrepo"}, xmakecmd.splitargs(args.command))
    local result = xmakecmd.run(context, argv, {timeout = 600000})
    result.display.title = "xrepo " .. (args.command or "")
    return result
end
