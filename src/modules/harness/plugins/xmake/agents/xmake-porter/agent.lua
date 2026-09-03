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
-- @file        agent.lua
--

--
-- the porter arrives knowing what it is looking at
--
-- its first two steps were always the same two: detect the build system, then
-- read it. neither needs a model — they are the same answer every time — and
-- doing them here costs nothing and saves two round trips of a conversation
-- which is already long.
--
-- what it does *not* do is decide anything. the facts and the list of things
-- which could not be worked out go into the task, and deciding them is the
-- whole reason there is an agent at all.
--

-- imports
import("harness.core.progress")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})

-- what it found, handed over with the task
function before(context)
    local rootdir = context.cwd or os.curdir()
    progress.stage(context.progress, "reading the project")

    local found = projectimport.detect(rootdir)
    if #found == 0 then
        return "There is nothing here this can read: no CMakeLists.txt, no .sln, no "
               .. "meson.build, no SConstruct. Say so rather than converting by hand."
    end

    local project, errors = projectimport.read(rootdir, {})
    if not project then
        return string.format("`%s` is here but could not be read: %s\nStart with "
            .. "`xmake_import` and work out why.", found[1].title, tostring(errors))
    end

    progress.stage(context.progress, "reading the project", "done")
    return _facts(found[1], project)
end

-- the facts, as the agent is given them
function _facts(found, project)
    local summary = model.summary(project)
    local lines = {}
    table.insert(lines, string.format(
        "I have already read it for you, so do not read the %s files by eye.", found.title))
    table.insert(lines, "")
    table.insert(lines, string.format("**%s**, built with %s (%s): %d target%s (%s)",
        project.name or "?", found.title, table.concat(found.files, ", "),
        summary.targets, summary.targets == 1 and "" or "s", summary.kinds))
    table.insert(lines, "")

    for _, one in ipairs(project.targets) do
        local parts = {}
        for _, field in ipairs({"files", "includedirs", "defines", "deps", "packages",
                                "links", "syslinks"}) do
            if #(one[field] or {}) > 0 then
                table.insert(parts, string.format("%s: %s", field,
                                                  table.concat(one[field], " ")))
            end
        end
        table.insert(lines, string.format("- `%s` (%s) — %s", one.name, one.kind,
                                          table.concat(parts, "; ")))
    end

    table.insert(lines, "")
    if #project.unresolved == 0 then
        table.insert(lines, "Nothing was left undecided, which is worth checking rather than "
                            .. "trusting: write it and verify it.")
    else
        table.insert(lines, string.format("**%d thing%s to decide** — this is the work:",
            #project.unresolved, #project.unresolved == 1 and "" or "s"))
        table.insert(lines, "")
        for _, one in ipairs(project.unresolved) do
            table.insert(lines, string.format("- %s%s %s%s", _where(one),
                one.target and ("(" .. one.target .. ")") or "",
                one.why or "",
                one.text and ("  —  `" .. one.text .. "`") or ""))
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Read only the lines named above, decide each one, then "
                        .. "`xmake_import_write` and `xmake_import_verify`.")
    return table.concat(lines, "\n")
end

-- where it is, when it is anywhere in particular
--
-- the ones which come from the flags are about a target and not about a line,
-- and `nil:?` in front of them reads as a bug
function _where(one)
    if not one.file then
        return ""
    end
    return string.format("`%s:%s` ", one.file, tostring(one.line or "?"))
end

-- an agent which has nothing to convert does not need the whole toolbox
--
-- a shorter tool list is a shorter request every step, and this one is long
--
function define(context)
    local rootdir = context.cwd or os.curdir()
    if #projectimport.detect(rootdir) == 0 then
        return {maxsteps = 4}
    end
end
