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
-- @file        autotools.lua
--

--
-- read an autotools project into the neutral model
--
-- a `Makefile.am` is the most readable of these formats and by some distance:
-- it is a list of variables whose names carry their meaning.
--
--   bin_PROGRAMS      = foo          the binaries it installs
--   lib_LTLIBRARIES   = libbar.la    the libraries
--   noinst_LIBRARIES  = libaux.a     the ones it does not install
--   foo_SOURCES       = a.c b.c      whose sources these are
--   foo_CPPFLAGS      = -Iinclude    and whose flags
--   foo_LDADD         = libbar.la -lz
--   SUBDIRS           = src tests
--
-- the prefix before the underscore says where it is installed and the suffix
-- says what it is, so `bin_PROGRAMS` and `noinst_PROGRAMS` are both binaries
-- and only one of them is installed. `_LTLIBRARIES` is libtool's, which builds
-- both a static and a shared library from one declaration — that is a decision
-- and it is written down rather than guessed.
--
-- `configure.ac` is read for what it says about dependencies:
-- `AC_CHECK_LIB`, `PKG_CHECK_MODULES` and `AC_INIT` are the useful three. the
-- rest of it is m4 and this does not pretend to expand it.
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- the primary suffixes, and what they build
local PRIMARIES = {
    PROGRAMS = "binary",
    LIBRARIES = "static",
    LTLIBRARIES = "libtool",
    SCRIPTS = nil,
    DATA = nil,
    HEADERS = nil,
    JAVA = nil,
    PYTHON = nil,
    MANS = nil
}

-- read a project
function read(rootdir, opt)
    opt = opt or {}
    local top = nil
    for _, name in ipairs({"Makefile.am", "GNUmakefile.am"}) do
        if os.isfile(path.join(rootdir, name)) then
            top = path.join(rootdir, name)
            break
        end
    end
    if not top then
        return nil, string.format("there is no Makefile.am in %s", rootdir)
    end

    local state = reader.new({from = "autotools", rootdir = rootdir,
                              maxfiles = opt.maxfiles or 120})
    _configure(state, rootdir)
    _readfile(state, top)
    state.model.name = state.model.name or path.filename(path.absolute(rootdir))
    return reader.resolvedeps(state.model)
end

---------------------------------------------------------------------------------
-- configure.ac
---------------------------------------------------------------------------------

-- what `configure.ac` says about the project and what it needs
function _configure(state, rootdir)
    local filepath = nil
    for _, name in ipairs({"configure.ac", "configure.in"}) do
        if os.isfile(path.join(rootdir, name)) then
            filepath = path.join(rootdir, name)
            break
        end
    end
    if not filepath then
        return
    end
    reader.opening(state, filepath)
    local relative = path.relative(filepath, state.rootdir)

    for _, entry in ipairs(reader.lines(filepath, {comment = "dnl"})) do
        local text = entry.text
        local where = {file = relative, line = entry.line}

        -- AC_INIT([name], [version])
        local name = text:match("^AC_INIT%s*%(%s*%[?([^%],)]+)")
        if name then
            state.model.name = state.model.name or name:trim()
        end

        -- AC_CHECK_LIB([z], [deflate])
        local library = text:match("^AC_CHECK_LIB%s*%(%s*%[?([%w_%-%.%+]+)")
        if library then
            _package(state, library, where, "AC_CHECK_LIB")
        end

        -- PKG_CHECK_MODULES([DEPS], [glib-2.0 >= 2.0 gtk+-3.0])
        local modules = text:match("^PKG_CHECK_MODULES%s*%([^,]*,%s*%[?([^%]),]+)")
        if modules then
            -- `glib-2.0 >= 2.40 gtk+-3.0` is two packages and one constraint:
            -- the word after a comparison is the version and not a third
            local pieces = reader.words(modules)
            local idx = 1
            while idx <= #pieces do
                local one = pieces[idx]
                if one:match("^[<>=!]+$") then
                    idx = idx + 1
                elseif one:match("^[<>=!]") then
                    -- `>=2.40`, all one word
                else
                    local pkg = one:match("^([%w_%-%.%+]+)")
                    if pkg then
                        _package(state, pkg, where, "PKG_CHECK_MODULES")
                    end
                end
                idx = idx + 1
            end
        end

        -- the language it configures
        if text:find("AC_PROG_CXX", 1, true) then
            model.add(state.model.languages, "c++")
        elseif text:find("AC_PROG_CC", 1, true) then
            model.add(state.model.languages, "c")
        end

        -- AC_ARG_ENABLE / AC_ARG_WITH are the project's options
        local option = text:match("^AC_ARG_ENABLE%s*%(%s*%[?([%w_%-]+)")
            or text:match("^AC_ARG_WITH%s*%(%s*%[?([%w_%-]+)")
        if option then
            table.insert(state.model.options, {
                name = option, description = nil, default = false,
                file = relative, line = entry.line
            })
            reader.condition(state, where, text,
                "an autoconf option: what it switches on is decided in the m4 this did not read")
        end
    end
end

-- a package the project checks for
function _package(state, name, where, how)
    name = name:lower()
    for _, one in ipairs(state.model.packages) do
        if one.name == name then
            return
        end
    end
    table.insert(state.model.packages, {
        name = name, origin = name, required = true,
        file = where.file, line = where.line, how = how
    })
end

---------------------------------------------------------------------------------
-- Makefile.am
---------------------------------------------------------------------------------

-- read one `Makefile.am`, and the subdirectories it names
function _readfile(state, filepath)
    if not reader.opening(state, filepath) then
        return
    end
    local relative = path.relative(filepath, state.rootdir)
    local prefix = reader.prefixof(state, filepath)
    local variables = {}

    for _, entry in ipairs(reader.lines(filepath)) do
        local name, operator, value = entry.text:match("^([%w_%.]+)%s*([%+]?=)%s*(.*)$")
        if name then
            local values = _values(state, variables, value, path.directory(filepath))
            if operator == "+=" then
                variables[name] = table.join(variables[name] or {}, values)
            else
                variables[name] = values
            end
            variables[name .. "@line"] = entry.line
        end
    end

    _targets(state, variables, {file = relative, prefix = prefix,
                                dir = path.directory(filepath)})

    for _, subdir in ipairs(variables.SUBDIRS or {}) do
        if subdir ~= "." and not subdir:startswith("$") then
            _readfile(state, path.join(path.directory(filepath), subdir, "Makefile.am"))
        end
    end
end

-- the make variables automake defines, which every project uses
--
-- `$(top_srcdir)` is the top of the project and `$(srcdir)` is the directory of
-- the file being read. leaving them unexpanded turns `-I$(top_srcdir)/include`
-- into an include directory called `$(top_srcdir)/include`, which is not one
--
-- they expand to real directories and `reader.join` turns an absolute path
-- inside the project back into a relative one, so the two meet without either
-- of them knowing about automake
local ROOTS = {top_srcdir = true, top_builddir = true, abs_top_srcdir = true,
               abs_top_builddir = true}
local HERE = {srcdir = true, builddir = true, abs_srcdir = true, abs_builddir = true}

-- the values of an assignment, with `$(FOO)` followed where we can
function _values(state, variables, value, here)
    local out = {}
    for _, one in ipairs(reader.words(value)) do
        local name = one:match("^%$[%(%{]([%w_]+)[%)%}]$")
        if name and variables[name] then
            for _, item in ipairs(variables[name]) do
                table.insert(out, item)
            end
        else
            table.insert(out, expand(state, one, here))
        end
    end
    return out
end

-- expand the directory variables inside a word
--
-- @param here  the directory of the file being read
--
function expand(state, one, here)
    return (tostring(one or ""):gsub("%$[%(%{]([%w_]+)[%)%}]", function (name)
        if ROOTS[name] then
            return state.rootdir
        end
        if HERE[name] then
            return here or state.rootdir
        end
        return "$(" .. name .. ")"
    end):gsub("//+", "/"))
end

-- the targets a `Makefile.am` declares
function _targets(state, variables, where)
    for name, values in pairs(variables) do
        local prefix, primary = name:match("^([%w_]+)_(%u+)$")
        if primary and PRIMARIES[primary] ~= nil and type(values) == "table" then
            for _, one in ipairs(values) do
                _target(state, variables, one, primary, prefix, where)
            end
        end
    end
end

-- one of them
function _target(state, variables, filename, primary, installprefix, where)
    if filename:startswith("$") then
        reader.unexpanded(state, where, filename,
                          "a make variable naming a target, which was not expanded")
        return
    end

    -- `libfoo.la` is the target `libfoo`, and its variables are `libfoo_la_*`
    local name = filename:gsub("%.la$", ""):gsub("%.a$", ""):gsub("%$%(EXEEXT%)$", "")
    local stem = filename:gsub("[%.%-%+/]", "_")
    local kind = PRIMARIES[primary]

    if kind == "libtool" then
        -- libtool builds a static and a shared library from one declaration,
        -- and which one the project actually ships is a decision
        kind = "shared"
        model.note(state.model, "`%s` is a libtool library: it builds a static and a "
                   .. "shared one from the same declaration, and this reads it as shared",
                   name)
    end
    if not kind then
        return
    end

    local one = model.target(state.model, name, {kind = kind, from = where.file})
    one.installed = not installprefix:startswith("noinst")
    if installprefix == "check" then
        one.installed = false
        model.note(state.model, "`%s` is a check_ target: it is built for the test suite",
                   name)
    end

    local sources = variables[stem .. "_SOURCES"]
    if sources then
        for _, file in ipairs(sources) do
            if file:startswith("$") then
                reader.unexpanded(state, {file = where.file, target = name}, file,
                                  "a make variable in _SOURCES, so these sources are unknown")
            else
                model.add(one.files, reader.join(state, where.prefix, file))
            end
        end
    else
        -- automake defaults the sources to the target name plus the language
        -- suffix, which is a real project shape and not an omission
        model.note(state.model, "`%s` has no _SOURCES: automake defaults it to `%s.c`",
                   name, name)
        model.add(one.files, reader.join(state, where.prefix, name .. ".c"))
    end

    _flags(state, one, variables, stem, where)
    _link(state, one, variables, stem, where)

    -- the headers this target installs
    for _, key in ipairs({"include_HEADERS", "nobase_include_HEADERS", "pkginclude_HEADERS"}) do
        for _, file in ipairs(variables[key] or {}) do
            model.add(one.headerdirs, path.directory(reader.join(state, where.prefix, file)))
        end
    end
end

-- the compiler flags of one target, and the ones which apply to all of them
function _flags(state, one, variables, stem, where)
    for _, key in ipairs({"AM_CPPFLAGS", "AM_CFLAGS", "AM_CXXFLAGS",
                          stem .. "_CPPFLAGS", stem .. "_CFLAGS", stem .. "_CXXFLAGS"}) do
        local values = variables[key]
        if values then
            local expanded = {}
            for _, flag in ipairs(values) do
                table.insert(expanded, expand(state, flag, path.join(state.rootdir, where.prefix)))
            end
            local rest = reader.flags(state, one, expanded, where.prefix)
            for _, flag in ipairs(rest) do
                if flag:startswith("$") then
                    reader.unexpanded(state, {file = where.file, target = one.name}, flag,
                        "a make variable in the flags, usually a PKG_CHECK_MODULES result")
                elseif key:endswith("CXXFLAGS") then
                    model.add(one.cxxflags, flag)
                elseif key:endswith("CFLAGS") then
                    model.add(one.cflags, flag)
                else
                    model.add(one.cxflags, flag)
                end
            end
        end
    end
end

-- what it links against
function _link(state, one, variables, stem, where)
    for _, key in ipairs({stem .. "_LDADD", stem .. "_LIBADD", "LDADD",
                          stem .. "_LDFLAGS", "AM_LDFLAGS"}) do
        for _, value in ipairs(variables[key] or {}) do
            if value:startswith("$") then
                reader.unexpanded(state, {file = where.file, target = one.name}, value,
                    "a make variable in the link line, usually a PKG_CHECK_MODULES result")
            elseif value:endswith(".la") or value:endswith(".a") then
                -- another target of this project, named by the file it produces:
                -- `libaux.a` is the target `libaux`, which is how `_target`
                -- named it, so the two meet in `reader.resolvedeps`
                model.add(one.links, path.basename(value))
            else
                reader.flags(state, one, {value}, where.prefix)
            end
        end
    end
end
