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
-- @file        model.lua
--

--
-- what a project is, once it is no longer the build system it came from
--
-- every reader — cmake, msbuild, meson, scons — produces one of these, and the
-- emitter turns one of these into an `xmake.lua`. neither end knows about the
-- other, which is what makes a new reader a new file and nothing else.
--
-- the model carries two kinds of thing, and the difference is the whole point:
--
--   the facts        a target called `demo`, a binary, built from these files,
--                    with these defines. a reader states them or says nothing.
--   the unresolved   the `if(WIN32)` it could not evaluate, the variable it
--                    could not expand, the function it does not know. every one
--                    of them is recorded with its file and line.
--
-- a converter which guessed at the second kind would produce an `xmake.lua`
-- which looks right and builds the wrong thing. so the reader never guesses:
-- it hands the model, with its gaps marked, to something which can read the
-- surrounding code and decide — @see harness.plugins.xmake.import.import
--

-- the target kinds a model may use, and what they mean in xmake
local KINDS = {binary = true, static = true, shared = true, headeronly = true,
               object = true, phony = true, moduleonly = true}

-- create an empty model
--
-- @param opt   {name = "demo", from = "cmake", dir = "/path/to/project"}
--
function new(opt)
    opt = opt or {}
    return {
        name = opt.name,
        from = opt.from,
        dir = opt.dir,
        languages = {},
        options = {},
        packages = {},
        targets = {},
        notes = {},
        unresolved = {}
    }
end

-- add a target, or return the one which is already there
--
-- a project describes one target in several places — `add_executable` here,
-- three `target_include_directories` further down — so the reader asks for it
-- by name every time and fills in what it has
--
function target(model, name, opt)
    opt = opt or {}
    for _, one in ipairs(model.targets) do
        if one.name == name then
            if opt.kind then
                one.kind = opt.kind
            end
            return one
        end
    end
    local one = {
        name = name,
        kind = opt.kind or "binary",
        files = {},
        headerdirs = {},
        includedirs = {},
        sysincludedirs = {},
        defines = {},
        undefines = {},
        links = {},
        syslinks = {},
        linkdirs = {},
        frameworks = {},
        deps = {},
        packages = {},
        options = {},
        languages = {},
        cxflags = {},
        cflags = {},
        cxxflags = {},
        ldflags = {},
        rules = {},
        installed = opt.installed,
        conditions = {},
        from = opt.from
    }
    table.insert(model.targets, one)
    return one
end

-- get a target by name, without creating one
function get(model, name)
    for _, one in ipairs(model.targets) do
        if one.name == name then
            return one
        end
    end
end

-- add values to one of a target's lists, keeping the order and dropping the
-- duplicates: a project which says `-Iinclude` in four places means it once
function add(list, values)
    if not list then
        return
    end
    for _, value in ipairs(type(values) == "table" and values or {values}) do
        value = tostring(value or ""):trim()
        if value ~= "" and not table.contains(list, value) then
            table.insert(list, value)
        end
    end
end

-- say something about the project which is not a fact about a target
function note(model, format, ...)
    local args = {...}
    local text = #args > 0 and string.format(format, table.unpack(args)) or format
    if not table.contains(model.notes, text) then
        table.insert(model.notes, text)
    end
end

-- record something the reader could not work out
--
-- this is the reader's most useful output after the targets themselves: it is
-- the list of places where somebody — or something — has to look at the
-- original and decide
--
-- @param what  {file = "CMakeLists.txt", line = 42, text = "if(WIN32)",
--               why = "a condition which was not evaluated", target = "demo"}
--
function unresolved(model, what)
    table.insert(model.unresolved, {
        file = what.file,
        line = what.line,
        text = what.text and text_oneline(what.text) or nil,
        why = what.why,
        target = what.target
    })
end

-- one line of it, short enough for a list
function text_oneline(str)
    str = tostring(str or ""):gsub("[ \t\n\r]+", " ")
    if #str > 160 then
        str = str:sub(1, 157) .. "..."
    end
    return str:trim()
end

-- is this a kind xmake knows?
function iskind(kind)
    return KINDS[kind] == true
end

-- everything wrong with a model, as a list of sentences
--
-- it is checked rather than trusted because a reader is a parser of somebody
-- else's language and the next project will use a corner of it nobody has seen
--
function problems(model)
    local found = {}
    if type(model) ~= "table" then
        return {"the model is not a table"}
    end
    if #(model.targets or {}) == 0 then
        table.insert(found, "there is no target in it")
    end
    local seen = {}
    for _, one in ipairs(model.targets or {}) do
        if not one.name or one.name == "" then
            table.insert(found, "a target without a name")
        elseif seen[one.name] then
            table.insert(found, string.format("two targets called `%s`", one.name))
        else
            seen[one.name] = true
        end
        if not iskind(one.kind) then
            table.insert(found, string.format("`%s` is a `%s`, which is not a target kind",
                                              tostring(one.name), tostring(one.kind)))
        end
        if #(one.files or {}) == 0 and one.kind ~= "headeronly" and one.kind ~= "phony" then
            table.insert(found, string.format("`%s` has no source file", tostring(one.name)))
        end
    end
    for _, one in ipairs(model.targets or {}) do
        for _, dep in ipairs(one.deps or {}) do
            if not seen[dep] then
                table.insert(found, string.format("`%s` depends on `%s`, which is not a target here",
                                                  one.name, dep))
            end
        end
    end
    return found
end

-- what the model holds, in a few numbers
function summary(model)
    local kinds = {}
    for _, one in ipairs(model.targets or {}) do
        kinds[one.kind] = (kinds[one.kind] or 0) + 1
    end
    local parts = {}
    for _, kind in ipairs({"binary", "static", "shared", "headeronly", "object", "phony"}) do
        if kinds[kind] then
            table.insert(parts, string.format("%d %s", kinds[kind], kind))
        end
    end
    return {
        targets = #(model.targets or {}),
        kinds = table.concat(parts, ", "),
        packages = #(model.packages or {}),
        options = #(model.options or {}),
        unresolved = #(model.unresolved or {}),
        notes = #(model.notes or {})
    }
end
