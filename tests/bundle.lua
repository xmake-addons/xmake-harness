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
-- @file        bundle.lua
--

-- imports
import("harness.skills.bundle")
import("harness.skills.registry", {alias = "skillregistry"})

-- write a skill file
function _skill(filepath, name, description)
    io.writefile(filepath, string.format("---\nname: %s\ndescription: %s\n---\n\nthe body\n",
        name, description or ("Use when doing " .. name)))
end

-- build one bundle of the given shape under a fresh directory
function _bundle(shape)
    local dir = os.tmpfile() .. ".bundle"
    os.tryrm(dir)
    os.mkdir(dir)
    if shape == "skills" then
        os.mkdir(path.join(dir, "skills", "alpha"))
        _skill(path.join(dir, "skills", "alpha", "SKILL.md"), "alpha")
    elseif shape == "flat" then
        os.mkdir(path.join(dir, "alpha"))
        _skill(path.join(dir, "alpha", "SKILL.md"), "alpha")
    elseif shape == "dsh" then
        _skill(path.join(dir, "alpha.md"), "alpha")
        io.writefile(path.join(dir, "README.md"), "# just a readme\n")
        io.writefile(path.join(dir, "notes.md"), "---\ntitle: no name\n---\nbody\n")
    elseif shape == "dsh-agents" then
        os.mkdir(path.join(dir, ".agents", "skills"))
        _skill(path.join(dir, ".agents", "skills", "alpha.md"), "alpha")
    elseif shape == "claude-plugin" then
        os.mkdir(path.join(dir, ".claude-plugin"))
        os.mkdir(path.join(dir, "skills", "alpha"))
        io.writefile(path.join(dir, ".claude-plugin", "plugin.json"),
            '{"name": "my-plugin", "description": "a plugin"}')
        _skill(path.join(dir, "skills", "alpha", "SKILL.md"), "alpha")
    elseif shape == "claude-market" then
        os.mkdir(path.join(dir, ".claude-plugin"))
        io.writefile(path.join(dir, ".claude-plugin", "marketplace.json"),
            '{"name": "my-market", "plugins": [{"name": "a", "source": "./plugins/a"},'
            .. ' {"name": "b", "source": "./plugins/b"}]}')
        for _, name in ipairs({"a", "b"}) do
            os.mkdir(path.join(dir, "plugins", name, "skills", name))
            _skill(path.join(dir, "plugins", name, "skills", name, "SKILL.md"), name)
        end
    elseif shape == "claude-market-self" then
        -- the marketplace whose only plugin is the repository itself, e.g. xmake-skills
        os.mkdir(path.join(dir, ".claude-plugin"))
        io.writefile(path.join(dir, ".claude-plugin", "marketplace.json"),
            '{"name": "self", "plugins": [{"name": "self", "source": "./"}]}')
        for _, name in ipairs({"alpha", "beta"}) do
            os.mkdir(path.join(dir, "skills", name))
            _skill(path.join(dir, "skills", name, "SKILL.md"), name)
        end
    elseif shape == "empty" then
        io.writefile(path.join(dir, "README.md"), "# nothing here\n")
    end
    return dir
end

function test_the_layouts_are_recognised()
    local expected = {skills = "skills", flat = "flat", dsh = "dsh",
                      ["claude-plugin"] = "claude-plugin", ["claude-market"] = "claude-market",
                      empty = "unknown"}
    for shape, kind in pairs(expected) do
        local dir = _bundle(shape)
        assert(bundle.detect(dir) == kind, string.format("%s was detected as %s", shape, bundle.detect(dir)))
        os.tryrm(dir)
    end
end

function test_a_skills_directory()
    local dir = _bundle("skills")
    assert(#bundle.skillfiles(dir) == 1)
    assert(bundle.roots(dir)[1] == path.join(dir, "skills"))
    os.tryrm(dir)
end

function test_a_dsh_flat_file_is_a_skill()
    -- one markdown file is one skill, which is how dsh keeps them
    local dir = _bundle("dsh")
    local files = bundle.skillfiles(dir)
    assert(#files == 1, string.format("%d files", #files))
    assert(path.filename(files[1]) == "alpha.md")
    os.tryrm(dir)
end

function test_a_readme_is_not_a_skill()
    -- neither a readme nor a markdown file without a name and a description
    local dir = _bundle("dsh")
    for _, filepath in ipairs(bundle.skillfiles(dir)) do
        assert(path.filename(filepath) ~= "README.md" and path.filename(filepath) ~= "notes.md",
            path.filename(filepath) .. " must not be a skill")
    end
    os.tryrm(dir)
end

function test_the_dsh_project_directories()
    -- a repository shaped like a project keeps them in `.agents/skills`
    local dir = _bundle("dsh-agents")
    assert(#bundle.skillfiles(dir) == 1)
    os.tryrm(dir)
end

function test_a_claude_plugin()
    local dir = _bundle("claude-plugin")
    local title, kind = bundle.describe(dir)
    assert(kind == "claude-plugin")
    assert(title:find("my-plugin", 1, true), title)
    assert(#bundle.skillfiles(dir) == 1)
    os.tryrm(dir)
end

function test_a_claude_marketplace_collects_every_plugin()
    local dir = _bundle("claude-market")
    assert(#bundle.roots(dir) == 2, "each plugin contributes its own root")
    assert(#bundle.skillfiles(dir) == 2)
    os.tryrm(dir)
end

function test_a_marketplace_whose_plugin_is_itself()
    -- `"source": "./"` points back at the repository, which is what xmake-skills does
    local dir = _bundle("claude-market-self")
    assert(#bundle.skillfiles(dir) == 2, string.format("%d files", #bundle.skillfiles(dir)))
    os.tryrm(dir)
end

function test_the_same_file_is_never_counted_twice()
    -- the patterns reach three levels down, so a nested root can find what the
    -- outer one already found
    local dir = _bundle("claude-market-self")
    local seen = {}
    for _, filepath in ipairs(bundle.skillfiles(dir)) do
        assert(not seen[filepath], "duplicated: " .. filepath)
        seen[filepath] = true
    end
    os.tryrm(dir)
end

function test_an_empty_bundle_holds_nothing()
    local dir = _bundle("empty")
    assert(#bundle.skillfiles(dir) == 0)
    os.tryrm(dir)
end

function test_a_flat_skill_is_loaded_by_the_registry()
    local dir = _bundle("dsh")
    local registry = skillregistry.new()
    registry:adddir(dir, "test")
    local skill = registry:get("alpha")
    assert(skill ~= nil, "the flat markdown skill was not loaded")
    assert(skill.description:find("alpha", 1, true), skill.description)
    os.tryrm(dir)
end

function test_the_excluded_directories_are_left_alone()
    -- an installed pack lives inside the user skills directory and is loaded on
    -- its own, the plain scan must not claim it first
    local dir = _bundle("skills")
    local registry = skillregistry.new()
    registry:adddir(dir, "user", {exclude = {path.join(dir, "skills")}})
    assert(registry:get("alpha") == nil, "the excluded directory was scanned anyway")
    os.tryrm(dir)
end

function test_a_hidden_directory_loses_its_dot()
    -- `~/.claude` and `~/.dsh` are exactly what one points this at, and
    -- `pack:.claude` reads like a mistake
    local installer = import("harness.skills.installer", {anonymous = true})
    local dir = _bundle("skills")
    local hidden = path.join(path.directory(dir), ".dsh-" .. path.basename(dir))
    os.mv(dir, hidden)
    local source = installer.resolve({service = function () return {} end}, hidden)
    assert(source ~= nil and not source.name:startswith("."), tostring(source and source.name))
    os.tryrm(hidden)
end
