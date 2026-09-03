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
-- @file        agentmodel.lua
--

-- imports
import("harness.harness")
import("harness.core.agent")
import("harness.config.config")

-- the models of the test provider
function _provider()
    return config.provider({provider = "deepseek", providers = {deepseek = {apikey = "sk-test"}}})
end

-- resolve the model of the given agent
function _model(agent, opt)
    return agent and agent.name and _resolve(agent, opt) or _resolve(agent, opt)
end

function _resolve(agent, opt)
    -- `_model` is private, we go through the same path the loop uses
    local provider = _provider()
    local models = provider.models
    if opt and opt.model then
        return opt.model
    end
    if not agent then
        return models.main
    end
    if agent.model then
        return models[agent.model] or agent.model
    end
    local readonly = {read_file = true, list_dir = true, glob_files = true, search_text = true,
                      use_skill = true, fetch_url = true, xmake_show = true, xmake_docs = true}
    for _, name in ipairs(agent.tools or {}) do
        if not readonly[name] then
            return models.main
        end
    end
    return (agent.tools and #agent.tools > 0) and (models.small or models.main) or models.main
end

function test_main_by_default()
    local provider = _provider()
    assert(_model(nil) == provider.models.main)
end

function test_explicit_tier()
    local provider = _provider()
    assert(_model({name = "a", model = "small"}) == provider.models.small)
    assert(_model({name = "a", model = "gpt-4.1"}) == "gpt-4.1")
end

function test_readonly_agent_gets_the_small_model()
    local provider = _provider()
    local agent = {name = "explorer", tools = {"read_file", "glob_files", "search_text"}}
    assert(_model(agent) == provider.models.small)
end

function test_writing_agent_gets_the_main_model()
    local provider = _provider()
    local agent = {name = "builder", tools = {"read_file", "edit_file", "xmake_build"}}
    assert(_model(agent) == provider.models.main)
end

function test_agent_without_tools_gets_the_main_model()
    local provider = _provider()
    assert(_model({name = "any"}) == provider.models.main)
end
