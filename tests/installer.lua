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
-- @file        installer.lua
--

-- imports
import("harness.core.context")
import("harness.skills.installer")

function _harness()
    local instance = context.new({})
    instance:service("skillsources", {})
    return instance
end

function test_register_and_resolve()
    local instance = _harness()
    installer.register(instance, {name = "mypack", url = "https://example.com/mypack.git", description = ".."})
    local source = installer.resolve(instance, "mypack")
    assert(source and source.url == "https://example.com/mypack.git")
end

function test_resolve_alias()
    local instance = _harness()
    installer.register(instance, {name = "short", url = "https://example.com/real.git", packname = "real-pack"})
    local source = installer.resolve(instance, "short")
    assert(source.name == "real-pack", source.name)
end

function test_resolve_github()
    local source = installer.resolve(_harness(), "github:xmake-io/xmake-skills")
    assert(source.name == "xmake-skills", source.name)
    assert(source.url == "https://github.com/xmake-io/xmake-skills.git", source.url)
end

function test_resolve_url()
    local source = installer.resolve(_harness(), "https://gitlab.com/user/my-skills.git")
    assert(source.name == "my-skills", source.name)
end

function test_resolve_localdir()
    local dir = path.join(os.tmpdir(), "harness-test-skills")
    os.mkdir(dir)
    local source = installer.resolve(_harness(), dir)
    assert(source.localdir ~= nil)
    assert(source.name == "harness-test-skills", source.name)
    os.tryrm(dir)
end

function test_resolve_unknown()
    local source, errors = installer.resolve(_harness(), "not-a-known-pack")
    assert(source == nil and errors ~= nil)
end
