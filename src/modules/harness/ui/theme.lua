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
-- every color is a named style, the views never hardcode an escape sequence:
-- they ask the theme for a name, e.g. theme.styled("code.keyword", "local").
--
-- the palette is defined twice, for the 256 color terminals and for the basic
-- ones, and the right one is picked at load time. the users can override any
-- single entry from their configuration:
--
--   "ui": {"theme": "dark", "colors": {"code.keyword": "${bright magenta}"}}
--

-- imports
import("core.base.tty")
import("core.base.colors")
import("harness.util.util")

-- the escape sequence which resets the foreground color only, so we can
-- colorize the text inside a colored background, e.g. the diff lines
local FG_RESET = "\027[39m"

-- the shared structure of every theme, the color values are filled per palette
function _base()
    return {
        -- the conversation
        ["text"]             = "reset",
        ["dim"]              = "dim",
        ["title"]            = "title",
        ["user.bullet"]      = "dim",
        ["user.text"]        = "reset",
        ["assistant.bullet"] = "green",
        ["assistant.text"]   = "reset",
        ["reasoning"]        = "dim",

        -- the tool cards
        ["tool.bullet"]      = "green",
        ["tool.name"]        = "title",
        ["tool.args"]        = "dim",
        ["tool.result"]      = "dim",
        ["tool.error"]       = "red",
        ["tool.pending"]     = "orange",

        -- the messages
        ["notice"]           = "orange",
        ["error"]            = "red",
        ["success"]          = "green",
        ["hint"]             = "dim",
        ["prompt"]           = "dim",
        ["spinner"]          = "salmon",
        ["status"]           = "dim",
        ["border"]           = "border",
        ["box"]              = "border",

        -- the diffs
        ["diff.add"]         = "green",
        ["diff.del"]         = "red",
        ["diff.addline"]     = "addbg",
        ["diff.delline"]     = "delbg",
        ["diff.addmark"]     = "addmark",
        ["diff.delmark"]     = "delmark",
        ["diff.lineno"]      = "lineno",
        ["diff.context"]     = "reset",

        -- the code
        ["code.keyword"]     = "magenta",
        ["code.control"]     = "magenta",
        ["code.string"]      = "green",
        ["code.number"]      = "blue",
        ["code.func"]        = "blue",
        ["code.type"]        = "yellow",
        ["code.property"]    = "yellow",
        ["code.variable"]    = "orange",
        ["code.constant"]    = "blue",
        ["code.comment"]     = "comment",
        ["code.operator"]    = "operator",
        ["code.punct"]       = "punct",
        ["code.text"]        = "reset",
        ["code.gutter"]      = "border",

        -- the markdown
        ["md.h1"]            = "cyan",
        ["md.h2"]            = "cyan",
        ["md.h3"]            = "title",
        ["md.bold"]          = "title",
        ["md.italic"]        = "italic",
        ["md.strike"]        = "dim",
        ["md.code"]          = "inlinecode",
        ["md.quote"]         = "dim",
        ["md.bullet"]        = "orange",
        ["md.link"]          = "link",
        ["md.rule"]          = "border",
        ["md.table"]         = "border",
        ["md.tablehead"]     = "title",

        -- the widgets
        ["select.active"]    = "cyan",
        ["select.normal"]    = "reset",
        ["select.hint"]      = "dim",
        ["badge.plan"]       = "purple",
        ["badge.accept"]     = "green",
        ["badge.bypass"]     = "red",
        ["badge.sandbox"]    = "cyan"
    }
end

-- the 256 color palette, it follows the claude code colors closely
function _palette256()
    return {
        reset      = "${reset}",
        dim        = "${#245}",
        title      = "${bright}",
        italic     = "${#252}",
        border     = "${#240}",
        green      = "${#114}",
        red        = "${#210}",
        orange     = "${#215}",
        salmon     = "${#210}",
        yellow     = "${#186}",
        blue       = "${#75}",
        cyan       = "${#80}",
        magenta    = "${#176}",
        purple     = "${#141}",
        comment    = "${#245}",
        operator   = "${#252}",
        punct      = "${#250}",
        lineno     = "${#240}",
        inlinecode = "${#180}",
        link       = "${underline #75}",
        addbg      = "${on#22}",
        delbg      = "${on#52}",
        addmark    = "${#114}",
        delmark    = "${#210}"
    }
end

-- the basic palette, for the terminals without the 256 colors
function _palette8()
    return {
        reset      = "${reset}",
        dim        = "${dim}",
        title      = "${bright}",
        italic     = "${bright}",
        border     = "${dim}",
        green      = "${green}",
        red        = "${red}",
        orange     = "${yellow}",
        salmon     = "${bright red}",
        yellow     = "${yellow}",
        blue       = "${blue}",
        cyan       = "${cyan}",
        magenta    = "${magenta}",
        purple     = "${bright magenta}",
        comment    = "${dim}",
        operator   = "${reset}",
        punct      = "${reset}",
        lineno     = "${dim}",
        inlinecode = "${cyan}",
        link       = "${underline blue}",
        addbg      = "${ongreen black}",
        delbg      = "${onred black}",
        addmark    = "${green}",
        delmark    = "${red}"
    }
end

-- the theme variants, they only override a few palette entries
function themes()
    return {
        default = {},
        dark    = {},
        light   = {
            dim      = "${#243}",
            border   = "${#250}",
            comment  = "${#243}",
            green    = "${#28}",
            blue     = "${#26}",
            magenta  = "${#127}",
            yellow   = "${#94}",
            cyan     = "${#30}",
            addbg    = "${on#194}",
            delbg    = "${on#224}"
        },
        plain   = {}
    }
end

-- the current theme
local _CURRENT = _CURRENT or nil

-- load the theme from the configuration
function load(config)
    local name = util.tget(config or {}, "ui.theme") or "default"
    local variants = themes()
    if not variants[name] then
        name = "default"
    end

    -- pick the palette which the terminal can render
    local palette = tty.has_color256() and _palette256() or _palette8()
    util.tmerge(palette, variants[name])

    -- resolve every style name to its escape sequence
    local colorset = {}
    for style, key in pairs(_base()) do
        colorset[style] = palette[key] or key
    end

    -- the user overrides are raw color tags, e.g. "${bright red}"
    util.tmerge(colorset, util.tget(config or {}, "ui.colors") or {})

    local codes = {}
    local plain = (name == "plain") or not tty.has_color8()
    if not plain then
        for style, tag in pairs(colorset) do
            codes[style] = colors.translate(tag, {patch_reset = false, ignore_unknown = true})
        end
    end
    _CURRENT = {name = name, colors = colorset, codes = codes, plain = plain, palette = palette}
    return _CURRENT
end

-- get the current theme
function current()
    if not _CURRENT then
        load({})
    end
    return _CURRENT
end

-- get the escape sequence of the given style name
function get(name)
    return current().codes[name] or ""
end

-- get the reset sequence
function reset()
    if current().plain then
        return ""
    end
    return "\027[0m"
end

-- get the sequence which resets the foreground color but keeps the background
function fgreset()
    if current().plain then
        return ""
    end
    return FG_RESET
end

-- wrap the given text with the named style
function styled(name, str)
    local code = get(name)
    if code == "" then
        return str
    end
    return code .. str .. reset()
end

-- is the theme plain, e.g. no colors at all?
function isplain()
    return current().plain
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
