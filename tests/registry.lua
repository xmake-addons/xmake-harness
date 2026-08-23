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

-- write a skill file
function _skillfile(dir, name, description)
    os.mkdir(dir)
    local filepath = path.join(dir, "SKILL.md")
    io.writefile(filepath, string.format("---\nname: %s\ndescription: %s\n---\n\nbody\n",
        name, description or ("Use when doing " .. name)))
    return filepath
end

function test_skills_the_first_name_wins()
    local root = os.tmpfile() .. ".skills"
    os.tryrm(root)
    _skillfile(path.join(root, "alpha"), "shared")
    _skillfile(path.join(root, "beta"), "shared")
    local registry = skillregistry.new()
    registry:adddir(root, "test")
    assert(#registry:all() == 1, "the same name must not be loaded twice")
    os.tryrm(root)
end

function test_skills_a_shadowed_name_is_reported()
    -- dropping the second one is right, dropping it silently is not: the pack
    -- would report more skills than it contributed and nobody could tell which
    local root = os.tmpfile() .. ".skills"
    os.tryrm(root)
    local first = _skillfile(path.join(root, "alpha"), "shared")
    local second = _skillfile(path.join(root, "beta"), "shared")
    local registry = skillregistry.new()
    registry:adddir(root, "test")

    local shadowed = registry:shadowed()
    assert(#shadowed == 1, string.format("%d reported", #shadowed))
    assert(shadowed[1].name == "shared")
    assert(shadowed[1].filepath == second, shadowed[1].filepath)
    assert(shadowed[1].takenfrom == first, tostring(shadowed[1].takenfrom))
    assert(shadowed[1].source == "test")
    os.tryrm(root)
end

function test_skills_nothing_shadowed_reports_nothing()
    local root = os.tmpfile() .. ".skills"
    os.tryrm(root)
    _skillfile(path.join(root, "alpha"), "one")
    _skillfile(path.join(root, "beta"), "two")
    local registry = skillregistry.new()
    registry:adddir(root, "test")
    assert(#registry:shadowed() == 0)
    os.tryrm(root)
end

-- the tool card of a call which failed
function test_a_failed_tool_still_renders_a_card()
    -- the pipeline's error result carries no display: the call never got that
    -- far. the card still has to name the tool, and it must never take the
    -- session down with it
    local transcript = import("harness.ui.transcript", {anonymous = true})
    local result = {id = "x", name = "edit_file", iserror = true,
                    output = "the old string was not found", duration = 3}
    local lines = transcript.tool(result, {width = 80})
    assert(#lines > 0)
    local text = table.concat(lines, "\n")
    assert(text:find("edit_file", 1, true), "the card must say which tool failed:\n" .. text)
    assert(text:find("the old string was not found", 1, true), text)
end

function test_a_style_survives_a_missing_value()
    local theme = import("harness.ui.theme", {anonymous = true})
    assert(theme.styled("tool.name", nil) == "" or type(theme.styled("tool.name", nil)) == "string")
    assert(type(theme.styled("tool.name", 42)) == "string")
end
