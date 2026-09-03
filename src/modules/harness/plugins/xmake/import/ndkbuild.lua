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
-- @file        ndkbuild.lua
--

--
-- read an `Android.mk` into the neutral model
--
-- it is a makefile by syntax and a data format by convention: every module is
-- `include $(CLEAR_VARS)`, a run of `LOCAL_*` assignments, and one
-- `include $(BUILD_*)` which says what to build from them.
--
--   include $(CLEAR_VARS)
--   LOCAL_MODULE    := demo
--   LOCAL_SRC_FILES := main.c util.c
--   LOCAL_C_INCLUDES := $(LOCAL_PATH)/include
--   LOCAL_STATIC_LIBRARIES := aux
--   include $(BUILD_SHARED_LIBRARY)
--
-- so the reading is exact rather than best-effort, which a plain makefile can
-- never be. `Application.mk` is read too: it carries the abis and the stl,
-- which are not target facts but are worth saying.
--

-- imports
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- what a `BUILD_*` builds
local BUILDS = {
    BUILD_EXECUTABLE = "binary",
    BUILD_SHARED_LIBRARY = "shared",
    BUILD_STATIC_LIBRARY = "static",
    PREBUILT_SHARED_LIBRARY = nil,
    PREBUILT_STATIC_LIBRARY = nil
}

-- the `LOCAL_*` variables which go straight into the model
local LISTS = {
    LOCAL_C_INCLUDES = "includedirs",
    LOCAL_EXPORT_C_INCLUDES = "includedirs",
    LOCAL_STATIC_LIBRARIES = "deps",
    LOCAL_SHARED_LIBRARIES = "deps",
    LOCAL_WHOLE_STATIC_LIBRARIES = "deps"
}

-- read a project
function read(rootdir, opt)
    opt = opt or {}
    local top = _find(rootdir)
    if not top then
        return nil, string.format("there is no Android.mk in %s", rootdir)
    end

    local state = reader.new({from = "ndkbuild", rootdir = rootdir,
                              name = path.filename(path.absolute(rootdir)),
                              maxfiles = opt.maxfiles or 60})
    model.note(state.model, "an Android.mk describes an android build: it is configured "
               .. "with `xmake f -p android --ndk=<path>`, and the libraries it links "
               .. "(`log`, `android`, `EGL`, ..) are the ndk's and exist nowhere else")
    _application(state, path.directory(top))
    _readfile(state, top)
    return reader.resolvedeps(state.model)
end

-- the `Android.mk`, wherever the project keeps it
function _find(rootdir)
    for _, name in ipairs({"Android.mk", "jni/Android.mk", "src/main/jni/Android.mk",
                           "app/src/main/jni/Android.mk", "app/jni/Android.mk"}) do
        local filepath = path.join(rootdir, name)
        if os.isfile(filepath) then
            return filepath
        end
    end
end

-- `Application.mk` says how the whole thing is built
function _application(state, dir)
    local filepath = path.join(dir, "Application.mk")
    if not os.isfile(filepath) then
        return
    end
    reader.opening(state, filepath)
    local relative = path.relative(filepath, state.rootdir)
    for _, entry in ipairs(reader.lines(filepath)) do
        local name, value = entry.text:match("^(APP_[%w_]+)%s*[:%+]?=%s*(.*)$")
        if name == "APP_ABI" then
            model.note(state.model, "Application.mk builds for %s: in xmake that is "
                       .. "`xmake f -p android -a <arch>` and not something in the file",
                       value)
        elseif name == "APP_STL" then
            model.unresolved(state.model, {
                file = relative, line = entry.line, text = string.format("APP_STL := %s", value),
                why = "the c++ runtime is `set_runtimes` in xmake, e.g. `c++_shared`"
            })
        elseif name == "APP_PLATFORM" then
            model.note(state.model, "Application.mk targets %s: `set_config(\"ndk_sdkver\", ..)`",
                       value)
        elseif name == "APP_CPPFLAGS" or name == "APP_CFLAGS" then
            model.note(state.model, "Application.mk sets %s for every module: %s", name, value)
        end
    end
end

-- read one `Android.mk`, and whatever it includes
function _readfile(state, filepath)
    if not reader.opening(state, filepath) then
        return
    end
    local relative = path.relative(filepath, state.rootdir)
    local here = path.directory(filepath)
    local prefix = reader.prefixof(state, filepath)
    local where = {file = relative, prefix = prefix, dir = here}

    local variables = {}
    local globals = {}
    for _, entry in ipairs(reader.lines(filepath)) do
        local text = entry.text

        -- include $(CLEAR_VARS) starts a module, include $(BUILD_*) ends one
        local included = text:match("^include%s+(.+)$")
        if included then
            local name = included:match("^%$[%(%{]([%w_]+)[%)%}]$")
            if name == "CLEAR_VARS" then
                variables = {}
            elseif name and BUILDS[name] ~= nil then
                if BUILDS[name] then
                    _module(state, variables, BUILDS[name], where, entry)
                else
                    _prebuilt(state, variables, where, entry)
                end
                variables = {}
            elseif name then
                -- `include $(call all-subdir-makefiles)` and friends
                model.unresolved(state.model, {
                    file = relative, line = entry.line, text = text,
                    why = "an ndk-build include which was not followed"
                })
            else
                for _, one in ipairs(reader.words(_expand(included, here, state))) do
                    _readfile(state, path.absolute(one, here))
                end
            end
        else
            local name, operator, value = text:match("^([%w_]+)%s*([:%+%?]?=)%s*(.*)$")
            if name then
                local values = reader.words(_expand(value, here, state))
                if operator == "+=" then
                    variables[name] = table.join(variables[name] or {}, values)
                else
                    variables[name] = values
                end
                if not name:startswith("LOCAL_") then
                    globals[name] = variables[name]
                end
            end
        end
    end
end

-- `$(LOCAL_PATH)` is the directory of the file, which is the only variable
-- almost every `Android.mk` uses
function _expand(value, here, state)
    return (tostring(value or ""):gsub("%$[%(%{]([%w_]+)[%)%}]", function (name)
        if name == "LOCAL_PATH" or name == "call my-dir" then
            return here
        end
        return "$(" .. name .. ")"
    end))
end

-- one module
function _module(state, variables, kind, where, entry)
    local name = (variables.LOCAL_MODULE or {})[1]
    if not name then
        return
    end
    local one = model.target(state.model, name, {kind = kind, from = where.file})

    for _, file in ipairs(variables.LOCAL_SRC_FILES or {}) do
        if file:find("%$") then
            reader.unexpanded(state, {file = where.file, line = entry.line, target = name}, file,
                              "a make variable in LOCAL_SRC_FILES, so this source is unknown")
        else
            model.add(one.files, reader.join(state, where.prefix, file))
        end
    end

    for key, field in pairs(LISTS) do
        for _, value in ipairs(variables[key] or {}) do
            if field == "deps" then
                model.add(one.deps, value)
            else
                model.add(one[field], reader.join(state, where.prefix, value))
            end
        end
    end

    for _, key in ipairs({"LOCAL_CFLAGS", "LOCAL_CPPFLAGS", "LOCAL_CXXFLAGS",
                          "LOCAL_EXPORT_CFLAGS"}) do
        local rest = reader.flags(state, one, variables[key] or {}, where.prefix)
        for _, flag in ipairs(rest) do
            if key == "LOCAL_CPPFLAGS" or key == "LOCAL_CXXFLAGS" then
                model.add(one.cxxflags, flag)
            else
                model.add(one.cflags, flag)
            end
        end
    end

    -- `LOCAL_LDLIBS := -llog -lz` is the android system's libraries
    for _, value in ipairs(variables.LOCAL_LDLIBS or {}) do
        local link = value:match("^%-l(.+)$")
        if link then
            model.add(one.syslinks, link)
        else
            model.add(one.ldflags, value)
        end
    end

    local standard = (variables.LOCAL_CPP_FEATURES or {})[1]
    if standard then
        model.note(state.model, "`%s` asks for the c++ features `%s`", name,
                   table.concat(variables.LOCAL_CPP_FEATURES, " "))
    end
end

-- a prebuilt library is a file, not something to build
function _prebuilt(state, variables, where, entry)
    local name = (variables.LOCAL_MODULE or {})[1]
    local filename = (variables.LOCAL_SRC_FILES or {})[1]
    if not name then
        return
    end
    model.unresolved(state.model, {
        file = where.file, line = entry.line, target = name,
        text = string.format("%s := %s", name, tostring(filename)),
        why = "a prebuilt library: it is a file to link against and not a target to build, "
              .. "so `add_links` and `add_linkdirs` rather than a target"
    })
end
