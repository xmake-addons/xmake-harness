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
-- the skill commands: /skills [install|update|remove]
--
-- the packs are never bundled with the harness: they are fetched on demand from
-- their own repositories, and the user always confirms the fetch.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.skills.installer")
import("harness.skills.updates")

-- the commands of this group
function commands()
    return {
        {name = "skills", description = "List, install, update or remove the skill packs", run = _skills}
    }
end

-- /skills [install|update|remove] [pack]
function _skills(app, args)
    local action, spec = (args or ""):match("^(%S+)%s*(.*)$")
    if action == "install" or action == "add" then
        return _install(app, spec)
    elseif action == "update" or action == "upgrade" then
        return _update(app, spec)
    elseif action == "remove" or action == "uninstall" then
        return _remove(spec)
    elseif action ~= nil and action ~= "list" then
        return {kind = "message", iserror = true,
                text = string.format("unknown action: %s\nusage: /skills [install|update|remove] <pack>", action)}
    end
    return _list(app)
end

-- list the skills and the packs
function _list(app)
    local registry = app.harness:service("skills")
    local skills = registry:all()
    local lines = {string.format("%d skills are loaded", #skills), ""}

    local bysource = {}
    for _, skill in ipairs(skills) do
        bysource[skill.source] = (bysource[skill.source] or 0) + 1
    end
    for source, count in table.orderpairs(bysource) do
        table.insert(lines, string.format("  %s %d", text.pad(source, 22), count))
    end

    table.insert(lines, "")
    local packs = installer.installed()
    if #packs > 0 then
        table.insert(lines, "the installed packs:")
        for _, pack in ipairs(packs) do
            table.insert(lines, string.format("  %s %d skills  %s  %s%s", text.pad(pack.name, 22),
                pack.skills, text.pad(pack.title or "", 20), pack.url or pack.dir,
                _hasupdates(app, pack.name) and "  · updates upstream" or ""))
        end
    else
        table.insert(lines, "no skill pack is installed.")
    end

    local shadowed = app.harness:service("skills"):shadowed()
    if #shadowed > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("%d skill%s could not be loaded, the name was already taken:",
            #shadowed, #shadowed == 1 and "" or "s"))
        for _, item in ipairs(shadowed) do
            table.insert(lines, string.format("  %s %s", text.pad(item.name, 22), _where(item.filepath)))
            table.insert(lines, string.format("  %s kept: %s", text.pad("", 22), _where(item.takenfrom)))
        end
    end

    local available = _available(app)
    if #available > 0 then
        table.insert(lines, "")
        table.insert(lines, "the available packs:")
        for _, line in ipairs(available) do
            table.insert(lines, line)
        end
    end
    table.insert(lines, "")
    table.insert(lines, "install one with `/skills install <name|github:user/repo|url|dir|archive>`")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- does this pack have something waiting upstream?
--
-- from the cache, @see harness.skills.updates: a listing must not stop to talk
-- to the network
--
function _hasupdates(app, name)
    for _, entry in ipairs(updates.stale(app.harness)) do
        if entry.name == name then
            return true
        end
    end
    return false
end

-- the packs which are registered but not installed
function _available(app)
    local results = {}
    for name, source in table.orderpairs(installer.sources(app.harness)) do
        if not installer.isinstalled(source.packname or name) then
            table.insert(results, string.format("  %s %s", text.pad(name, 22),
                text.truncate(source.description or source.url, 70)))
        end
    end
    return results
end

-- install a pack
function _install(app, spec)
    local source, errors = installer.resolve(app.harness, spec)
    if not source then
        return {kind = "message", text = errors, iserror = true}
    end
    if source.url and not _askfetch(app, source) then
        return {kind = "message", text = "cancelled."}
    end

    local pack, installerrors = installer.install(source, {
        onprogress = function (message)
            app:notify(message)
        end
    })
    if not pack then
        return {kind = "message", text = installerrors, iserror = true}
    end
    for _, root in ipairs(pack.skillsdirs or {pack.skillsdir}) do
        app.harness:service("skills"):adddir(root, "pack:" .. pack.name)
    end
    if pack.skills == 0 then
        return {kind = "message", iserror = true, text = string.format(
            "`%s` holds no skill: %s.\n"
            .. "a skill is a `SKILL.md` in its own directory, or a markdown file whose "
            .. "frontmatter has a name and a description.", pack.name, pack.title)}
    end
    local shadowed = _shadowedby(app, pack.name)
    return {kind = "message", text = string.format(
        "the skill pack `%s` is ready: %d skills from %s (%s)\n%s%d skills are loaded in total",
        pack.name, pack.skills, pack.dir, pack.title,
        shadowed > 0 and string.format("%d of them kept a name somebody else already had, see /skills\n", shadowed) or "",
        #app.harness:service("skills"):all())}
end

-- where a skill file sits, short enough to read
--
-- two skills of the same name usually come from the same pack — two plugins of
-- one marketplace both calling something `configure` — so the pack name says
-- nothing and only the path tells them apart
--
function _where(filepath)
    if not filepath then
        return "(unknown)"
    end
    local packsdir = installer.dir()
    if filepath:startswith(packsdir) then
        return filepath:sub(#packsdir + 2)
    end
    return filepath
end

-- how many of this pack's skills lost their name to somebody else
function _shadowedby(app, packname)
    local count = 0
    for _, item in ipairs(app.harness:service("skills"):shadowed()) do
        if item.source == "pack:" .. packname then
            count = count + 1
        end
    end
    return count
end

-- a pack is markdown only, but it still downloads a repository into the user
-- home, so we always ask first
function _askfetch(app, source)
    if not app.ask then
        return true
    end
    local lines = {theme.styled("tool.name", source.name), theme.styled("md.code", source.url)}
    if source.description then
        table.insert(lines, theme.styled("dim", source.description))
    end
    table.insert(lines, theme.styled("dim", "it is cloned into " .. path.join(installer.dir(), source.name)))
    return app:ask({
        lines = lines,
        question = installer.isinstalled(source.name)
            and "Do you want to update it from the network?"
            or "Do you want to fetch it from the network?",
        options = {{text = "Yes", value = true}, {text = "No", value = false}}})
end

-- update the installed packs
function _update(app, spec)
    local packs = installer.installed()
    if spec and spec ~= "" then
        packs = {{name = spec}}
    end
    if #packs == 0 then
        return {kind = "message", text = "no skill pack is installed."}
    end

    local results = {}
    for _, pack in ipairs(packs) do
        table.insert(results, _updateone(app, pack))
    end
    return {kind = "message", text = "the skill packs are updated:\n" .. table.concat(results, "\n")}
end

-- update one pack
function _updateone(app, pack)
    local source = installer.resolve(app.harness, pack.name) or {name = pack.name, url = pack.url}
    source.url = source.url or pack.url
    if not source.url then
        return string.format("  %s: it is not a git pack, nothing to update", pack.name)
    end
    local updated, errors = installer.install(source, {onprogress = function (message) app:notify(message) end})
    if updated then
        updates.clear(pack.name)
    end
    return updated and string.format("  %s: %d skills", pack.name, updated.skills)
        or string.format("  %s: %s", pack.name, tostring(errors))
end

-- remove an installed pack
function _remove(spec)
    spec = (spec or ""):trim()
    if spec == "" then
        return {kind = "message", text = "usage: /skills remove <pack>", iserror = true}
    end
    local ok, errors = installer.remove(spec)
    if not ok then
        return {kind = "message", text = errors, iserror = true}
    end
    return {kind = "message", text = string.format(
        "the skill pack `%s` is removed, restart `xmake ai` to unload its skills", spec)}
end
