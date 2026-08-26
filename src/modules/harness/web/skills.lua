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
-- @file        skills.lua
--

--
-- the skills, as a settings page shows them
--
-- three questions, and the page answers all three in one place:
--
--   what does this harness know      the skills which are loaded, where each
--                                    came from, and which are switched off
--   what can it be taught            the packs somebody can install, the ones
--                                    the plugins register and anything with a
--                                    git url
--   what has it been taught already  the packs which are installed, and what
--                                    to do about them
--
-- installing is `/skills install <name>` doing the same work, @see
-- harness.commands.builtin.skills: the same installer, the same directory, the
-- same packs. a page which had its own idea of where skills live would be a
-- second harness wearing the first one's name.
--

-- imports
import("harness.config.config")
import("harness.skills.installer")
import("harness.skills.registry", {alias = "skillregistry"})

-- everything the skills page draws itself from
function describe(harness)
    local harnessconfig = harness:config()
    local registry = harness:service("skills")
    local settings = harnessconfig.skills or {}
    local disabled = settings.disabled or {}

    local skills = {}
    for _, skill in ipairs(registry and registry:all() or {}) do
        table.insert(skills, {
            name = skill.name,
            description = skill.description,
            source = skill.source,
            enabled = not table.contains(disabled, skill.name)
        })
    end
    table.sort(skills, function (a, b) return a.name < b.name end)

    return {
        skills = skills,
        installed = _installed(),
        available = _available(harness),
        dir = installer.dir()
    }
end

-- the packs which are installed
function _installed()
    local packs = {}
    for _, pack in ipairs(installer.installed()) do
        table.insert(packs, {
            name = pack.name,
            title = pack.title,
            url = pack.url,
            skills = pack.skills,
            layout = pack.layout,
            updatable = pack.isgit or false
        })
    end
    return packs
end

-- the packs a plugin has registered, minus the ones already installed
function _available(harness)
    local packs = {}
    for name, source in pairs(installer.sources(harness)) do
        local packname = source.packname or source.name or name
        if not installer.isinstalled(packname) then
            table.insert(packs, {
                name = name,
                title = source.title or source.description,
                url = source.url
            })
        end
    end
    table.sort(packs, function (a, b) return a.name < b.name end)
    return packs
end

-- install a pack, by name, url or directory
--
-- @return  the pack, or nil and the reason
--
function install(harness, spec)
    local source, errors = installer.resolve(harness, spec)
    if not source then
        return nil, errors
    end
    local pack, installerrors = installer.install(source)
    if not pack then
        return nil, installerrors
    end
    _reload(harness)
    return {name = pack.name, title = pack.title, skills = pack.skills, url = pack.url}
end

-- take one away again
function remove(harness, name)
    local ok, errors = installer.remove(name)
    if not ok then
        return nil, errors
    end
    _reload(harness)
    return true
end

-- switch one skill off, or back on
--
-- it is written to the user configuration and not held here: the terminal reads
-- the same setting, and a skill switched off in a browser is switched off,
-- @see harness.skills.registry.enabled
--
function enable(harness, name, enabled)
    local harnessconfig = harness:config()
    harnessconfig.skills = harnessconfig.skills or {}
    local disabled = harnessconfig.skills.disabled or {}

    local kept = {}
    for _, one in ipairs(disabled) do
        if one ~= name then
            table.insert(kept, one)
        end
    end
    if enabled == false then
        table.insert(kept, name)
    end
    harnessconfig.skills.disabled = kept
    config.set("skills.disabled", kept)
    return true
end

-- read the skills again, after the directory changed under us
--
-- the registry is built at startup from the directories which existed then, so
-- a pack installed now is a pack nobody has read yet
--
function _reload(harness)
    local harnessconfig = harness:config()
    local registry = skillregistry.new()
    local packdirs = installer.packdirs()
    for _, dir in ipairs(skillregistry.defaultdirs(harnessconfig, harness:rootdir())) do
        registry:adddir(dir, _sourcename(dir, harness:rootdir()), {exclude = packdirs})
    end

    -- the packs are read after the plain directories and through the service,
    -- which is how the bootstrap does it, @see harness.harness.bootstrap
    harness:service("skills", registry)
    installer.loadall(harness)
    return registry
end

-- where a skill directory came from, as somebody reads it
function _sourcename(dir, rootdir)
    if rootdir and dir:startswith(rootdir) then
        return "project"
    end
    if dir:startswith(config.homedir()) then
        return "user"
    end
    return "builtin"
end
