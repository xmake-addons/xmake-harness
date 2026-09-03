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
-- @file        agents.lua
--

--
-- the agent commands: /agents [install|remove|enable|disable]
--
-- a subagent is a markdown file, so a pack of them is a directory of markdown,
-- and the same machinery which installs the skill packs installs these,
-- @see harness.packs.packs. nothing is bundled: the packs live in their own
-- repositories and are fetched when somebody asks.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.core.reload", {alias = "reloader"})
import("harness.agents.installer", {alias = "installer"})

-- the commands of this group
function commands()
    return {
        {name = "agents", description = "List the subagents, or install, update and remove packs of them",
         run = _agents}
    }
end

-- /agents [install|update|remove|enable|disable] [what]
function _agents(app, args)
    local action, rest = (args or ""):trim():match("^(%S*)%s*(.*)$")
    if action == "install" or action == "add" then
        return _install(app, rest)
    elseif action == "update" then
        return _update(app, rest)
    elseif action == "remove" or action == "uninstall" then
        return _remove(app, rest)
    elseif action == "enable" then
        return _enable(app, rest, true)
    elseif action == "disable" then
        return _enable(app, rest, false)
    elseif action ~= "" then
        return {kind = "message", iserror = true,
                text = "/agents [install|update|remove|enable|disable] [what]"}
    end
    return _list(app)
end

-- /agents
function _list(app)
    local registry = app.harness:service("agents")
    local all = registry:all()
    local disabled = ((app.harness:config().agents or {}).disabled) or {}

    local lines = {}
    table.insert(lines, string.format("%d subagent%s:", #all, #all == 1 and "" or "s"))
    table.insert(lines, "")
    for _, agent in ipairs(all) do
        local off = table.contains(disabled, agent.name)
        table.insert(lines, string.format("  %s %s %s %s",
            off and theme.styled("dim", "○") or theme.styled("added", "●"),
            text.pad(agent.name, 22),
            text.pad("[" .. (agent.source or "user") .. "]", 18),
            text.truncate(text.oneline(agent.description or ""), 60)))
    end

    -- the ones which are on disk and cannot be used
    --
    -- a file skipped in silence still holds its name, and somebody who wrote a
    -- broken agent sees it simply not appear, with nothing to fix and nothing
    -- to delete
    local broken = registry.broken and registry:broken() or {}
    if #broken > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("%d cannot be used:", #broken))
        for _, one in ipairs(broken) do
            table.insert(lines, string.format("  %s %s",
                theme.styled("error", text.pad(one.name, 22)), one.why))
            table.insert(lines, string.format("    %s", one.filepath))
        end
    end

    local shadowed = registry.shadowed and registry:shadowed() or {}
    if #shadowed > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("%d kept a name somebody else already had:", #shadowed))
        for _, one in ipairs(shadowed) do
            table.insert(lines, string.format("  %s from %s, the one in use is %s's",
                text.pad(one.name, 22), one.source, one.takenby))
        end
    end

    local packs = installer.installed()
    table.insert(lines, "")
    if #packs > 0 then
        table.insert(lines, string.format("%d installed pack%s in %s:",
                                          #packs, #packs == 1 and "" or "s", installer.dir()))
        for _, pack in ipairs(packs) do
            table.insert(lines, string.format("  %s %d agent%s · %s",
                text.pad(pack.name, 22), pack.agents, pack.agents == 1 and "" or "s",
                pack.layout))
        end
        table.insert(lines, "")
    end

    local available = {}
    for name, source in pairs(installer.sources(app.harness)) do
        if not installer.isinstalled(source.packname or source.name or name) then
            table.insert(available, name)
        end
    end
    table.sort(available)
    if #available > 0 then
        table.insert(lines, string.format("available: %s", table.concat(available, ", ")))
    end
    table.insert(lines, string.format("your own go in %s as `<name>.md`, "
        .. "or `<name>/AGENT.md` with its skills beside it.", installer.dir()))
    table.insert(lines, "`/agents install <name|github:user/repo|dir|pack.zip>` for a pack of them.")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /agents install <what>
function _install(app, spec)
    local source, errors = installer.resolve(app.harness, spec)
    if not source then
        return {kind = "message", text = errors, iserror = true}
    end

    -- a fetch is minutes of network that nothing here waits on, so it goes to
    -- the background exactly as a skill pack does, @see harness.shell.jobs
    local store = app.harness:service("jobs")
    if store and source.url then
        local job, joberrors = installer.fetch(source, {
            jobs = store,
            context = {harness = app.harness, config = app.harness:config(),
                       cwd = app.harness:rootdir()},
            onfinish = function (pack)
                if pack then
                    reloader.agents(app.harness)
                end
            end})
        if not job then
            return {kind = "message", text = tostring(joberrors), iserror = true}
        end
        return {kind = "message", text = string.format(
            "fetching the subagent pack `%s` in the background (job %s).\n"
            .. "carry on, it will say when it is ready.", source.name, job.id)}
    end

    local pack, installerrors = installer.install(source, {})
    if not pack then
        return {kind = "message", text = tostring(installerrors), iserror = true}
    end
    reloader.agents(app.harness)
    return _installed(app, pack)
end

-- what to say once a pack has landed
function _installed(app, pack)
    if pack.count == 0 then
        return {kind = "message", iserror = true, text = string.format(
            "`%s` holds no subagent: %s.\n"
            .. "an agent is a markdown file whose frontmatter has a name and a description, "
            .. "in `agents/`, `.claude/agents/` or the root of the pack.", pack.name, pack.title)}
    end
    return {kind = "message", text = string.format(
        "the subagent pack `%s` is ready: %d agent%s from %s (%s)\n%d subagents in total",
        pack.name, pack.count, pack.count == 1 and "" or "s", pack.dir, pack.layout,
        #app.harness:service("agents"):all())}
end

-- /agents update [name]
function _update(app, name)
    local packs = installer.installed()
    if #packs == 0 then
        return {kind = "message", text = "no subagent pack is installed."}
    end
    local updated = {}
    for _, pack in ipairs(packs) do
        if (name or "") == "" or pack.name == name then
            if pack.url then
                local source = {name = pack.name, url = pack.url}
                local one = installer.install(source, {})
                table.insert(updated, string.format("  %s: %s", pack.name,
                    one and string.format("%d agents", one.count) or "could not be updated"))
            else
                table.insert(updated, string.format("  %s: it has no remote to update from",
                                                    pack.name))
            end
        end
    end
    if #updated == 0 then
        return {kind = "message", text = string.format("`%s` is not installed.", tostring(name)),
                iserror = true}
    end
    reloader.agents(app.harness)
    return {kind = "message", text = "updated:\n" .. table.concat(updated, "\n")}
end

-- /agents remove <name>
function _remove(app, name)
    if (name or "") == "" then
        return {kind = "message", text = "/agents remove <pack>", iserror = true}
    end
    local ok, errors = installer.remove(name)
    if not ok then
        return {kind = "message", text = tostring(errors), iserror = true}
    end
    reloader.agents(app.harness)
    return {kind = "message", text = string.format("`%s` is removed, %d subagents left.",
        name, #app.harness:service("agents"):all())}
end

-- /agents enable|disable <name>
--
-- it is written to the user configuration and not held here, so a subagent
-- switched off stays switched off, @see harness.agents.registry.enabled
--
function _enable(app, name, enabled)
    if (name or "") == "" then
        return {kind = "message", text = "/agents enable|disable <name>", iserror = true}
    end
    local config = import("harness.config.config", {anonymous = true})
    local harnessconfig = app.harness:config()
    harnessconfig.agents = harnessconfig.agents or {}
    local disabled = harnessconfig.agents.disabled or {}

    local kept = {}
    for _, one in ipairs(disabled) do
        if one ~= name then
            table.insert(kept, one)
        end
    end
    if not enabled then
        table.insert(kept, name)
    end
    harnessconfig.agents.disabled = kept
    config.set("agents.disabled", kept)
    return {kind = "message", text = string.format("`%s` is %s.", name,
                                                   enabled and "enabled" or "disabled")}
end
