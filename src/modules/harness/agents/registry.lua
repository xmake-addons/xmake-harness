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
-- the agent registry
--
-- an agent is a markdown file with the frontmatter, it describes a specialized
-- worker which the main agent can delegate to with the `run_agent` tool:
--
--   ---
--   name: explorer
--   description: Search the codebase and report the findings
--   tools: read_file, glob_files, search_text
--   model: small
--   ---
--
--   the system prompt of this agent ..
--

-- imports
import("core.base.object")
import("harness.util.frontmatter")
import("harness.config.config")

-- define the registry class
local registry = registry or object {_init = {"_agents", "_order", "_dirs", "_broken", "_shadowed"}}

-- create a new registry
function new()
    return registry {{}, {}, {}, {}, {}}
end

-- get the default agent directories
function defaultdirs(harnessconfig, rootdir)
    local dirs = {}
    table.insert(dirs, path.join(os.scriptdir(), "..", "assets", "agents"))
    table.insert(dirs, path.join(config.homedir(), "agents"))
    -- the project subagents, once the project is trusted, @see harness.config.trust
    if harnessconfig._trusted ~= false then
        table.insert(dirs, path.join(rootdir or os.curdir(), ".xmake-harness", "agents"))
    end
    for _, dir in ipairs((harnessconfig.agents or {}).dirs or {}) do
        table.insert(dirs, dir)
    end
    return dirs
end

-- add an agent directory
--
-- @param opt   {exclude = {".. the installed packs .."}}
--
function registry:adddir(dir, source, opt)
    if not os.isdir(dir) then
        return self
    end
    -- the packs live inside the user directory, so a plain scan finds them
    -- twice: once as themselves and once as loose files with the wrong source
    for _, excluded in ipairs((opt or {}).exclude or {}) do
        if dir == excluded or dir:startswith(excluded .. "/") then
            return self
        end
    end
    -- which directories it was built from, so that whoever rebuilds it can
    -- build the same one: a plugin's agents come from a directory nothing else
    -- knows about, @see harness.core.reload
    if not table.contains(self._dirs, dir) then
        table.insert(self._dirs, dir)
    end
    for _, filepath in ipairs(os.files(path.join(dir, "*.md"))) do
        self:addfile(filepath, source)
    end

    -- an agent may also be a directory of its own, which is how one which
    -- brings more than a prompt is written: `<name>/AGENT.md` beside the
    -- skills, the notes and whatever else it needs. adding a second builtin
    -- agent is then a directory and not an edit, @see harness.agents.bundle
    for _, filepath in ipairs(os.files(path.join(dir, "*", "AGENT.md"))) do
        self:addfile(filepath, source)
    end
    return self
end

-- the directories an agent bundle keeps its own skills in
--
-- an agent which needs a skill to do its work ships it, rather than asking the
-- user to install one: `<agent>/skills/<name>/SKILL.md`
--
function registry:skilldirs()
    local results = {}
    for _, agent in ipairs(self:all()) do
        local dir = agent.dir and path.join(agent.dir, "skills") or nil
        if dir and os.isdir(dir) and not table.contains(results, dir) then
            table.insert(results, dir)
        end
    end
    return results
end

-- the directories it was built from
function registry:dirs()
    return self._dirs
end

-- add one agent file
function registry:addfile(filepath, source)
    local content = io.readfile(filepath) or ""
    local attributes, body = frontmatter.parse(content)

    -- `<name>/AGENT.md` is named after its directory, a loose `<name>.md`
    -- after itself
    local name = attributes.name
    if not name then
        name = path.basename(filepath)
        if name == "AGENT" then
            name = path.filename(path.directory(filepath))
        end
    end

    -- an agent which cannot be used is reported and not skipped
    --
    -- skipping it leaves the file on disk holding a name, and every surface
    -- showing nothing: somebody who wrote a broken one sees it simply not
    -- appear, with no reason and nothing to delete
    local why = _broken(attributes, body, name)
    if why then
        table.insert(self._broken, {name = name, filepath = filepath,
                                    source = source or "user", why = why})
        return self
    end

    -- the first of a name wins, and the rest are said rather than dropped: a
    -- pack which brought a name somebody's own agent already has has silently
    -- contributed nothing, @see registry:shadowed
    local taken = self._agents[name]
    if taken then
        table.insert(self._shadowed, {name = name, filepath = filepath,
                                      source = source or "user",
                                      takenby = taken.source, takenfrom = taken.filepath})
        return self
    end
    self:add({
        name = name,
        dir = path.directory(filepath),
        description = attributes.description or "",
        tools = frontmatter.list(attributes.tools),
        model = attributes.model,
        permission = attributes.permission,
        maxsteps = tonumber(attributes.maxsteps),
        prompt = body,
        source = source or "user",
        filepath = filepath
    })
    return self
end

-- why this file cannot be used as an agent, if it cannot
function _broken(attributes, body, name)
    if type(attributes) ~= "table" then
        return "its frontmatter could not be read"
    end
    if (attributes.description or "") == "" then
        return "it has no description, so nothing can decide to use it"
    end
    if (body or ""):trim() == "" then
        return "it has no instructions in it"
    end
    if not tostring(name or ""):match("^[%w][%w_%-%.]*$") then
        return string.format("`%s` is not a usable name", tostring(name))
    end
    return nil
end

-- the files which look like agents and cannot be used, with the reason
function registry:broken()
    return self._broken
end

-- the agents which lost their name to another
function registry:shadowed()
    return self._shadowed
end

-- add an agent definition
function registry:add(definition)
    assert(definition and definition.name, "harness: invalid agent definition!")
    if not self._agents[definition.name] then
        table.insert(self._order, definition.name)
    end
    self._agents[definition.name] = definition
    return self
end

-- get an agent by name
function registry:get(name)
    return self._agents[name]
end

-- get all the agents
function registry:all()
    local results = {}
    for _, name in ipairs(self._order) do
        table.insert(results, self._agents[name])
    end
    return results
end

-- get the enabled agents
function registry:enabled(harnessconfig)
    local disabled = (harnessconfig.agents or {}).disabled or {}
    local results = {}
    for _, agent in ipairs(self:all()) do
        if not table.contains(disabled, agent.name) then
            table.insert(results, agent)
        end
    end
    return results
end
