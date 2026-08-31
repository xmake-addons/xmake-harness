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
-- @file        scons.lua
--

--
-- read an scons project into the neutral model
--
-- an `SConstruct` is python, and there is no reading python without running it.
-- so this reader is deliberately the weakest of the four: it finds the calls
-- which declare a target and the obvious lists around them, and it says plainly
-- that the rest is python.
--
-- that is not a failure of the reader, it is the shape of the problem — and it
-- is why what comes out is a starting point with its gaps marked rather than
-- something to be trusted. a model reading the `SConstruct` beside this model
-- is how the rest gets answered, @see harness.plugins.xmake.import.import
--

-- imports
import("harness.plugins.xmake.import.model")

-- read a project
function read(rootdir, opt)
    opt = opt or {}
    local top = nil
    for _, name in ipairs({"SConstruct", "SConstruct.py", "sconstruct"}) do
        if os.isfile(path.join(rootdir, name)) then
            top = path.join(rootdir, name)
            break
        end
    end
    if not top then
        return nil, string.format("there is no SConstruct in %s", rootdir)
    end

    local state = {
        model = model.new({from = "scons", dir = rootdir,
                           name = path.filename(path.absolute(rootdir))}),
        rootdir = rootdir,
        variables = {},
        seen = {},
        maxfiles = opt.maxfiles or 60
    }
    model.note(state.model, "an SConstruct is python: only the calls which declare a "
               .. "target were read, and everything around them is unread")
    _readfile(state, top)
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

function _line(state, line, where)
    local text = line:gsub("#.*$", ""):trim()
    if text == "" then
        return
    end

    -- src = ['a.c', 'b.c']  /  src = Glob('*.c')
    local name, rest = text:match("^([%a_][%w_]*)%s*=%s*(.+)$")
    if name and rest then
        local glob = rest:match("^Glob%s*%(%s*['\"]([^'\"]+)['\"]")
        if glob then
            state.variables[name] = {glob}
            return
        end
        local inside = rest:match("^%[(.*)%]%s*$")
        if inside then
            state.variables[name] = _values(inside)
            return
        end
    end

    -- env.Program('demo', src)  /  Program(target='demo', source=src)
    for call, kind in pairs({Program = "binary", StaticLibrary = "static",
                             SharedLibrary = "shared", Library = "static"}) do
        local body = text:match("%f[%w]" .. call .. "%s*%((.*)%)%s*$")
        if body then
            _target(state, body, kind, call, where)
            return
        end
    end

    -- SConscript('sub/SConscript')
    local script = text:match("SConscript%s*%(%s*['\"]([^'\"]+)['\"]")
    if script then
        local filepath = path.join(where.dir, script)
        if os.isdir(filepath) then
            filepath = path.join(filepath, "SConscript")
        end
        _readfile(state, filepath)
        return
    end

    -- the environment, which is where most projects put their flags
    for key, field in pairs({CPPPATH = "includedirs", CPPDEFINES = "defines",
                             LIBS = "links", LIBPATH = "linkdirs"}) do
        local values = text:match(key .. "%s*=%s*%[(.-)%]")
        if values then
            state.environment = state.environment or {}
            state.environment[field] = state.environment[field] or {}
            for _, one in ipairs(_values(values)) do
                model.add(state.environment[field], one)
            end
            model.unresolved(state.model, {
                file = where.file, line = where.line, text = text,
                why = string.format("an environment %s, which applies to whichever targets "
                                    .. "use this environment", key)
            })
        end
    end
end

function _target(state, body, kind, call, where)
    local values = _values(body)
    local name = nil
    local sources = {}
    for _, value in ipairs(values) do
        local key, rest = value:match("^([%a_][%w_]*)%s*=%s*(.*)$")
        if key == "target" then
            name = _unquote(rest)
        elseif key == "source" then
            table.insert(sources, _unquote(rest))
        elseif not key then
            if not name then
                name = _unquote(value)
            else
                table.insert(sources, _unquote(value))
            end
        end
    end
    if not name then
        return
    end
    if call == "Library" then
        model.note(state.model, "`%s` is a `Library`: static is assumed", name)
    end

    local one = model.target(state.model, name, {kind = kind, from = where.file})
    for _, source in ipairs(sources) do
        local list = state.variables[source]
        if list then
            for _, file in ipairs(list) do
                model.add(one.files, _join(where.prefix, file))
            end
        elseif source:find("%.") or source:find("*", 1, true) then
            model.add(one.files, _join(where.prefix, source))
        else
            model.unresolved(state.model, {
                file = where.file, line = where.line, text = source, target = name,
                why = "a python value which was not followed, so these sources are unknown"
            })
        end
    end

    -- whatever the environment carried, since this is the environment it used
    for field, values in pairs(state.environment or {}) do
        for _, value in ipairs(values) do
            model.add(one[field], field == "includedirs" or field == "linkdirs"
                      and _join(where.prefix, value) or value)
        end
    end
end

-- split a python argument list, and take the quotes off the strings
--
-- a `keyword=value` piece keeps its quotes, because the caller splits it again
--
function _values(body)
    local out = {}
    for _, piece in ipairs(tostring(body or ""):split(",", {plain = true})) do
        piece = piece:trim()
        if piece ~= "" then
            table.insert(out, piece:find("=", 1, true) and piece or _unquote(piece))
        end
    end
    return out
end

function _unquote(str)
    str = tostring(str or ""):trim()
    return str:match("^'(.*)'$") or str:match("^\"(.*)\"$") or str
end

function _join(prefix, one)
    if prefix == "" or prefix == "." then
        return one
    end
    return path.normalize(path.join(prefix, one))
end

function _resolvedeps(project)
    for _, one in ipairs(project.targets) do
        local links = {}
        for _, link in ipairs(one.links) do
            if model.get(project, link) then
                model.add(one.deps, link)
            else
                table.insert(links, link)
            end
        end
        one.links = links
    end
end
