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
-- @file        bundle.lua
--

--
-- where a pack keeps its subagents
--
-- an agent is a markdown file whose frontmatter carries a name and a
-- description, and every tool which produces them puts them somewhere slightly
-- different. rather than demand one layout we read the ones which exist:
--
--   agents         <root>/agents/<name>.md          the usual pack
--   claude         <root>/.claude/agents/<name>.md  a claude code project
--   dsh            <root>/.agents/<name>.md         the deepseek harness
--   flat           <root>/<name>.md                 a bare directory of them
--   claude-plugin  .claude-plugin/plugin.json + agents/
--   claude-market  .claude-plugin/marketplace.json + plugins/<p>/agents/
--
-- so a repository shaped like somebody else's project works as a pack, which is
-- the point: the agents people already have are the agents worth having.
--

-- imports
import("core.base.json")
import("harness.util.frontmatter")

-- the directories a pack may keep its agents in, relative to its root
local SUBDIRS = {"agents", ".claude/agents", ".agents/agents", ".agents", ".dsh/agents"}

-- the markdown files which are never an agent
local NOTAGENTS = {readme = true, license = true, changelog = true,
                   contributing = true, agents = true, claude = true, skill = true}

-- what shape is this directory?
--
-- @return  the layout, and what the manifest says
--
function detect(dir)
    local manifest = _manifest(dir, "marketplace.json")
    if manifest then
        return "claude-market", manifest
    end
    manifest = _manifest(dir, "plugin.json")
    if manifest then
        return "claude-plugin", manifest
    end
    for _, subdir in ipairs(SUBDIRS) do
        if os.isdir(path.join(dir, subdir)) then
            return subdir == "agents" and "agents" or "dsh", {}
        end
    end
    if #_flatfiles(dir) > 0 then
        return "flat", {}
    end
    return "unknown", {}
end

-- read a `.claude-plugin/<name>` manifest
function _manifest(dir, name)
    local filepath = path.join(dir, ".claude-plugin", name)
    if not os.isfile(filepath) then
        return nil
    end
    local manifest = try { function () return json.decode(io.readfile(filepath)) end }
    return type(manifest) == "table" and manifest or {}
end

-- the directories which hold the agents of this pack
function roots(dir)
    local layout, manifest = detect(dir)
    if layout == "claude-market" then
        return _marketroots(dir, manifest)
    end

    local results = {}
    for _, subdir in ipairs(SUBDIRS) do
        local root = path.join(dir, subdir)
        if os.isdir(root) then
            table.insert(results, root)
        end
    end
    if #results == 0 then
        table.insert(results, dir)
    end
    return results
end

-- the agent directories of every plugin in a marketplace
--
-- a plugin is either a directory in the repository or, often, the repository
-- itself. only what is on disk can be loaded; a manifest which points at
-- somebody else's clone is somebody else's clone
--
function _marketroots(dir, manifest)
    local results = {}
    local seen = {}
    local function consider(root)
        for _, subdir in ipairs(SUBDIRS) do
            local one = path.join(root, subdir)
            if os.isdir(one) and not seen[one] then
                seen[one] = true
                table.insert(results, one)
            end
        end
    end
    for _, plugin in ipairs((manifest or {}).plugins or {}) do
        local source = type(plugin) == "table" and plugin.source or nil
        if type(source) == "string" then
            consider(path.normalize(path.join(dir, source)))
        end
    end
    if #results == 0 then
        consider(dir)
        for _, one in ipairs(os.dirs(path.join(dir, "plugins", "*"))) do
            consider(one)
        end
    end
    return results
end

-- the markdown files of a directory which are agents
function _flatfiles(dir)
    local results = {}
    for _, filepath in ipairs(os.files(path.join(dir, "*.md"))) do
        if isagent(filepath) then
            table.insert(results, filepath)
        end
    end
    return results
end

-- is this markdown file an agent?
--
-- a `README.md` in a directory of agents is a readme, and an agent without a
-- description is one nothing can decide to use
--
function isagent(filepath)
    local name = path.basename(filepath):lower()
    if NOTAGENTS[name] then
        return false
    end
    local attributes = frontmatter.parse(io.readfile(filepath) or "")
    return type(attributes) == "table" and (attributes.description or "") ~= ""
end

-- every agent file of a pack
function agentfiles(packdir)
    local results = {}
    local seen = {}
    for _, root in ipairs(roots(packdir)) do
        for _, filepath in ipairs(os.files(path.join(root, "*.md"))) do
            if not seen[filepath] and isagent(filepath) then
                seen[filepath] = true
                table.insert(results, filepath)
            end
        end
    end
    return results
end

-- what a pack calls itself, and how it is laid out
function describe(packdir)
    local layout, manifest = detect(packdir)
    local title = (manifest or {}).name or (manifest or {}).description
    return title or path.filename(packdir), layout
end
