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
-- @file        references.lua
--

--
-- the source references
--
-- an answer about code rests on somewhere in the code, and `src/json.hpp:101`
-- is how one says where. the terminal turns it into something clickable, which
-- is worth having on its own.
--
-- the part worth building, though, is the check. a model which cites a line it
-- never read is more convincing than one which says nothing and just as wrong,
-- and the reader has no way to tell them apart — the reference looks the same
-- either way. we do have a way: the file is right there. so a reference which
-- points at a file that does not exist, or past the end of one that does, is
-- rendered as what it is rather than as evidence.
--
-- nothing is added to the text, only colored: these are marked after the lines
-- have been wrapped, and a marker character would push the wrapping out by one.
--

-- imports
import("harness.ui.theme")

-- where the relative paths are resolved from
local _PROJECT = nil

-- what we already know about a file, so a long answer does not read it twice
local _LINES = {}

-- the extensions which are never a source reference
--
-- a version number reads exactly like a file and a line: `1.2:3`. so does a
-- host and a port
--
local NOTPATHS = {com = true, org = true, net = true, io = true, cn = true, dev = true}

-- set the directory the references are resolved against
function setproject(rootdir)
    if rootdir ~= _PROJECT then
        _PROJECT = rootdir
        _LINES = {}
    end
    return _PROJECT
end

-- forget what was read, e.g. after the agent has edited something
function forget()
    _LINES = {}
end

-- find the references in a piece of text
--
-- @return  {{text = "src/a.c:12", path = "src/a.c", line = 12}}
--
function find(str)
    local results = {}
    for filepath, line in (str or ""):gmatch("([%w_%-%./\\]+%.%w+):(%d+)") do
        if _isreference(filepath) then
            table.insert(results, {text = filepath .. ":" .. line, path = filepath, line = tonumber(line)})
        end
    end
    return results
end

-- is this really a file and a line?
--
-- two things read exactly like one and are not: a url with a port, which the
-- `//` gives away, and a version number, whose last part is all digits — no
-- source file is called `1.2`
--
-- the pattern deliberately captures no character before the path. it used to,
-- to see what came in front, and that ate the first letter whenever the
-- reference began the string: `src/a.c:1` was checked as `rc/a.c:1`, found
-- missing, and shown as a broken citation. inside backticks — where most
-- citations are written — the reference always begins the string
--
function _isreference(filepath)
    if filepath:find("//", 1, true) then
        return false
    end
    local extension = filepath:match("%.(%w+)$")
    if not extension or extension:match("^%d+$") or NOTPATHS[extension:lower()] then
        return false
    end
    return true
end

-- does this reference point at something which is really there?
--
-- @return  "ok", "missing" when there is no such file, "outofrange" when the
--          file is shorter than that, or "unknown" when we cannot tell
--
function check(filepath, line)
    local count = _linecount(filepath)
    if count == nil then
        return "missing"
    elseif count == false then
        return "unknown"
    elseif line > count then
        return "outofrange"
    end
    return "ok"
end

-- how many lines that file has
--
-- @return  the count, nil when there is no such file, false when we will not
--          look (it is huge, or it is not text)
--
function _linecount(filepath)
    local known = _LINES[filepath]
    if known ~= nil then
        return known
    end
    local absolute = path.is_absolute(filepath) and filepath
        or (_PROJECT and path.join(_PROJECT, filepath) or filepath)
    local result = nil
    if os.isfile(absolute) then
        local size = os.filesize(absolute) or 0
        if size > 4 * 1024 * 1024 then
            result = false
        else
            local content = io.readfile(absolute)
            result = content and (#content:gsub("[^\n]", "") + 1) or false
        end
    end
    _LINES[filepath] = result
    return result
end

-- how to show one reference, or nil to leave it alone
--
-- red says "this is not where you say it is", which is a claim of its own and
-- has to be earned. a bare `references.lua:70` names no directory: it is not at
-- the project root, but it may well be three levels down and right. we do not
-- know, so we say nothing — an honest no-opinion beats a confident wrong one.
--
-- a path which names a directory is a different matter: it points somewhere
-- exactly, and there either is a file there or there is not
--
function _style(filepath, line)
    local verdict = check(filepath, line)
    if verdict == "ok" then
        return "md.ref"
    elseif verdict == "unknown" then
        return nil
    end
    if verdict == "missing" and not filepath:find("[/\\]") then
        return nil
    end
    return "md.refbroken"
end

-- color the references in one already-wrapped line
function mark(str)
    if theme.isplain() or not str or str == "" then
        return str
    end
    return (str:gsub("([%w_%-%./\\]+%.%w+):(%d+)", function (filepath, line)
        if not _isreference(filepath) then
            return nil
        end
        local style = _style(filepath, tonumber(line))
        if not style then
            return nil
        end
        return theme.styled(style, filepath .. ":" .. line)
    end))
end

-- expand the `@file` references of an input
--
-- both front ends do this and neither should do it differently: the terminal
-- reads `@src/main.c` out of a line somebody typed, and so does a browser,
-- where the same `@` also opens a completion, @see harness.web.files
--
-- @param input    the line the user wrote
-- @param rootdir  the project it is written in
-- @return         the line, with the files appended to it
--
function expand(input, rootdir)
    if type(input) ~= "string" or input == "" then
        return input
    end
    local attachments = {}
    local seen = {}
    for reference in input:gmatch("@([%w%._%-/\\]+)") do
        local filepath = path.absolute(reference, rootdir)
        if not seen[filepath] and os.isfile(filepath) then
            seen[filepath] = true
            local content = io.readfile(filepath) or ""
            if #content < 131072 then
                table.insert(attachments, string.format("### %s\n\n```\n%s\n```", reference, content))
            end
        end
    end
    if #attachments == 0 then
        return input
    end
    return input .. "\n\n" .. table.concat(attachments, "\n\n")
end
