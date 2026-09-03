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
-- @file        bazel.lua
--

--
-- read a bazel project into the neutral model
--
-- a `BUILD` file is starlark and this is not an interpreter, but the rules
-- which declare a target are calls with keyword arguments and nothing else:
--
--   cc_library(
--       name = "aux",
--       srcs = ["aux.cc"],
--       hdrs = ["aux.h"],
--       includes = ["."],
--       defines = ["AUX=1"],
--       deps = ["//other:lib"],
--   )
--
-- so the reading is of the calls and their arguments, and everything around
-- them — the `load()` statements, the macros, the `select()`s — is written down
-- rather than guessed at.
--
-- labels are the part which does not map: `//path/to:target` is a target in
-- another package, `:local` is one here, and `@repo//..` is somebody else's
-- repository and therefore a package. that last one is a decision and is
-- marked as one.
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- the rules which declare a target
local RULES = {
    cc_binary = "binary",
    cc_library = "static",
    cc_test = "binary",
    cc_shared_library = "shared",
    objc_library = "static"
}

-- read a project
function read(rootdir, opt)
    opt = opt or {}
    local state = reader.new({from = "bazel", rootdir = rootdir,
                              name = path.filename(path.absolute(rootdir)),
                              maxfiles = opt.maxfiles or 80})

    local found = _buildfiles(rootdir, state.maxfiles)
    if #found == 0 then
        return nil, string.format("there is no BUILD file in %s", rootdir)
    end
    for _, filepath in ipairs(found) do
        _readfile(state, filepath)
    end
    _labels(state.model)
    _buildir(state, rootdir)
    return reader.resolvedeps(state.model)
end

-- xmake builds into `build/`, and a bazel project has a file called `BUILD`
--
-- on a case-insensitive filesystem — macos by default, windows always — those
-- are the same name, and the build fails with "cannot create directory ...
-- Not a directory" some way in, which says nothing about why. so the converted
-- project builds somewhere else and the file says why
--
function _buildir(state, rootdir)
    for _, name in ipairs({"BUILD", "BUILD.bazel"}) do
        local filepath = path.join(rootdir, name)
        if os.isfile(filepath) and name:lower() == "build" then
            state.model.buildir = "xmake-build"
            model.note(state.model, "the root has a file called `%s`, which is the same name "
                       .. "as xmake's `build` directory on a case-insensitive filesystem: "
                       .. "the build goes to `xmake-build` instead", name)
            return
        end
    end
end

-- every BUILD file of a workspace
--
-- bazel packages are directories with a BUILD in them, and a workspace is as
-- many of those as somebody wrote
--
function _buildfiles(rootdir, limit)
    local out = {}
    for _, name in ipairs({"BUILD", "BUILD.bazel"}) do
        local filepath = path.join(rootdir, name)
        if os.isfile(filepath) then
            table.insert(out, filepath)
        end
    end
    for _, name in ipairs({"BUILD", "BUILD.bazel"}) do
        for _, filepath in ipairs(os.files(path.join(rootdir, "**", name))) do
            if #out < limit then
                table.insert(out, filepath)
            end
        end
    end
    return out
end

-- read one BUILD file
function _readfile(state, filepath)
    if not reader.opening(state, filepath) then
        return
    end
    local relative = path.relative(filepath, state.rootdir)
    -- the package a label without a path refers to
    local package = path.directory(relative)
    if package == "." then
        package = ""
    end
    local where = {file = relative, prefix = reader.prefixof(state, filepath),
                   package = package}

    local content = io.readfile(filepath) or ""
    for _, call in ipairs(_calls(content)) do
        local kind = RULES[call.name]
        if kind then
            _target(state, call, kind, where)
        elseif call.name == "load" then
            -- a rule from somewhere else, so the targets it declares are not
            -- ones this can read
            model.note(state.model, "%s loads %s, whose rules were not read",
                       relative, (call.args[1] or {}).value or "something")
        end
    end
end

-- the calls of a starlark file, with their keyword arguments
--
-- @return  {{name = "cc_library", line = 3, args = {{key = "name", value = "aux",
--            values = {..}}}}, ..}
--
function _calls(content)
    local out = {}
    local pos = 1
    local length = #content
    local line = 1

    while pos <= length do
        local start, stop, name = content:find("([%a_][%w_]*)%s*%(", pos)
        if not start then
            break
        end
        for _ in content:sub(pos, start):gmatch("\n") do
            line = line + 1
        end
        -- a call at the start of a line is a statement; one inside an argument
        -- is a value and is read as part of it
        local before = content:sub(1, start - 1):match("([^\n]*)$") or ""
        local body, after = _balanced(content, stop)
        if before:trim() == "" and body then
            table.insert(out, {name = name, line = line, args = _arguments(body)})
        end
        for _ in content:sub(start, after or stop):gmatch("\n") do
            line = line + 1
        end
        pos = after or (stop + 1)
    end
    return out
end

-- from the open bracket to the one which closes it
function _balanced(content, open)
    local depth = 1
    local pos = open + 1
    local length = #content
    local quote = nil
    while pos <= length do
        local ch = content:sub(pos, pos)
        if quote then
            if ch == "\\" then
                pos = pos + 1
            elseif ch == quote then
                quote = nil
            end
        elseif ch == "\"" or ch == "'" then
            quote = ch
        elseif ch == "#" then
            local stop = content:find("\n", pos, true)
            pos = stop or length
        elseif ch == "(" or ch == "[" or ch == "{" then
            depth = depth + 1
        elseif ch == ")" or ch == "]" or ch == "}" then
            depth = depth - 1
            if depth == 0 then
                return content:sub(open + 1, pos - 1), pos + 1
            end
        end
        pos = pos + 1
    end
    return nil
end

-- the `key = value` arguments of a call
function _arguments(body)
    local out = {}
    for _, piece in ipairs(_split(body)) do
        local key, value = piece:match("^%s*([%a_][%w_]*)%s*=%s*(.*)$")
        if key then
            table.insert(out, {key = key, value = _scalar(value), values = _list(value)})
        end
    end
    return out
end

-- split on the commas which are not inside anything
function _split(body)
    local out = {}
    local current = {}
    local depth = 0
    local quote = nil
    for idx = 1, #body do
        local ch = body:sub(idx, idx)
        if quote then
            table.insert(current, ch)
            if ch == quote then
                quote = nil
            end
        elseif ch == "\"" or ch == "'" then
            quote = ch
            table.insert(current, ch)
        elseif ch == "[" or ch == "(" or ch == "{" then
            depth = depth + 1
            table.insert(current, ch)
        elseif ch == "]" or ch == ")" or ch == "}" then
            depth = depth - 1
            table.insert(current, ch)
        elseif ch == "," and depth == 0 then
            table.insert(out, table.concat(current))
            current = {}
        else
            table.insert(current, ch)
        end
    end
    if #current > 0 then
        table.insert(out, table.concat(current))
    end
    return out
end

-- a single string value
function _scalar(value)
    return value:match("^%s*[\"']([^\"']*)[\"']%s*$")
end

-- the strings of a list value
function _list(value)
    local out = {}
    for one in value:gmatch("[\"']([^\"']*)[\"']") do
        table.insert(out, one)
    end
    return out
end

-- one target
function _target(state, call, kind, where)
    local args = {}
    for _, one in ipairs(call.args) do
        args[one.key] = one
    end
    local name = args.name and args.name.value
    if not name then
        return
    end

    -- a target is `//package:name`, and two packages may both have a `lib`
    local full = where.package == "" and name
        or string.format("%s/%s", where.package, name)
    local one = model.target(state.model, full, {kind = kind, from = where.file})
    one.label = string.format("//%s:%s", where.package, name)

    for _, file in ipairs((args.srcs or {}).values or {}) do
        model.add(one.files, _path(state, where, file))
    end
    for _, file in ipairs((args.hdrs or {}).values or {}) do
        model.add(one.headerdirs, path.directory(_path(state, where, file)))
    end
    for _, dir in ipairs((args.includes or {}).values or {}) do
        model.add(one.includedirs, _path(state, where, dir))
    end
    for _, define in ipairs((args.defines or {}).values or {}) do
        model.add(one.defines, define)
    end
    for _, define in ipairs((args.local_defines or {}).values or {}) do
        model.add(one.defines, define)
    end
    for _, flag in ipairs((args.copts or {}).values or {}) do
        model.add(one.cxflags, flag)
    end
    for _, flag in ipairs((args.linkopts or {}).values or {}) do
        local link = flag:match("^%-l(.+)$")
        if link then
            model.add(one.syslinks, link)
        else
            model.add(one.ldflags, flag)
        end
    end
    for _, label in ipairs((args.deps or {}).values or {}) do
        table.insert(one.labels or {}, label)
        one.labels = one.labels or {}
        model.add(one.labels, label)
    end

    if kind == "static" and args.linkstatic and args.linkstatic.value == "False" then
        model.note(state.model, "`%s` sets linkstatic=False: bazel decides static or shared "
                   .. "at the point of use, and this reads it as static", full)
    end
    if call.args and _hasselect(call) then
        model.unresolved(state.model, {
            file = where.file, line = call.line, target = full,
            text = "select({..})",
            why = "a bazel select(): the values differ by platform and none of them was chosen"
        })
    end
end

-- does any argument use `select()`?
function _hasselect(call)
    for _, one in ipairs(call.args) do
        if (one.value or ""):find("select", 1, true) then
            return true
        end
    end
    return false
end

-- a source path, which is relative to the package it is declared in
function _path(state, where, file)
    if file:startswith("//") then
        return (file:gsub("^//", ""):gsub(":", "/"))
    end
    if where.package == "" then
        return path.normalize(file)
    end
    return path.normalize(path.join(where.package, file))
end

-- the labels, once every package has been read
--
-- `//aux:aux` is a target here, `:aux` is one in the same package, and
-- `@boost//:headers` is somebody else's repository and therefore a package
--
function _labels(project)
    for _, one in ipairs(project.targets) do
        for _, label in ipairs(one.labels or {}) do
            if label:startswith("@") then
                local name = label:match("^@([%w_%-%.]+)")
                if name then
                    model.add(one.packages, name:lower())
                end
            else
                local target = _resolve(project, label, one)
                if target then
                    model.add(one.deps, target)
                else
                    model.unresolved(project, {
                        target = one.name, text = label,
                        why = "a bazel label which names nothing read here"
                    })
                end
            end
        end
        one.labels = nil
    end
end

-- which target a label names
function _resolve(project, label, from)
    local package, name = label:match("^//([^:]*):(.+)$")
    if not package then
        name = label:match("^:(.+)$")
        if name then
            package = path.directory(from.name)
            if package == "." then
                package = ""
            end
        end
    end
    if not name then
        -- `//path/to/lib` is `//path/to:lib`
        package = label:match("^//(.+)$")
        if package then
            name = path.filename(package)
        end
    end
    if not name then
        return nil
    end
    local full = (package == "" or package == nil) and name
        or string.format("%s/%s", package, name)
    if model.get(project, full) then
        return full
    end
    if model.get(project, name) then
        return name
    end
    return nil
end
