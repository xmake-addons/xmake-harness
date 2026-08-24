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
-- @file        report.lua
--

--
-- what `xmake ai` prints outside the tui: the listings, the configuration and
-- the environment check
--

-- imports
import("core.base.colors")
import("lib.detect.find_tool")
import("harness.util.text")
import("harness.config.config")
import("harness.ui.terminal")
import("harness.sandbox.sandbox")
import("harness.core.session", {alias = "sessions"})

-- print the given lines
--
-- @note we never pass a line as a format, it may contain a `%` of its own
--
function printlines(lines)
    for _, line in ipairs(lines) do
        io.write(line, "\n")
    end
    return true
end

-- show the resolved configuration
function showconfig(context)
    local harnessconfig = context:config()
    local provider = config.provider(harnessconfig)
    cprint("${bright}the harness configuration${clear}")
    cprint("  user config:    %s", config.userfile())
    cprint("  project config: %s", harnessconfig._projectfile)
    cprint("  provider:       ${bright}%s${clear} (%s)", provider.name, provider.baseurl)
    cprint("  main model:     ${bright}%s${clear}", tostring(provider.models.main))
    cprint("  small model:    %s", tostring(provider.models.small))
    cprint("  api key:        %s", (provider.apikey and provider.apikey ~= "")
        and ("${green}configured${clear} (" .. provider.apikey:sub(1, 6) .. "..)") or "${color.failure}missing${clear}")
    cprint("  permission:     %s", (harnessconfig.permission or {}).mode)
    cprint("  sandbox:        %s", sandbox.status(harnessconfig))
    cprint("  context:        %s", (harnessconfig.context or {}).mode or "auto")
    cprint("  tools:          %d", #context:service("tools"):names())
    cprint("  skills:         %d", #context:service("skills"):all())
    cprint("  agents:         %d", #context:service("agents"):all())
    cprint("  plugins:        %d", #(context:service("plugins") or {}))
    return true
end

-- check the harness environment
function doctor(context)
    local harnessconfig = context:config()
    local provider = config.provider(harnessconfig)
    local lines = {colors.translate("${bright}the harness environment${clear}")}
    local function _check(name, ok, detail)
        table.insert(lines, colors.translate(string.format("  %s %s ${dim}%s${clear}",
            ok and "${green}[ok]${clear}" or "${color.failure}[!!]${clear}", text.pad(name, 18), detail or "")))
    end

    local curl = find_tool("curl")
    local git = find_tool("git")
    _check("curl", curl ~= nil, curl and curl.program or "not found, it is required")
    _check("git", git ~= nil, git and git.program or "not found, the skills cannot be synced")
    _check("api key", provider.apikey ~= nil and provider.apikey ~= "",
        string.format("%s, %s", provider.name, provider.models.main or "?"))
    _check("user config", os.isfile(config.userfile()), config.userfile())
    _check("skills", #context:service("skills"):all() > 0,
        string.format("%d loaded", #context:service("skills"):all()))
    _check("agents", #context:service("agents"):all() > 0,
        string.format("%d loaded", #context:service("agents"):all()))
    _check("tools", #context:service("tools"):names() > 0,
        string.format("%d registered", #context:service("tools"):names()))
    _check("plugins", true, string.format("%d loaded", #(context:service("plugins") or {})))
    _check("sandbox", true, sandbox.status(harnessconfig) .. ", available: " .. table.concat(sandbox.backends(), "/"))
    _check("terminal", true, string.format("%s, tty: %s, size: %dx%d", os.getenv("TERM") or "unknown",
        tostring(io.isatty()), terminal.size().width, terminal.size().height))
    _check("sessions", true, string.format("%d here, %d in total",
        #sessions.list({cwd = context:rootdir()}), #sessions.list({all = true})))
    return lines
end

-- list the harness resources
function list(context, kind)
    local listers = {
        skills = _skills, agents = _agents, tools = _tools, commands = _commands,
        plugins = _plugins, providers = _providers, sessions = _sessions
    }
    local lister = listers[kind]
    if not lister then
        raise("unknown list kind: %s", tostring(kind))
    end
    lister(context)
    return true
end

-- the skills
function _skills(context)
    for _, skill in ipairs(context:service("skills"):all()) do
        cprint("  ${bright}%s${clear} ${dim}[%s]${clear}\n    %s", skill.name, skill.source,
            text.truncate(skill.description, 100))
    end
end

-- the agents
function _agents(context)
    for _, agent in ipairs(context:service("agents"):all()) do
        cprint("  ${bright}%s${clear}\n    %s", agent.name, text.truncate(agent.description, 100))
    end
end

-- write a line which carries somebody else's text
--
-- never `print` and never `cprint`: both run the string through `vformat`,
-- which reads `$(..)` as an xmake variable and replaces it with nothing. a tool
-- description or a session title is not ours to reinterpret, and a command line
-- shown with its substitutions removed is a command line the reader has not
-- actually seen
--
function _say(str)
    io.write(tostring(str), "\n")
end

-- the tools
function _tools(context)
    for _, tool in ipairs(context:service("tools"):tools()) do
        cprint("  ${bright}%s${clear} ${dim}[%s]${clear}", tool.name, tool.permission or "none")
        -- an mcp server writes its own descriptions, they are not ours
        _say("    " .. text.truncate((tool.description or ""):gsub("\n.*", ""), 100))
    end
end

-- the commands
function _commands(context)
    for _, command in ipairs(context:service("commands"):all()) do
        cprint("  ${bright}/%s${clear}", command.name)
        _say("    " .. (command.description or ""))
    end
end

-- the plugins
function _plugins(context)
    for _, plugin in ipairs(context:service("plugins") or {}) do
        cprint("  ${bright}%s${clear}  %s\n    ${dim}%s${clear}", plugin.name, plugin.description or "", plugin.dir or "")
    end
end

-- the providers
function _providers(context)
    local harnessconfig = context:config()
    for _, name in ipairs(config.providernames(harnessconfig)) do
        local provider = config.provider(harnessconfig, name)
        cprint("  ${bright}%s${clear} ${dim}%s${clear}\n    %s  %s", text.pad(name, 14), provider.baseurl or "",
            provider.models.main or "", (provider.apikey and provider.apikey ~= "")
            and "${green}key configured${clear}" or "${dim}no key${clear}")
    end
end

-- the sessions of this project
function _sessions(context)
    local items = sessions.list({cwd = context:rootdir(), limit = 30})
    if #items == 0 then
        cprint("${dim}no session for %s yet.${clear}", context:rootdir())
        return
    end
    sessions_list(items)
end

-- print a session list
--
-- @param opt   the options, e.g. {title = "..", numbered = true}
--
function sessions_list(items, opt)
    opt = opt or {}
    if opt.title then
        cprint("${bright}%s${clear}", opt.title)
        io.write("\n")
    end
    for idx, meta in ipairs(items) do
        local prefix = opt.numbered and string.format("  ${bright}%d${clear}. ", idx) or "  "
        -- the title is the user's own first words, so it is written and not
        -- formatted, @see _say()
        _say(colors.translate(string.format("%s%s  ${dim}%s · %d msgs${clear}  ", prefix,
            os.date("%m-%d %H:%M", meta.updatetime or 0), meta.id, meta.events or 0),
            {patch_reset = false}) .. text.truncate(meta.title or "(no title)", 48))
    end
    if opt.numbered then
        io.write("\n")
    end
end
