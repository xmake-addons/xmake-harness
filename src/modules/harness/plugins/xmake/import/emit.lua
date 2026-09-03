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
-- @file        emit.lua
--

--
-- a model, written as an `xmake.lua`
--
-- this is the half of the conversion which has one right answer: given the
-- facts, the file which states them is a matter of the api and the house style,
-- and neither is something to ask a model about every time. what it produces is
-- idiomatic and boring on purpose — the description scope only, one target per
-- block, the builtin rules rather than hand-written flags.
--
-- what it does not do is invent. a target whose sources are unknown is written
-- with the unknown marked, so that the file says where somebody has to look
-- instead of quietly building nothing.
--

-- imports
import("harness.plugins.xmake.import.model")

-- how a language maps to the `set_languages` value
local LANGUAGES = {["c++"] = "c++", c = "c"}

-- write the model out
--
-- @param project   the model, @see harness.plugins.xmake.import.model
-- @param opt       {header = true, todo = true}
-- @return          the text of an xmake.lua
--
function render(project, opt)
    opt = opt or {}
    local out = {}
    -- `select` is not available in the sandbox, so the arguments are counted
    -- the other way round
    local function line(format, ...)
        local args = {...}
        table.insert(out, #args > 0 and string.format(format, table.unpack(args)) or format)
    end

    if opt.header ~= false then
        line("-- converted from %s by `xmake ai`", project.from or "another build system")
        if opt.todo ~= false and #(project.unresolved or {}) > 0 then
            line("--")
            line("-- %d thing%s in the original had no direct equivalent, see the TODOs",
                 #project.unresolved, #project.unresolved == 1 and "" or "s")
        end
        line("")
    end

    -- the modes come first, because a project without them has no debug build
    line("add_rules(\"mode.debug\", \"mode.release\")")
    line("")

    -- where the build goes, when the default would collide with something
    if project.buildir then
        line("-- the default `build` would collide with a file of the original")
        line("set_config(\"builddir\", %s)", _quote(project.buildir))
        line("")
    end

    _shared(project, line)
    _options(project, line)
    _packages(project, line)

    -- the targets, in an order which puts a dependency before what needs it, so
    -- the file reads the way the build runs
    for _, one in ipairs(_ordered(project)) do
        _target(project, one, line, opt)
    end

    -- in parentheses: gsub returns the count as well, and a caller which wrote
    -- `print(render(..))` would print it
    return (table.concat(out, "\n"):gsub("\n\n\n+", "\n\n"))
end

-- the settings which belong to the whole project and not to a target
--
-- the msvc runtime is the one which matters: every target in a build has to
-- agree about it, and a project which sets it four times is a project where
-- somebody will change three of them. it is said once, at the top, where it
-- applies to everything below.
--
-- it is only hoisted when every target already agrees. one which disagrees is
-- a fact about that project and stays where it is
--
local SHARED = {"runtimes", "languages"}

function _shared(project, line)
    -- `next` is not available in the sandbox, so it is counted rather than
    -- asked whether it is empty
    local hoisted = {}
    local count = 0
    for _, key in ipairs(SHARED) do
        local value = _agreed(project, key)
        if value then
            hoisted[key] = value
            count = count + 1
        end
    end
    if count == 0 then
        return
    end
    if hoisted.languages then
        line("set_languages(%s)", _list(hoisted.languages))
    end
    if hoisted.runtimes then
        -- no platform filter: the runtime is an msvc idea and xmake ignores it
        -- everywhere else already, so `{plat = "windows"}` is noise which reads
        -- as though it were doing something
        line("set_runtimes(%s)", _quote(hoisted.runtimes))
    end
    line("")
    project.hoisted = hoisted
end

-- what every target says about this, when they all say the same thing
function _agreed(project, key)
    local targets = project.targets or {}
    if #targets < 2 then
        return nil
    end
    local answer = nil
    for _, one in ipairs(targets) do
        local value = key == "languages" and one.languages or (one.settings or {})[key]
        if type(value) == "table" then
            value = #value > 0 and table.concat(value, ",") or nil
        end
        if value == nil then
            return nil
        end
        if answer == nil then
            answer = value
        elseif answer ~= value then
            return nil
        end
    end
    if key == "languages" and answer then
        return answer:split(",", {plain = true})
    end
    return answer
end

-- the options of the project
function _options(project, line)
    if #(project.options or {}) == 0 then
        return
    end
    for _, one in ipairs(project.options) do
        line("option(\"%s\")", _name(one.name))
        if one.description and one.description ~= "" then
            line("    set_description(%s)", _quote(one.description))
        end
        line("    set_default(%s)", tostring(one.default and true or false))
        line("option_end()")
        line("")
    end
end

-- the packages it needs
function _packages(project, line)
    if #(project.packages or {}) == 0 then
        return
    end
    local names = {}
    for _, one in ipairs(project.packages) do
        table.insert(names, _quote(one.name))
    end
    line("add_requires(%s)", table.concat(names, ", "))
    line("")
end

-- one target
function _target(project, one, line, opt)
    line("target(%s)", _quote(one.name))
    line("    set_kind(%s)", _quote(one.kind))

    local hoisted = project.hoisted or {}
    if #one.languages > 0 and not hoisted.languages then
        line("    set_languages(%s)", _list(one.languages))
    end

    -- what the original said with flags, said with the api which means it on
    -- every compiler, @see harness.plugins.xmake.import.normalize
    local settings = one.settings or {}
    if settings.warnings then
        line("    set_warnings(%s)", _list(settings.warnings))
    end
    if settings.symbols then
        line("    set_symbols(%s)", _quote(settings.symbols))
    end
    if settings.optimize then
        line("    set_optimize(%s)", _quote(settings.optimize))
    end
    if settings.runtimes and not hoisted.runtimes then
        line("    set_runtimes(%s)", _quote(settings.runtimes))
    end
    if settings.exceptions then
        line("    set_exceptions(%s)", _quote(settings.exceptions))
    end
    for _, policy in ipairs(one.policies or {}) do
        line("    set_policy(%s, %s)", _quote(policy.name), tostring(policy.value))
    end

    if #one.files > 0 then
        line("    add_files(%s)", _list(one.files))
    elseif one.kind ~= "headeronly" and one.kind ~= "phony" then
        line("    -- TODO: the sources of this target could not be worked out")
    end

    -- a header directory becomes the headers in it: `add_headerfiles` takes
    -- patterns and installs what they match, which is what the original meant
    -- by listing them at all
    if #one.headerdirs > 0 and (one.kind == "static" or one.kind == "shared"
                                or one.kind == "headeronly") then
        local patterns = {}
        for _, dir in ipairs(one.headerdirs) do
            table.insert(patterns, (dir == "." and "" or dir .. "/") .. "*.h")
        end
        _add(line, "add_headerfiles", patterns)
    end
    _add(line, "add_includedirs", one.includedirs)
    _add(line, "add_sysincludedirs", one.sysincludedirs)
    _add(line, "add_defines", one.defines)
    _add(line, "add_undefines", one.undefines)
    _add(line, "add_deps", one.deps)
    _add(line, "add_packages", one.packages)
    _add(line, "add_options", one.options)
    _add(line, "add_links", one.links)
    _add(line, "add_syslinks", one.syslinks)
    _add(line, "add_linkdirs", one.linkdirs)
    _add(line, "add_frameworks", one.frameworks)
    _add(line, "add_rules", one.rules)
    -- whatever flags are left have no api behind them, and they belong to the
    -- compiler which was being used when somebody wrote them. an `/GR-` handed
    -- to gcc is an error and a `-fno-rtti` handed to cl is a warning and a
    -- wasted afternoon, so each keeps the tools it is for
    _flags(line, "add_cflags", one.cflags)
    _flags(line, "add_cxxflags", one.cxxflags)
    _flags(line, "add_cxflags", one.cxflags)
    _flags(line, "add_ldflags", one.ldflags)

    -- what the original made conditional, said once and in the target it
    -- belongs to: the reader could not evaluate it, and this is where whoever
    -- can will look for it
    if opt.todo ~= false and #(one.conditions or {}) > 0 then
        for _, condition in ipairs(one.conditions) do
            line("    -- TODO: the original guarded some of this with `%s`", condition)
        end
    end
    line("")
end

-- the flags of one api, split by the compilers they are for
function _flags(line, api, values)
    if not values or #values == 0 then
        return
    end
    local msvc = {}
    local gcc = {}
    local any = {}
    for _, flag in ipairs(values) do
        if flag:startswith("/") then
            table.insert(msvc, flag)
        elseif flag:startswith("-") then
            table.insert(gcc, flag)
        else
            table.insert(any, flag)
        end
    end
    if #any > 0 then
        line("    %s(%s)", api, _list(any))
    end
    if #gcc > 0 then
        line("    %s(%s, {tools = {\"gcc\", \"clang\"}})", api, _list(gcc))
    end
    if #msvc > 0 then
        line("    %s(%s, {tools = \"cl\"})", api, _list(msvc))
    end
end

-- one `add_*` line, when there is anything to put in it
function _add(line, api, values)
    if values and #values > 0 then
        line("    %s(%s)", api, _list(values))
    end
end

-- the targets, dependencies first
--
-- xmake does not need the order and a reader does: a file which mentions
-- `add_deps("mylib")` fifty lines before `mylib` exists reads backwards
--
function _ordered(project)
    local done = {}
    local out = {}
    local function visit(one, depth)
        if done[one.name] or depth > 32 then
            return
        end
        done[one.name] = true
        for _, name in ipairs(one.deps or {}) do
            local dep = model.get(project, name)
            if dep then
                visit(dep, depth + 1)
            end
        end
        table.insert(out, one)
    end
    for _, one in ipairs(project.targets or {}) do
        visit(one, 0)
    end
    return out
end

-- a lua string, quoted the way the rest of an xmake.lua is
function _quote(str)
    str = tostring(str or "")
    if str:find("\"", 1, true) or str:find("\\", 1, true) then
        return string.format("%q", str)
    end
    return "\"" .. str .. "\""
end

-- a list of them, wrapped when it is long enough to need it
function _list(values)
    local quoted = {}
    local width = 0
    for _, value in ipairs(values) do
        local one = _quote(value)
        width = width + #one + 2
        table.insert(quoted, one)
    end
    if width <= 66 then
        return table.concat(quoted, ", ")
    end
    return "\n        " .. table.concat(quoted, ",\n        ") .. "\n    "
end

-- a name which is safe to use as one
function _name(str)
    return tostring(str or ""):gsub("[^%w_%-%.]", "_")
end

-- everything the conversion could not answer, as a list somebody can work down
--
-- it is written beside the `xmake.lua` and not into it: a file with forty TODO
-- comments in it is not a build file, and the list is a thing to finish and
-- delete rather than something to live with
--
function todos(project)
    local out = {}
    table.insert(out, string.format("# what the conversion could not answer (%d)",
                                    #(project.unresolved or {})))
    table.insert(out, "")
    table.insert(out, "each of these is a place where the original says something this")
    table.insert(out, "conversion could not work out on its own. read the original at the")
    table.insert(out, "line given, decide, and change the xmake.lua.")
    table.insert(out, "")

    local bytarget = {}
    local general = {}
    for _, one in ipairs(project.unresolved or {}) do
        if one.target then
            bytarget[one.target] = bytarget[one.target] or {}
            table.insert(bytarget[one.target], one)
        else
            table.insert(general, one)
        end
    end

    if #general > 0 then
        table.insert(out, "## the project")
        table.insert(out, "")
        for _, one in ipairs(general) do
            table.insert(out, _todoline(one))
        end
        table.insert(out, "")
    end
    for _, one in ipairs(project.targets or {}) do
        local items = bytarget[one.name]
        if items then
            table.insert(out, string.format("## %s", one.name))
            table.insert(out, "")
            for _, item in ipairs(items) do
                table.insert(out, _todoline(item))
            end
            table.insert(out, "")
        end
    end
    if #(project.notes or {}) > 0 then
        table.insert(out, "## notes")
        table.insert(out, "")
        for _, note in ipairs(project.notes) do
            table.insert(out, "- " .. note)
        end
        table.insert(out, "")
    end
    return table.concat(out, "\n")
end

function _todoline(one)
    -- the ones which come from the flags are about a target and not about a
    -- line, and a `?` in front of them reads as something missing
    local where = one.file and string.format("`%s:%s` — ", one.file, tostring(one.line or "?"))
        or (one.target and string.format("`%s` — ", one.target) or "")
    return string.format("- [ ] %s%s\n      `%s`", where, one.why or "?", one.text or "")
end
