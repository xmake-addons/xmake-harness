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
-- @file        model.lua
--

--
-- the model commands: /model, /provider, /config, /theme
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")
import("harness.config.config")

-- the commands of this group
function commands()
    return {
        {name = "model",    description = "Show or switch the model, e.g. /model deepseek-reasoner", run = _model},
        {name = "provider", description = "Show or switch the llm provider, e.g. /provider anthropic", run = _provider},
        {name = "config",   description = "Show or set the user configuration, e.g. /config ui.theme dark", run = _config},
        {name = "theme",    description = "Show or switch the ui theme, e.g. /theme light",       run = _theme}
    }
end

-- /model [name|small <name>]
function _model(app, args)
    local harnessconfig = app.harness:config()
    args = (args or ""):trim()
    if args == "" then
        return {kind = "message", text = _modelinfo(harnessconfig)}
    end

    local tier, name = args:match("^(small)%s+(.+)$")
    if tier then
        harnessconfig.smallmodel = name
        config.set("smallmodel", name)
        return {kind = "message", text = string.format("the small model is switched to %s", name)}
    end
    harnessconfig.model = args
    config.set("model", args)
    return {kind = "message", text = string.format("the model is switched to %s", args)}
end

-- what the models are right now
function _modelinfo(harnessconfig)
    local provider = config.provider(harnessconfig)
    local lines = {string.format("the current model: %s (provider: %s)", provider.models.main, provider.name),
                   string.format("the small model:   %s", provider.models.small)}
    if provider.modellist then
        table.insert(lines, "")
        table.insert(lines, "the known models of this provider:")
        for _, name in ipairs(provider.modellist) do
            table.insert(lines, "  " .. name)
        end
    end
    table.insert(lines, "")
    table.insert(lines, "switch it with `/model <name>`, or `/model small <name>` for the small model.")
    return table.concat(lines, "\n")
end

-- /provider [name]
function _provider(app, args)
    local harnessconfig = app.harness:config()
    args = (args or ""):trim()
    if args == "" then
        return {kind = "message", text = _providerinfo(harnessconfig)}
    end

    harnessconfig.provider = args
    harnessconfig.model = nil
    harnessconfig.smallmodel = nil
    config.set("provider", args)
    config.set("model", nil)
    config.set("smallmodel", nil)

    local provider = config.provider(harnessconfig)
    if not provider.apikey or provider.apikey == "" then
        return {kind = "message", text = string.format(
            "the provider is switched to %s, but its api key is missing:\n  /config providers.%s.apikey <your key>%s",
            args, args, provider.apikeyurl and ("\n  get one at " .. provider.apikeyurl) or "")}
    end
    return {kind = "message", text = string.format("the provider is switched to %s (%s)", args, provider.models.main)}
end

-- what the providers are
function _providerinfo(harnessconfig)
    local lines = {string.format("the current provider: %s", harnessconfig.provider), "", "the available providers:"}
    for _, name in ipairs(config.providernames(harnessconfig)) do
        local provider = config.provider(harnessconfig, name)
        table.insert(lines, string.format("  %s %s (%s)", text.pad(name, 14), provider.models.main or "",
            (provider.apikey and provider.apikey ~= "") and "configured" or "no api key"))
    end
    table.insert(lines, "")
    table.insert(lines, "switch it with `/provider <name>`, and set its key with `/config providers.<name>.apikey <key>`.")
    return table.concat(lines, "\n")
end

-- /config [key] [value]
function _config(app, args)
    local harnessconfig = app.harness:config()
    args = (args or ""):trim()
    if args == "" then
        return {kind = "message", text = _configinfo(harnessconfig)}
    end

    local key, value = args:match("^(%S+)%s+(.+)$")
    if not key then
        return {kind = "message", text = string.format("%s = %s", args, _display(args, util.tget(harnessconfig, args)))}
    end

    local parsed = util.tovalue(value:trim())
    config.set(key, parsed)
    util.tset(harnessconfig, key, parsed)
    if key:startswith("ui.") then
        theme.load(harnessconfig)
    end
    return {kind = "message", text = string.format("%s = %s (saved to %s)", key, _display(key, parsed), config.userfile())}
end

-- the values which matter most, so `/config` alone is useful
function _configinfo(harnessconfig)
    local lines = {"the user config file: " .. config.userfile(), ""}
    local keys = {"provider", string.format("providers.%s.apikey", harnessconfig.provider),
                  "model", "smallmodel", "permission.mode", "ui.theme",
                  "sandbox.enabled", "context.mode", "context.threshold", "maxtokens"}
    for _, key in ipairs(keys) do
        table.insert(lines, string.format("  %s %s", text.pad(key, 32), _display(key, util.tget(harnessconfig, key))))
    end
    table.insert(lines, "")
    table.insert(lines, "set a value with `/config <key> <value>`, e.g.")
    table.insert(lines, string.format("  /config providers.%s.apikey sk-xxxxxx", harnessconfig.provider))
    table.insert(lines, "  /config ui.theme light")
    return table.concat(lines, "\n")
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

-- /theme [name]
function _theme(app, args)
    args = (args or ""):trim()
    if args == "" then
        return {kind = "message", text = string.format(
            "the current theme: %s\nthe available themes: %s\nswitch it with `/theme <name>`",
            theme.current().name, table.concat(theme.names(), ", "))}
    end
    util.tset(app.harness:config(), "ui.theme", args)
    config.set("ui.theme", args)
    theme.load(app.harness:config())
    return {kind = "message", text = string.format("the theme is switched to %s", args)}
end
