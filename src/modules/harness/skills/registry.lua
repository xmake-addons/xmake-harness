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
-- @file        registry.lua
--

--
-- the skill registry
--
-- a skill is a directory with a `SKILL.md` file, the frontmatter declares its
-- name and when it should be used, and the body holds the instructions:
--
--   skills/
--     xmake-packages/
--       SKILL.md
--       reference.md      (the optional extra files the skill can point to)
--
-- only the name and the description of every skill are put into the system
-- prompt, the body is loaded on demand by the `use_skill` tool, so a large
-- skill library costs almost no context.
--

-- imports
import("core.base.object")
import("harness.util.frontmatter")
import("harness.skills.bundle")
import("harness.config.config")

-- define the registry class
local registry = registry or object {_init = {"_skills", "_order", "_dirs", "_shadowed"}}

-- create a new registry
function new()
    return registry {{}, {}, {}, {}}
end

-- get the default skill directories
function defaultdirs(harnessconfig, rootdir)
    local dirs = {}

    -- the builtin skills of the harness itself
    table.insert(dirs, path.join(os.scriptdir(), "..", "assets", "skills"))

    -- the user skills, e.g. ~/.xmake/harness/skills
    table.insert(dirs, path.join(config.homedir(), "skills"))

    -- the project skills, e.g. <project>/.xmake-harness/skills
    --
    -- a skill is instructions the model follows, so it is only read once the
    -- project is trusted, @see harness.config.trust
    if harnessconfig._trusted ~= false then
        table.insert(dirs, path.join(rootdir or os.curdir(), ".xmake-harness", "skills"))
    end

    -- the configured directories
    for _, dir in ipairs((harnessconfig.skills or {}).dirs or {}) do
        table.insert(dirs, dir)
    end
    return dirs
end

-- add a skill directory and load all the skills inside it
--
-- @param dir       the directory which contains the skill directories
-- @param source    the source name, e.g. "user", "project", "plugin:xmake"
--
function registry:adddir(dir, source, opt)
    dir = path.normalize(dir)
    if not os.isdir(dir) or table.contains(self._dirs, dir) then
        return self
    end
    table.insert(self._dirs, dir)
    local exclude = (opt or {}).exclude
    for _, skillfile in ipairs(_findskillfiles(dir)) do
        if not _isinside(skillfile, exclude) then
            self:addfile(skillfile, source)
        end
    end
    return self
end

-- is this file inside one of the given directories?
--
-- the installed packs live inside the user skills directory, and they are
-- loaded on their own so that each one keeps its own name as the source. the
-- plain scan must leave them alone or it would claim them first and report
-- somebody else's skills as the user's
--
function _isinside(filepath, dirs)
    for _, dir in ipairs(dirs or {}) do
        if path.normalize(filepath):startswith(path.normalize(dir) .. path.sep()) then
            return true
        end
    end
    return false
end

-- find all the skill files under the given directory
--
-- both shapes count: a directory which holds a `SKILL.md`, and a lone markdown
-- file which is the skill itself, @see harness.skills.bundle
--
function _findskillfiles(dir)
    return bundle.files(dir)
end

-- add one skill file
function registry:addfile(skillfile, source)
    if not os.isfile(skillfile) then
        return self
    end
    local content = io.readfile(skillfile) or ""
    local attributes, body = frontmatter.parse(content)
    local name = attributes.name or _defaultname(skillfile)
    -- the first one with a name keeps it
    --
    -- a pack which brings together the skills of many plugins, e.g. a claude
    -- marketplace, will have two of them called `code-review` sooner or later.
    -- dropping the second is the right call — but dropping it silently is not,
    -- because the pack then reports more skills than it contributed and nobody
    -- can tell which ones went missing, @see registry:shadowed()
    --
    local taken = self._skills[name]
    if taken then
        table.insert(self._shadowed, {name = name, filepath = skillfile,
                                      source = source or "user", takenby = taken.source,
                                      takenfrom = taken.filepath})
        return self
    end
    local skill = {
        name = name,
        description = attributes.description or "",
        dir = path.directory(skillfile),
        filepath = skillfile,
        source = source or "user",
        attributes = attributes,
        _body = body
    }
    self._skills[name] = skill
    table.insert(self._order, name)
    return self
end

-- the name of a skill whose frontmatter does not give one
--
-- `<name>/SKILL.md` is named after its directory, a flat `<name>.md` after
-- itself, @see harness.skills.bundle
--
function _defaultname(skillfile)
    if path.filename(skillfile):lower() == "skill.md" then
        return path.filename(path.directory(skillfile))
    end
    return path.basename(skillfile)
end

-- the skills which could not be loaded because their name was taken
--
-- @return  {{name = "code-review", filepath = "..", source = "pack:a",
--            takenby = "pack:b", takenfrom = ".."}}
--
function registry:shadowed()
    return self._shadowed
end

-- get a skill by name
function registry:get(name)
    return self._skills[name]
end

-- get all the skills
function registry:all()
    local results = {}
    for _, name in ipairs(self._order) do
        table.insert(results, self._skills[name])
    end
    table.sort(results, function (a, b) return a.name < b.name end)
    return results
end

-- get the enabled skills of the given configuration
function registry:enabled(harnessconfig)
    local settings = harnessconfig.skills or {}
    local results = {}
    for _, skill in ipairs(self:all()) do
        local ok = true
        if settings.enabled and #settings.enabled > 0 then
            ok = table.contains(settings.enabled, skill.name)
        end
        if settings.disabled and table.contains(settings.disabled, skill.name) then
            ok = false
        end
        if ok then
            table.insert(results, skill)
        end
    end
    return results
end

-- get the content of the given skill
--
-- the relative links inside the skill are rewritten to the absolute paths, so
-- the agent can read the extra files of the skill directly
--
function registry:content(skill)
    local body = skill._body
    if not body then
        local content = io.readfile(skill.filepath) or ""
        local _, parsed = frontmatter.parse(content)
        body = parsed
        skill._body = body
    end
    local header = string.format("(the skill files are in %s)\n\n", skill.dir)
    return header .. body
end

-- get the directories which are scanned
function registry:dirs()
    return self._dirs
end
