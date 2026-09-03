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
-- @file        info.lua
--

--
-- the informational commands: /help, /status, /agents, /tools, /plugins,
-- /doctor, /cwd, /init
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.config.config")
import("harness.sandbox.sandbox")

-- the commands of this group
function commands()
    return {
        {name = "help",    description = "Show the available commands and the shortcuts",  run = _help},
        {name = "status",  description = "Show the harness status: the provider, the model, the tools", run = _status},
        {name = "tools",   description = "List the registered tools",                      run = _tools},
        {name = "plugins", description = "List the loaded harness plugins",                run = _plugins},
        {name = "doctor",  description = "Check the harness environment",                  run = _doctor},
        {name = "cwd",     description = "Show or change the working directory",           run = _cwd},
        {name = "init",    description = "Create the project instruction file (XMAKE.md)", run = _init}
    }
end

-- the keyboard shortcuts, they are shown by /help
local SHORTCUTS = {
    {"enter",       "send the message"},
    {"alt+enter",   "insert a new line"},
    {"shift+tab",   "cycle the permission mode"},
    {"esc",         "interrupt the current work"},
    {"ctrl+c",      "clear the input, twice to exit"},
    {"ctrl+d",      "exit"},
    {"ctrl+l",      "clear the screen"},
    {"up/down",     "browse the input history"},
    {"/ and @",     "the command and the file completion"},
    {"!<command>",  "run a shell command directly"}
}

-- /help
function _help(app)
    local lines = {"Commands:"}
    for _, command in ipairs(app.harness:service("commands"):all()) do
        table.insert(lines, string.format("  %s %s", text.pad("/" .. command.name, 14), command.description))
    end
    table.insert(lines, "")
    table.insert(lines, "Shortcuts:")
    for _, shortcut in ipairs(SHORTCUTS) do
        table.insert(lines, string.format("  %s %s", text.pad(shortcut[1], 14), shortcut[2]))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /status
function _status(app)
    local harnessconfig = app.harness:config()
    local provider = config.provider(harnessconfig)
    local lines = {
        string.format("provider:    %s (%s)", provider.name, provider.baseurl),
        string.format("model:       %s / %s", provider.models.main, provider.models.small),
        string.format("api key:     %s", (provider.apikey and provider.apikey ~= "") and "configured" or "missing"),
        string.format("cwd:         %s", app.harness:rootdir()),
        string.format("mode:        %s", app.mode),
        string.format("sandbox:     %s", sandbox.status(harnessconfig)),
        string.format("session:     %s (%d events)", app.session:id(), #app.session:events()),
        string.format("tools:       %d", #app.harness:service("tools"):names()),
        string.format("skills:      %d", #app.harness:service("skills"):all()),
        string.format("agents:      %d", #app.harness:service("agents"):all())
    }
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
        table.insert(lines, string.format("  %s %s %s", text.pad(tool.name, 16),
            text.pad("[" .. (tool.permission or "none") .. "]", 10),
            text.truncate((tool.description or ""):gsub("\n.*", ""), 80)))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /plugins
function _plugins(app)
    local plugins = app.harness:service("plugins") or {}
    local lines = {string.format("%d plugins:", #plugins), ""}
    for _, plugin in ipairs(plugins) do
        table.insert(lines, string.format("  %s %s", text.pad(plugin.name, 16),
            text.truncate(plugin.description or "", 90)))
    end
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /doctor
function _doctor(app)
    local aicli = import("harness.cli.ai", {anonymous = true})
    local terminal = import("harness.ui.terminal", {anonymous = true})
    local lines = aicli.doctor(app.harness)
    table.insert(lines, string.format("  %s %s %s", theme.styled("success", "[ok]"),
        text.pad("input", 18), theme.styled("dim", terminal.inputbackend())))
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /cwd [dir]
function _cwd(app, args)
    args = (args or ""):trim()
    if args == "" then
        return {kind = "message", text = app.harness:rootdir()}
    end
    local dir = path.absolute(args, app.harness:rootdir())
    if not os.isdir(dir) then
        return {kind = "message", text = string.format("%s is not a directory", dir), iserror = true}
    end
    app.harness:rootdir_set(path.normalize(dir))
    return {kind = "message", text = "the working directory is switched to " .. dir}
end

-- /init
function _init()
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
