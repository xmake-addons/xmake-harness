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
-- @file        normalize.lua
--

--
-- say the same thing the way xmake says it
--
-- a build system written for one compiler states its intentions as that
-- compiler's flags: `-fvisibility=hidden`, `/MT`, `-Wall`, `-O2`. copying them
-- across produces an `xmake.lua` which works on the machine it was converted on
-- and says nothing about what it wants — `add_cxflags("-fvisibility=hidden")`
-- is not portable, is not readable, and is not what xmake is for.
--
-- so every flag with an api behind it becomes that api, and every flag a mode
-- rule already provides is dropped. what is left over is left over: a flag this
-- does not know stays a flag, and is worth a look rather than a silent copy.
--
-- nothing is dropped quietly. every one of these is recorded as a note, so the
-- conversion can be read against the original and disagreed with.
--

-- imports
import("harness.plugins.xmake.import.model")

-- the flags which `mode.debug` and `mode.release` already set
--
-- a converted project which adds `-O2` by hand has two answers to the same
-- question and the rule's answer is the one which is right on every compiler
local MODEFLAGS = {
    ["-O0"] = "mode.debug", ["-O1"] = "mode.release", ["-O2"] = "mode.release",
    ["-O3"] = "mode.release", ["-Og"] = "mode.debug", ["-Ofast"] = "mode.release",
    ["-g"] = "mode.debug", ["-g3"] = "mode.debug", ["-ggdb"] = "mode.debug",
    ["/Od"] = "mode.debug", ["/O2"] = "mode.release", ["/O1"] = "mode.release",
    ["/Zi"] = "mode.debug", ["/ZI"] = "mode.debug", ["/Z7"] = "mode.debug",
    ["-DNDEBUG"] = "mode.release", ["/DNDEBUG"] = "mode.release"
}

-- the flags which are a setting, and which one
local SETTINGS = {
    ["-fvisibility=hidden"]          = {symbols = "hidden"},
    ["-fvisibility-inlines-hidden"]  = {symbols = "hidden"},
    ["-s"]                           = {symbols = "none"},
    ["-fno-exceptions"]              = {exceptions = "no-cxx"},
    ["-fno-cxx-exceptions"]          = {exceptions = "no-cxx"},
    ["/EHsc"]                        = {drop = "xmake enables c++ exceptions by default"},
    ["-fPIC"]                        = {drop = "xmake compiles shared libraries with -fPIC already"},
    ["-Wall"]                        = {warnings = "all"},
    ["-Wextra"]                      = {warnings = "extra"},
    ["-Werror"]                      = {warnings = "error"},
    ["-w"]                           = {warnings = "none"},
    ["-pedantic"]                    = {warnings = "pedantic"},
    ["/W4"]                          = {warnings = "extra"},
    ["/W3"]                          = {warnings = "all"},
    ["/WX"]                          = {warnings = "error"},
    ["/w"]                           = {warnings = "none"},
    ["/MT"]                          = {runtimes = "MT"},
    ["/MTd"]                         = {runtimes = "MTd"},
    ["/MD"]                          = {runtimes = "MD"},
    ["/MDd"]                         = {runtimes = "MDd"},
    ["-flto"]                        = {policy = {"build.optimization.lto", true}},
    ["/GL"]                          = {policy = {"build.optimization.lto", true}},
    ["-fsanitize=address"]           = {policy = {"build.sanitizer.address", true}},
    ["-fsanitize=undefined"]         = {policy = {"build.sanitizer.undefined", true}},
    ["-fsanitize=thread"]            = {policy = {"build.sanitizer.thread", true}}
}

-- the libraries which are the system's and never a package
local SYSLIBS = {
    m = true, dl = true, rt = true, util = true, c = true, pthread = true,
    ["stdc++"] = true, ["c++"] = true, ["c++abi"] = true, gcc = true, gcc_s = true,
    resolv = true, nsl = true, crypt = true, anl = true, atomic = true,
    ws2_32 = true, user32 = true, kernel32 = true, gdi32 = true, advapi32 = true,
    shell32 = true, ole32 = true, oleaut32 = true, uuid = true, comdlg32 = true,
    winspool = true, shlwapi = true, iphlpapi = true, psapi = true, dbghelp = true,
    version = true, winmm = true, crypt32 = true, secur32 = true, bcrypt = true,
    setupapi = true, wldap32 = true, normaliz = true, userenv = true, netapi32 = true
}

-- the flags which name a language standard
function _language(flag)
    local standard = flag:match("^%-std=(.+)$") or flag:match("^/std:(.+)$")
    if not standard then
        return nil
    end
    -- `c++17`, `gnu++17`, `c11`, `gnu11`, `c++latest`
    if standard:match("^c%+%+%d+$") or standard:match("^gnu%+%+%d+$")
       or standard:match("^c%d+$") or standard:match("^gnu%d+$") then
        return standard
    end
    if standard == "c++latest" then
        return "c++latest"
    end
    return nil
end

-- the flags which are `-I`, `-D` or `-l` written the long way round
function _asvalue(flag)
    local value = flag:match("^%-D(.+)$") or flag:match("^/D(.+)$")
    if value then
        return "defines", value
    end
    value = flag:match("^%-I(.+)$")
    if value then
        return "includedirs", value
    end
    value = flag:match("^%-l(.+)$")
    if value then
        return "links", value
    end
    value = flag:match("^%-L(.+)$")
    if value then
        return "linkdirs", value
    end
    return nil
end

-- normalise the whole project
--
-- @param project   the model
-- @return          the model, changed in place
--
function apply(project)
    for _, one in ipairs(project.targets or {}) do
        _flags(project, one)
        _links(project, one)
    end
    return project
end

-- the flags of one target
function _flags(project, one)
    one.settings = one.settings or {}
    one.policies = one.policies or {}

    for _, field in ipairs({"cxflags", "cflags", "cxxflags", "ldflags"}) do
        local kept = {}
        for _, flag in ipairs(one[field] or {}) do
            if not _flag(project, one, flag, field) then
                table.insert(kept, flag)
            end
        end
        one[field] = kept
    end

    -- the warnings are a list and the strongest one wins the argument: `all`
    -- and `extra` together are what `-Wall -Wextra` meant
    if one.settings.warnings then
        table.sort(one.settings.warnings, function (a, b)
            local order = {none = 1, all = 2, extra = 3, pedantic = 4, error = 5}
            return (order[a] or 0) < (order[b] or 0)
        end)
    end
end

-- one flag: is it something else in xmake?
--
-- @return  true when it was taken, so the caller drops it from the flags
--
function _flag(project, one, flag, field)
    -- a mode rule already answers this, and its answer works on every compiler
    local mode = MODEFLAGS[flag]
    if mode then
        model.note(project, "`%s`: `%s` is dropped, `%s` sets it", one.name, flag, mode)
        return true
    end

    local standard = _language(flag)
    if standard then
        model.add(one.languages, standard)
        model.note(project, "`%s`: `%s` becomes `set_languages(\"%s\")`", one.name, flag, standard)
        return true
    end

    -- `-DFOO`, `-Iinclude`, `-lz`: values written as flags
    local into, value = _asvalue(flag)
    if into then
        model.add(one[into], value)
        model.note(project, "`%s`: `%s` becomes `%s`", one.name, flag, into)
        return true
    end

    local setting = SETTINGS[flag]
    if not setting then
        return false
    end
    if setting.drop then
        model.note(project, "`%s`: `%s` is dropped, %s", one.name, flag, setting.drop)
        return true
    end
    if setting.policy then
        table.insert(one.policies, {name = setting.policy[1], value = setting.policy[2]})
        model.note(project, "`%s`: `%s` becomes `set_policy(\"%s\", ..)`", one.name, flag,
                   setting.policy[1])
        return true
    end
    for key, value in pairs(setting) do
        if key == "warnings" then
            one.settings.warnings = one.settings.warnings or {}
            model.add(one.settings.warnings, value)
        else
            one.settings[key] = value
        end
        model.note(project, "`%s`: `%s` becomes `set_%s(\"%s\")`", one.name, flag, key, value)
    end
    return true
end

-- the libraries: which are the system's, and which want looking up
function _links(project, one)
    local kept = {}
    for _, link in ipairs(one.links or {}) do
        local name = link:gsub("^lib", ""):gsub("%.lib$", "")
        if SYSLIBS[name] then
            model.add(one.syslinks, name)
            model.note(project, "`%s`: `%s` is a system library, so `add_syslinks`",
                       one.name, name)
        else
            table.insert(kept, link)
            -- it is linked by name, which in xmake usually means it should be a
            -- package instead: that is a decision and not a conversion
            model.unresolved(project, {
                target = one.name, text = string.format("add_links(\"%s\")", link),
                why = string.format("`%s` is linked by name: check `xrepo search %s` — it is "
                                    .. "usually `add_requires` and `add_packages` instead",
                                    link, name)
            })
        end
    end
    one.links = kept
end
