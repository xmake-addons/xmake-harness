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
-- @file        list_dir.lua
--

-- imports
import("harness.fs.fs")
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "list_dir",
        group = "fs",
        permission = "read",
        description = [[List the entries of a directory.

Prefer `glob_files` when you are looking for the files by a pattern.]],
        parameters = {
            type = "object",
            properties = {
                path = {type = "string",  description = "The directory path, the working directory by default."},
                all  = {type = "boolean", description = "Show the hidden entries, false by default."}
            }
        }
    }
end

-- run the tool
function run(context, args)
    local dirpath = fs.resolve(context, args.path or ".")
    if not os.isdir(dirpath) then
        raise("%s is not a directory!", args.path or ".")
    end
    local entries = fs.listdir(dirpath, {all = args.all, skipignored = true})
    local results = {}
    for _, entry in ipairs(entries) do
        if entry.kind == "dir" then
            table.insert(results, entry.name .. "/")
        else
            table.insert(results, string.format("%s (%s)", entry.name, util.filesize(entry.size or 0)))
        end
    end
    local shortpath = util.shortpath(dirpath, context.cwd)
    return {
        output = #results > 0 and table.concat(results, "\n") or "(empty directory)",
        display = {
            title = "List",
            subject = shortpath,
            summary = string.format("%d entr%s", #results, #results == 1 and "y" or "ies")
        }
    }
end
