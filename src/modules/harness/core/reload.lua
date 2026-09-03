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
-- @file        reload.lua
--

--
-- read the configuration, the skills, the agents and the commands again
--
-- everything here is built once at startup from what was on disk then, @see
-- harness.harness.bootstrap. so writing a skill means restarting to use it,
-- editing `~/.xmake/harness/config.json` means restarting to have it read, and
-- a session which has been going for an hour is the most expensive thing to
-- restart — it is the one with the context in it.
--
-- what this cannot do is reload the lua of the harness itself: xmake caches an
-- imported module for the life of the process, so a change to the harness
-- sources still needs a new one. that is a matter for whoever is working on the
-- harness, and not for somebody using it.
--

-- imports
import("harness.config.config")
import("harness.skills.installer")
import("harness.skills.registry", {alias = "skillregistry"})
import("harness.agents.registry", {alias = "agentregistry"})
import("harness.agents.installer", {alias = "agentinstaller"})
import("harness.commands.registry", {alias = "commandregistry"})

-- is this directory one of those, or inside one of them?
function _inside(dir, dirs)
    for _, one in ipairs(dirs or {}) do
        if dir == one or dir:startswith(one .. "/") then
            return true
        end
    end
    return false
end

-- where a directory of skills, agents or commands came from
function sourcename(dir, rootdir)
    if rootdir and dir:startswith(rootdir) then
        return "project"
    end
    if dir:startswith(config.homedir()) then
        return "user"
    end
    return "builtin"
end

-- read the configuration files again
--
-- the table is filled in place and not replaced: everything which was handed a
-- configuration at startup holds this table, and handing out a new one would
-- leave all of them reading the old
--
function settings(harness)
    local current = harness:config()

    -- the answer about this directory is carried across: without it a `/reload`
    -- in an untrusted project would merge the project configuration back in and
    -- forget that it was ever untrusted, @see harness.config.trust
    local fresh = config.load({rootdir = harness:rootdir(), options = current._options,
                               trusted = current._trusted})
    for key in pairs(current) do
        if fresh[key] == nil then
            current[key] = nil
        end
    end
    for key, value in pairs(fresh) do
        current[key] = value
    end
    return current
end

-- read the skills again
--
-- @return  the registry, and how many skills are in it
--
function skills(harness)
    local harnessconfig = harness:config()
    local existing = harness:service("skills")
    local registry = skillregistry.new()
    local packdirs = installer.packdirs()
    local defaults = skillregistry.defaultdirs(harnessconfig, harness:rootdir())
    for _, dir in ipairs(defaults) do
        registry:adddir(dir, sourcename(dir, harness:rootdir()), {exclude = packdirs})
    end

    -- a plugin may ship skills of its own and the plugins are not loaded again
    -- here, so the directories they contributed are carried across. without
    -- this every `/reload` quietly drops them, and the only sign is a skill
    -- which used to be listed and is not
    for _, dir in ipairs(existing and existing:dirs() or {}) do
        if not table.contains(defaults, dir) and not _inside(dir, packdirs) then
            registry:adddir(dir, sourcename(dir, harness:rootdir()), {exclude = packdirs})
        end
    end

    -- the packs are read after the plain directories and through the service,
    -- which is how the bootstrap does it, @see harness.harness.bootstrap
    -- the skills an agent bundle ships with it, @see harness.agents.registry
    for _, dir in ipairs((harness:service("agents") or {}).skilldirs
                         and harness:service("agents"):skilldirs() or {}) do
        registry:adddir(dir, "agent:" .. path.filename(path.directory(dir)), {exclude = packdirs})
    end

    harness:service("skills", registry)
    installer.loadall(harness)

    -- a skill which has just been installed is one somebody can open by hand
    skillcommands(harness)
    return registry, #registry:all()
end

-- read the subagents again
function agents(harness)
    local existing = harness:service("agents")
    local registry = agentregistry.new()
    local packdirs = agentinstaller.packdirs()
    local defaults = agentregistry.defaultdirs(harness:config(), harness:rootdir())
    for _, dir in ipairs(defaults) do
        registry:adddir(dir, sourcename(dir, harness:rootdir()), {exclude = packdirs})
    end
    -- and the ones a plugin contributed, for the same reason as the skills
    for _, dir in ipairs(existing and existing:dirs() or {}) do
        if not table.contains(defaults, dir) and not _inside(dir, packdirs) then
            registry:adddir(dir, sourcename(dir, harness:rootdir()), {exclude = packdirs})
        end
    end
    harness:service("agents", registry)
    agentinstaller.loadall(harness)
    return registry, #registry:all()
end

-- read the slash commands again
--
-- the builtin ones and the markdown files are read again; the ones a plugin or
-- an mcp server added at startup are carried across, because the plugins are not
-- loaded again here and a command which vanished on `/reload` would be a worse
-- surprise than one which is a version behind.
--
-- they are told apart by their source: everything which came from a directory
-- carries the name of that directory, @see harness.commands.registry.adddir, so
-- a command with none is one which was handed to the registry at runtime. that
-- also keeps a markdown command which has been deleted from coming back — it
-- has a source, so it is not carried
--
function commands(harness)
    local existing = harness:service("commands")
    local registry = commandregistry.new()
    registry:load_builtin()
    for _, dir in ipairs(commandregistry.defaultdirs(harness:config(), harness:rootdir())) do
        registry:adddir(dir, sourcename(dir, harness:rootdir()))
    end
    for _, command in ipairs(existing and existing:all() or {}) do
        local athand = command.source == nil or command.source == "plugin"
        if athand and command.source ~= "skill" and not registry:get(command.name) then
            registry:add(command)
        end
    end
    harness:service("commands", registry)
    skillcommands(harness, registry)
    return registry, #registry:all()
end

-- one command per skill, so a skill can be opened by hand
--
-- the model decides on its own whether a skill is worth loading, and it does not
-- always decide to: the listing says what each one is for, and a skill which
-- sounds close enough is still one the model has to choose to open. `/skill:x`
-- takes the choice away from it
--
function skillcommands(harness, registry)
    registry = registry or harness:service("commands")
    local skillregistry = harness:service("skills")
    if not registry or not skillregistry then
        return
    end

    -- the skills which went away take their commands with them, and a skill
    -- switched off in the settings is one which went away
    for _, command in ipairs(registry:all()) do
        if command.source == "skill" then
            registry:remove(command.name)
        end
    end
    for _, skill in ipairs(skillregistry:enabled(harness:config())) do
        registry:add({
            name = "skill:" .. skill.name,
            description = skill.description or "",
            source = "skill",
            skill = skill.name,
            run = function (app, args)
                return _useskill(skill.name, args)
            end
        })
    end
end

-- what `/skill:x <task>` sends
function _useskill(name, args)
    local task = (args or ""):trim()
    if task == "" then
        return {kind = "message", text = string.format(
            "say what it is for: `/skill:%s <what you want done>`.\n"
            .. "loading a skill on its own costs a turn and answers nothing.", name)}
    end
    return {kind = "prompt", text = string.format(
        "Load the `%s` skill with `use_skill` before you do anything else, then follow it "
        .. "for this:\n\n%s", name, task)}
end

-- read all of it again
--
-- @return  {config = true, skills = 54, agents = 3, commands = 21}
--
function everything(harness)
    settings(harness)
    -- the subagents first: one of them may be a bundle which ships skills, and
    -- the skill registry is built from what the agents brought
    local _, agentcount = agents(harness)
    local _, skillcount = skills(harness)
    local _, commandcount = commands(harness)
    harness:emit("harness/reloaded", harness)
    return {config = true, skills = skillcount, agents = agentcount, commands = commandcount}
end
