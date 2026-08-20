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
-- the tool registry
--
-- a tool is a plain module which exports two functions:
--
--   define()             -> {name = .., description = .., parameters = .., permission = ..}
--   run(context, args)   -> {output = ".."} or raises the errors
--
-- the builtin tools are discovered from `harness/tools/builtin/*.lua`, and the
-- plugins can register their own tools with `registry:add(definition)`.
--

-- imports
import("core.base.object")

-- define the registry class
local registry = registry or object {_init = {"_tools", "_order"}}

-- create a new registry
function new()
    return registry {{}, {}}
end

-- load all the builtin tools
function registry:load_builtin(disabled)
    local builtindir = path.join(os.scriptdir(), "builtin")
    local names = {}
    for _, filepath in ipairs(os.files(path.join(builtindir, "*.lua"))) do
        table.insert(names, path.basename(filepath))
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if not table.contains(disabled or {}, name) then
            local module = import("harness.tools.builtin." .. name, {anonymous = true, try = true})
            if module and module.define then
                local definition = module.define()
                definition.run = definition.run or module.run
                definition.source = "builtin"
                self:add(definition)
            end
        end
    end
    return self
end

-- add a tool
--
-- @param definition    the tool definition
--                      - name          the tool name, e.g. "read_file"
--                      - description   the description for the model
--                      - parameters    the json schema of the arguments
--                      - permission    "none"/"read"/"write"/"exec"/"network"
--                      - group         the group name, e.g. "fs", "shell", "xmake"
--                      - run           function (context, args) -> {output = ".."}
--                      - render        function (args) -> the short tui summary
--
function registry:add(definition)
    assert(definition and definition.name, "harness: invalid tool definition!")
    if not self._tools[definition.name] then
        table.insert(self._order, definition.name)
    end
    self._tools[definition.name] = definition
    return self
end

-- remove a tool
function registry:remove(name)
    self._tools[name] = nil
    for idx, toolname in ipairs(self._order) do
        if toolname == name then
            table.remove(self._order, idx)
            break
        end
    end
    return self
end

-- get a tool by name
function registry:get(name)
    return self._tools[name]
end

-- get all the tool names in the registration order
function registry:names()
    return self._order
end

-- get all the tools
function registry:tools()
    local results = {}
    for _, name in ipairs(self._order) do
        table.insert(results, self._tools[name])
    end
    return results
end

-- get the schemas which are sent to the model
--
-- @param opt   the options, e.g. {only = {"read_file"}, without = {"bash"}, groups = {"fs"}}
--
function registry:schemas(opt)
    opt = opt or {}
    local schemas = {}
    for _, name in ipairs(self._order) do
        local tool = self._tools[name]
        local ok = true
        if opt.only and not table.contains(opt.only, name) then
            ok = false
        end
        if opt.without and table.contains(opt.without, name) then
            ok = false
        end
        if opt.groups and not table.contains(opt.groups, tool.group) then
            ok = false
        end
        if ok and not tool.hidden then
            table.insert(schemas, {
                name = tool.name,
                description = tool.description,
                parameters = tool.parameters or {type = "object", properties = {}}
            })
        end
    end
    return schemas
end
