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
-- @file        cmake.lua
--

--
-- read a cmake project into the neutral model
--
-- cmake is a language, not a data format, and this is not an interpreter: it
-- reads the commands, keeps the variables it can follow, and takes the targets
-- out of the handful of commands which declare them. everything else it writes
-- down as unresolved rather than pretending.
--
-- what it does follow, because almost every project uses it:
--
--   set(FOO a b c)                  a variable, expanded in `${FOO}` afterwards
--   project(demo ...)               the project name and its languages
--   option(WITH_X "why" ON)         a build option
--   add_executable / add_library    a target and its sources
--   target_*(name PUBLIC|PRIVATE ..)  its includes, defines, links, options
--   find_package(zlib REQUIRED)     a dependency to resolve as a package
--   add_subdirectory(sub)           read that one too
--   file(GLOB var pattern)          a source pattern, kept as a pattern
--   if()/else()/endif()             recorded, not evaluated, @see _branch
--
-- what it deliberately does not do is evaluate a condition. `if(WIN32)` is a
-- fact about a platform and `if(BUILD_TESTING)` is a fact about a choice, and
-- guessing which is which produces an `xmake.lua` that builds the wrong thing
-- on somebody else's machine. every branch is recorded with its file and line
-- and the targets it touched, and something which can read the surrounding code
-- decides, @see harness.plugins.xmake.import.model
--

-- imports
import("harness.util.text")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- the commands which declare where the sources of a target are
local SOURCEKEYWORDS = {PUBLIC = true, PRIVATE = true, INTERFACE = true}

-- the extensions we recognise as source rather than header
local SOURCES = {c = true, cc = true, cpp = true, cxx = true, ["c++"] = true,
                 m = true, mm = true, s = true, S = true, asm = true, cu = true,
                 f = true, f90 = true, rs = true, go = true, swift = true, zig = true}

-- read a project
--
-- @param rootdir   the directory which holds the top `CMakeLists.txt`
-- @param opt       {maxfiles = 200}
-- @return          the model, or nil and the reason
--
function read(rootdir, opt)
    opt = opt or {}
    local top = path.join(rootdir, "CMakeLists.txt")
    if not os.isfile(top) then
        return nil, string.format("there is no CMakeLists.txt in %s", rootdir)
    end

    local state = reader.new({from = "cmake", rootdir = rootdir,
                              maxfiles = opt.maxfiles or 200})
    _readfile(state, top)
    state.model.name = state.model.name or path.filename(path.absolute(rootdir))
    return reader.resolvedeps(state.model)
end



-- read one CMakeLists.txt, and whatever it adds
function _readfile(state, filepath)
    if not reader.opening(state, filepath) then
        return
    end

    local content = io.readfile(filepath) or ""
    local commands = parse(content)
    local relative = path.relative(filepath, state.rootdir)

    -- the directory variables cmake sets for every file it reads: without them
    -- `${CMAKE_CURRENT_SOURCE_DIR}/vendor` is an unexpanded variable and a hole
    -- in the model, when it is simply "here"
    local here = path.directory(filepath)
    for _, name in ipairs({"CMAKE_CURRENT_SOURCE_DIR", "CMAKE_CURRENT_LIST_DIR"}) do
        state.variables[name] = {here}
    end
    for _, name in ipairs({"CMAKE_SOURCE_DIR", "PROJECT_SOURCE_DIR", "CMAKE_HOME_DIRECTORY"}) do
        state.variables[name] = {state.rootdir}
    end

    local branch = {}
    for _, command in ipairs(commands) do
        _command(state, command, {file = relative, dir = path.directory(filepath), branch = branch})
    end
end

---------------------------------------------------------------------------------
-- the language
---------------------------------------------------------------------------------

-- split a cmake file into its commands
--
-- a command is `name(argument argument ...)`, an argument is a bare word, a
-- quoted string or a bracket argument, and `#` starts a comment unless it is
-- inside one of those. that is the whole grammar
--
-- @return  {{name = "set", args = {"FOO", "a"}, line = 3, raw = "set(FOO a)"}, ..}
--
function parse(content)
    content = tostring(content or "")
    local commands = {}
    local pos = 1
    local line = 1
    local length = #content

    local function advance(upto)
        for _ in content:sub(pos, upto - 1):gmatch("\n") do
            line = line + 1
        end
        pos = upto
    end

    while pos <= length do
        local ch = content:sub(pos, pos)
        if ch == "#" then
            -- a bracket comment `#[[ .. ]]` or a line one
            local bracket = content:match("^#(%[=*%[)", pos)
            if bracket then
                local close = bracket:gsub("%[", "]")
                local stop = content:find(close, pos + #bracket + 1, true)
                advance(stop and (stop + #close) or (length + 1))
            else
                local stop = content:find("\n", pos, true)
                advance(stop and (stop + 1) or (length + 1))
            end
        elseif ch:match("[%s]") then
            advance(pos + 1)
        elseif ch:match("[%a_]") then
            local name = content:match("^([%w_%.%+%-]+)", pos)
            local after = pos + #name
            local open = content:find("%(", after)
            local between = open and content:sub(after, open - 1) or nil
            if not open or (between and between:trim() ~= "") then
                -- a word which is not a command, e.g. something we do not know
                advance(after)
            else
                local startline = line
                advance(open + 1)
                local args, stop = _arguments(content, pos)
                local raw = string.format("%s(%s)", name, content:sub(pos, stop - 2):trim())
                table.insert(commands, {name = name:lower(), args = args, line = startline,
                                        raw = text.oneline(raw)})
                advance(stop)
            end
        else
            advance(pos + 1)
        end
    end
    return commands
end

-- read the arguments of a command, up to the closing bracket
--
-- @return  the arguments, and where the command ends
--
function _arguments(content, pos)
    local args = {}
    local depth = 1
    local length = #content
    while pos <= length do
        local ch = content:sub(pos, pos)
        if ch == ")" then
            depth = depth - 1
            if depth == 0 then
                return args, pos + 1
            end
            pos = pos + 1
        elseif ch == "(" then
            -- a nested bracket, e.g. `if(NOT (A OR B))`: it is part of the
            -- expression and not a new command
            depth = depth + 1
            pos = pos + 1
        elseif ch == "\"" then
            local value, stop = _quoted(content, pos)
            table.insert(args, value)
            pos = stop
        elseif ch == "#" then
            local stop = content:find("\n", pos, true)
            pos = stop and (stop + 1) or (length + 1)
        elseif ch:match("%s") then
            pos = pos + 1
        else
            local bracket = content:match("^(%[=*%[)", pos)
            if bracket then
                local close = bracket:gsub("%[", "]")
                local stop = content:find(close, pos + #bracket, true)
                table.insert(args, content:sub(pos + #bracket, (stop or length + 1) - 1))
                pos = stop and (stop + #close) or (length + 1)
            else
                local value = content:match("^([^%s%(%)#\"]+)", pos)
                if not value or value == "" then
                    pos = pos + 1
                else
                    table.insert(args, value)
                    pos = pos + #value
                end
            end
        end
    end
    return args, pos
end

-- a quoted argument, with its escapes
function _quoted(content, pos)
    local out = {}
    pos = pos + 1
    local length = #content
    while pos <= length do
        local ch = content:sub(pos, pos)
        if ch == "\\" then
            local next = content:sub(pos + 1, pos + 1)
            if next == "n" then
                table.insert(out, "\n")
            elseif next == "t" then
                table.insert(out, "\t")
            else
                table.insert(out, next)
            end
            pos = pos + 2
        elseif ch == "\"" then
            return table.concat(out), pos + 1
        else
            table.insert(out, ch)
            pos = pos + 1
        end
    end
    return table.concat(out), pos
end

---------------------------------------------------------------------------------
-- the variables
---------------------------------------------------------------------------------

-- expand `${FOO}` and `$ENV{FOO}` as far as we can follow them
--
-- what cannot be expanded is left as it was written: a value which still has a
-- `${` in it is a value somebody has to look at, and silently dropping it would
-- turn `${SRC}` into an empty file list and a target which builds nothing
--
function expand(state, str)
    if type(str) ~= "string" or not str:find("$", 1, true) then
        return str
    end
    local result = str
    for _ = 1, 8 do
        local before = result
        result = result:gsub("%${([%w_%.%-]+)}", function (name)
            local value = state.variables[name]
            if value == nil then
                return "${" .. name .. "}"
            end
            return type(value) == "table" and table.concat(value, ";") or tostring(value)
        end)
        if result == before then
            break
        end
    end
    return result
end

-- expand a list of arguments, and split the ones which came back as a list
function _expandall(state, args)
    local out = {}
    for _, arg in ipairs(args) do
        local value = expand(state, arg)
        if type(value) == "string" and value:find(";", 1, true) then
            for _, one in ipairs(value:split(";", {plain = true})) do
                if one ~= "" then
                    table.insert(out, one)
                end
            end
        elseif value ~= "" then
            table.insert(out, value)
        end
    end
    return out
end

-- is this still holding something we could not expand?
function _unexpanded(value)
    return type(value) == "string" and value:find("${", 1, true) ~= nil
end

---------------------------------------------------------------------------------
-- the commands
---------------------------------------------------------------------------------

-- act on one command
function _command(state, command, where)
    local handler = HANDLERS[command.name]
    if handler then
        handler(state, command, where)
    end
end

-- the branch a command sits in, as a sentence, or nil at the top level
function _branch(where)
    if #where.branch == 0 then
        return nil
    end
    return table.concat(where.branch, " and ")
end

-- record a target as having been declared inside a condition
function _conditional(state, one, command, where)
    local branch = _branch(where)
    if not branch then
        return
    end
    model.add(one.conditions, branch)
    model.unresolved(state.model, {
        file = where.file, line = command.line, text = branch, target = one.name,
        why = "the target is declared inside a condition which was not evaluated"
    })
end

HANDLERS = {}

-- project(name [LANGUAGES C CXX])
HANDLERS["project"] = function (state, command, where)
    local args = _expandall(state, command.args)
    if args[1] and not state.model.name then
        state.model.name = args[1]
    end
    local languages = false
    for _, arg in ipairs(args) do
        if arg == "LANGUAGES" then
            languages = true
        elseif languages then
            local name = ({C = "c", CXX = "c++", OBJC = "objc", OBJCXX = "objc++",
                           CUDA = "cuda", Fortran = "fortran", ASM = "asm"})[arg]
            if name then
                model.add(state.model.languages, name)
            end
        end
    end
end

-- set(NAME value ...) and set(NAME value CACHE TYPE "docs")
HANDLERS["set"] = function (state, command, where)
    local args = command.args
    if #args == 0 then
        return
    end
    local name = expand(state, args[1])
    local values = {}
    for idx = 2, #args do
        local arg = args[idx]
        if arg == "CACHE" or arg == "PARENT_SCOPE" or arg == "FORCE" then
            break
        end
        table.insert(values, expand(state, arg))
    end
    state.variables[name] = values
end

HANDLERS["unset"] = function (state, command)
    local name = expand(state, command.args[1] or "")
    state.variables[name] = nil
end

-- list(APPEND NAME value ...)
HANDLERS["list"] = function (state, command)
    local args = command.args
    local action = (args[1] or ""):upper()
    local name = expand(state, args[2] or "")
    if action ~= "APPEND" or name == "" then
        return
    end
    local values = state.variables[name] or {}
    for idx = 3, #args do
        table.insert(values, expand(state, args[idx]))
    end
    state.variables[name] = values
end

-- option(NAME "what it is" ON)
HANDLERS["option"] = function (state, command, where)
    local args = _expandall(state, command.args)
    if not args[1] then
        return
    end
    local default = (args[3] or "OFF"):upper()
    table.insert(state.model.options, {
        name = args[1],
        description = args[2],
        default = default == "ON" or default == "TRUE" or default == "1",
        file = where.file,
        line = command.line
    })
    state.variables[args[1]] = {args[3] or "OFF"}
end

-- add_executable(name [WIN32] [MACOSX_BUNDLE] sources...)
HANDLERS["add_executable"] = function (state, command, where)
    local args = _expandall(state, command.args)
    local name = args[1]
    if not name then
        return
    end
    -- add_executable(name ALIAS other)
    if (args[2] or ""):upper() == "ALIAS" then
        model.note(state.model, "`%s` is an alias of `%s`", name, tostring(args[3]))
        return
    end
    local one = model.target(state.model, name, {kind = "binary", from = where.file})
    _sources(state, one, args, 2, command, where)
    _conditional(state, one, command, where)
end

-- add_library(name [STATIC|SHARED|MODULE|INTERFACE|OBJECT] sources...)
HANDLERS["add_library"] = function (state, command, where)
    local args = _expandall(state, command.args)
    local name = args[1]
    if not name then
        return
    end
    if (args[2] or ""):upper() == "ALIAS" then
        model.note(state.model, "`%s` is an alias of `%s`", name, tostring(args[3]))
        return
    end
    local kinds = {STATIC = "static", SHARED = "shared", MODULE = "shared",
                   INTERFACE = "headeronly", OBJECT = "object"}
    local start = 2
    local kind = kinds[(args[2] or ""):upper()]
    if kind then
        start = 3
    else
        -- a library with no kind follows BUILD_SHARED_LIBS, which is a choice
        -- and not a fact: static is the usual answer and it is written down
        kind = "static"
        model.note(state.model, "`%s` has no explicit kind: it follows BUILD_SHARED_LIBS, "
                   .. "and is read as static here", name)
    end
    local one = model.target(state.model, name, {kind = kind, from = where.file})
    _sources(state, one, args, start, command, where)
    _conditional(state, one, command, where)
end

-- the sources of a target, from the arguments after its name and kind
function _sources(state, one, args, start, command, where)
    local prefix = path.relative(where.dir, state.rootdir)
    for idx = start, #args do
        local arg = args[idx]
        if arg == "EXCLUDE_FROM_ALL" or SOURCEKEYWORDS[arg] then
            -- a keyword, not a file
        elseif _unexpanded(arg) then
            model.unresolved(state.model, {
                file = where.file, line = command.line, text = arg, target = one.name,
                why = "a variable which could not be expanded, so this source is unknown"
            })
        else
            local file = reader.join(state, prefix, arg)
            local extension = path.extension(file):sub(2):lower()
            if SOURCES[extension] or file:find("*", 1, true) then
                model.add(one.files, file)
            elseif extension ~= "" then
                model.add(one.headerdirs, path.directory(file))
            else
                model.add(one.files, file)
            end
        end
    end
end



-- target_include_directories / target_compile_definitions / ...
function _targetlists(field, transform)
    return function (state, command, where)
        local args = _expandall(state, command.args)
        local name = args[1]
        if not name then
            return
        end
        -- inside a condition the values are still taken, because dropping them
        -- would lose them altogether — but they are marked, so that what looks
        -- like a fact about the target can be told from what is one
        local branch = _branch(where)
        local one = model.get(state.model, name)
        if not one then
            model.unresolved(state.model, {
                file = where.file, line = command.line, text = command.raw,
                why = string.format("it configures `%s`, which is not declared here", name)
            })
            return
        end
        local prefix = path.relative(where.dir, state.rootdir)
        for idx = 2, #args do
            local arg = args[idx]
            if not SOURCEKEYWORDS[arg] and arg ~= "SYSTEM" and arg ~= "BEFORE" then
                if _unexpanded(arg) then
                    model.unresolved(state.model, {
                        file = where.file, line = command.line, text = arg, target = name,
                        why = "a variable which could not be expanded"
                    })
                else
                    transform(state, one, arg, prefix, command, where)
                    if branch then
                        model.add(one.conditions, branch)
                        model.unresolved(state.model, {
                            file = where.file, line = command.line, target = name,
                            text = string.format("%s (%s)", arg, branch),
                            why = "it is only set when the condition holds, and it was taken as if it always does"
                        })
                    end
                end
            end
        end
    end
end

HANDLERS["target_include_directories"] = _targetlists("includedirs",
    function (state, one, arg, prefix)
        -- the generator expressions are a build-time thing and there is nothing
        -- to do with them here beyond keeping the path out of them
        local value = arg:match("^%$<BUILD_INTERFACE:(.+)>$") or arg
        if not value:find("$<", 1, true) then
            model.add(one.includedirs, reader.join(state, prefix, value))
        end
    end)

HANDLERS["target_compile_definitions"] = _targetlists("defines",
    function (state, one, arg)
        if not arg:find("$<", 1, true) then
            model.add(one.defines, (arg:gsub("^%-D", "")))
        end
    end)

HANDLERS["target_link_libraries"] = _targetlists("links",
    function (state, one, arg)
        if arg:find("$<", 1, true) then
            return
        end
        -- a name which is another target here is a dependency, and anything
        -- else is a library to link against
        if model.get(state.model, arg) then
            model.add(one.deps, arg)
        elseif arg:find("::", 1, true) then
            -- an imported target, e.g. `ZLIB::ZLIB`: it is a package
            model.add(one.packages, (arg:gsub("::.*$", ""):lower()))
        elseif arg:startswith("-") then
            model.add(one.ldflags, arg)
        else
            model.add(one.links, arg)
        end
    end)

HANDLERS["target_compile_options"] = _targetlists("cxflags",
    function (state, one, arg)
        if not arg:find("$<", 1, true) then
            model.add(one.cxflags, arg)
        end
    end)

HANDLERS["target_link_directories"] = _targetlists("linkdirs",
    function (state, one, arg, prefix)
        model.add(one.linkdirs, reader.join(state, prefix, arg))
    end)

HANDLERS["target_sources"] = _targetlists("files",
    function (state, one, arg, prefix)
        model.add(one.files, reader.join(state, prefix, arg))
    end)

-- target_compile_features(name PUBLIC cxx_std_17)
HANDLERS["target_compile_features"] = _targetlists("languages",
    function (state, one, arg)
        local standard = arg:match("^cxx_std_(%d+)$")
        if standard then
            model.add(one.languages, "c++" .. standard)
            return
        end
        standard = arg:match("^c_std_(%d+)$")
        if standard then
            model.add(one.languages, "c" .. standard)
        end
    end)

-- find_package(zlib REQUIRED COMPONENTS ..)
HANDLERS["find_package"] = function (state, command, where)
    local args = _expandall(state, command.args)
    local name = args[1]
    if not name then
        return
    end
    local required = false
    for _, arg in ipairs(args) do
        if arg == "REQUIRED" then
            required = true
        end
    end
    for _, one in ipairs(state.model.packages) do
        if one.name == name:lower() then
            return
        end
    end
    table.insert(state.model.packages, {
        name = name:lower(),
        origin = name,
        required = required,
        file = where.file,
        line = command.line
    })
end

HANDLERS["pkg_check_modules"] = function (state, command, where)
    local args = _expandall(state, command.args)
    for idx = 2, #args do
        local arg = args[idx]
        if arg ~= "REQUIRED" and arg ~= "QUIET" and arg ~= "IMPORTED_TARGET" then
            table.insert(state.model.packages, {name = arg:lower(), origin = arg,
                                                required = true, file = where.file,
                                                line = command.line})
        end
    end
end

-- add_subdirectory(sub)
HANDLERS["add_subdirectory"] = function (state, command, where)
    local args = _expandall(state, command.args)
    if not args[1] or _unexpanded(args[1]) then
        return
    end
    _readfile(state, path.join(where.dir, args[1], "CMakeLists.txt"))
end

-- include_directories / add_definitions apply to everything after them, which
-- is a scope this reader does not model: they are recorded for whoever does
HANDLERS["include_directories"] = function (state, command, where)
    local args = _expandall(state, command.args)
    local prefix = path.relative(where.dir, state.rootdir)
    for _, arg in ipairs(args) do
        if arg ~= "SYSTEM" and arg ~= "BEFORE" and arg ~= "AFTER" and not _unexpanded(arg) then
            model.add(state.model.includedirs or {}, arg)
            state.model.includedirs = state.model.includedirs or {}
            model.add(state.model.includedirs, reader.join(state, prefix, arg))
        end
    end
end

HANDLERS["add_definitions"] = function (state, command, where)
    local args = _expandall(state, command.args)
    state.model.defines = state.model.defines or {}
    for _, arg in ipairs(args) do
        if arg:startswith("-D") then
            model.add(state.model.defines, arg:sub(3))
        end
    end
end

-- file(GLOB var pattern) — the pattern is kept as a pattern, which is what
-- xmake wants anyway: `add_files("src/*.c")` is the same idea written once
HANDLERS["file"] = function (state, command, where)
    local args = _expandall(state, command.args)
    local action = (args[1] or ""):upper()
    if action ~= "GLOB" and action ~= "GLOB_RECURSE" then
        return
    end
    local name = args[2]
    if not name then
        return
    end
    local patterns = {}
    local prefix = path.relative(where.dir, state.rootdir)
    for idx = 3, #args do
        local arg = args[idx]
        if arg ~= "CONFIGURE_DEPENDS" and arg ~= "LIST_DIRECTORIES" and arg ~= "true"
           and arg ~= "false" and arg ~= "RELATIVE" then
            local pattern = reader.join(state, prefix, arg)
            if action == "GLOB_RECURSE" and not pattern:find("**", 1, true) then
                pattern = pattern:gsub("/%*", "/**")
            end
            table.insert(patterns, pattern)
        end
    end
    state.variables[name] = patterns
    if action == "GLOB_RECURSE" then
        model.note(state.model, "`%s` is a recursive glob, written as `**` in xmake", name)
    end
end

-- the conditions, recorded and not evaluated
HANDLERS["if"] = function (state, command, where)
    local condition = table.concat(command.args, " ")
    table.insert(where.branch, condition)
    model.unresolved(state.model, {
        file = where.file, line = command.line, text = condition,
        why = "a condition which was not evaluated: what it guards may or may not apply"
    })
end

HANDLERS["elseif"] = function (state, command, where)
    if #where.branch > 0 then
        where.branch[#where.branch] = table.concat(command.args, " ")
    end
end

HANDLERS["else"] = function (state, command, where)
    if #where.branch > 0 then
        where.branch[#where.branch] = "not (" .. where.branch[#where.branch] .. ")"
    end
end

HANDLERS["endif"] = function (state, command, where)
    table.remove(where.branch)
end

-- the ones which are worth knowing about but have no place in the model yet
for _, name in ipairs({"add_custom_command", "add_custom_target", "install",
                       "configure_file", "add_test", "include", "macro", "function",
                       "foreach", "while", "execute_process"}) do
    HANDLERS[name] = function (state, command, where)
        model.unresolved(state.model, {
            file = where.file, line = command.line, text = command.raw,
            why = string.format("`%s` has no direct equivalent and was not converted", name)
        })
    end
end
