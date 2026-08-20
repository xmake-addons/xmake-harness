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
-- @file        read_file.lua
--

-- imports
import("harness.fs.fs")
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "read_file",
        group = "fs",
        permission = "read",
        description = [[Read the content of a file from the filesystem.

- The path can be absolute or relative to the working directory.
- The result is prefixed with the line numbers, e.g. `   12| local foo = 1`.
- Use the `offset` and `limit` arguments to read a window of a large file.
- Always read a file before editing it.]],
        parameters = {
            type = "object",
            properties = {
                path   = {type = "string",  description = "The file path to read."},
                offset = {type = "integer", description = "The line number to start from, 1-based."},
                limit  = {type = "integer", description = "The maximum number of lines to read, 2000 by default."}
            },
            required = {"path"}
        }
    }
end

-- run the tool
function run(context, args)
    local filepath = fs.resolve(context, args.path)
    local maxsize = (context.config.context or {}).maxfilesize or 262144
    local lines = fs.readlines(filepath, {maxsize = maxsize})
    local offset = math.max(1, tonumber(args.offset) or 1)
    local limit = math.min(tonumber(args.limit) or 2000, 5000)

    local results = {}
    local endline = math.min(#lines, offset + limit - 1)
    for idx = offset, endline do
        table.insert(results, string.format("%6d| %s", idx, lines[idx]))
    end
    if #results == 0 then
        return {output = string.format("%s is empty or the offset(%d) is out of range(%d lines).", args.path, offset, #lines),
                display = {title = "Read", subject = util.shortpath(filepath, context.cwd), summary = "Empty"}}
    end

    local output = table.concat(results, "\n")
    if endline < #lines then
        output = output .. string.format("\n\n[showing the lines %d-%d of %d, use the offset argument to read more]", offset, endline, #lines)
    end
    return {
        output = output,
        display = {
            title = "Read",
            subject = util.shortpath(filepath, context.cwd),
            summary = string.format("Read %d line%s", endline - offset + 1, (endline - offset) > 0 and "s" or "")
        }
    }
end
