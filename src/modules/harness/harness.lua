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
-- @file        harness.lua
--

--
-- the harness bootstrap
--
-- it composes one running harness out of the layers:
--
--   the configuration  ->  the context  ->  the registries  ->  the plugins
--
-- everything above the context is a plugin, including the xmake enhancement,
-- so the harness itself stays generic and a different build system, a different
-- toolchain or a different workflow is added without touching the core.
--

-- imports
import("harness.ui.theme")
import("harness.config.config")
import("harness.config.trust")
import("harness.mcp.mcp")
import("harness.core.context")
import("harness.tools.registry", {alias = "toolregistry"})
import("harness.shell.jobs")
import("harness.skills.installer")
import("harness.agents.installer", {alias = "agentinstaller"})
import("harness.skills.registry", {alias = "skillregistry"})
import("harness.agents.registry", {alias = "agentregistry"})
import("harness.commands.registry", {alias = "commandregistry"})
import("harness.core.reload")

-- bootstrap the harness
--
-- @param opt   the options
--              - rootdir   the project root directory
--              - options   the command line overrides of the configuration
--              - trusted   do we read what this directory tells us to, nil to
--                          decide it here, @see harness.config.trust
--              - ask       what to call when nobody has decided yet
--
-- @return      the harness context
--
function bootstrap(opt)
    opt = opt or {}
    local rootdir = path.normalize(opt.rootdir or os.curdir())

    -- whether this directory is trusted is settled before anything in it is
    -- read, because the project configuration is one of the things it decides
    local trusted = trust.resolve({rootdir = rootdir, override = opt.trusted, ask = opt.ask})
    local harnessconfig = config.load({rootdir = rootdir, options = opt.options,
                                       trusted = trusted})
    theme.load(harnessconfig)

    local harness = context.new(harnessconfig)
    harness:rootdir_set(rootdir)

    -- the tool registry
    --
    -- the builtin tools are native lua and run in process, the mcp servers add
    -- the tools of the third parties to the same registry, @see harness.mcp.mcp
    local tools = toolregistry.new()
    tools:load_builtin((harnessconfig.tools or {}).disabled)
    harness:service("tools", tools)

    -- the skill registry
    --
    -- the builtin/user/project directories first, then the installed skill
    -- packs, which are fetched on demand and never bundled with the harness
    --
    local skills = skillregistry.new()
    local packdirs = installer.packdirs()
    for _, dir in ipairs(skillregistry.defaultdirs(harnessconfig, rootdir)) do
        skills:adddir(dir, _sourcename(dir, rootdir), {exclude = packdirs})
    end
    harness:service("jobs", jobs.new())
    harness:service("skills", skills)
    harness:service("skillsources", {})
    installer.loadall(harness)

    -- the agent registry
    --
    -- the builtin/user/project directories first, then the installed packs,
    -- exactly as the skills do: a pack never takes a name a user's own agent
    -- already has, @see harness.agents.installer
    local agents = agentregistry.new()
    local agentpackdirs = agentinstaller.packdirs()
    for _, dir in ipairs(agentregistry.defaultdirs(harnessconfig, rootdir)) do
        agents:adddir(dir, _sourcename(dir, rootdir), {exclude = agentpackdirs})
    end
    harness:service("agents", agents)
    harness:service("agentsources", {})
    agentinstaller.loadall(harness)

    -- the command registry
    local commands = commandregistry.new()
    commands:load_builtin()
    for _, dir in ipairs(commandregistry.defaultdirs(harnessconfig, rootdir)) do
        commands:adddir(dir, _sourcename(dir, rootdir))
    end
    harness:service("commands", commands)

    -- one slash command per skill, so a skill can be opened by hand rather than
    -- waiting for the model to decide it is worth opening
    reload.skillcommands(harness, commands)

    -- the task list
    harness:service("todos", {})

    -- load the plugins
    harness:service("plugins", _loadplugins(harness, rootdir))

    -- load the mcp servers, they may bring more tools
    mcp.load(harness)

    harness:emit("harness/ready", harness)
    return harness
end

-- get the source name of the given directory
function _sourcename(dir, rootdir)
    if dir:startswith(rootdir) then
        return "project"
    elseif dir:startswith(config.homedir()) then
        return "user"
    end
    return "builtin"
end

-- get the plugin directories
function plugindirs(harnessconfig, rootdir)
    local dirs = {}
    table.insert(dirs, path.join(os.scriptdir(), "plugins"))
    table.insert(dirs, path.join(config.homedir(), "plugins"))
    -- the project plugins are lua which runs in this process, so they wait for
    -- the project to be trusted like everything else does, @see harness.config.trust
    if harnessconfig._trusted ~= false then
        table.insert(dirs, path.join(rootdir or os.curdir(), ".xmake-harness", "plugins"))
    end
    for _, dir in ipairs((harnessconfig.plugins or {}).dirs or {}) do
        table.insert(dirs, dir)
    end
    return dirs
end

-- load all the plugins
function _loadplugins(harness, rootdir)
    local harnessconfig = harness:config()
    local disabled = (harnessconfig.plugins or {}).disabled or {}
    local plugins = {}
    local loaded = {}
    for _, dir in ipairs(plugindirs(harnessconfig, rootdir)) do
        if os.isdir(dir) then
            for _, pluginfile in ipairs(os.files(path.join(dir, "*", "plugin.lua"))) do
                local plugindir = path.directory(pluginfile)
                local name = path.filename(plugindir)
                if not loaded[name] and not table.contains(disabled, name) then
                    loaded[name] = true
                    local plugin = _loadplugin(harness, plugindir, name)
                    if plugin then
                        table.insert(plugins, plugin)
                    end
                end
            end
        end
    end
    return plugins
end

-- load one plugin
function _loadplugin(harness, plugindir, name)
    local module = import("plugin", {rootdir = plugindir, anonymous = true, try = true})
    if not module or not module.apply then
        utils.warning("harness: the plugin(%s) is invalid, it must export apply(harness)", name)
        return nil
    end
    local definition = module.define and module.define() or {}
    definition.name = definition.name or name
    definition.dir = plugindir
    local errors
    local ok = try {
        function ()
            module.apply(harness, definition)
            return true
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if not ok then
        utils.warning("harness: failed to load the plugin(%s): %s", name, tostring(errors))
        return nil
    end
    return definition
end
