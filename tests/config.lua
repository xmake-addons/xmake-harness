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
-- @file        config.lua
--

-- imports
import("harness.util.util")
import("harness.config.config")

function test_defaults()
    local defaults = config.defaults()
    assert(defaults.provider == "deepseek")
    assert(defaults.permission.mode == "default")
end

function test_provider_preset()
    local provider = config.provider({provider = "deepseek", providers = {deepseek = {apikey = "sk-test"}}})
    assert(provider.name == "deepseek")
    assert(provider.kind == "openai")
    assert(provider.baseurl:find("deepseek", 1, true))
    assert(provider.apikey == "sk-test")
    assert(provider.models.main ~= nil)
    assert(provider.models.small ~= nil)
end

function test_model_override()
    local provider = config.provider({provider = "deepseek", model = "my-model", providers = {}})
    assert(provider.models.main == "my-model")
    -- the small model keeps the preset, it is only overridden by `smallmodel`
    assert(provider.models.small ~= "my-model")
    local provider2 = config.provider({provider = "deepseek", smallmodel = "tiny", providers = {}})
    assert(provider2.models.small == "tiny")
end

function test_custom_provider()
    local harnessconfig = {provider = "mine", providers = {mine = {kind = "anthropic", baseurl = "https://x", apikey = "k",
        models = {main = "m"}}}}
    local provider = config.provider(harnessconfig)
    assert(provider.kind == "anthropic" and provider.models.main == "m")
end

function test_tget_tset()
    local tbl = {}
    util.tset(tbl, "providers.deepseek.apikey", "sk-1")
    assert(tbl.providers.deepseek.apikey == "sk-1")
    assert(util.tget(tbl, "providers.deepseek.apikey") == "sk-1")
    assert(util.tget(tbl, "providers.none.apikey") == nil)
end

function test_tmerge()
    local dst = {a = 1, nested = {x = 1, y = 2}}
    util.tmerge(dst, {a = 2, nested = {y = 3, z = 4}})
    assert(dst.a == 2)
    assert(dst.nested.x == 1 and dst.nested.y == 3 and dst.nested.z == 4)
end

function test_tovalue()
    assert(util.tovalue("true") == true)
    assert(util.tovalue("123") == 123)
    assert(util.tovalue("hello") == "hello")
end
