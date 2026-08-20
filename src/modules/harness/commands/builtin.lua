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
-- @file        builtin.lua
--

--
-- the builtin slash commands
--
-- they are modelled after the claude code commands, so the muscle memory works:
-- /help /clear /model /config /context /compact /cost /agents /skills /tools ..
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")
import("harness.config.config")
import("harness.context.compact")
import("harness.context.window")
import("harness.skills.installer")
import("harness.permission.policy")
import("harness.sandbox.sandbox")
import("harness.core.session", {alias = "sessions"})

-- get all the builtin commands
function commands()
    return {
        {name = "help",        description = "Show the available commands and the shortcuts",       run = _help},
        {name = "clear",       description = "Clear the conversation and start a new session",      run = _clear},
        {name = "exit",        description = "Exit the tui",                                        run = _exit},
        {name = "quit",        description = "Exit the tui",                                        run = _exit},
        {name = "model",       description = "Show or switch the model, e.g. /model deepseek-reasoner", run = _model},
        {name = "provider",    description = "Show or switch the llm provider, e.g. /provider anthropic", run = _provider},
        {name = "config",      description = "Show or set the user configuration, e.g. /config ui.theme dark", run = _config},
        {name = "status",      description = "Show the harness status: the provider, the model, the tools", run = _status},
        {name = "cost",        description = "Show the token usage and the cache hit rate of this session", run = _cost},
        {name = "context",     description = "Show how much of the context window is used",         run = _context},
        {name = "compact",     description = "Compact the conversation into a summary",             run = _compact},
        {name = "permissions", description = "Show or switch the permission mode, e.g. /permissions plan", run = _permissions},
        {name = "sandbox",     description = "Show or toggle the command sandbox",                  run = _sandbox},
        {name = "theme",       description = "Show or switch the ui theme, e.g. /theme light",      run = _theme},
        {name = "skills",      description = "List, install, update or remove the skill packs",      run = _skills},
        {name = "agents",      description = "List the available subagents",                        run = _agents},
        {name = "tools",       description = "List the registered tools",                           run = _tools},
        {name = "plugins",     description = "List the loaded harness plugins",                     run = _plugins},
        {name = "sessions",    description = "List the recent sessions of this project",            run = _sessions},
        {name = "resume",      description = "Resume a session of this project, it asks which one",  run = _resume},
        {name = "export",      description = "Export the current conversation to a markdown file",  run = _export},
        {name = "init",        description = "Create the project instruction file (XMAKE.md)",      run = _init},
        {name = "cwd",         description = "Show or change the working directory",                run = _cwd},
        {name = "doctor",      description = "Check the harness environment",                       run = _doctor}
    }
end

-- /help
function _help(app)
    local lines = {"Commands:"}
    for _, command in ipairs(app.harness:service("commands"):all()) do
        table.insert(lines, string.format("  %s %s", text.pad("/" .. command.name, 14), command.description))
    end
    table.insert(lines, "")
    table.insert(lines, "Shortcuts:")
    table.insert(lines, "  enter          send the message")
    table.insert(lines, "  alt+enter      insert a new line")
    table.insert(lines, "  shift+tab      cycle the permission mode")
    table.insert(lines, "  esc            interrupt the current work")
    table.insert(lines, "  ctrl+c         clear the input, twice to exit")
    table.insert(lines, "  ctrl+d         exit")
    table.insert(lines, "  ctrl+l         clear the screen")
    table.insert(lines, "  up/down        browse the input history")
    table.insert(lines, "  /              the command completion, @ the file completion")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /clear
--
-- it starts a new session, the previous one stays on the disk and can be resumed
--
function _clear(app)
    local previous = app.session:id()
    local session = app:newsession()
    return {kind = "clear", text = string.format(
        "a new session is started (%s)\nthe previous one is saved, resume it with `/resume %s`",
        session:id(), previous)}
end

-- /exit
function _exit()
    return {kind = "exit"}
end

-- /model
function _model(app, args)
    local harnessconfig = app.harness:config()
    local provider = config.provider(harnessconfig)
    if args == "" then
        local lines = {string.format("the current model: %s (provider: %s)", provider.models.main, provider.name)}
        table.insert(lines, string.format("the small model:   %s", provider.models.small))
        if provider.modellist then
            table.insert(lines, "")
            table.insert(lines, "the known models of this provider:")
            for _, name in ipairs(provider.modellist) do
                table.insert(lines, "  " .. name)
            end
        end
        table.insert(lines, "")
        table.insert(lines, "switch it with `/model <name>`, or `/model small <name>` for the small model.")
        return {kind = "message", text = table.concat(lines, "\n")}
    end
    local tier, name = args:match("^(small)%s+(.+)$")
    if tier then
        harnessconfig.smallmodel = name
        config.set("smallmodel", name)
        return {kind = "message", text = string.format("the small model is switched to %s", name)}
    end
    harnessconfig.model = args:trim()
    config.set("model", harnessconfig.model)
    return {kind = "message", text = string.format("the model is switched to %s", harnessconfig.model)}
end

-- /provider
function _provider(app, args)
    local harnessconfig = app.harness:config()
    if args == "" then
        local lines = {string.format("the current provider: %s", harnessconfig.provider)}
        table.insert(lines, "")
        table.insert(lines, "the available providers:")
        for _, name in ipairs(config.providernames(harnessconfig)) do
            local provider = config.provider(harnessconfig, name)
            local configured = provider.apikey and provider.apikey ~= "" and "configured" or "no api key"
            table.insert(lines, string.format("  %s %s (%s)", text.pad(name, 14), provider.models.main or "", configured))
        end
        table.insert(lines, "")
        table.insert(lines, "switch it with `/provider <name>`, and set its key with `/config providers.<name>.apikey <key>`.")
        return {kind = "message", text = table.concat(lines, "\n")}
    end
    local name = args:trim()
    harnessconfig.provider = name
    harnessconfig.model = nil
    harnessconfig.smallmodel = nil
    config.set("provider", name)
    config.set("model", nil)
    config.set("smallmodel", nil)
    local provider = config.provider(harnessconfig)
    if not provider.apikey or provider.apikey == "" then
        return {kind = "message", text = string.format(
            "the provider is switched to %s, but its api key is missing:\n  /config providers.%s.apikey <your key>%s",
            name, name, provider.apikeyurl and ("\n  get one at " .. provider.apikeyurl) or "")}
    end
    return {kind = "message", text = string.format("the provider is switched to %s (%s)", name, provider.models.main)}
end

-- /config
function _config(app, args)
    local harnessconfig = app.harness:config()
    if args == "" then
        local lines = {"the user config file: " .. config.userfile(), ""}
        local keys = {"provider", string.format("providers.%s.apikey", harnessconfig.provider),
                      "model", "smallmodel", "permission.mode", "ui.theme",
                      "sandbox.enabled", "context.autocompact", "context.threshold", "maxtokens"}
        for _, key in ipairs(keys) do
            table.insert(lines, string.format("  %s %s", text.pad(key, 32), _display(key, util.tget(harnessconfig, key))))
        end
        table.insert(lines, "")
        table.insert(lines, "set a value with `/config <key> <value>`, e.g.")
        table.insert(lines, string.format("  /config providers.%s.apikey sk-xxxxxx", harnessconfig.provider))
        table.insert(lines, "  /config ui.theme light")
        return {kind = "message", text = table.concat(lines, "\n")}
    end
    local key, value = args:match("^(%S+)%s+(.+)$")
    if not key then
        key = args:trim()
        return {kind = "message", text = string.format("%s = %s", key, _display(key, util.tget(harnessconfig, key)))}
    end
    local parsed = util.tovalue(value:trim())
    config.set(key, parsed)
    util.tset(harnessconfig, key, parsed)
    if key:startswith("ui.") then
        theme.load(harnessconfig)
    end
    return {kind = "message", text = string.format("%s = %s (saved to %s)", key, _display(key, parsed), config.userfile())}
end

-- render a config value, the secrets are never printed in full
function _display(key, value)
    if value == nil then
        return "(unset)"
    end
    if key:endswith("apikey") or key:endswith("token") or key:endswith("secret") then
        local str = tostring(value)
        if str == "" then
            return "(unset)"
        end
        return str:sub(1, 6) .. string.rep("*", math.min(12, math.max(0, #str - 6)))
    end
    return tostring(value)
end

-- /status
function _status(app)
    local harnessconfig = app.harness:config()
    local provider = config.provider(harnessconfig)
    local lines = {}
    table.insert(lines, string.format("provider:    %s (%s)", provider.name, provider.baseurl))
    table.insert(lines, string.format("model:       %s / %s", provider.models.main, provider.models.small))
    table.insert(lines, string.format("api key:     %s", (provider.apikey and provider.apikey ~= "") and "configured" or "missing"))
    table.insert(lines, string.format("cwd:         %s", app.harness:rootdir()))
    table.insert(lines, string.format("mode:        %s", app.mode))
    table.insert(lines, string.format("sandbox:     %s", sandbox.status(harnessconfig)))
    table.insert(lines, string.format("session:     %s (%d events)", app.session:id(), #app.session:events()))
    table.insert(lines, string.format("tools:       %d", #app.harness:service("tools"):names()))
    table.insert(lines, string.format("skills:      %d", #app.harness:service("skills"):all()))
    table.insert(lines, string.format("agents:      %d", #app.harness:service("agents"):all()))
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /cost
function _cost(app)
    local usage = app.session:usage()
    local lines = {}
    table.insert(lines, string.format("requests:    %d", usage.requests or 0))
    table.insert(lines, string.format("input:       %s tokens", util.count(usage.input or 0)))
    table.insert(lines, string.format("output:      %s tokens", util.count(usage.output or 0)))
    local rate = app.session:cacherate()
    if rate then
        table.insert(lines, string.format("cache:       %.0f%% hit (%s hit / %s miss)", rate * 100,
            util.count(usage.cachehit or 0), util.count(usage.cachemiss or 0)))
    else
        table.insert(lines, "cache:       no data")
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /context [full|auto]
--
-- it shows what actually fills the context window, and switches between the
-- optimized projection and the full history
--
function _context(app, args)
    local action = (args or ""):trim():lower()
    if action == "full" or action == "auto" then
        util.tset(app.harness:config(), "context.mode", action)
        config.set("context.mode", action)
        return {kind = "message", text = action == "full"
            and "the context mode is `full`: the whole history is sent, nothing is pruned or compacted"
            or "the context mode is `auto`: the old tool results are pruned and the history is compacted when needed"}
    end
    local result = window.breakdown(app.harness, app.session, {mode = app.mode})
    local lines = window.render(result, {width = app._width and app:_width() or 80})
    table.insert(lines, "")
    table.insert(lines, "  /compact to summarize now · /context full to disable the optimization")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /compact
function _compact(app, args)
    app:notify("compacting the conversation ..")
    local summary, errors = compact.run(app.harness, app.session, {focus = args, manual = true})
    if not summary then
        return {kind = "message", text = "cannot compact: " .. tostring(errors), iserror = true}
    end
    return {kind = "compacted", text = "the conversation is compacted into a summary"}
end

-- /permissions
function _permissions(app, args)
    if args == "" then
        local lines = {string.format("the current mode: %s (%s)", app.mode, policy.modedesc(app.mode)), ""}
        for _, mode in ipairs(policy.modes()) do
            table.insert(lines, string.format("  %s %s", text.pad(mode, 14), policy.modedesc(mode)))
        end
        table.insert(lines, "")
        table.insert(lines, "switch it with `/permissions <mode>` or shift+tab")
        return {kind = "message", text = table.concat(lines, "\n")}
    end
    local mode = args:trim()
    if not table.contains(policy.modes(), mode) then
        return {kind = "message", text = string.format("unknown mode: %s", mode), iserror = true}
    end
    app:setmode(mode)
    return {kind = "message", text = string.format("the permission mode is switched to %s", mode)}
end

-- /sandbox
function _sandbox(app, args)
    local harnessconfig = app.harness:config()
    harnessconfig.sandbox = harnessconfig.sandbox or {}
    if args == "" then
        return {kind = "message", text = string.format("the sandbox is %s, the available backends: %s\ntoggle it with `/sandbox on|off`",
            sandbox.status(harnessconfig), table.concat(sandbox.backends(), ", "))}
    end
    local enabled = util.tobool(args:trim(), nil)
    if enabled == nil then
        harnessconfig.sandbox.backend = args:trim()
        config.set("sandbox.backend", args:trim())
        return {kind = "message", text = string.format("the sandbox backend is set to %s", args:trim())}
    end
    harnessconfig.sandbox.enabled = enabled
    config.set("sandbox.enabled", enabled)
    return {kind = "message", text = string.format("the sandbox is %s (%s)", enabled and "enabled" or "disabled", sandbox.status(harnessconfig))}
end

-- /theme
function _theme(app, args)
    if args == "" then
        return {kind = "message", text = string.format("the current theme: %s\nthe available themes: %s\nswitch it with `/theme <name>`",
            theme.current().name, table.concat(theme.names(), ", "))}
    end
    local name = args:trim()
    util.tset(app.harness:config(), "ui.theme", name)
    config.set("ui.theme", name)
    theme.load(app.harness:config())
    return {kind = "message", text = string.format("the theme is switched to %s", name)}
end

-- /skills [install|update|remove] [pack]
--
-- the packs are never bundled with the harness: they are fetched on demand from
-- their own repositories, and the user always confirms the fetch
--
function _skills(app, args)
    local action, spec = (args or ""):match("^(%S+)%s*(.*)$")
    if action == "install" or action == "add" then
        return _skills_install(app, spec, {})
    elseif action == "update" or action == "upgrade" then
        return _skills_update(app, spec)
    elseif action == "remove" or action == "uninstall" then
        return _skills_remove(app, spec)
    elseif action ~= nil and action ~= "list" then
        return {kind = "message", text = string.format("unknown action: %s\nusage: /skills [install|update|remove] <pack>", action), iserror = true}
    end
    return _skills_list(app)
end

-- list the skills and the packs
function _skills_list(app)
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

    local packs = installer.installed()
    table.insert(lines, "")
    if #packs > 0 then
        table.insert(lines, "the installed packs:")
        for _, pack in ipairs(packs) do
            table.insert(lines, string.format("  %s %d skills  %s", text.pad(pack.name, 22), pack.skills,
                pack.url or pack.dir))
        end
    else
        table.insert(lines, "no skill pack is installed.")
    end

    local available = {}
    for name, source in table.orderpairs(installer.sources(app.harness)) do
        if not installer.isinstalled(source.packname or name) then
            table.insert(available, string.format("  %s %s", text.pad(name, 22),
                text.truncate(source.description or source.url, 70)))
        end
    end
    if #available > 0 then
        table.insert(lines, "")
        table.insert(lines, "the available packs:")
        for _, line in ipairs(available) do
            table.insert(lines, line)
        end
    end
    table.insert(lines, "")
    table.insert(lines, "install one with `/skills install <name|github:user/repo|url|dir>`")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- install a skill pack
function _skills_install(app, spec, opt)
    local source, errors = installer.resolve(app.harness, spec)
    if not source then
        return {kind = "message", text = errors, iserror = true}
    end

    -- a remote pack runs code-free markdown, but it still downloads a repository
    -- into the user home, so we always ask first
    if source.url and app.ask then
        local lines = {
            theme.styled("tool.name", source.name),
            theme.styled("md.code", source.url)
        }
        if source.description then
            table.insert(lines, theme.styled("dim", source.description))
        end
        table.insert(lines, "")
        table.insert(lines, theme.styled("dim", "it is cloned into " .. path.join(installer.dir(), source.name)))
        local answer = app:ask({
            title = installer.isinstalled(source.name) and "Update skill pack" or "Install skill pack",
            lines = lines,
            question = "Do you want to fetch it from the network?",
            options = {
                {text = "Yes", value = true},
                {text = "No (esc)", value = false}
            }
        })
        if not answer then
            return {kind = "message", text = "cancelled."}
        end
    end

    local pack, installerrors = installer.install(source, {
        onprogress = function (message)
            app:notify(message)
        end
    })
    if not pack then
        return {kind = "message", text = installerrors, iserror = true}
    end
    app.harness:service("skills"):adddir(pack.skillsdir, "pack:" .. pack.name)
    return {kind = "message", text = string.format("the skill pack `%s` is ready: %d skills from %s\n%d skills are loaded in total",
        pack.name, pack.skills, pack.dir, #app.harness:service("skills"):all())}
end

-- update the installed packs
function _skills_update(app, spec)
    local packs = installer.installed()
    if spec and spec ~= "" then
        packs = {{name = spec}}
    end
    if #packs == 0 then
        return {kind = "message", text = "no skill pack is installed."}
    end
    local results = {}
    for _, pack in ipairs(packs) do
        local source = installer.resolve(app.harness, pack.name) or {name = pack.name, url = pack.url}
        if not source.url then
            source.url = pack.url
        end
        if source.url then
            local updated, errors = installer.install(source, {onprogress = function (message) app:notify(message) end})
            table.insert(results, updated
                and string.format("  %s: %d skills", pack.name, updated.skills)
                or string.format("  %s: %s", pack.name, tostring(errors)))
        else
            table.insert(results, string.format("  %s: it is not a git pack, nothing to update", pack.name))
        end
    end
    return {kind = "message", text = "the skill packs are updated:\n" .. table.concat(results, "\n")}
end

-- remove an installed pack
function _skills_remove(app, spec)
    if not spec or spec == "" then
        return {kind = "message", text = "usage: /skills remove <pack>", iserror = true}
    end
    local ok, errors = installer.remove(spec:trim())
    if not ok then
        return {kind = "message", text = errors, iserror = true}
    end
    return {kind = "message", text = string.format("the skill pack `%s` is removed, restart `xmake ai` to unload its skills", spec)}
end

-- /agents
function _agents(app)
    local agents = app.harness:service("agents"):all()
    local lines = {string.format("%d agents:", #agents), ""}
    for _, agent in ipairs(agents) do
        table.insert(lines, string.format("  %s %s", text.pad(agent.name, 20), text.truncate(agent.description, 90)))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /tools
function _tools(app)
    local tools = app.harness:service("tools"):tools()
    local lines = {string.format("%d tools:", #tools), ""}
    for _, tool in ipairs(tools) do
        table.insert(lines, string.format("  %s %s %s", text.pad(tool.name, 16), text.pad("[" .. (tool.permission or "none") .. "]", 10),
            text.truncate((tool.description or ""):gsub("\n.*", ""), 80)))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /plugins
function _plugins(app)
    local plugins = app.harness:service("plugins") or {}
    local lines = {string.format("%d plugins:", #plugins), ""}
    for _, plugin in ipairs(plugins) do
        table.insert(lines, string.format("  %s %s", text.pad(plugin.name, 16), text.truncate(plugin.description or "", 90)))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /sessions [all|remove <id>]
--
-- the sessions are kept per project directory, so this lists the history of
-- the project you are in
--
function _sessions(app, args)
    local action, spec = (args or ""):match("^(%S+)%s*(.*)$")
    if action == "remove" or action == "rm" then
        local ok, errors = sessions.remove((spec or ""):trim(), app.harness:rootdir())
        return {kind = "message", text = ok and string.format("the session %s is removed", spec) or errors, iserror = not ok}
    end
    local all = (action == "all")
    local items = sessions.list({cwd = app.harness:rootdir(), all = all, limit = 20})
    local lines = {}
    if #items == 0 then
        return {kind = "message", text = all and "no session yet."
            or string.format("no session for %s yet.", app.harness:rootdir())}
    end
    table.insert(lines, all and "the recent sessions of every project:"
        or string.format("the recent sessions of %s:", app.harness:rootdir()))
    table.insert(lines, "")
    for _, meta in ipairs(items) do
        local usage = meta.usage or {}
        table.insert(lines, string.format("  %s  %s  %s  %s", meta.id,
            os.date("%m-%d %H:%M", meta.updatetime or 0),
            text.pad(string.format("%d msgs", meta.events or 0), 9),
            text.truncate(meta.title or "(no title)", 52)))
        if all and meta.cwd then
            table.insert(lines, theme.styled("dim", "                                        " .. util.shortpath(meta.cwd, "")))
        end
    end
    table.insert(lines, "")
    table.insert(lines, "resume one with `/resume <id>`, remove one with `/sessions remove <id>`")
    table.insert(lines, "`/sessions all` lists every project · `xmake ai -c` continues the last one")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /resume [id]
--
-- without an id it lets the user pick one of this project, exactly like
-- `xmake ai -r` does on the command line
--
function _resume(app, args)
    local id = (args or ""):trim()
    if id == "" then
        if not app.ask then
            return _sessions(app, "")
        end
        local items = sessions.list({cwd = app.harness:rootdir(), limit = 12})
        if #items == 0 then
            return {kind = "message", text = string.format("no session for %s yet.", app.harness:rootdir())}
        end
        local options = {}
        for _, meta in ipairs(items) do
            table.insert(options, {
                text = string.format("%s  %s  %s", os.date("%m-%d %H:%M", meta.updatetime or 0),
                    text.pad(string.format("%d msgs", meta.events or 0), 9),
                    text.truncate(meta.title or "(no title)", 44)),
                value = meta.id})
        end
        table.insert(options, {text = "Cancel (esc)", value = false})
        id = app:ask({
            title = "Resume a session",
            lines = {theme.styled("dim", app.harness:rootdir())},
            question = "Which session do you want to resume?",
            options = options})
        if not id then
            return {kind = "message", text = "cancelled."}
        end
    end
    local session, errors = sessions.load(id, app.harness:rootdir())
    if not session then
        return {kind = "message", text = tostring(errors), iserror = true}
    end
    app:setsession(session)
    return {kind = "resumed", text = string.format("the session %s is resumed (%d messages)",
        session:id(), #session:events())}
end

-- /export
function _export(app, args)
    local filepath = args:trim()
    if filepath == "" then
        filepath = path.join(app.harness:rootdir(), string.format("harness-%s.md", os.date("%Y%m%d-%H%M%S")))
    end
    local lines = {string.format("# %s", app.session:title() or "conversation"), ""}
    for _, event in ipairs(app.session:events()) do
        if event.kind == "user" then
            table.insert(lines, "## User\n\n" .. (event.text or ""))
        elseif event.kind == "assistant" and event.text and event.text ~= "" then
            table.insert(lines, "## Assistant\n\n" .. event.text)
        elseif event.kind == "tool" then
            table.insert(lines, string.format("### Tool: %s\n\n```\n%s\n```", event.name, (event.output or ""):sub(1, 2000)))
        end
    end
    io.writefile(filepath, table.concat(lines, "\n\n"))
    return {kind = "message", text = "the conversation is exported to " .. filepath}
end

-- /init
function _init(app)
    return {kind = "prompt", text = [[Analyze this project and create an `XMAKE.md` file at the project root.

It is the instruction file which every future agent session reads first, so keep it
short and factual:

- what the project is and what it builds
- the build/test/run commands which actually work here
- the layout of the important directories
- the code style and the conventions a contributor must follow
- anything surprising which is easy to get wrong

Read the build files and a few sources first. If `XMAKE.md` already exists, improve it
instead of rewriting it.]]}
end

-- /cwd
function _cwd(app, args)
    if args == "" then
        return {kind = "message", text = app.harness:rootdir()}
    end
    local dir = path.absolute(args:trim(), app.harness:rootdir())
    if not os.isdir(dir) then
        return {kind = "message", text = string.format("%s is not a directory", dir), iserror = true}
    end
    app.harness:rootdir_set(path.normalize(dir))
    return {kind = "message", text = "the working directory is switched to " .. dir}
end

-- /doctor
function _doctor(app)
    local aicli = import("harness.cli.ai", {anonymous = true})
    local terminal = import("harness.ui.terminal", {anonymous = true})
    local lines = aicli.doctor(app.harness)
    table.insert(lines, string.format("  %s %s %s",
        theme.styled("success", "[ok]"), text.pad("input", 18),
        theme.styled("dim", terminal.inputbackend())))
    return {kind = "message", text = table.concat(lines, "\n")}
end

