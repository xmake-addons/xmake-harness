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
-- @file        meson.lua
--

--
-- read a meson project into the neutral model
--
-- meson is a small language with real values in it: `files('a.c', 'b.c')` is a
-- list, `executable('demo', src, ...)` is a call with keyword arguments, and
-- variables hold lists rather than strings. that makes it easier to read than
-- cmake and this reader takes the same line: the calls which declare a target,
-- the variables it can follow, and everything else written down as unresolved.
--

-- imports
import("harness.plugins.xmake.import.model")

-- read a project
function read(rootdir, opt)
    opt = opt or {}
    local top = path.join(rootdir, "meson.build")
    if not os.isfile(top) then
        return nil, string.format("there is no meson.build in %s", rootdir)
    end
    local state = {
        model = model.new({from = "meson", dir = rootdir}),
        rootdir = rootdir,
        variables = {},
        seen = {},
        maxfiles = opt.maxfiles or 100
    }
    _readfile(state, top)
    state.model.name = state.model.name or path.filename(path.absolute(rootdir))
    _resolvedeps(state.model)
    return state.model
end

function _readfile(state, filepath)
    if state.seen[filepath] or not os.isfile(filepath) or state.maxfiles <= 0 then
        return
    end
    state.seen[filepath] = true
    state.maxfiles = state.maxfiles - 1
    local relative = path.relative(filepath, state.rootdir)
    local prefix = path.relative(path.directory(filepath), state.rootdir)
    local lines = (io.readfile(filepath) or ""):split("\n", {strict = true})
    for number, line in ipairs(lines) do
        _line(state, line, {file = relative, prefix = prefix, line = number,
                            dir = path.directory(filepath)})
    end
end

-- one line of it
--
-- a call may run over several lines and this reads one at a time, which is
-- enough for the shape almost every project has and is honest about the rest:
-- a call it could not read whole is recorded rather than half-understood
--
function _line(state, line, where)
    local text = line:gsub("#.*$", ""):trim()
    if text == "" then
        return
    end

    -- project('demo', 'c', 'cpp', version: '1.0')
    local args = text:match("^project%s*%((.*)%)%s*$")
    if args then
        local values = _values(state, args)
        state.model.name = state.model.name or values[1]
        for idx = 2, #values do
            local name = ({c = "c", cpp = "c++", objc = "objc", cuda = "cuda",
                           fortran = "fortran", rust = "rust"})[values[idx]]
            if name then
                model.add(state.model.languages, name)
            end
        end
        return
    end

    -- dependency('zlib'), which is regularly the right-hand side of an
    -- assignment and so has to be looked for before one
    local assigned, dependency = text:match("^([%a_][%w_]*)%s*=%s*dependency%s*%(%s*['\"]([^'\"]+)['\"]")
    dependency = dependency or text:match("^dependency%s*%(%s*['\"]([^'\"]+)['\"]")
    if dependency then
        _package(state, dependency, where)
        if assigned then
            -- so that `dependencies: zlib` further down knows what `zlib` is
            state.variables[assigned] = {dependency}
        end
        return
    end

    -- src = files('a.c', 'b.c')  /  src = ['a.c', 'b.c']
    local name, rest = text:match("^([%a_][%w_]*)%s*=%s*(.+)$")
    if name and rest then
        local values = _values(state, rest:match("^files%s*%((.*)%)%s*$") or
                                      rest:match("^%[(.*)%]%s*$") or rest)
        state.variables[name] = values
        return
    end

    -- executable('demo', src, dependencies: dep, include_directories: inc)
    for call, kind in pairs({executable = "binary", static_library = "static",
                             shared_library = "shared", library = "static",
                             both_libraries = "static"}) do
        local body = text:match("^" .. call .. "%s*%((.*)%)%s*$")
                     or text:match("^[%a_][%w_]*%s*=%s*" .. call .. "%s*%((.*)%)%s*$")
        if body then
            _target(state, body, kind, call, where)
            return
        end
    end

    -- subdir('lib')
    local subdir = text:match("^subdir%s*%(%s*'([^']+)'%s*%)%s*$")
    if subdir then
        _readfile(state, path.join(where.dir, subdir, "meson.build"))
        return
    end

    -- what is left and looks like it matters
    if text:match("^if%s") or text:match("^foreach%s") or text:find("configure_file", 1, true)
       or text:find("custom_target", 1, true) then
        model.unresolved(state.model, {
            file = where.file, line = where.line, text = text,
            why = "meson logic which was not evaluated"
        })
    end
end

-- a package the project depends on
function _package(state, name, where)
    for _, one in ipairs(state.model.packages) do
        if one.name == name:lower() then
            return
        end
    end
    table.insert(state.model.packages, {name = name:lower(), origin = name,
                                        required = true, file = where.file, line = where.line})
end

-- one target declaration
function _target(state, body, kind, call, where)
    local values = _values(state, body)
    local name = values[1]
    if not name then
        return
    end
    if call == "library" or call == "both_libraries" then
        model.note(state.model, "`%s` is a `%s`: static is assumed, meson decides it at "
                   .. "configure time", name, call)
    end
    local one = model.target(state.model, name, {kind = kind, from = where.file})
    for idx = 2, #values do
        local value = values[idx]
        if value:find(":", 1, true) then
            _keyword(state, one, value, where)
        else
            local list = state.variables[value]
            if list then
                for _, file in ipairs(list) do
                    model.add(one.files, _join(where.prefix, file))
                end
            elseif value:find("%.") then
                model.add(one.files, _join(where.prefix, value))
            else
                model.unresolved(state.model, {
                    file = where.file, line = where.line, text = value, target = name,
                    why = "a value which is not a file and not a variable we followed"
                })
            end
        end
    end
end

-- a `name: value` argument
function _keyword(state, one, value, where)
    local key, rest = value:match("^%s*([%a_][%w_]*)%s*:%s*(.*)$")
    if not key then
        return
    end
    local items = _values(state, rest)
    if key == "dependencies" then
        for _, item in ipairs(items) do
            -- it is usually a variable holding what `dependency()` returned
            local held = state.variables[item]
            model.add(one.packages, (held and held[1] or item):lower())
        end
    elseif key == "include_directories" then
        for _, item in ipairs(items) do
            model.add(one.includedirs, _join(where.prefix, item))
        end
    elseif key == "link_with" then
        for _, item in ipairs(items) do
            model.add(one.deps, item)
        end
    elseif key == "c_args" or key == "cpp_args" then
        for _, item in ipairs(items) do
            if item:startswith("-D") then
                model.add(one.defines, item:sub(3))
            else
                model.add(one.cxflags, item)
            end
        end
    elseif key == "install" then
        one.installed = rest:find("true", 1, true) ~= nil
    end
end

-- split an argument list into its values, unquoting the strings
function _values(state, body)
    local out = {}
    for _, piece in ipairs(tostring(body or ""):split(",", {plain = true})) do
        piece = piece:trim()
        if piece ~= "" then
            local quoted = piece:match("^'(.*)'$") or piece:match("^\"(.*)\"$")
            table.insert(out, quoted or piece)
        end
    end
    return out
end

function _join(prefix, one)
    if prefix == "" or prefix == "." then
        return one
    end
    return path.normalize(path.join(prefix, one))
end

-- a dependency which names a target here is a dependency and not a package
function _resolvedeps(project)
    for _, one in ipairs(project.targets) do
        local packages = {}
        for _, name in ipairs(one.packages) do
            if model.get(project, name) then
                model.add(one.deps, name)
            else
                table.insert(packages, name)
            end
        end
        one.packages = packages
    end
end
