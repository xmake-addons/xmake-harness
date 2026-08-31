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
local registry = registry or object {_init = {"_agents", "_order", "_dirs"}}

-- create a new registry
function new()
    return registry {{}, {}, {}}
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
function registry:adddir(dir, source)
    if not os.isdir(dir) then
        return self
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
    return self
end

-- the directories it was built from
function registry:dirs()
    return self._dirs
end

-- add one agent file
function registry:addfile(filepath, source)
    local content = io.readfile(filepath) or ""
    local attributes, body = frontmatter.parse(content)
    local name = attributes.name or path.basename(filepath)
    self:add({
        name = name,
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
