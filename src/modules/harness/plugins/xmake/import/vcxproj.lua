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
-- @file        vcxproj.lua
--

--
-- read a visual studio project into the neutral model
--
-- a `.vcxproj` is msbuild, which is xml with a small language in the attributes:
-- every property group and every item is guarded by a `Condition` naming a
-- configuration and a platform, and the same target is described several times
-- over — once for `Debug|Win32`, once for `Release|x64`, and so on.
--
-- so the reading is done per configuration and then folded: what every
-- configuration agrees on is a fact about the target, and what they disagree
-- about is a fact about a mode. the release-only defines end up as unresolved
-- with the configuration named, because `mode.release` in xmake is a rule and
-- not a copy of the target.
--
-- a `.sln` is read for the projects it lists and nothing else: the build order
-- in a solution is the dependencies of the projects in it, which the projects
-- state themselves.
--

-- imports
import("harness.util.xml")
import("harness.plugins.xmake.import.model")
import("harness.plugins.xmake.import.reader")

-- what msbuild calls a target kind, and what it is here
local KINDS = {
    Application = "binary",
    StaticLibrary = "static",
    DynamicLibrary = "shared",
    Utility = "phony"
}

-- the item names which are sources
local SOURCEITEMS = {ClCompile = true, ClInclude = false, MASM = true, CudaCompile = true,
                     ResourceCompile = false, Midl = false, None = false}

-- the msbuild properties which are worth reading, and where they go
local COMPILERLISTS = {
    PreprocessorDefinitions = "defines",
    AdditionalIncludeDirectories = "includedirs"
}

-- read one `.vcxproj`, or a `.sln` and everything in it
--
-- @param filepath  the project or the solution
-- @param opt       {rootdir = ".."}
-- @return          the model, or nil and the reason
--
function read(filepath, opt)
    opt = opt or {}
    if not os.isfile(filepath) then
        return nil, string.format("%s does not exist", filepath)
    end
    local rootdir = opt.rootdir or path.directory(filepath)
    local project = model.new({from = "vcxproj", dir = rootdir,
                               name = path.basename(filepath)})

    if path.extension(filepath):lower() == ".sln" then
        project.from = "sln"
        local projects, errors = solution(filepath)
        if not projects then
            return nil, errors
        end
        if #projects == 0 then
            return nil, "the solution lists no project"
        end
        for _, one in ipairs(projects) do
            _project(project, one.path, rootdir)
        end
        _resolvedeps(project)
        return project
    end

    local ok, errors = _project(project, filepath, rootdir)
    if not ok then
        return nil, errors
    end
    _resolvedeps(project)
    return project
end

-- the projects a solution lists
--
-- the `.sln` is not xml: it is a line format, and the only line which matters
-- here names a project and where it is
--
-- @return  {{name = "demo", path = "/abs/demo.vcxproj", guid = ".."}, ..}
--
function solution(filepath)
    if not os.isfile(filepath) then
        return nil, string.format("%s does not exist", filepath)
    end
    local dir = path.directory(filepath)
    local projects = {}
    for _, line in ipairs((io.readfile(filepath) or ""):split("\n", {strict = true})) do
        -- Project("{type}") = "name", "relative\path.vcxproj", "{guid}"
        local name, relative, guid = line:match(
            "^Project%(\"{[^}]*}\"%)%s*=%s*\"([^\"]+)\",%s*\"([^\"]+)\",%s*\"{([^}]*)}\"")
        if name and relative and relative:lower():endswith(".vcxproj") then
            table.insert(projects, {
                name = name,
                path = path.normalize(path.join(dir, (relative:gsub("\\", "/")))),
                guid = guid
            })
        end
    end
    return projects
end

-- read one project into the model
function _project(project, filepath, rootdir)
    if not os.isfile(filepath) then
        model.note(project, "%s is listed but not there", filepath)
        return true
    end
    local root, errors = xml.loadfile(filepath)
    if not root then
        return nil, string.format("%s: %s", path.filename(filepath), tostring(errors))
    end

    local here = path.directory(filepath)
    local relative = path.relative(here, rootdir)
    local name = _name(root) or path.basename(filepath)
    local file = path.relative(filepath, rootdir)

    -- the kind, which may differ between configurations: a project which is a
    -- library in one and an application in another is a project to look at
    local kinds = {}
    for _, group in ipairs(xml.find(root, "PropertyGroup")) do
        for _, item in ipairs(xml.children(group, "ConfigurationType")) do
            local kind = KINDS[xml.text(item)]
            if kind then
                kinds[kind] = _configuration(group.attrs.Condition) or "all"
            end
        end
    end
    local kind = nil
    local kindcount = 0
    for one in pairs(kinds) do
        kind = kind or one
        kindcount = kindcount + 1
    end
    if kindcount > 1 then
        model.unresolved(project, {
            file = file, target = name,
            why = "the configurations do not agree on what this project builds",
            text = "ConfigurationType"
        })
    end

    local one = model.target(project, name, {kind = kind or "binary", from = file})
    _sources(project, one, root, relative, file)
    _compiler(project, one, root, relative, file)
    _linker(project, one, root, relative, file)
    _references(project, one, root)
    return true
end

-- the project name, as msbuild states it
function _name(root)
    for _, group in ipairs(xml.find(root, "PropertyGroup")) do
        local item = xml.child(group, "ProjectName")
        if item and xml.text(item) ~= "" then
            return xml.text(item)
        end
        item = xml.child(group, "RootNamespace")
        if item and xml.text(item) ~= "" then
            return xml.text(item)
        end
    end
end

-- the sources and the headers
function _sources(project, one, root, prefix, file)
    for _, group in ipairs(xml.find(root, "ItemGroup")) do
        for _, item in ipairs(xml.children(group)) do
            local issource = SOURCEITEMS[item.name]
            local include = item.attrs.Include
            if include and include ~= "" and issource ~= nil then
                local relative = _path(prefix, include)
                if issource then
                    -- a source excluded from every build is not a source
                    if not _excludedalways(item) then
                        model.add(one.files, relative)
                    end
                elseif item.name == "ClInclude" then
                    model.add(one.headerdirs, path.directory(relative))
                end
            end
        end
    end
    if #one.files == 0 and one.kind ~= "phony" then
        model.unresolved(project, {
            file = file, target = one.name,
            why = "no source file was listed, the project may build from a wildcard or a target file",
            text = "ItemGroup"
        })
    end
end

-- is this item excluded from the build in every configuration it names?
function _excludedalways(item)
    local excluded = xml.children(item, "ExcludedFromBuild")
    if #excluded == 0 then
        return false
    end
    for _, one in ipairs(excluded) do
        if xml.text(one):lower() ~= "true" then
            return false
        end
    end
    return true
end

-- the compiler settings
function _compiler(project, one, root, prefix, file)
    for _, group in ipairs(xml.find(root, "ItemDefinitionGroup")) do
        local configuration = _configuration(group.attrs.Condition)
        for _, compile in ipairs(xml.children(group, "ClCompile")) do
            for element, field in pairs(COMPILERLISTS) do
                for _, item in ipairs(xml.children(compile, element)) do
                    _values(project, one, xml.text(item), field, prefix, configuration, file)
                end
            end
            local standard = xml.child(compile, "LanguageStandard")
            if standard then
                local version = xml.text(standard):match("stdcpp(%d+)")
                if version then
                    model.add(one.languages, "c++" .. version)
                end
            end
        end
    end
end

-- the linker settings
function _linker(project, one, root, prefix, file)
    for _, group in ipairs(xml.find(root, "ItemDefinitionGroup")) do
        local configuration = _configuration(group.attrs.Condition)
        for _, link in ipairs(xml.children(group, "Link")) do
            for _, item in ipairs(xml.children(link, "AdditionalDependencies")) do
                _values(project, one, xml.text(item), "syslinks", prefix, configuration, file)
            end
            for _, item in ipairs(xml.children(link, "AdditionalLibraryDirectories")) do
                _values(project, one, xml.text(item), "linkdirs", prefix, configuration, file)
            end
        end
    end
end

-- the projects this one is built after
function _references(project, one, root)
    for _, reference in ipairs(xml.find(root, "ProjectReference")) do
        local include = reference.attrs.Include
        if include then
            model.add(one.deps, path.basename((include:gsub("\\", "/"))))
        end
    end
end

-- split a `;`-separated msbuild list and put it where it belongs
--
-- the inherited value is dropped: `%(PreprocessorDefinitions)` means "and
-- whatever was set further up", and what was set further up is either already
-- here or is a default of the toolchain
--
function _values(project, one, text, field, prefix, configuration, file)
    for _, value in ipairs(tostring(text or ""):split(";", {plain = true})) do
        value = value:trim()
        if value ~= "" and not value:startswith("%(") then
            if value:find("$(", 1, true) then
                model.unresolved(project, {
                    file = file, target = one.name, text = value,
                    why = "an msbuild variable which was not expanded"
                })
            elseif field == "includedirs" or field == "linkdirs" then
                model.add(one[field], _path(prefix, value))
            elseif field == "syslinks" then
                model.add(one[field], (value:gsub("%.lib$", "")))
            else
                model.add(one[field], value)
            end

            -- a value which belongs to one configuration is not a fact about
            -- the target: in xmake that is `mode.debug` or `mode.release`, and
            -- which of the two it is has to be decided rather than assumed
            if configuration then
                model.add(one.conditions, string.format("the %s configuration", configuration))
                model.unresolved(project, {
                    file = file, target = one.name,
                    text = string.format("%s (%s only)", value, configuration),
                    why = "it belongs to one configuration, which is a mode rule in xmake"
                })
            end
        end
    end
end

-- the configuration a `Condition` names, when it names one
function _configuration(condition)
    if not condition then
        return nil
    end
    local name = condition:match("==%s*'([^'|]+)|")
    -- `Debug|Win32` and `Release|x64` are the two everybody has, and a value
    -- which is in both is a value which is in neither in particular
    return name
end

-- a project-relative path, with the separators turned round
function _path(prefix, one)
    one = tostring(one or ""):gsub("\\", "/"):gsub("/+$", "")
    if one == "" or one == "." then
        return prefix == "" and "." or prefix
    end
    if one:match("^%a:/") then
        return one
    end
    if prefix == "" or prefix == "." then
        return path.normalize(one)
    end
    return path.normalize(path.join(prefix, one))
end

-- a reference which names a project which is not here is worth saying
--
-- the shared part — a link which turns out to be a target — is in the reader,
-- @see harness.plugins.xmake.import.reader.resolvedeps
--
function _resolvedeps(project)
    local byname = {}
    for _, one in ipairs(project.targets) do
        byname[one.name] = true
    end
    for _, one in ipairs(project.targets) do
        local deps = {}
        for _, dep in ipairs(one.deps) do
            if byname[dep] then
                table.insert(deps, dep)
            else
                model.note(project, "`%s` references `%s`, which is not in this solution",
                           one.name, dep)
            end
        end
        one.deps = deps
    end
    return reader.resolvedeps(project)
end
