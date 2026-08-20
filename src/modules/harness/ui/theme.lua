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
-- @file        theme.lua
--

--
-- the ui theme
--
-- every color is configurable, we never hardcode the escape sequences in the
-- views, they always ask the theme for a named style, e.g. theme.get("tool.name").
--
-- a theme is a plain table of `name -> xmake color tag`, so the users can
-- override any entry from their configuration:
--
--   "ui": {"theme": "dark", "colors": {"tool.name": "${bright blue}"}}
--

-- imports
import("core.base.colors")
import("harness.util.util")

-- the builtin themes
function themes()
    return {
        default = {
            ["text"]            = "${reset}",
            ["dim"]             = "${dim}",
            ["title"]           = "${bright}",
            ["user.bullet"]     = "${dim}",
            ["user.text"]       = "${reset}",
            ["assistant.bullet"]= "${color.success}",
            ["assistant.text"]  = "${reset}",
            ["reasoning"]       = "${dim}",
            ["tool.bullet"]     = "${color.success}",
            ["tool.name"]       = "${bright}",
            ["tool.args"]       = "${dim}",
            ["tool.result"]     = "${dim}",
            ["tool.error"]      = "${color.failure}",
            ["tool.pending"]    = "${color.warning}",
            ["notice"]          = "${color.warning}",
            ["error"]           = "${color.failure}",
            ["success"]         = "${color.success}",
            ["hint"]            = "${dim}",
            ["prompt"]          = "${dim}",
            ["spinner"]         = "${color.warning}",
            ["status"]          = "${dim}",
            ["border"]          = "${dim}",
            ["diff.add"]        = "${green}",
            ["diff.del"]        = "${red}",
            ["diff.addline"]    = "${on#22}",
            ["diff.delline"]    = "${on#52}",
            ["diff.lineno"]     = "${dim}",
            ["code.keyword"]    = "${magenta}",
            ["code.string"]     = "${green}",
            ["code.comment"]    = "${dim}",
            ["code.number"]     = "${cyan}",
            ["code.func"]       = "${yellow}",
            ["md.heading"]      = "${bright cyan}",
            ["md.bold"]         = "${bright}",
            ["md.italic"]       = "${underline}",
            ["md.code"]         = "${cyan}",
            ["md.quote"]        = "${dim}",
            ["md.bullet"]       = "${yellow}",
            ["md.link"]         = "${underline blue}",
            ["select.active"]   = "${bright cyan}",
            ["select.normal"]   = "${reset}",
            ["badge.plan"]      = "${bright magenta}",
            ["badge.accept"]    = "${bright green}",
            ["badge.bypass"]    = "${bright red}"
        },
        light = {
            ["assistant.bullet"]= "${green}",
            ["md.heading"]      = "${bright blue}",
            ["dim"]             = "${color.dim}"
        },
        plain = {}
    }
end

-- the current theme
local _CURRENT = _CURRENT or nil

-- load the theme from the configuration
function load(config)
    local name = util.tget(config or {}, "ui.theme") or (config or {}).theme or "default"
    local all = themes()
    local colorset = {}
    util.tmerge(colorset, all.default)
    if name ~= "default" and all[name] then
        util.tmerge(colorset, all[name])
    end
    util.tmerge(colorset, util.tget(config or {}, "ui.colors") or {})
    _CURRENT = {name = name, colors = colorset, plain = (name == "plain")}
    return _CURRENT
end

-- get the current theme
function current()
    if not _CURRENT then
        load({})
    end
    return _CURRENT
end

-- get the translated escape sequence of the given style name
function get(name)
    local theme = current()
    if theme.plain then
        return ""
    end
    local tag = theme.colors[name]
    if not tag then
        return ""
    end
    return colors.translate(tag)
end

-- reset the styles
function reset()
    if current().plain then
        return ""
    end
    return colors.translate("${reset}")
end

-- wrap the given text with the named style
function styled(name, str)
    local prefix = get(name)
    if prefix == "" then
        return str
    end
    return prefix .. str .. reset()
end

-- get all the theme names
function names()
    local results = {}
    for name, _ in pairs(themes()) do
        table.insert(results, name)
    end
    table.sort(results)
    return results
end
