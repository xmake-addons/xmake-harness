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
-- @file        glob_files.lua
--

-- imports
import("harness.fs.fs")
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "glob_files",
        group = "fs",
        permission = "read",
        description = [[Find the files by a glob pattern, e.g. `src/**/*.lua`, `*.md`.

- `*` matches inside one directory level, `**` matches recursively.
- The results are sorted by the modification time, the newest first.]],
        parameters = {
            type = "object",
            properties = {
                pattern = {type = "string",  description = "The glob pattern, e.g. `src/**/*.c`."},
                path    = {type = "string",  description = "The root directory, the working directory by default."},
                limit   = {type = "integer", description = "The maximum number of results, 200 by default."}
            },
            required = {"pattern"}
        }
    }
end

-- nothing matched, and often for a reason worth saying
--
-- in xmake's patterns `**` already means "at any depth", so `src/**/*` reads as
-- "a file inside a subdirectory of src" and not "everything under src". the
-- second is what somebody writing it meant, every other glob in the world
-- agrees with them, and the empty answer sends them round the loop again
--
function _nothing(pattern)
    pattern = tostring(pattern or "")
    if pattern:find("**/", 1, true) then
        local better = pattern:gsub("%*%*/%*%*", "**"):gsub("%*%*/%*$", "**")
                              :gsub("%*%*/(%*%.[%w_]+)$", "**.%1"):gsub("%*%*%.%*%.", "**.")
        return string.format("(no files matched)\n\n"
            .. "in xmake's patterns `**` already matches at any depth, so `%s` means "
            .. "\"a file inside a subdirectory\" and not \"every file underneath\".\n"
            .. "try `%s`, or `dir/**.cpp` for one extension.", pattern, better)
    end
    return "(no files matched)"
end

-- run the tool
function run(context, args)
    local rootdir = fs.resolve(context, args.path or ".")
    local pattern = args.pattern
    if not path.is_absolute(pattern) then
        pattern = path.join(rootdir, pattern)
    end
    local limit = math.min(tonumber(args.limit) or 200, 1000)
    local files = os.files(pattern)

    -- sort by the modification time
    local items = {}
    for _, filepath in ipairs(files) do
        table.insert(items, {path = filepath, mtime = os.mtime(filepath) or 0})
    end
    table.sort(items, function (a, b) return a.mtime > b.mtime end)

    local results = {}
    for idx, item in ipairs(items) do
        if idx > limit then
            break
        end
        table.insert(results, util.shortpath(item.path, context.cwd))
    end
    local output = #results > 0 and table.concat(results, "\n") or _nothing(args.pattern)
    if #items > limit then
        output = output .. string.format("\n\n[%d files matched, showing the first %d]", #items, limit)
    end
    return {
        output = output,
        display = {
            title = "Glob",
            subject = args.pattern,
            summary = string.format("%d file%s", #items, #items == 1 and "" or "s")
        }
    }
end
