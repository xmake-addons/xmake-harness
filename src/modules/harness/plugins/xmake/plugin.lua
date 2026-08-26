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
-- @file        plugin.lua
--

--
-- the xmake enhancement plugin
--
-- the harness itself knows nothing about xmake, this plugin adds everything:
--
--   tools/       the xmake tools: create, configure, build, run, test, show, lua, xrepo
--   /xmake       the command line itself, in your terminal, without tokens
--   agents/      the `xmake-builder` subagent
--   prompt       the project facts and the rules which matter in an xmake.lua
--   skills       the xmake skill pack from https://github.com/xmake-io/xmake-skills,
--                registered as a source and fetched on demand, never bundled
--
-- a project which does not use xmake never sees any of it.
--

-- imports
import("harness.util.util")
import("harness.config.config")
import("harness.skills.installer")
import("harness.skills.updates")
import("harness.plugins.xmake.docs")
import("harness.plugins.xmake.prompt", {alias = "xmakeprompt"})

-- the tools of this plugin, one module each
local TOOLS = {"xmake_create", "xmake_config", "xmake_build", "xmake_run", "xmake_test",
               "xmake_show", "xmake_lua", "xrepo", "xmake_docs"}

-- describe the plugin
function define()
    return {
        name = "xmake",
        description = "The xmake build enhancement: the tools, the skills, the docs and the builder agent."
    }
end

-- apply the plugin to the harness
function apply(harness, definition)
    local settings = (harness:config().plugins or {}).xmake or {}
    if settings.enabled == false then
        return
    end
    _addtools(harness, definition)
    _addcommands(harness)
    _addskills(harness, settings)
    _adddocs(harness, settings)
    harness:service("agents"):adddir(path.join(definition.dir, "agents"), "plugin:xmake")
    xmakeprompt.apply(harness, {hasskills = _hasskills(settings)})
end

-- register the tools
function _addtools(harness, definition)
    local tools = harness:service("tools")
    for _, name in ipairs(TOOLS) do
        local module = import("tools." .. name, {rootdir = definition.dir, anonymous = true})
        local tool = module.define()
        tool.run = tool.run or module.run
        tools:add(tool)
    end
end

-- register the `/xmake` command
--
-- it is the plugin's, not the harness': a project without an xmake.lua has no
-- use for it, and the same seam gives cmake its own `/cmake` one day
--
function _addcommands(harness)
    local module = import("harness.commands.builtin.xmakecli", {anonymous = true})
    harness:service("commands"):add(module.command())
end

-- register the documentation command
--
-- the documentation is maintained in its own repository too, so it follows the
-- same rule as the skills: fetched on demand, never bundled
--
function _adddocs(harness, settings)
    local module = import("harness.commands.builtin.xmakedocs", {anonymous = true})
    harness:service("commands"):add(module.command())

    -- the documentation is a repository too, so it goes stale the same way and
    -- is watched the same way, @see harness.skills.updates
    local docsdir = docs.find(harness:config())
    if docsdir and os.isdir(path.join(docsdir, ".git")) then
        updates.watch(harness, {name = "xmake-docs", dir = docsdir, command = "/xmake-docs update"})
    end
    if not docs.isavailable(harness:config()) and os.isfile(path.join(harness:rootdir(), "xmake.lua")) then
        harness:service("notices", table.join(harness:service("notices") or {},
            {"the xmake documentation is not installed, run `/xmake-docs` to look the apis up"}))
    end
end

-- register the xmake skill pack
--
-- it is maintained in its own repository and it is NOT bundled here: the user
-- installs it with `/skills install xmake` and updates it with `/skills update`
--
function _addskills(harness, settings)
    installer.register(harness, {
        name = "xmake-skills",
        url = "https://github.com/xmake-io/xmake-skills.git",
        description = "The xmake build skills: the packages, the rules, the toolchains, the packaging, .."
    })
    installer.register(harness, {
        name = "xmake",
        url = "https://github.com/xmake-io/xmake-skills.git",
        packname = "xmake-skills",
        description = "The xmake build skills (an alias of xmake-skills)"
    })

    -- an existing claude code checkout is reused as is, so one copy serves both
    local skillsdir = _skillsdir(settings)
    if skillsdir then
        harness:service("skills"):adddir(skillsdir, "plugin:xmake")
    end

    -- tell the user once that the skills are available but not installed
    if not _hasskills(settings) and os.isfile(path.join(harness:rootdir(), "xmake.lua")) then
        harness:service("notices", table.join(harness:service("notices") or {},
            {"the xmake skills are not installed yet, run `/skills install xmake` to get the build recipes"}))
    end
end

-- are the xmake skills available?
function _hasskills(settings)
    return _skillsdir(settings) ~= nil or installer.isinstalled("xmake-skills")
end

-- find an existing xmake skills checkout
function _skillsdir(settings)
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")

    -- @note a nil in the middle of a table constructor truncates its array
    -- part, the candidates are collected one by one
    local candidates = {}
    table.insert(candidates, settings.skillsdir)
    table.insert(candidates, path.join(config.homedir(), "skills", "xmake-skills", "skills"))
    if home then
        table.insert(candidates, path.join(home, ".claude", "xmake-skills", "skills"))
    end

    for _, dir in ipairs(candidates) do
        if os.isdir(dir) then
            return dir
        end
    end
end
