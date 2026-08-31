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
-- @file        xmake_import.lua
--

--
-- read a project built with something else, as facts
--
-- this tool exists so that the model does not have to read a `CMakeLists.txt`
-- and work out what the targets are. it is given them: the names, the kinds,
-- the sources, the includes, the defines, the dependencies — and, separately,
-- the list of places where the original says something the reader could not
-- work out.
--
-- that second list is the useful half. it is the model's work, and it is stated
-- rather than left to be noticed.
--

-- imports
import("harness.util.text")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})

-- define the tool
function define()
    return {
        name = "xmake_import",
        group = "xmake",
        permission = "read",
        description = [[Read a project built with another build system, as facts.

Use it before converting anything: it gives you the targets, their sources,
includes, defines and dependencies without you reading the original, and — more
useful — the list of places the reader could not work out on its own.

- `action` is `detect` (what is this project built with), `read` (the facts) or
  `todo` (only what could not be worked out).
- Reads CMake, Visual Studio (`.sln`/`.vcxproj`), Meson and SCons.
- It never writes anything. `xmake_import_write` writes the `xmake.lua`.

The unresolved list is your work: each entry names a file and a line in the
original. Read those, decide, and say what the answer is.]],
        parameters = {
            type = "object",
            properties = {
                action = {type = "string", description = "`detect`, `read` or `todo`. `read` by default.",
                          enum = {"detect", "read", "todo"}},
                dir    = {type = "string", description = "The project directory, the working directory by default."},
                reader = {type = "string", description = "Force a reader: `cmake`, `vcxproj`, `meson` or `scons`."},
                file   = {type = "string", description = "For Visual Studio, the `.sln` or `.vcxproj` to read."}
            }
        },
        commandline = function (args)
            return string.format("read the %s project in %s",
                                 args.reader or "", args.dir or ".")
        end
    }
end

-- run the tool
function run(context, args)
    local rootdir = path.absolute(args.dir or ".", context.cwd)
    if not os.isdir(rootdir) then
        raise("%s is not a directory.", args.dir or ".")
    end

    local action = args.action or "read"
    if action == "detect" then
        return _detect(rootdir, context)
    end

    local project, errors = projectimport.read(rootdir, {reader = args.reader, file = args.file})
    if not project then
        raise(tostring(errors))
    end
    if action == "todo" then
        return _todo(project, context)
    end
    return _read(project, context, rootdir)
end

-- what this project is built with
function _detect(rootdir, context)
    local found = projectimport.detect(rootdir)
    if #found == 0 then
        return {
            output = "nothing here looks like a project this can read. it knows cmake, "
                     .. "visual studio, meson and scons.",
            display = {title = "Import", subject = _short(rootdir, context), summary = "nothing to read"}
        }
    end
    local lines = {}
    for _, one in ipairs(found) do
        table.insert(lines, string.format("- %s (`%s`): %s", one.title, one.name,
                                          table.concat(one.files, ", ")))
    end
    if found[1].hasxmake then
        table.insert(lines, "")
        table.insert(lines, "there is already an xmake.lua here: converting would replace it.")
    end
    return {
        output = table.concat(lines, "\n"),
        display = {title = "Import", subject = _short(rootdir, context),
                   summary = string.format("%s", found[1].title)}
    }
end

-- the facts
function _read(project, context, rootdir)
    local lines = {}
    local summary = model.summary(project)

    table.insert(lines, string.format("# %s, read from %s", project.name or "?", project.from))
    table.insert(lines, "")
    if #project.languages > 0 then
        table.insert(lines, string.format("languages: %s", table.concat(project.languages, ", ")))
    end
    if #project.options > 0 then
        local names = {}
        for _, one in ipairs(project.options) do
            table.insert(names, string.format("%s=%s", one.name, tostring(one.default)))
        end
        table.insert(lines, string.format("options: %s", table.concat(names, ", ")))
    end
    if #project.packages > 0 then
        local names = {}
        for _, one in ipairs(project.packages) do
            table.insert(names, one.origin or one.name)
        end
        table.insert(lines, string.format("packages: %s", table.concat(names, ", ")))
        table.insert(lines, "")
        table.insert(lines, "each of those is a name in the *other* build system. check it against "
                            .. "xmake-repo with `xrepo search` before writing `add_requires`.")
    end
    table.insert(lines, "")

    for _, one in ipairs(project.targets) do
        table.insert(lines, string.format("## %s (%s)", one.name, one.kind))
        _field(lines, "files", one.files)
        _field(lines, "includedirs", one.includedirs)
        _field(lines, "headerdirs", one.headerdirs)
        _field(lines, "defines", one.defines)
        _field(lines, "deps", one.deps)
        _field(lines, "packages", one.packages)
        _field(lines, "links", one.links)
        _field(lines, "syslinks", one.syslinks)
        _field(lines, "linkdirs", one.linkdirs)
        _field(lines, "languages", one.languages)
        _field(lines, "cxflags", one.cxflags)
        _field(lines, "ldflags", one.ldflags)
        if one.from then
            table.insert(lines, string.format("  declared in: %s", one.from))
        end
        table.insert(lines, "")
    end

    local problems = model.problems(project)
    if #problems > 0 then
        table.insert(lines, "## problems with what was read")
        table.insert(lines, "")
        for _, one in ipairs(problems) do
            table.insert(lines, "- " .. one)
        end
        table.insert(lines, "")
    end

    table.insert(lines, _todotext(project))
    return {
        output = table.concat(lines, "\n"),
        display = {
            title = "Import",
            subject = string.format("%s · %s", project.name or "?", project.from),
            summary = string.format("%d target%s, %d to decide", summary.targets,
                                    summary.targets == 1 and "" or "s", summary.unresolved)
        }
    }
end

-- only what has to be decided
function _todo(project, context)
    local summary = model.summary(project)
    return {
        output = _todotext(project),
        display = {
            title = "Import",
            subject = string.format("%s · what to decide", project.name or "?"),
            summary = string.format("%d", summary.unresolved)
        }
    }
end

-- the unresolved list, as the model reads it
function _todotext(project)
    local lines = {}
    if #project.unresolved == 0 then
        table.insert(lines, "## nothing was left undecided")
        table.insert(lines, "")
        table.insert(lines, "the reader worked all of it out. that is worth checking rather than "
                            .. "trusting: build it and see.")
    else
        table.insert(lines, string.format("## %d thing%s to decide", #project.unresolved,
                                          #project.unresolved == 1 and "" or "s"))
        table.insert(lines, "")
        table.insert(lines, "each names a place in the original. read it, decide, and say so.")
        table.insert(lines, "")
        for _, one in ipairs(project.unresolved) do
            table.insert(lines, string.format("- `%s:%s`%s %s", tostring(one.file),
                tostring(one.line or "?"),
                one.target and (" (" .. one.target .. ")") or "", one.why or ""))
            if one.text then
                table.insert(lines, string.format("      %s", one.text))
            end
        end
    end
    if #project.notes > 0 then
        table.insert(lines, "")
        table.insert(lines, "## notes")
        table.insert(lines, "")
        for _, one in ipairs(project.notes) do
            table.insert(lines, "- " .. one)
        end
    end
    return table.concat(lines, "\n")
end

-- one line of a target's fields, when it has any
function _field(lines, name, values)
    if values and #values > 0 then
        table.insert(lines, string.format("  %s: %s", name, table.concat(values, " ")))
    end
end

function _short(filepath, context)
    return path.relative(filepath, context.cwd)
end
