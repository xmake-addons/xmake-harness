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
-- @file        search.lua
--

--
-- the content search
--
-- a big project is the normal case, and reading whole files to find one symbol
-- is what fills a context window fastest. so the search has to be good enough
-- that the agent can work from the matches instead:
--
--   - `ripgrep` drives it when the machine has it, it is much faster than
--     anything we can do from lua, and it already skips the ignored files
--   - otherwise we walk the project ourselves, which is slower but produces the
--     very same results, so the agent never has to care which one ran
--
-- the output modes follow what an agent actually needs: the matching lines, the
-- file names alone (cheap, for "where is this?"), or the counts per file.
--

-- imports
import("harness.fs.fs")
import("harness.util.util")
import("harness.util.regex")
import("lib.detect.find_tool")

-- search the given pattern
--
-- @param opt   the options
--              - pattern       the pattern, a regular expression
--              - rootdir       where to search
--              - include       only the files matching this glob, e.g. "*.lua"
--              - mode          "content", "files" or "count"
--              - ignorecase    ignore the case
--              - context       how many lines around a match, e.g. 2
--              - limit         the maximum number of the results
--
-- @return      {matches = {..}, total = 12, files = 3, tool = "ripgrep"}
--
function run(opt)
    opt = opt or {}
    opt.mode = opt.mode or "content"
    opt.limit = math.min(opt.limit or 100, 1000)

    local ripgrep = _ripgrep()
    if ripgrep then
        local result = _withripgrep(ripgrep, opt)
        if result then
            return result
        end
    end
    return _withlua(opt)
end

-- find the ripgrep program
function _ripgrep()
    local cached = _g.ripgrep
    if cached == nil then
        local tool = find_tool("rg")
        cached = tool and tool.program or false
        _g.ripgrep = cached
    end
    return cached or nil
end

-- search with ripgrep
--
-- @return  the result, or nil when ripgrep could not run it
--
function _withripgrep(program, opt)
    local argv = {"--no-heading", "--line-number", "--color", "never", "--no-messages"}
    if opt.ignorecase then
        table.insert(argv, "--ignore-case")
    end
    if opt.include then
        table.insert(argv, "--glob")
        table.insert(argv, opt.include)
    end
    if opt.mode == "files" then
        table.insert(argv, "--files-with-matches")
    elseif opt.mode == "count" then
        table.insert(argv, "--count-matches")
    elseif (opt.context or 0) > 0 then
        table.insert(argv, "--context")
        table.insert(argv, tostring(opt.context))
    end
    table.insert(argv, "--max-count")
    table.insert(argv, tostring(opt.limit))
    table.insert(argv, "--regexp")
    table.insert(argv, opt.pattern)
    table.insert(argv, opt.rootdir)

    local outdata = try { function () return os.iorunv(program, argv) end }
    if outdata == nil then
        -- ripgrep exits with 1 when nothing matched, that is not a failure
        return {matches = {}, total = 0, files = 0, tool = "ripgrep"}
    end
    return _parse(outdata, opt)
end

-- parse the output of ripgrep
function _parse(outdata, opt)
    local matches = {}
    local files = {}
    local total = 0
    for _, line in ipairs(outdata:split("\n", {plain = true})) do
        if line ~= "" then
            local item = _parseline(line, opt)
            if item then
                files[item.path] = true
                total = total + (item.count or 1)
                if #matches < opt.limit then
                    table.insert(matches, item)
                end
            end
        end
    end
    return {matches = matches, total = total, files = _count(files), tool = "ripgrep"}
end

-- parse one line of the ripgrep output
function _parseline(line, opt)
    if opt.mode == "files" then
        return {path = line}
    elseif opt.mode == "count" then
        local filepath, count = line:match("^(.+):(%d+)$")
        if filepath then
            return {path = filepath, count = tonumber(count)}
        end
        return nil
    end

    -- "path:12:the line" for a match, "path-12-the line" for a context line
    local filepath, lineno, text = line:match("^(.-):(%d+):(.*)$")
    if filepath then
        return {path = filepath, line = tonumber(lineno), text = text}
    end
    filepath, lineno, text = line:match("^(.-)%-(%d+)%-(.*)$")
    if filepath then
        return {path = filepath, line = tonumber(lineno), text = text, iscontext = true}
    end
    return nil
end

-- search with our own walker
function _withlua(opt)
    local matcher = _matcher(opt)
    local matches = {}
    local files = 0
    local total = 0
    for _, filepath in ipairs(_files(opt)) do
        if #matches >= opt.limit and opt.mode ~= "count" then
            break
        end
        local count = _searchfile(filepath, matcher, matches, opt)
        if count > 0 then
            total = total + count
            files = files + 1
        end
    end
    return {matches = matches, total = total, files = files, tool = "lua"}
end

-- get the files to search
function _files(opt)
    if not opt.include then
        return fs.walk(opt.rootdir, {maxcount = 20000})
    end

    -- a bare `*.lua` means "anywhere below the root"
    local pattern = opt.include
    if not pattern:find("/", 1, true) and not pattern:find("\\", 1, true) then
        pattern = path.join("**", pattern)
    end
    return os.files(path.join(opt.rootdir, pattern))
end

-- make the matcher of the given pattern
--
-- the model writes the regex syntax, we translate it to the lua patterns and
-- fall back to the plain text search when it uses something we cannot express
--
function _matcher(opt)
    local patterns = regex.translate(opt.pattern)
    if not patterns then
        local needle = opt.ignorecase and opt.pattern:lower() or opt.pattern
        return function (line)
            local target = opt.ignorecase and line:lower() or line
            return target:find(needle, 1, true) ~= nil
        end
    end
    if opt.ignorecase then
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

-- search one file
--
-- @return  the number of the matches in this file
--
function _searchfile(filepath, matcher, matches, opt)
    if fs.isbinary(filepath) or (os.filesize(filepath) or 0) >= 4194304 then
        return 0
    end

    local count = 0
    local lineno = 0
    local before = {}
    local after = 0
    for line in io.lines(filepath) do
        lineno = lineno + 1
        if matcher(line) then
            count = count + 1
            if opt.mode == "files" then
                table.insert(matches, {path = filepath})
                return count
            end
            if opt.mode ~= "count" and #matches < opt.limit then
                _addcontext(matches, filepath, before, opt)
                table.insert(matches, {path = filepath, line = lineno, text = line})
                after = opt.context or 0
            end
        elseif after > 0 and #matches < opt.limit then
            table.insert(matches, {path = filepath, line = lineno, text = line, iscontext = true})
            after = after - 1
        end
        _remember(before, {path = filepath, line = lineno, text = line, iscontext = true}, opt.context or 0)
    end
    if opt.mode == "count" and count > 0 then
        table.insert(matches, {path = filepath, count = count})
    end
    return count
end

-- keep the last lines, they become the context before a match
function _remember(before, item, size)
    if size <= 0 then
        return
    end
    table.insert(before, item)
    while #before > size do
        table.remove(before, 1)
    end
end

-- flush the remembered lines in front of a match
function _addcontext(matches, filepath, before, opt)
    if (opt.context or 0) <= 0 then
        return
    end
    for _, item in ipairs(before) do
        if #matches < opt.limit then
            table.insert(matches, item)
        end
    end
    for idx = #before, 1, -1 do
        before[idx] = nil
    end
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

-- count the keys of a set
function _count(set)
    local count = 0
    for _, _ in pairs(set) do
        count = count + 1
    end
    return count
end
