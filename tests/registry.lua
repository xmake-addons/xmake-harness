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

-- imports
import("harness.tools.registry", {alias = "toolregistry"})
import("harness.skills.registry", {alias = "skillregistry"})
import("harness.agents.registry", {alias = "agentregistry"})

function test_tools_builtin()
    local registry = toolregistry.new()
    registry:load_builtin()
    assert(registry:get("read_file") ~= nil)
    assert(registry:get("run_command") ~= nil)
    assert(#registry:names() >= 10, "tools: " .. #registry:names())
end

function test_tools_schemas()
    local registry = toolregistry.new()
    registry:load_builtin()
    local schemas = registry:schemas({only = {"read_file", "write_file"}})
    assert(#schemas == 2)
    assert(schemas[1].parameters.type == "object")
end

function test_tools_filter()
    local registry = toolregistry.new()
    registry:load_builtin()
    local all = #registry:schemas({})
    local without = #registry:schemas({without = {"run_command"}})
    assert(without == all - 1)
end

function test_tools_add()
    local registry = toolregistry.new()
    registry:add({name = "my_tool", description = "..", permission = "read"})
    assert(registry:get("my_tool").permission == "read")
    registry:remove("my_tool")
    assert(registry:get("my_tool") == nil)
end

function test_skills()
    local registry = skillregistry.new()
    local dir = path.join(os.scriptdir(), "..", "src", "modules", "harness", "assets", "skills")
    registry:adddir(dir, "test")
    local skills = registry:all()
    assert(#skills >= 1, "skills: " .. #skills)
    local skill = registry:get("harness-extending")
    assert(skill ~= nil and skill.description ~= "")
    assert(registry:content(skill):find("plugin", 1, true))
end

function test_agents()
    local registry = agentregistry.new()
    registry:adddir(path.join(os.scriptdir(), "..", "src", "modules", "harness", "assets", "agents"), "test")
    assert(registry:get("explorer") ~= nil)
    assert(registry:get("explorer").model == "small")
    assert(#registry:get("explorer").tools > 0)
end

function test_agents_disabled()
    local registry = agentregistry.new()
    registry:add({name = "a", description = ".."})
    registry:add({name = "b", description = ".."})
    assert(#registry:enabled({agents = {disabled = {"a"}}}) == 1)
end
