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
-- @file        reader.lua
--

--
-- what every reader of a build system does the same way
--
-- the build systems differ; reading them does not. by the fifth reader the same
-- five helpers had been written five times — the path rule, the link which
-- turns out to be a dependency, the line continued with a backslash, the words
-- of a value, the condition written down rather than evaluated — and a bug
-- fixed in one of them stayed in the other four.
--
-- so they live here, and a reader is the part which is actually about cmake or
-- qmake or autotools. that is the whole point of the split: adding a build
-- system should be a file about that build system and nothing else.
--

-- imports
import("harness.plugins.xmake.import.model")

-- start reading a project
--
-- @param opt   {from = "qmake", rootdir = "..", name = "..", maxfiles = 60}
--
function new(opt)
    opt = opt or {}
    return {
        model = model.new({from = opt.from, dir = opt.rootdir, name = opt.name}),
        rootdir = opt.rootdir,
        variables = {},
        seen = {},
        maxfiles = opt.maxfiles or 100
    }
end

-- may we read another file, and mark it read
--
-- every reader follows the project's own includes — `add_subdirectory`,
-- `subdir`, `SUBDIRS`, `SConscript` — and every one of them can be a cycle or
-- a repository with four hundred of them
--
function opening(state, filepath)
    if state.seen[filepath] or not os.isfile(filepath) then
        return false
    end
    if state.maxfiles <= 0 then
        model.note(state.model, "there are more build files than were read")
        return false
    end
    state.seen[filepath] = true
    state.maxfiles = state.maxfiles - 1
    return true
end

-- a path as the model states them: relative to the top of the project
--
-- an absolute path expanded from the build system's own variables is a path on
-- the machine which happened to read it, and an `xmake.lua` with `/var/folders`
-- in it is of no use to anybody. anything inside the project is written
-- relative to it; anything outside stays as it was, because it is a fact worth
-- seeing rather than hiding
--
-- @param prefix    where the file being read sits, relative to the root
--
function join(state, prefix, one)
    one = tostring(one or ""):gsub("\\", "/")
    if one == "" then
        return ""
    end
    if one:startswith("/") or one:match("^%a:/") then
        if state and state.rootdir then
            local inside = path.relative(one, state.rootdir)
            if inside and not inside:startswith("..") then
                return path.normalize(inside)
            end
        end
        return one
    end
    if prefix == nil or prefix == "" or prefix == "." then
        return path.normalize(one)
    end
    return path.normalize(path.join(prefix, one))
end

-- where a file being read sits, relative to the top
function prefixof(state, filepath)
    return path.relative(path.directory(filepath), state.rootdir)
end

-- the lines of a file, with the comments off and the continuations joined
--
-- @param opt   {comment = "#", continuation = "\\"}
-- @return      {{text = "SOURCES += a.cpp", line = 3}, ..}
--
function lines(filepath, opt)
    opt = opt or {}
    local comment = opt.comment or "#"
    local out = {}
    local pending = nil
    local startline = 0
    for number, line in ipairs((io.readfile(filepath) or ""):split("\n", {strict = true})) do
        local text = line
        if comment ~= false then
            text = _uncomment(text, comment)
        end
        text = text:trim()
        if pending then
            text = pending .. " " .. text
            pending = nil
        else
            startline = number
        end
        if text:endswith("\\") then
            pending = text:sub(1, -2):trim()
        elseif text ~= "" then
            table.insert(out, {text = text, line = startline})
        end
    end
    if pending and pending ~= "" then
        table.insert(out, {text = pending, line = startline})
    end
    return out
end

-- take the comment off a line, minding the quotes
function _uncomment(line, marker)
    local quote = nil
    for idx = 1, #line do
        local ch = line:sub(idx, idx)
        if quote then
            if ch == quote then
                quote = nil
            end
        elseif ch == "\"" or ch == "'" then
            quote = ch
        elseif line:sub(idx, idx + #marker - 1) == marker then
            return line:sub(1, idx - 1)
        end
    end
    return line
end

-- the words of a value, unquoted
function words(value)
    local out = {}
    for _, piece in ipairs(tostring(value or ""):split("%s+")) do
        piece = piece:trim()
        local quoted = piece:match("^\"(.*)\"$") or piece:match("^'(.*)'$")
        piece = quoted or piece
        if piece ~= "" then
            table.insert(out, piece)
        end
    end
    return out
end

-- write down a condition rather than evaluating it
--
-- `if(WIN32)` is a fact about a platform and `if(BUILD_TESTING)` is a fact
-- about a choice. they are the same shape, guessing which is which produces a
-- build which is wrong on somebody else's machine, and the reader is not the
-- thing which can tell them apart
--
function condition(state, where, text, why)
    model.unresolved(state.model, {
        file = where and where.file, line = where and where.line,
        target = where and where.target, text = text,
        why = why or "a condition which was not evaluated: what it guards may or may not apply"
    })
end

-- write down a variable which could not be expanded
function unexpanded(state, where, text, why)
    model.unresolved(state.model, {
        file = where and where.file, line = where and where.line,
        target = where and where.target, text = text,
        why = why or "a variable which could not be expanded"
    })
end

-- a link which names a target of this project is a dependency
--
-- it cannot be decided when the link is read: every build system lets a target
-- be linked before the file which declares it has been read, and most projects
-- do exactly that. so it is decided at the end, when every target is known
--
function resolvedeps(project)
    for _, one in ipairs(project.targets) do
        local links = {}
        for _, link in ipairs(one.links or {}) do
            if link ~= one.name and model.get(project, link) then
                model.add(one.deps, link)
            else
                table.insert(links, link)
            end
        end
        one.links = links

        -- and a package which names one is the same mistake in the other
        -- direction: meson's `dependencies:` and cmake's imported targets both
        -- carry names which may be either
        local packages = {}
        for _, name in ipairs(one.packages or {}) do
            if name ~= one.name and model.get(project, name) then
                model.add(one.deps, name)
            else
                table.insert(packages, name)
            end
        end
        one.packages = packages
    end
    return project
end

-- the flags of a compiler command line, sorted into what they mean
--
-- `-Iinclude`, `-DFOO=1`, `-lz`, `-L../lib` and `-isystem x` say the same thing
-- in every build system which has a command line at all, so reading them is
-- worth doing once
--
-- @param one   the target to add them to
-- @return      the flags which were not one of those
--
function flags(state, one, argv, prefix)
    local rest = {}
    local idx = 1
    local pending = nil
    while idx <= #argv do
        local flag = argv[idx]
        if pending then
            _value(state, one, pending, flag, prefix)
            pending = nil
        elseif flag == "-I" or flag == "-D" or flag == "-l" or flag == "-L"
               or flag == "-isystem" or flag == "-include" or flag == "-framework" then
            pending = flag
        else
            local name, value = flag:match("^(%-%a)(.+)$")
            if name and (name == "-I" or name == "-D" or name == "-l" or name == "-L") then
                _value(state, one, name, value, prefix)
            else
                value = flag:match("^%-isystem(.+)$")
                if value then
                    _value(state, one, "-isystem", value, prefix)
                else
                    table.insert(rest, flag)
                end
            end
        end
        idx = idx + 1
    end
    if pending then
        table.insert(rest, pending)
    end
    return rest
end

-- one `-X value` pair
function _value(state, one, name, value, prefix)
    if name == "-I" then
        model.add(one.includedirs, join(state, prefix, value))
    elseif name == "-isystem" then
        model.add(one.sysincludedirs, join(state, prefix, value))
    elseif name == "-D" then
        model.add(one.defines, value)
    elseif name == "-l" then
        model.add(one.links, value)
    elseif name == "-L" then
        model.add(one.linkdirs, join(state, prefix, value))
    elseif name == "-framework" then
        model.add(one.frameworks, value)
    elseif name == "-include" then
        model.add(one.cxflags, "-include")
        model.add(one.cxflags, value)
    end
end

-- split a command line into its arguments, minding the quotes
--
-- a `compile_commands.json` carries one string per file and a makefile carries
-- them everywhere, so this is not specific to either
--
function argv(command)
    local out = {}
    local current = {}
    local quote = nil
    local idx = 1
    local text = tostring(command or "")
    while idx <= #text do
        local ch = text:sub(idx, idx)
        if quote then
            if ch == quote then
                quote = nil
            elseif ch == "\\" and quote == "\"" then
                idx = idx + 1
                table.insert(current, text:sub(idx, idx))
            else
                table.insert(current, ch)
            end
        elseif ch == "\"" or ch == "'" then
            quote = ch
        elseif ch == "\\" then
            idx = idx + 1
            table.insert(current, text:sub(idx, idx))
        elseif ch:match("%s") then
            if #current > 0 then
                table.insert(out, table.concat(current))
                current = {}
            end
        else
            table.insert(current, ch)
        end
        idx = idx + 1
    end
    if #current > 0 then
        table.insert(out, table.concat(current))
    end
    return out
end
