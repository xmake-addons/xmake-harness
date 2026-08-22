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
-- @file        xmake_lua.lua
--

-- imports
import("harness.util.text")
import("harness.plugins.xmake.xmakecmd")

-- define the tool
function define()
    return {
        name = "xmake_lua",
        group = "xmake",
        permission = "exec",
        description = [[Run a lua script inside the xmake runtime.

This is the right way to write the temporary scripts: no python, no bash, no extra
dependency, and it works the same on windows, macos and linux. The whole xmake
script api is available (`os`, `io`, `path`, `import(..)`, ..).

e.g. `print(os.host()); import("core.project.project"); for _, t in pairs(project.targets()) do print(t:name()) end`]],
        parameters = {
            type = "object",
            properties = {
                script = {type = "string", description = "The lua code to run."},
                file   = {type = "string", description = "A lua script file to run instead of the inline code."}
            }
        },
        commandline = function (args)
            if args.file and args.file ~= "" then
                return xmakecmd.commandline({"lua", args.file})
            end
            return xmakecmd.commandline({"lua", "-c", text.truncate((args.script or ""):gsub("%s+", " "), 60)})
        end
    }
end

-- run the tool
function run(context, args)
    if args.file and args.file ~= "" then
        return xmakecmd.run(context, {"lua", args.file})
    end

    local script = args.script or ""
    if script == "" then
        raise("the script is empty!")
    end

    -- the script goes into a temporary file, so any quoting is out of the way
    local scriptfile = os.tmpfile() .. ".lua"
    io.writefile(scriptfile, script)
    local result = xmakecmd.run(context, {"lua", scriptfile})
    os.tryrm(scriptfile)
    result.display.title = xmakecmd.commandline({"lua", "-c",
        text.truncate(script:gsub("%s+", " "), 60)})
    return result
end
