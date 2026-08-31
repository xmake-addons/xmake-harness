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
-- @file        importcli.lua
--

--
-- the import command: /import
--
-- the whole conversion is a job for the agent — the deciding is the work, and
-- there is a subagent whose whole purpose is that, @see agents/xmake-porter.md.
-- this is the way in: it says what is here and hands the job over.
--

-- imports
import("harness.util.text")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})

-- the command, as the xmake plugin registers it
function command()
    return {
        name = "import",
        description = "Convert a project from cmake, visual studio, meson or scons to xmake",
        run = _import
    }
end

-- /import [dir]
function _import(app, args)
    local rootdir = path.absolute((args or ""):trim() ~= "" and args:trim() or ".",
                                  app.harness:rootdir())
    if not os.isdir(rootdir) then
        return {kind = "message", text = string.format("%s is not a directory.", rootdir),
                iserror = true}
    end

    local found = projectimport.detect(rootdir)
    if #found == 0 then
        return {kind = "message", iserror = true, text = string.format(
            "nothing in %s looks like a project which can be converted.\n"
            .. "it reads cmake, visual studio (.sln/.vcxproj), meson and scons.",
            path.relative(rootdir, app.harness:rootdir()))}
    end

    -- what is here, said before anything is done about it
    local lines = {}
    for _, one in ipairs(found) do
        table.insert(lines, string.format("  %s: %s", one.title,
                                          table.concat(one.files, ", ")))
    end
    local overwrite = found[1].hasxmake
        and "\nthere is already an xmake.lua here, so say whether to replace it." or ""

    return {kind = "prompt", text = string.format(
        "Convert this project to xmake. It is built with %s:\n\n%s\n%s\n"
        .. "Use the `xmake-porter` subagent: read the project with `xmake_import`, decide the "
        .. "parts it could not, write the `xmake.lua`, and verify it with "
        .. "`xmake_import_verify` until it builds the same targets. Report what you decided.",
        found[1].title, table.concat(lines, "\n"), overwrite)}
end
