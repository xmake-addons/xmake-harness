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
-- @file        registry.lua
--

--
-- the slash command registry
--
-- a command is either a lua definition (the builtin ones and the ones added by
-- the plugins) or a markdown file which expands to a prompt:
--
--   commands/review.md
--   ---
--   description: Review the current changes
--   ---
--   Review the changes of `git diff` and report the problems: $ARGUMENTS
--
-- the lua commands return an action to the tui:
--
--   {kind = "message", text = ".."}  print something
--   {kind = "prompt",  text = ".."}  send a prompt to the model
--   {kind = "exit"}                  quit the tui
--   {kind = "none"}                  nothing, the command did everything itself
--

-- imports
import("core.base.object")
import("harness.util.frontmatter")
import("harness.config.config")

-- define the registry class
local registry = registry or object {_init = {"_commands", "_order"}}

-- create a new registry
function new()
    return registry {{}, {}}
end

-- get the default command directories
function defaultdirs(harnessconfig, rootdir)
    local dirs = {
        path.join(os.scriptdir(), "..", "assets", "commands"),
        path.join(config.homedir(), "commands")
    }
    -- the project commands, once the project is trusted, @see harness.config.trust
    if (harnessconfig or {})._trusted ~= false then
        table.insert(dirs, path.join(rootdir or os.curdir(), ".xmake-harness", "commands"))
    end
    return dirs
end

-- load the builtin commands
function registry:load_builtin()
    local builtin = import("harness.commands.builtin", {anonymous = true})
    for _, definition in ipairs(builtin.commands()) do
        self:add(definition)
    end
    return self
end

-- add a command directory
function registry:adddir(dir, source)
    if not os.isdir(dir) then
        return self
    end
    for _, filepath in ipairs(os.files(path.join(dir, "*.md"))) do
        local content = io.readfile(filepath) or ""
        local attributes, body = frontmatter.parse(content)
        local name = attributes.name or path.basename(filepath)
        self:add({
            name = name,
            description = attributes.description or "",
            source = source or "user",
            filepath = filepath,
            prompt = body
        })
    end
    return self
end

-- add a command
function registry:add(definition)
    assert(definition and definition.name, "harness: invalid command definition!")
    if not self._commands[definition.name] then
        table.insert(self._order, definition.name)
    end
    self._commands[definition.name] = definition
    return self
end

-- take a command away again
function registry:remove(name)
    if self._commands[name] then
        self._commands[name] = nil
        for idx, one in ipairs(self._order) do
            if one == name then
                table.remove(self._order, idx)
                break
            end
        end
    end
    return self
end

-- get a command by name
function registry:get(name)
    return self._commands[name]
end

-- get all the commands
function registry:all()
    local results = {}
    for _, name in ipairs(self._order) do
        table.insert(results, self._commands[name])
    end
    table.sort(results, function (a, b) return a.name < b.name end)
    return results
end

-- find the commands with the given prefix, it is used by the completion
function registry:find(prefix)
    local results = {}
    for _, command in ipairs(self:all()) do
        if command.name:startswith(prefix) then
            table.insert(results, command)
        end
    end
    return results
end

-- run the given command line, e.g. "/model deepseek-reasoner"
--
-- @param app       the tui application
-- @param line      the command line without the leading slash
--
function registry:run(app, line)
    local name, argstr = line:match("^(%S+)%s*(.*)$")
    if not name then
        return {kind = "message", text = "the command is empty"}
    end
    local command = self:get(name)
    if not command then
        return {kind = "message", text = string.format("unknown command: /%s, try /help", name), iserror = true}
    end
    if command.run then
        return command.run(app, argstr or "") or {kind = "none"}
    end
    if command.prompt then
        local prompt = command.prompt:gsub("%$ARGUMENTS", (argstr or ""):gsub("%%", "%%%%"))
        return {kind = "prompt", text = prompt}
    end
    return {kind = "none"}
end
