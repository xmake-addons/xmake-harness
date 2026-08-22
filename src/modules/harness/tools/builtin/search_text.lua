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
import("harness.util.util")
import("harness.util.regex")

-- define the tool
function define()
    return {
        name = "search_text",
        group = "fs",
        permission = "read",
        description = [[Search a pattern in the file contents, like `grep -rn`.

- The pattern is a regular expression, the common syntax is supported:
  `.` `*` `+` `?` `[]` `^` `$` `\d` `\w` `\s` `|`.
- Use `include` to restrict the file types, e.g. `*.lua`.
- The build directories, `.git` and `node_modules` are skipped automatically.]],
        parameters = {
            type = "object",
            properties = {
                pattern    = {type = "string",  description = "The pattern to search."},
                path       = {type = "string",  description = "The root directory, the working directory by default."},
                include    = {type = "string",  description = "Only search the files matching this glob, e.g. `*.lua`."},
                ignorecase = {type = "boolean", description = "Ignore the case, false by default."},
                limit      = {type = "integer", description = "The maximum number of matched lines, 100 by default."}
            },
            required = {"pattern"}
        }
    }
end

-- run the tool
-- get the files to search
function _files(context, args)
    local rootdir = fs.resolve(context, args.path or ".")
    if not args.include then
        return fs.walk(rootdir, {maxcount = 20000})
    end

    -- a bare `*.lua` means "anywhere below the root"
    local pattern = args.include
    if not pattern:find("/", 1, true) and not pattern:find("\\", 1, true) then
        pattern = path.join("**", pattern)
    end
    return os.files(path.join(rootdir, pattern))
end

-- make the matcher of the given pattern
--
-- the model writes the regex syntax, we translate it to the lua patterns and
-- fall back to the plain text search when it uses something we cannot express
--
function _matcher(args)
    local patterns = regex.translate(args.pattern)
    if not patterns then
        local needle = args.ignorecase and args.pattern:lower() or args.pattern
        return function (line)
            local target = args.ignorecase and line:lower() or line
            return target:find(needle, 1, true) ~= nil
        end
    end
    if args.ignorecase then
        for idx, pattern in ipairs(patterns) do
            patterns[idx] = _ignorecase(pattern)
        end
    end
    return function (line)
        for _, pattern in ipairs(patterns) do
            if try { function () return line:find(pattern) end } then
                return true
            end
        end
        return false
    end
end

-- search one file and collect the matched lines
--
-- @return  the number of the matches in this file
--
function _searchfile(filepath, matcher, results, opt)
    if fs.isbinary(filepath) or (os.filesize(filepath) or 0) >= 4194304 then
        return 0
    end
    local count = 0
    local lineno = 0
    for line in io.lines(filepath) do
        lineno = lineno + 1
        if matcher(line) then
            count = count + 1
            if #results < opt.limit then
                table.insert(results, string.format("%s:%d: %s",
                    util.shortpath(filepath, opt.cwd), lineno, line:trim():sub(1, 300)))
            end
        end
    end
    return count
end

-- run the tool
function run(context, args)
    local limit = math.min(tonumber(args.limit) or 100, 500)
    local matcher = _matcher(args)
    local results = {}
    local matchedfiles = 0
    local total = 0
    for _, filepath in ipairs(_files(context, args)) do
        if #results >= limit then
            break
        end
        local count = _searchfile(filepath, matcher, results, {limit = limit, cwd = context.cwd})
        if count > 0 then
            total = total + count
            matchedfiles = matchedfiles + 1
        end
    end

    local output = #results > 0 and table.concat(results, "\n") or "(no matches)"
    if total > #results then
        output = output .. string.format("\n\n[%d matches in total, showing the first %d]", total, #results)
    end
    return {
        output = output,
        display = {
            title = "Search",
            subject = args.pattern,
            summary = string.format("%d match%s in %d file%s", total, total == 1 and "" or "es",
                matchedfiles, matchedfiles == 1 and "" or "s")
        }
    }
end

-- make the lua pattern case insensitive
function _ignorecase(pattern)
    return (pattern:gsub("(%%?)(%a)", function (percent, letter)
        if percent ~= "" then
            return percent .. letter
        end
        return string.format("[%s%s]", letter:lower(), letter:upper())
    end))
end
