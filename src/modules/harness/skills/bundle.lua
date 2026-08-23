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
-- the skill bundle layouts
--
-- a skill is always a markdown file with a name and a description in its
-- frontmatter. what differs between the tools which produce them is only where
-- those files sit, so instead of demanding one layout we recognise the ones
-- which exist:
--
--   skills           <root>/skills/<name>/SKILL.md      the xmake-skills packs
--   flat             <root>/<name>/SKILL.md             a bare pack of skills
--   claude-plugin    .claude-plugin/plugin.json + skills/<name>/SKILL.md
--   claude-market    .claude-plugin/marketplace.json + plugins/<p>/skills/..
--   dsh              <root>/<name>.md                   one file is one skill
--
-- the deepseek harness (dsh) also reads a project's `.dsh/skills` and
-- `.agents/skills`, so a repository shaped like a project works too.
--
-- a flat markdown file is only a skill when its frontmatter carries both a name
-- and a description. that is what dsh requires, and it is what keeps a README
-- from becoming a skill.
--

-- imports
import("core.base.json")
import("harness.util.frontmatter")

-- the directories a bundle may keep its skills in, relative to its root
local SUBDIRS = {"skills", ".agents/skills", ".dsh/skills"}

-- the markdown files which are never a skill
local NOTSKILLS = {readme = true, license = true, changelog = true,
                   contributing = true, agents = true, claude = true}

-- detect the layout of the given directory
--
-- @return  the kind, and what the manifest says, e.g.
--          "claude-plugin", {name = "code-review", description = ".."}
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
    if os.isdir(path.join(dir, "skills")) then
        return "skills", {}
    end
    if #os.files(path.join(dir, "*/SKILL.md")) > 0 then
        return "flat", {}
    end
    if #_flatfiles(dir) > 0 then
        return "dsh", {}
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

-- the directories which hold the skills of this bundle
--
-- a marketplace is a directory of plugins, so every one of them contributes its
-- own; everything else has at most a handful
--
function roots(dir)
    local kind, manifest = detect(dir)
    if kind == "claude-market" then
        return _marketroots(dir, manifest)
    end

    local results = {}
    for _, subdir in ipairs(SUBDIRS) do
        local root = path.join(dir, subdir)
        if os.isdir(root) then
            table.insert(results, root)
        end
    end
    if #results == 0 or kind == "dsh" or kind == "flat" then
        table.insert(results, dir)
    end
    return results
end

-- the skill directories of every plugin in a marketplace
--
-- a plugin is either a directory in the repository or, quite often, the
-- repository itself: `xmake-skills` is one marketplace whose single plugin has
-- `"source": "./"`. the manifest may also point at plugins which live in
-- another repository; only what is on disk can be loaded, the rest is somebody
-- else's clone
--
function _marketroots(dir, manifest)
    local results = {}
    for _, plugindir in ipairs(_plugindirs(dir, manifest)) do
        local found = false
        for _, subdir in ipairs(SUBDIRS) do
            local root = path.join(plugindir, subdir)
            if os.isdir(root) then
                found = true
                if not table.contains(results, root) then
                    table.insert(results, root)
                end
            end
        end
        -- only when the plugin keeps its skills loose in its own directory, a
        -- plugin whose `skills/` was already taken must not be taken again:
        -- the patterns reach deep enough to find the very same files twice
        if not found and #files(plugindir) > 0 and not table.contains(results, plugindir) then
            table.insert(results, plugindir)
        end
    end
    return results
end

-- the plugin directories of a marketplace which are on disk
function _plugindirs(dir, manifest)
    local results = {}
    for _, plugin in ipairs((manifest or {}).plugins or {}) do
        -- a string source is a path inside this repository, a table is a
        -- reference to another one
        local source = type(plugin) == "table" and plugin.source or nil
        if type(source) == "string" then
            local plugindir = path.normalize(path.join(dir, source))
            if os.isdir(plugindir) and not table.contains(results, plugindir) then
                table.insert(results, plugindir)
            end
        end
    end
    for _, group in ipairs({"plugins", "external_plugins"}) do
        for _, plugindir in ipairs(os.dirs(path.join(dir, group, "*"))) do
            if not table.contains(results, plugindir) then
                table.insert(results, plugindir)
            end
        end
    end
    return results
end

-- every skill file of the given bundle
function skillfiles(dir)
    local results = {}
    local seen = {}
    for _, root in ipairs(roots(dir)) do
        for _, filepath in ipairs(files(root)) do
            -- the roots may nest, and the patterns reach three levels down, so
            -- the same file can be found from two of them
            local key = path.normalize(filepath)
            if not seen[key] then
                seen[key] = true
                table.insert(results, filepath)
            end
        end
    end
    return results
end

-- the skill files directly inside one skill root
--
-- both shapes live side by side: a directory which holds a SKILL.md, and a
-- markdown file which is the skill itself
--
function files(root)
    local results = {}
    for _, pattern in ipairs({"*/SKILL.md", "*/*/SKILL.md", "*/*/*/SKILL.md", "SKILL.md"}) do
        for _, filepath in ipairs(os.files(path.join(root, pattern))) do
            table.insert(results, filepath)
        end
    end
    for _, filepath in ipairs(_flatfiles(root)) do
        table.insert(results, filepath)
    end

    -- sorted, because two skills may want the same name and the first one keeps
    -- it. leaving that to the order the filesystem happens to hand back would
    -- make the winner differ between machines, and a skill which appears on one
    -- developer's setup and not another's is the worst kind of bug
    table.sort(results)
    return results
end

-- the flat markdown files of the given directory which are skills
function _flatfiles(dir)
    local results = {}
    for _, filepath in ipairs(os.files(path.join(dir, "*.md"))) do
        if isskillfile(filepath) then
            table.insert(results, filepath)
        end
    end
    return results
end

-- is this markdown file a skill?
--
-- a name and a description are what makes one: without them there is nothing to
-- put in the system prompt and nothing for the model to ask for
--
function isskillfile(filepath)
    if NOTSKILLS[path.basename(filepath):lower()] then
        return false
    end
    local attributes = frontmatter.parse(io.readfile(filepath) or "")
    return attributes ~= nil and attributes.name ~= nil and attributes.description ~= nil
end

-- describe the bundle for the user
function describe(dir)
    local kind, manifest = detect(dir)
    local titles = {
        ["claude-market"] = "claude marketplace",
        ["claude-plugin"] = "claude plugin",
        ["dsh"] = "dsh skills",
        ["skills"] = "skill pack",
        ["flat"] = "skill pack",
        ["unknown"] = "unknown layout"
    }
    local title = titles[kind] or kind
    if manifest.name then
        title = string.format("%s `%s`", title, manifest.name)
    end
    return title, kind
end
