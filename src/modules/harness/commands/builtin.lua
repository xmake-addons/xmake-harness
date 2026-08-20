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
        {name = "skills",      description = "List the loaded skills",                              run = _skills},
        {name = "agents",      description = "List the available subagents",                        run = _agents},
        {name = "tools",       description = "List the registered tools",                           run = _tools},
        {name = "plugins",     description = "List the loaded harness plugins",                     run = _plugins},
        {name = "sessions",    description = "List the recent sessions of this project",            run = _sessions},
        {name = "resume",      description = "Resume a session, e.g. /resume <id>",                 run = _resume},
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
function _clear(app)
    app:newsession()
    return {kind = "clear", text = "the conversation is cleared"}
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

-- /context
function _context(app)
    local ratio, contextsize = compact.ratio(app.harness, app.session)
    local used = app.session:contexttokens()
    local barwidth = 30
    local filled = math.min(barwidth, math.floor(ratio * barwidth + 0.5))
    local bar = string.rep("█", filled) .. string.rep("░", barwidth - filled)
    local lines = {}
    table.insert(lines, string.format("%s %.0f%%", bar, ratio * 100))
    table.insert(lines, string.format("about %s of %s tokens are used", util.count(used), util.count(contextsize)))
    table.insert(lines, string.format("auto compaction: %s (at %.0f%%)",
        (app.harness:config().context or {}).autocompact ~= false and "on" or "off",
        ((app.harness:config().context or {}).threshold or 0.82) * 100))
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

-- /skills
function _skills(app)
    local registry = app.harness:service("skills")
    local skills = registry:all()
    local lines = {string.format("%d skills are loaded from: %s", #skills, table.concat(registry:dirs(), ", ")), ""}
    for _, skill in ipairs(skills) do
        table.insert(lines, string.format("  %s %s", text.pad(skill.name, 26), text.truncate(skill.description, 90)))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
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

-- /sessions
function _sessions(app)
    local items = sessions.list({cwd = app.harness:rootdir(), limit = 20})
    local lines = {string.format("%d recent sessions:", #items), ""}
    for _, meta in ipairs(items) do
        table.insert(lines, string.format("  %s  %s  %s", meta.id,
            os.date("%m-%d %H:%M", meta.updatetime or 0), text.truncate(meta.title or "(no title)", 60)))
    end
    table.insert(lines, "")
    table.insert(lines, "resume one with `/resume <id>`")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /resume
function _resume(app, args)
    local id = args:trim()
    if id == "" then
        return _sessions(app)
    end
    local session, errors = sessions.load(id)
    if not session then
        return {kind = "message", text = tostring(errors), iserror = true}
    end
    app:setsession(session)
    return {kind = "resumed", text = string.format("the session %s is resumed (%d events)", id, #session:events())}
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
    return {kind = "message", text = table.concat(aicli.doctor(app.harness), "\n")}
end

