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
-- @file        search_text.lua
--

-- imports
import("harness.fs.fs")
import("harness.fs.search")
import("harness.util.util")
import("harness.util.text")

-- define the tool
function define()
    return {
        name = "search_text",
        group = "fs",
        permission = "read",
        description = [[Search a pattern in the file contents, like `grep -rn`.

- The pattern is a regular expression: `.` `*` `+` `?` `[]` `^` `$` `\d` `\w` `\s` `|`.
- Prefer this over reading whole files: it is the cheapest way to find where
  something is defined or used, and it costs a fraction of the context.
- `mode` picks what you get back:
    `content` the matching lines with their file and line number (the default)
    `files`   only the file names, use it to locate something in a big project
    `count`   how many matches each file has
- Use `include` to restrict the file types, e.g. `*.lua`, and `context` to get
  the surrounding lines of every match.
- The build directories, `.git` and `node_modules` are skipped automatically.]],
        parameters = {
            type = "object",
            properties = {
                pattern    = {type = "string",  description = "The pattern to search."},
                path       = {type = "string",  description = "The root directory, the working directory by default."},
                include    = {type = "string",  description = "Only search the files matching this glob, e.g. `*.lua`."},
                mode       = {type = "string",  description = "`content`, `files` or `count`, `content` by default."},
                context    = {type = "integer", description = "How many lines to show around every match, 0 by default."},
                ignorecase = {type = "boolean", description = "Ignore the case, false by default."},
                limit      = {type = "integer", description = "The maximum number of results, 100 by default."}
            },
            required = {"pattern"}
        }
    }
end

-- run the tool
function run(context, args)
    local result = search.run({
        pattern = args.pattern,
        rootdir = fs.resolve(context, args.path or "."),
        noripgrep = (context.config.tools or {}).ripgrep == false,
        include = args.include,
        mode = args.mode or "content",
        context = math.min(tonumber(args.context) or 0, 10),
        ignorecase = args.ignorecase,
        limit = math.min(tonumber(args.limit) or 100, 500)
    })

    local lines = _render(result, context.cwd)
    local output = #lines > 0 and table.concat(lines, "\n") or "(no matches)"
    if result.total > #result.matches and (args.mode or "content") ~= "count" then
        output = output .. string.format("\n\n[%d matches in total, showing the first %d · "
            .. "use `mode=files` to see where they are]", result.total, #result.matches)
    end
    return {
        output = output,
        display = {
            title = "Search",
            subject = args.pattern,
            summary = string.format("%d match%s in %d file%s", result.total, result.total == 1 and "" or "es",
                result.files, result.files == 1 and "" or "s")
        }
    }
end

-- render the matches for the model
function _render(result, cwd)
    local lines = {}
    for _, match in ipairs(result.matches) do
        local filepath = util.shortpath(match.path, cwd)
        if match.count then
            table.insert(lines, string.format("%s: %d", filepath, match.count))
        elseif match.line then
            table.insert(lines, string.format("%s:%d:%s %s", filepath, match.line,
                match.iscontext and "-" or ":", match.text:trim():sub(1, 300)))
        else
            table.insert(lines, filepath)
        end
    end
    return lines
end
