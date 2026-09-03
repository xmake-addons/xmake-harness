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
-- @file        qmake.lua
--

--
-- read a qmake project into the neutral model
--
-- a `.pro` is a list of variables and that is nearly all of it:
--
--   TEMPLATE = app            what it builds
--   TARGET   = demo           what it is called
--   SOURCES += a.cpp b.cpp    with `\` continuing a line
--   QT      += core widgets   which qt modules
--   CONFIG  += c++17 staticlib
--   LIBS    += -L../lib -lz
--
-- so the reading is honest and short. what it does not do is evaluate the
-- scopes — `win32 { .. }` and `unix:!macx { .. }` are conditions, and which of
-- them applies is a decision like every other condition, @see the cmake reader.
--
-- the qt modules are the interesting part: `QT += core widgets` is not a list
-- of libraries to link, it is xmake's `add_rules("qt.widgetapp")` and its
-- `add_frameworks`. the mapping is stated here and the choice of rule — a
-- widget app, a quick app, a plain console program — is left where it belongs.
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- what a TEMPLATE builds
local TEMPLATES = {app = "binary", lib = "static", subdirs = "phony",
                   aux = "phony"}

-- the CONFIG values which say something about the kind
local CONFIGKINDS = {staticlib = "static", dll = "shared", shared = "shared",
                     plugin = "shared", console = "binary"}

-- the qt modules, as xmake names its frameworks
local QTMODULES = {
    core = "QtCore", gui = "QtGui", widgets = "QtWidgets", network = "QtNetwork",
    sql = "QtSql", xml = "QtXml", quick = "QtQuick", qml = "QtQml",
    concurrent = "QtConcurrent", test = "QtTest", opengl = "QtOpenGL",
    printsupport = "QtPrintSupport", svg = "QtSvg", charts = "QtCharts",
    multimedia = "QtMultimedia", webengine = "QtWebEngine",
    webenginewidgets = "QtWebEngineWidgets", dbus = "QtDBus"
}

-- read a project
--
-- @param rootdir   the directory which holds the `.pro`
-- @param opt       {file = "demo.pro"}
--
function read(rootdir, opt)
    opt = opt or {}
    local top = opt.file and path.absolute(opt.file, rootdir) or _find(rootdir)
    if not top then
        return nil, string.format("there is no .pro file in %s", rootdir)
    end

    local state = reader.new({from = "qmake", rootdir = rootdir,
                              name = path.basename(top), maxfiles = opt.maxfiles or 60})
    _readfile(state, top)
    return reader.resolvedeps(state.model)
end

-- the `.pro` of a directory, preferring one named after it
function _find(rootdir)
    local files = os.files(path.join(rootdir, "*.pro"))
    if #files == 0 then
        return nil
    end
    table.sort(files)
    local wanted = path.filename(path.absolute(rootdir)) .. ".pro"
    for _, filepath in ipairs(files) do
        if path.filename(filepath) == wanted then
            return filepath
        end
    end
    return files[1]
end

-- read one `.pro`, and whatever it includes
function _readfile(state, filepath, into)
    if not reader.opening(state, filepath) then
        return
    end
    local relative = path.relative(filepath, state.rootdir)
    local prefix = reader.prefixof(state, filepath)
    local variables = {}
    local scopes = {}

    for _, entry in ipairs(reader.lines(filepath)) do
        _statement(state, entry, {file = relative, prefix = prefix,
                                  dir = path.directory(filepath),
                                  variables = variables, scopes = scopes})
    end
    _target(state, variables, {file = relative, prefix = prefix})
end

-- one statement
function _statement(state, entry, where)
    local text = entry.text

    -- a scope: `win32 { .. }`, `unix:!macx {`, `CONFIG(debug, debug|release) {`
    local condition = text:match("^(.-)%s*{%s*$")
    if condition and condition ~= "" then
        table.insert(where.scopes, condition)
        model.unresolved(state.model, {
            file = where.file, line = entry.line, text = condition,
            why = "a qmake scope which was not evaluated: what it guards may or may not apply"
        })
        return
    end
    if text == "}" then
        table.remove(where.scopes)
        return
    end

    -- a one-line scope: `win32: LIBS += -lws2_32`
    local scope, rest = text:match("^([%w_!:%(%)|%s]-):%s*(%u[%u%d_]+%s*[%+%-%*]?=.*)$")
    if scope and rest and not scope:find("=", 1, true) then
        model.unresolved(state.model, {
            file = where.file, line = entry.line, text = text,
            why = "a qmake scope which was not evaluated"
        })
        text = rest
    end

    -- include(other.pri) / SUBDIRS
    local included = text:match("^include%s*%(%s*(.-)%s*%)$")
    if included then
        _readfile(state, path.absolute(included, where.dir))
        return
    end

    local name, operator, value = text:match("^([%u][%u%d_]*)%s*([%+%-%*]?=)%s*(.*)$")
    if not name then
        return
    end
    _assign(state, where, name, operator, value, entry)
end

-- a variable assignment
function _assign(state, where, name, operator, value, entry)
    local values = reader.words(value)
    local variables = where.variables
    if operator == "=" then
        variables[name] = values
    elseif operator == "+=" then
        variables[name] = table.join(variables[name] or {}, values)
    elseif operator == "-=" then
        local kept = {}
        for _, one in ipairs(variables[name] or {}) do
            if not table.contains(values, one) then
                table.insert(kept, one)
            end
        end
        variables[name] = kept
    end

    -- SUBDIRS is a project of projects
    if name == "SUBDIRS" then
        for _, one in ipairs(values) do
            local subdir = path.absolute(one, where.dir)
            if os.isdir(subdir) then
                local found = _find(subdir)
                if found then
                    _readfile(state, found)
                end
            elseif os.isfile(subdir .. ".pro") then
                _readfile(state, subdir .. ".pro")
            end
        end
    end
end

-- the target this file described
function _target(state, variables, where)
    local sources = variables.SOURCES or {}
    local headers = variables.HEADERS or {}
    local template = (variables.TEMPLATE or {})[1] or "app"
    if template == "subdirs" then
        return
    end
    if #sources == 0 and #headers == 0 then
        return
    end

    local name = (variables.TARGET or {})[1]
        or path.basename(path.filename(where.file))
    local kind = TEMPLATES[template] or "binary"
    local config = variables.CONFIG or {}
    for _, one in ipairs(config) do
        local said = CONFIGKINDS[one:lower()]
        if said and template == "lib" then
            kind = said
        elseif said == "binary" and template == "app" then
            kind = "binary"
        end
    end
    -- a `lib` with neither staticlib nor dll follows qmake's default, which is
    -- a shared library on unix and a static one nowhere in particular
    if template == "lib" and not _saidkind(config) then
        model.note(state.model, "`%s` is a TEMPLATE=lib with no staticlib/dll: "
                   .. "qmake builds a shared library by default", name)
        kind = "shared"
    end

    local one = model.target(state.model, name, {kind = kind, from = where.file})
    for _, file in ipairs(sources) do
        model.add(one.files, reader.join(state, where.prefix, file))
    end
    for _, file in ipairs(headers) do
        model.add(one.headerdirs, path.directory(reader.join(state, where.prefix, file)))
    end
    for _, dir in ipairs(variables.INCLUDEPATH or {}) do
        model.add(one.includedirs, reader.join(state, where.prefix, dir))
    end
    for _, define in ipairs(variables.DEFINES or {}) do
        model.add(one.defines, define)
    end
    for _, dir in ipairs(variables.DEPENDPATH or {}) do
        model.add(one.includedirs, reader.join(state, where.prefix, dir))
    end
    _libs(state, one, variables.LIBS or {}, where)
    _config(state, one, config, where)
    _qt(state, one, variables.QT or {}, template, config, where)

    for _, flag in ipairs(variables.QMAKE_CXXFLAGS or {}) do
        model.add(one.cxxflags, flag)
    end
    for _, flag in ipairs(variables.QMAKE_CFLAGS or {}) do
        model.add(one.cflags, flag)
    end
    for _, flag in ipairs(variables.QMAKE_LFLAGS or {}) do
        model.add(one.ldflags, flag)
    end

    -- the forms and the resources are qt's own build steps
    if #(variables.FORMS or {}) > 0 or #(variables.RESOURCES or {}) > 0 then
        model.unresolved(state.model, {
            file = where.file, target = name,
            text = string.format("FORMS=%d RESOURCES=%d", #(variables.FORMS or {}),
                                 #(variables.RESOURCES or {})),
            why = "the .ui and .qrc files are handled by the qt rules: add them to add_files"
        })
        for _, file in ipairs(table.join(variables.FORMS or {}, variables.RESOURCES or {})) do
            model.add(one.files, reader.join(state, where.prefix, file))
        end
    end
end

-- did CONFIG say which kind of library it is?
function _saidkind(config)
    for _, one in ipairs(config) do
        local said = one:lower()
        if said == "staticlib" or said == "dll" or said == "shared" or said == "plugin" then
            return true
        end
    end
    return false
end

-- LIBS += -L../lib -lz /abs/path/libfoo.a
function _libs(state, one, libs, where)
    local idx = 1
    while idx <= #libs do
        local value = libs[idx]
        local link = value:match("^%-l(.+)$")
        local dir = value:match("^%-L(.+)$")
        if link then
            model.add(one.links, link)
        elseif dir then
            model.add(one.linkdirs, reader.join(state, where.prefix, dir))
        elseif value == "-L" or value == "-l" then
            -- the value is the next word
            idx = idx + 1
            local next = libs[idx]
            if next then
                if value == "-l" then
                    model.add(one.links, next)
                else
                    model.add(one.linkdirs, reader.join(state, where.prefix, next))
                end
            end
        elseif value:find("%$%$") then
            model.unresolved(state.model, {
                file = where.file, target = one.name, text = value,
                why = "a qmake variable in LIBS which was not expanded"
            })
        elseif value:endswith(".a") or value:endswith(".lib") or value:endswith(".so") then
            model.add(one.links, path.basename(value):gsub("^lib", ""))
            model.add(one.linkdirs, reader.join(state, where.prefix, path.directory(value)))
        end
        idx = idx + 1
    end
end

-- CONFIG += c++17 warn_on
function _config(state, one, config, where)
    for _, value in ipairs(config) do
        local said = value:lower()
        local standard = said:match("^(c%+%+%d+)$") or said:match("^(c%+%+%dx)$")
        if standard then
            model.add(one.languages, (standard:gsub("x$", "0")))
        elseif said == "warn_on" then
            one.settings = one.settings or {}
            one.settings.warnings = one.settings.warnings or {}
            model.add(one.settings.warnings, "all")
        elseif said == "warn_off" then
            one.settings = one.settings or {}
            one.settings.warnings = {"none"}
        elseif said == "qt" or said == "console" or said == "staticlib" or said == "dll"
               or said == "shared" or said == "plugin" or said == "app_bundle"
               or said == "debug" or said == "release" or said == "debug_and_release" then
            -- said elsewhere, or a mode which is a rule in xmake
        elseif said == "no_keywords" then
            model.add(one.defines, "QT_NO_KEYWORDS")
        end
    end
end

-- QT += core widgets
function _qt(state, one, modules, template, config, where)
    if #modules == 0 then
        return
    end
    local frameworks = {}
    local unknown = {}
    for _, value in ipairs(modules) do
        local name = QTMODULES[value:lower()]
        if name then
            table.insert(frameworks, name)
        else
            table.insert(unknown, value)
        end
    end
    for _, name in ipairs(frameworks) do
        model.add(one.frameworks, name)
    end
    for _, name in ipairs(unknown) do
        model.add(one.frameworks, "Qt" .. name:sub(1, 1):upper() .. name:sub(2))
    end

    -- which qt rule it wants is a decision: a widget application, a quick one
    -- and a plain console program built against QtCore are three different
    -- rules and the `.pro` does not name any of them
    local suggestion = "qt.console"
    if table.contains(frameworks, "QtWidgets") then
        suggestion = "qt.widgetapp"
    elseif table.contains(frameworks, "QtQuick") or table.contains(frameworks, "QtQml") then
        suggestion = "qt.quickapp"
    end
    if template == "lib" then
        suggestion = one.kind == "shared" and "qt.shared" or "qt.static"
    end
    model.add(one.rules, suggestion)
    model.unresolved(state.model, {
        file = where.file, target = one.name,
        text = string.format("QT += %s", table.concat(modules, " ")),
        why = string.format("it is a qt project: `%s` is the rule this looks like, check it "
                            .. "against the others", suggestion)
    })
end


