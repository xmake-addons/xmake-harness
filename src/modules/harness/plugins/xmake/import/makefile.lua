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
-- @file        makefile.lua
--

--
-- read a hand-written `Makefile` into the neutral model
--
-- this is the weakest reader here and says so up front. make is a language with
-- recursive expansion, pattern rules, automatic variables and a shell in every
-- recipe; reading one properly means writing most of make. what this does is
-- read the shape almost every hand-written makefile has:
--
--   CC      = gcc
--   CFLAGS  = -Wall -Iinclude -DDEBUG
--   LDFLAGS = -lm
--   SRCS    = main.c util.c
--   OBJS    = $(SRCS:.c=.o)
--   TARGET  = demo
--
--   $(TARGET): $(OBJS)
--   	$(CC) -o $@ $^ $(LDFLAGS)
--
-- and it is explicit about what it did not read: every recipe line, every
-- pattern rule, every conditional, every `$(shell ..)`, every recursive
-- `$(MAKE) -C`. a converted makefile is a starting point and the notes say so.
--
-- where a project has *anything* else — a `CMakeLists.txt`, an `Android.mk`, a
-- `compile_commands.json` — that is worth reading first, which is why this has
-- the lowest weight of the real readers.
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- the variables which name what is built
local TARGETNAMES = {"TARGET", "TARGETS", "PROG", "PROGRAM", "PROGRAMS", "BIN",
                     "EXE", "NAME", "OUTPUT", "APP", "LIB", "LIBRARY", "SOLIB"}

-- the variables which name what it is built from
local SOURCENAMES = {"SRCS", "SRC", "SOURCES", "CSRCS", "CXXSRCS", "CPPSRCS",
                     "C_SRCS", "CPP_SRCS", "FILES", "OBJS_SRC"}

-- read a project
function read(rootdir, opt)
    opt = opt or {}
    local top = nil
    for _, name in ipairs({"Makefile", "makefile", "GNUmakefile"}) do
        if os.isfile(path.join(rootdir, name)) then
            top = path.join(rootdir, name)
            break
        end
    end
    if not top then
        return nil, string.format("there is no Makefile in %s", rootdir)
    end

    local state = reader.new({from = "makefile", rootdir = rootdir,
                              name = path.filename(path.absolute(rootdir)),
                              maxfiles = opt.maxfiles or 20})
    model.note(state.model, "a makefile is a language and this read only the variables and "
               .. "the rule heads: every recipe, pattern rule and conditional is unread")
    _readfile(state, top)

    if #state.model.targets == 0 then
        return nil, "nothing in the Makefile looked like a target this could read"
    end
    return reader.resolvedeps(state.model)
end

-- read one makefile
function _readfile(state, filepath)
    if not reader.opening(state, filepath) then
        return
    end
    local relative = path.relative(filepath, state.rootdir)
    local prefix = reader.prefixof(state, filepath)
    local where = {file = relative, prefix = prefix, dir = path.directory(filepath)}
    local variables = {}
    local rules = {}
    local content = io.readfile(filepath) or ""

    -- a recipe is a line which starts with a tab, and it belongs to the rule
    -- above it. that is the one piece of make's syntax which is unambiguous
    local pending = nil
    local number = 0
    local joined = {}
    for _, line in ipairs(content:split("\n", {strict = true})) do
        number = number + 1
        if pending then
            local text = pending.text .. " " .. line:gsub("^%s+", "")
            if text:endswith("\\") then
                pending.text = text:sub(1, -2):trim()
            else
                table.insert(joined, {text = text, line = pending.line, recipe = pending.recipe})
                pending = nil
            end
        else
            local recipe = line:startswith("\t")
            local text = line:gsub("^\t", "")
            if not recipe then
                text = _uncomment(text)
            end
            text = text:trim()
            if text:endswith("\\") then
                pending = {text = text:sub(1, -2):trim(), line = number, recipe = recipe}
            elseif text ~= "" then
                table.insert(joined, {text = text, line = number, recipe = recipe})
            end
        end
    end

    for _, entry in ipairs(joined) do
        if entry.recipe then
            _recipe(state, entry, where, rules)
        else
            _line(state, entry, where, variables, rules)
        end
    end
    _targets(state, variables, rules, where)
end

-- take the comment off, minding that `#` inside a variable is not one
function _uncomment(line)
    local pos = line:find("#", 1, true)
    if not pos then
        return line
    end
    -- an escaped one stays
    if pos > 1 and line:sub(pos - 1, pos - 1) == "\\" then
        return line
    end
    return line:sub(1, pos - 1)
end

-- one line which is not a recipe
function _line(state, entry, where, variables, rules)
    local text = entry.text

    -- include other.mk
    local included = text:match("^%-?include%s+(.+)$")
    if included then
        for _, one in ipairs(reader.words(_expand(included, variables))) do
            if not one:find("%$") then
                _readfile(state, path.absolute(one, where.dir))
            end
        end
        return
    end

    -- ifeq / ifdef / else / endif
    if text:match("^if[neqd]") or text == "else" or text == "endif" then
        if not text:match("^end") and text ~= "else" then
            reader.condition(state, {file = where.file, line = entry.line}, text,
                "a make conditional which was not evaluated")
        end
        return
    end

    -- NAME = value, NAME := value, NAME += value, NAME ?= value
    local name, operator, value = text:match("^([%w_%.%-]+)%s*([:%+%?!]?=)%s*(.*)$")
    if name then
        local expanded = _expand(value, variables)
        if operator == "+=" then
            variables[name] = ((variables[name] or "") .. " " .. expanded):trim()
        else
            variables[name] = expanded
        end
        return
    end

    -- a rule head: `target: prerequisites`
    local head, prerequisites = text:match("^([^:=]+):([^=].*)$")
    if not head then
        head, prerequisites = text:match("^([^:=]+):$")
        prerequisites = prerequisites or ""
    end
    if head then
        local names = reader.words(_expand(head, variables))
        for _, one in ipairs(names) do
            if one:find("%%") or one:startswith(".") then
                -- a pattern rule or a special target, which this does not read
                if one:find("%%") then
                    model.note(state.model, "%s has a pattern rule `%s`, which was not read",
                               where.file, text)
                end
            else
                rules[one] = {prerequisites = reader.words(_expand(prerequisites, variables)),
                              line = entry.line, recipes = {}}
                table.insert(rules, one)
            end
        end
    end
end

-- a recipe line, which is a shell command and mostly not readable
function _recipe(state, entry, where, rules)
    local last = rules[#rules]
    if last and rules[last] then
        table.insert(rules[last].recipes, entry.text)
    end

    -- `$(MAKE) -C sub` is a whole other project this did not read
    local subdir = entry.text:match("%$%(MAKE%)%s+%-C%s+([%w_%./%-]+)")
        or entry.text:match("make%s+%-C%s+([%w_%./%-]+)")
    if subdir then
        model.unresolved(state.model, {
            file = where.file, line = entry.line, text = entry.text,
            why = string.format("a recursive make into `%s`, which is another project this "
                                .. "did not read", subdir)
        })
    end
end

-- what the makefile builds
function _targets(state, variables, rules, where)
    local names = {}
    for _, key in ipairs(TARGETNAMES) do
        for _, one in ipairs(reader.words(variables[key] or "")) do
            if not one:find("%$") and not table.contains(names, one) then
                table.insert(names, one)
            end
        end
    end

    -- or the first real rule, which is what `make` with no argument builds
    if #names == 0 then
        for _, one in ipairs(rules) do
            if one ~= "all" and one ~= "clean" and one ~= "install" then
                table.insert(names, one)
                break
            end
        end
        -- `all: demo` names it in its prerequisites
        if #names == 0 and rules["all"] then
            for _, one in ipairs(rules["all"].prerequisites) do
                if rules[one] then
                    table.insert(names, one)
                end
            end
        end
    end

    if #names == 0 then
        return
    end

    local sources = _sources(variables)
    for index, name in ipairs(names) do
        local kind = "binary"
        if name:endswith(".a") then
            kind = "static"
        elseif name:endswith(".so") or name:endswith(".dylib") or name:endswith(".dll") then
            kind = "shared"
        end
        local clean = name:gsub("%.a$", ""):gsub("%.so.*$", ""):gsub("%.dylib$", "")
                          :gsub("%.dll$", ""):gsub("^lib", "")
        local one = model.target(state.model, clean, {kind = kind, from = where.file})

        -- every target of a makefile shares the one set of variables, and
        -- which sources belong to which is not written down anywhere
        if #names > 1 then
            model.unresolved(state.model, {
                file = where.file, target = clean,
                text = table.concat(names, " "),
                why = "the makefile builds several things from one set of variables: which "
                      .. "sources belong to which is not in the file"
            })
        end
        for _, file in ipairs(sources) do
            model.add(one.files, reader.join(state, where.prefix, file))
        end
        _flags(state, one, variables, where)

        if index == 1 and #(one.files or {}) == 0 then
            model.unresolved(state.model, {
                file = where.file, target = clean,
                why = "no source list was found: look for the pattern rule or the wildcard "
                      .. "which supplies them",
                text = "SRCS"
            })
        end
    end
end

-- the sources, from whichever variable holds them
function _sources(variables)
    local out = {}
    for _, key in ipairs(SOURCENAMES) do
        for _, one in ipairs(reader.words(variables[key] or "")) do
            if not one:find("%$") and not table.contains(out, one) then
                table.insert(out, one)
            end
        end
    end

    -- `OBJS = $(SRCS:.c=.o)` is the usual shape and the sources are already
    -- there; `OBJS = a.o b.o` with no SRCS is a list of sources spelt as objects
    if #out == 0 then
        for _, one in ipairs(reader.words(variables.OBJS or variables.OBJECTS or "")) do
            if one:endswith(".o") then
                table.insert(out, (one:gsub("%.o$", ".c")))
            end
        end
    end

    -- `$(wildcard src/*.c)` is a pattern, which is what xmake wants anyway
    for _, key in ipairs(SOURCENAMES) do
        local value = variables[key] or ""
        for pattern in value:gmatch("%$%(wildcard%s+([^%)]+)%)") do
            for _, one in ipairs(reader.words(pattern)) do
                if not table.contains(out, one) then
                    table.insert(out, one)
                end
            end
        end
    end
    return out
end

-- the flags, from the variables everybody uses for them
function _flags(state, one, variables, where)
    for _, key in ipairs({"CPPFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS", "LDLIBS", "LIBS"}) do
        local value = variables[key]
        if value then
            local argv = {}
            for _, word in ipairs(reader.words(value)) do
                if word:find("%$") then
                    reader.unexpanded(state, {file = where.file, target = one.name}, word,
                                      "a make variable in the flags which was not expanded")
                else
                    table.insert(argv, word)
                end
            end
            local rest = reader.flags(state, one, argv, where.prefix)
            for _, flag in ipairs(rest) do
                if key == "CXXFLAGS" then
                    model.add(one.cxxflags, flag)
                elseif key == "CFLAGS" then
                    model.add(one.cflags, flag)
                elseif key == "LDFLAGS" or key == "LDLIBS" or key == "LIBS" then
                    model.add(one.ldflags, flag)
                else
                    model.add(one.cxflags, flag)
                end
            end
        end
    end

    -- the compiler it was written for says which language it is
    local compiler = variables.CXX or variables.CC or ""
    if compiler:find("++") or variables.CXXFLAGS then
        model.add(state.model.languages, "c++")
    elseif compiler ~= "" then
        model.add(state.model.languages, "c")
    end
end

-- expand `$(FOO)` as far as we can follow it
function _expand(value, variables)
    local result = tostring(value or "")
    for _ = 1, 6 do
        local before = result
        result = result:gsub("%$[%(%{]([%w_%.%-]+)[%)%}]", function (name)
            local held = variables[name]
            if held == nil then
                return "$(" .. name .. ")"
            end
            return held
        end)
        if result == before then
            break
        end
    end
    -- `$(SRCS:.c=.o)` is a substitution, and the list it starts from is what
    -- matters here
    result = result:gsub("%$[%(%{]([%w_%.%-]+):[^%)%}]*[%)%}]", function (name)
        return variables[name] or ("$(" .. name .. ")")
    end)
    return result
end
