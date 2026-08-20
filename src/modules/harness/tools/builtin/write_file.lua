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
-- @file        write_file.lua
--

-- imports
import("harness.fs.fs")
import("harness.ui.diff")
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "write_file",
        group = "fs",
        permission = "write",
        description = [[Write the content to a file, it creates the file and its parent directories if needed.

- It overwrites the whole file, prefer `edit_file` for the partial changes.
- Read the file first if it already exists.]],
        parameters = {
            type = "object",
            properties = {
                path    = {type = "string", description = "The file path to write."},
                content = {type = "string", description = "The whole content of the file."}
            },
            required = {"path", "content"}
        },
        preview = function (context, args)
            local filepath = fs.resolve(context, args.path)
            local oldtext = os.isfile(filepath) and io.readfile(filepath) or ""
            return {kind = "diff", filepath = filepath, diff = diff.compute(oldtext, args.content or "")}
        end
    }
end

-- run the tool
function run(context, args)
    local filepath = fs.resolve(context, args.path)
    fs.checkwritable(context, filepath)
    local content = args.content or ""
    local exists = os.isfile(filepath)
    local oldtext = exists and io.readfile(filepath) or ""
    fs.writetext(filepath, content)

    local result = diff.compute(oldtext, content)
    local shortpath = util.shortpath(filepath, context.cwd)
    return {
        output = string.format("%s %s (%s)", exists and "Updated" or "Created", shortpath, diff.summary(result)),
        display = {
            title = exists and "Update" or "Create",
            subject = shortpath,
            summary = diff.summary(result),
            kind = "diff",
            filepath = filepath,
            diff = result
        }
    }
end
