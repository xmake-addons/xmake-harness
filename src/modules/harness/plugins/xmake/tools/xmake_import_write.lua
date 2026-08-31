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
-- @file        xmake_import_write.lua
--

--
-- write the first draft of the xmake.lua
--
-- the draft is the boring half of the conversion done for you: the api, the
-- order, the house style, the same answer every time. what it is not is the
-- finished file — the things which had to be judged are marked in it and listed
-- beside it, and finishing them is the work.
--
-- writing it by hand instead would be slower and worse, and rewriting it from
-- scratch afterwards is fine: it is a draft.
--

-- imports
import("harness.fs.fs")
import("harness.util.util")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.import", {alias = "projectimport"})

-- define the tool
function define()
    return {
        name = "xmake_import_write",
        group = "xmake",
        permission = "write",
        description = [[Write the first draft of an `xmake.lua` from another build system.

Run `xmake_import` first and read what it could not decide — this writes the
draft with those places marked, it does not answer them.

- It refuses to replace an existing `xmake.lua` unless `force` is set.
- `preview` returns the file it would write without writing it.
- It also writes `XMAKE-TODO.md` beside it when anything was left undecided.

After it: answer the TODOs by editing the `xmake.lua`, then `xmake_import_verify`.]],
        parameters = {
            type = "object",
            properties = {
                dir     = {type = "string",  description = "The project directory, the working directory by default."},
                reader  = {type = "string",  description = "Force a reader: `cmake`, `vcxproj`, `meson` or `scons`."},
                file    = {type = "string",  description = "For Visual Studio, the `.sln` or `.vcxproj` to read."},
                preview = {type = "boolean", description = "Return what it would write, and write nothing."},
                force   = {type = "boolean", description = "Replace an xmake.lua which is already there."}
            }
        },
        commandline = function (args)
            return string.format("write the xmake.lua for %s", args.dir or ".")
        end
    }
end

-- run the tool
function run(context, args)
    local rootdir = path.absolute(args.dir or ".", context.cwd)
    if not os.isdir(rootdir) then
        raise("%s is not a directory.", args.dir or ".")
    end

    local result, errors = projectimport.convert(rootdir, {
        reader = args.reader,
        file = args.file,
        force = args.force,
        dry = args.preview and true or false
    })
    if not result then
        raise(tostring(errors))
    end

    local summary = result.summary
    if args.preview then
        return {
            output = string.format("this is what it would write to %s:\n\n```lua\n%s\n```\n\n%s",
                path.join(path.relative(rootdir, context.cwd), "xmake.lua"), result.text,
                _after(result)),
            display = {title = "Import", subject = "the draft xmake.lua",
                       summary = string.format("%d target%s, not written", summary.targets,
                                               summary.targets == 1 and "" or "s")}
        }
    end

    -- through the same door everything else writes through, so the change is
    -- part of the conversation and can be put back, @see harness.fs.fs
    fs.writetext(result.path, result.text, context)
    if result.todopath then
        fs.writetext(result.todopath, io.readfile(result.todopath) or "", context)
    end

    local written = {path.relative(result.path, context.cwd)}
    if result.todopath then
        table.insert(written, path.relative(result.todopath, context.cwd))
    end
    return {
        output = string.format("wrote %s\n\n%s", table.concat(written, " and "), _after(result)),
        display = {
            title = "Import",
            subject = util.shortpath(result.path, context.cwd),
            summary = string.format("%d target%s, %d to decide", summary.targets,
                                    summary.targets == 1 and "" or "s", summary.unresolved)
        }
    }
end

-- what is left to do with it
function _after(result)
    local lines = {}
    local project = result.project
    if #result.problems > 0 then
        table.insert(lines, "what is wrong with it already:")
        for _, one in ipairs(result.problems) do
            table.insert(lines, "- " .. one)
        end
        table.insert(lines, "")
    end
    if #project.unresolved > 0 then
        table.insert(lines, string.format("%d place%s in the original could not be worked out, "
            .. "and they are the work: read them, decide, and edit the xmake.lua.",
            #project.unresolved, #project.unresolved == 1 and "" or "s"))
    end
    table.insert(lines, "")
    table.insert(lines, "then run `xmake_import_verify` to see whether it builds and whether it "
                        .. "built the same things the original did.")
    return table.concat(lines, "\n")
end
