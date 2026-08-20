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
-- @file        ai.lua
--

--
-- the entry of `xmake ai`
--

-- imports
import("core.base.json")
import("core.base.colors")
import("lib.detect.find_tool")
import("harness.harness")
import("harness.util.util")
import("harness.util.text")
import("harness.ui.app")
import("harness.ui.theme")
import("harness.cli.headless")
import("harness.config.config")
import("harness.sandbox.sandbox")
import("harness.core.session", {alias = "sessions"})

-- the main entry
function main(options)
    options = options or {}

    -- the configuration subcommands do not need the whole harness
    if options.config then
        return setconfig(options.config)
    end

    local rootdir = options.cwd and path.absolute(options.cwd) or os.curdir()
    local overrides = _overrides(options)
    local context = harness.bootstrap({rootdir = rootdir, options = overrides})

    if options.apikey then
        local name = context:config().provider
        config.set(string.format("providers.%s.apikey", name), options.apikey)
        cprint("${bright green}the api key of %s is saved to %s", name, config.userfile())
        return
    end
    if options.showconfig then
        return showconfig(context)
    end
    if options.doctor then
        for _, line in ipairs(doctor(context)) do
            print(line)
        end
        return
    end
    if options.setup then
        return setup(context)
    end
    if options.list then
        return list(context, options.list)
    end
    if options.command then
        return runcommand(context, options.command, options)
    end

    -- resolve the session
    local session = nil
    if options.resume then
        local loaded, errors = sessions.load(options.resume)
        if not loaded then
            raise(errors)
        end
        session = loaded
    elseif options["continue"] then
        session = sessions.last(rootdir)
        if not session then
            cprint("${color.warning}no previous session in this directory, starting a new one")
        end
    end

    -- the prompt from the command line
    local prompt = nil
    if options.prompt and #options.prompt > 0 then
        prompt = table.concat(options.prompt, " ")
    end

    -- check the api key early, so the user gets a clear message
    local provider = config.provider(context:config())
    if not provider.apikey or provider.apikey == "" then
        if io.isatty() and not options["print"] then
            setup(context)
            provider = config.provider(context:config())
        end
        if not provider.apikey or provider.apikey == "" then
            raise("the api key of the provider(%s) is not configured!\n"
                .. "run `xmake ai --apikey=<your key>` or `xmake ai --setup` first.", provider.name)
        end
    end

    -- the non-interactive mode
    if options["print"] or not io.isatty() then
        if not prompt then
            -- read the prompt from the stdin
            prompt = io.read("a")
        end
        if not prompt or prompt:trim() == "" then
            raise("no prompt is given!")
        end
        return headless.run(context, {
            prompt = prompt,
            session = session,
            quiet = options.quiet,
            mode = options.mode})
    end

    -- the interactive tui
    local instance = app.new(context, {session = session, mode = options.mode})
    instance:run({prompt = prompt, replay = session ~= nil})
end

-- build the configuration overrides of the command line options
function _overrides(options)
    local overrides = {}
    if options.provider then
        overrides.provider = options.provider
    end
    if options.model then
        overrides.model = options.model
    end
    if options.smallmodel then
        overrides.smallmodel = options.smallmodel
    end
    if options.mode then
        overrides.permission = {mode = options.mode}
    end
    if options.sandbox then
        overrides.sandbox = {enabled = true}
    end
    if options.notools then
        overrides.notools = true
    end
    return overrides
end

-- set the user configuration, e.g. --config=providers.deepseek.apikey=sk-xxx
function setconfig(assignment)
    local key, value = assignment:match("^([^=]+)=(.*)$")
    if not key then
        local current = config.get(assignment)
        cprint("%s = ${bright}%s", assignment, tostring(current))
        return
    end
    local parsed = util.tovalue(value)
    config.set(key, parsed)
    cprint("${bright green}%s${clear} = %s ${dim}(saved to %s)", key, tostring(parsed), config.userfile())
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
    cprint("  theme:          %s", theme.current().name)
    cprint("  tools:          %d", #context:service("tools"):names())
    cprint("  skills:         %d", #context:service("skills"):all())
    cprint("  agents:         %d", #context:service("agents"):all())
    cprint("  plugins:        %d", #(context:service("plugins") or {}))
end

-- the interactive setup wizard
function setup(context)
    local harnessconfig = context:config()
    cprint("")
    cprint("${bright}welcome to xmake ai${clear}")
    cprint("${dim}the configuration is saved to %s, it never touches your project.${clear}", config.userfile())
    cprint("")

    local names = config.providernames(harnessconfig)
    cprint("the available providers:")
    for idx, name in ipairs(names) do
        local provider = config.provider(harnessconfig, name)
        cprint("  ${bright}%d${clear}. %s ${dim}%s%s${clear}", idx, text.pad(name, 14),
            provider.models.main or "", (provider.apikey and provider.apikey ~= "") and "  (key configured)" or "")
    end
    cprint("")
    io.write(string.format("choose the provider [%s]: ", harnessconfig.provider))
    io.flush()
    local answer = (io.read("l") or ""):trim()
    local name = harnessconfig.provider
    if answer ~= "" then
        local index = tonumber(answer)
        name = index and names[index] or answer
    end
    if not name or not config.provider(harnessconfig, name) then
        raise("unknown provider: %s", tostring(answer))
    end
    config.set("provider", name)
    harnessconfig.provider = name

    local provider = config.provider(harnessconfig, name)
    if provider.apikeyurl then
        cprint("${dim}get an api key at %s${clear}", provider.apikeyurl)
    end
    io.write(string.format("the api key of %s%s: ", name,
        (provider.apikey and provider.apikey ~= "") and " (enter to keep the current one)" or ""))
    io.flush()
    local apikey = (io.read("l") or ""):trim()
    if apikey ~= "" then
        config.set(string.format("providers.%s.apikey", name), apikey)
        harnessconfig.providers = harnessconfig.providers or {}
        harnessconfig.providers[name] = harnessconfig.providers[name] or {}
        harnessconfig.providers[name].apikey = apikey
    end
    cprint("")
    cprint("${bright green}the setup is done${clear}, run `xmake ai` to start.")
    cprint("")
end

-- list the harness resources
function list(context, kind)
    if kind == "skills" then
        for _, skill in ipairs(context:service("skills"):all()) do
            cprint("  ${bright}%s${clear} ${dim}[%s]${clear}\n    %s", skill.name, skill.source, text.truncate(skill.description, 100))
        end
    elseif kind == "agents" then
        for _, agent in ipairs(context:service("agents"):all()) do
            cprint("  ${bright}%s${clear}\n    %s", agent.name, text.truncate(agent.description, 100))
        end
    elseif kind == "tools" then
        for _, tool in ipairs(context:service("tools"):tools()) do
            cprint("  ${bright}%s${clear} ${dim}[%s]${clear}\n    %s", tool.name, tool.permission or "none",
                text.truncate((tool.description or ""):gsub("\n.*", ""), 100))
        end
    elseif kind == "commands" then
        for _, command in ipairs(context:service("commands"):all()) do
            cprint("  ${bright}/%s${clear}  %s", command.name, command.description or "")
        end
    elseif kind == "plugins" then
        for _, plugin in ipairs(context:service("plugins") or {}) do
            cprint("  ${bright}%s${clear}  %s\n    ${dim}%s${clear}", plugin.name, plugin.description or "", plugin.dir or "")
        end
    elseif kind == "providers" then
        local harnessconfig = context:config()
        for _, name in ipairs(config.providernames(harnessconfig)) do
            local provider = config.provider(harnessconfig, name)
            cprint("  ${bright}%s${clear} ${dim}%s${clear}\n    %s  %s", text.pad(name, 14), provider.baseurl or "",
                provider.models.main or "", (provider.apikey and provider.apikey ~= "") and "${green}key configured${clear}" or "${dim}no key${clear}")
        end
    elseif kind == "sessions" then
        for _, meta in ipairs(sessions.list({cwd = context:rootdir(), limit = 30})) do
            cprint("  ${bright}%s${clear}  %s  %s", meta.id, os.date("%Y-%m-%d %H:%M", meta.updatetime or 0),
                text.truncate(meta.title or "(no title)", 60))
        end
    else
        raise("unknown list kind: %s", tostring(kind))
    end
end

-- check the harness environment
--
-- it is shared by `xmake ai --doctor` and the `/doctor` command, so both report
-- exactly the same thing
--
-- @return  the rendered lines
--
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
    _check("terminal", true, string.format("%s, tty: %s", os.getenv("TERM") or "unknown", tostring(io.isatty())))
    _check("sessions", true, string.format("%d in %s", #sessions.list({}), sessions.dir()))
    return lines
end

-- run one slash command without entering the tui
--
-- e.g. xmake ai --command=doctor
--      xmake ai --command="model deepseek-reasoner"
--      xmake ai --command="xmake-skills"
--
function runcommand(context, line, options)
    local app = _shimapp(context, options)
    local result = context:service("commands"):run(app, line)
    if result.kind == "prompt" then
        return headless.run(context, {prompt = result.text, session = app.session,
            quiet = options.quiet, mode = options.mode})
    end
    if result.text then
        if result.iserror then
            cprint("${color.failure}%s", result.text)
            os.exit(1)
        end
        print(result.text)
    end
end

-- make a minimal application shim, so the commands can run outside the tui
function _shimapp(context, options)
    return {
        harness = context,
        session = sessions.new({cwd = context:rootdir()}),
        mode = options and options.mode or (context:config().permission or {}).mode or "default",
        notify = function (self, message)
            cprint("${dim}%s${clear}", message)
        end,
        setmode = function (self, mode)
            self.mode = mode
            util.tset(context:config(), "permission.mode", mode)
        end,
        newsession = function (self)
            self.session = sessions.new({cwd = context:rootdir()})
            return self.session
        end,
        setsession = function (self, session)
            self.session = session
        end
    }
end
