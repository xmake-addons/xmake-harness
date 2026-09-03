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
-- @file        agentpacks.lua
--

--
-- a subagent is a markdown file, so a pack of them is a directory of markdown
-- and the machinery is the skills', @see harness.packs.packs
--

-- imports
import("harness.harness")
import("harness.packs.packs")
import("harness.agents.bundle")
import("harness.agents.registry", {alias = "agentregistry"})
import("harness.agents.installer", {alias = "installer"})

function _agent(name, description)
    return string.format("---\nname: %s\ndescription: %s\n---\n\nYou do the thing.\n",
                         name, description)
end

function _pack(files)
    local dir = os.tmpfile() .. ".agentpack"
    os.mkdir(dir)
    for name, content in pairs(files) do
        local filepath = path.join(dir, name)
        os.mkdir(path.directory(filepath))
        io.writefile(filepath, content)
    end
    return dir
end

---------------------------------------------------------------------------------
-- the layouts a pack may come in
---------------------------------------------------------------------------------

function test_the_usual_pack()
    local dir = _pack({["agents/porter.md"] = _agent("porter", "Port a project")})
    local layout = bundle.detect(dir)
    assert(layout == "agents", layout)
    assert(#bundle.agentfiles(dir) == 1, tostring(#bundle.agentfiles(dir)))
end

function test_somebody_elses_project_works_as_a_pack()
    -- the agents people already have are the agents worth having, and they are
    -- in `.claude/agents` and `.agents`
    for _, where in ipairs({".claude/agents/one.md", ".agents/one.md"}) do
        local dir = _pack({[where] = _agent("one", "Do one thing")})
        assert(#bundle.agentfiles(dir) == 1, string.format("%s: %d", where,
                                                           #bundle.agentfiles(dir)))
    end
end

function test_a_bare_directory_of_them()
    local dir = _pack({["a.md"] = _agent("a", "Do a"), ["b.md"] = _agent("b", "Do b"),
                       ["README.md"] = "# not an agent\n"})
    assert(bundle.detect(dir) == "flat", bundle.detect(dir))
    assert(#bundle.agentfiles(dir) == 2, tostring(#bundle.agentfiles(dir)))
end

function test_a_markdown_file_without_a_description_is_not_an_agent()
    -- an agent nothing can decide to use is not an agent
    local dir = _pack({["a.md"] = "---\nname: a\n---\nno description\n"})
    assert(#bundle.agentfiles(dir) == 0, tostring(#bundle.agentfiles(dir)))
end

function test_a_claude_marketplace()
    local dir = _pack({
        [".claude-plugin/marketplace.json"] = "{\"name\": \"mine\", \"plugins\": [{\"source\": \"./\"}]}",
        ["agents/one.md"] = _agent("one", "Do one thing")})
    assert(bundle.detect(dir) == "claude-market", bundle.detect(dir))
    assert(#bundle.agentfiles(dir) == 1, tostring(#bundle.agentfiles(dir)))
end

---------------------------------------------------------------------------------
-- installing one
---------------------------------------------------------------------------------

function test_what_a_specification_resolves_to()
    local instance = harness.bootstrap({rootdir = os.tmpdir(), trusted = true})
    local source = installer.resolve(instance, "github:someone/their-agents")
    assert(source and source.name == "their-agents", tostring(source and source.name))
    assert(source.url == "https://github.com/someone/their-agents.git", source.url)

    local dir = _pack({["agents/one.md"] = _agent("one", "Do one thing")})
    source = installer.resolve(instance, dir)
    assert(source and source.localdir == dir, tostring(source and source.localdir))

    local nothing, errors = installer.resolve(instance, "")
    assert(not nothing and errors:find("subagent pack", 1, true), tostring(errors))
end

function test_a_pack_registered_by_a_plugin()
    local instance = harness.bootstrap({rootdir = os.tmpdir(), trusted = true})
    installer.register(instance, {name = "theirs", url = "https://example.com/theirs.git",
                                  description = "their agents"})
    local source = installer.resolve(instance, "theirs")
    assert(source and source.url == "https://example.com/theirs.git", tostring(source))
    assert(installer.sources(instance)["theirs"], "and it is listed")
end

function test_installing_from_a_directory()
    local instance = harness.bootstrap({rootdir = os.tmpdir(), trusted = true})
    local dir = _pack({["agents/porter.md"] = _agent("packed-porter", "Port a project")})
    local source = installer.resolve(instance, dir)
    source.name = "test-agents-" .. tostring(os.time())

    local pack, errors = installer.install(source, {})
    assert(pack, tostring(errors))
    assert(pack.count == 1, tostring(pack.count))
    assert(installer.isinstalled(source.name), "and it is there")

    -- and the registry picks it up
    local registry = agentregistry.new()
    installer.loadall({service = function (self, name) return name == "agents" and registry or nil end})
    assert(registry:get("packed-porter"), "the agent of the pack is loaded")
    assert(registry:get("packed-porter").source == "pack:" .. source.name,
           registry:get("packed-porter").source)

    installer.remove(source.name)
    assert(not installer.isinstalled(source.name), "and it goes again")
end

---------------------------------------------------------------------------------
-- an agent which is a directory
---------------------------------------------------------------------------------

function test_an_agent_may_be_a_directory()
    -- one which brings more than a prompt is written as a directory, so adding
    -- a second builtin agent is a directory and not an edit
    local dir = _pack({["porter/AGENT.md"] = "---\ndescription: Port a project\n---\nDo it.\n"})
    local registry = agentregistry.new()
    registry:adddir(dir, "builtin")
    local one = registry:get("porter")
    assert(one, "it is named after its directory")
    assert(one.description == "Port a project", one.description)
    assert(one.dir and path.filename(one.dir) == "porter", tostring(one and one.dir))
end

function test_a_bundle_ships_the_skills_it_reads()
    -- an agent which needs a skill to do its work carries it, rather than
    -- asking the user to install one
    local dir = _pack({
        ["porter/AGENT.md"] = "---\ndescription: Port a project\n---\nDo it.\n",
        ["porter/skills/porting/SKILL.md"] = "---\nname: porting\ndescription: Use when porting\n---\nx\n"})
    local registry = agentregistry.new()
    registry:adddir(dir, "builtin")
    local dirs = registry:skilldirs()
    assert(#dirs == 1, tostring(#dirs))
    assert(dirs[1] == path.join(dir, "porter", "skills"), dirs[1])
end

function test_the_importer_is_one_of_them()
    -- the conversion is a self-contained thing: the agent and the three skills
    -- it reads live together, and installing it installs them
    local instance = harness.bootstrap({rootdir = os.tmpdir(), trusted = true})
    local porter = instance:service("agents"):get("xmake-porter")
    if not porter then
        return
    end
    assert(porter.dir and path.filename(porter.dir) == "xmake-porter", tostring(porter.dir))
    for _, name in ipairs({"xmake-import", "xmake-import-cmake", "xmake-import-msvc"}) do
        local skill = instance:service("skills"):get(name)
        assert(skill, name .. " is loaded")
        assert(skill.source == "agent:xmake-porter", string.format("%s: %s", name, skill.source))
    end
end

---------------------------------------------------------------------------------
-- the generic machinery is genuinely generic
---------------------------------------------------------------------------------

function test_a_kind_is_all_it_takes()
    -- skills and subagents are the same thing twice, and a third kind should be
    -- a table and not a copy of three hundred lines
    local kind = {
        name = "things", label = "thing", sources = "thingsources",
        roots = function (packdir) return {packdir} end,
        files = function (packdir) return os.files(path.join(packdir, "*.md")) end,
        describe = function (packdir) return path.filename(packdir), "flat" end
    }
    assert(packs.dir(kind):endswith("things"), packs.dir(kind))
    assert(packs.packname("https://github.com/a/b.git") == "b")
    assert(packs.dirname("/tmp/.hidden") == "hidden", packs.dirname("/tmp/.hidden"))
    assert(packs.archivename("/tmp/one.tar.gz") == "one", packs.archivename("/tmp/one.tar.gz"))
    assert(packs.isarchive("x.zip") and not packs.isarchive("x.md"))
end

---------------------------------------------------------------------------------
-- an agent which is more than a prompt
---------------------------------------------------------------------------------

import("harness.agents.script")
import("harness.core.subagent")

function _scripted(body)
    local dir = _pack({
        ["clever/AGENT.md"] = "---\ndescription: A clever one\ntools: read_file\n---\nDo it.\n",
        ["clever/agent.lua"] = body})
    local registry = agentregistry.new()
    registry:adddir(dir, "builtin")
    return registry:get("clever")
end

function test_an_agent_without_a_script_is_just_a_prompt()
    local dir = _pack({["plain.md"] = _agent("plain", "Do the thing")})
    local registry = agentregistry.new()
    registry:adddir(dir, "builtin")
    assert(not script.has(registry:get("plain")), "there is nothing to load")
end

function test_a_script_may_change_the_definition()
    -- a list of tools which depends on what is in the directory cannot be
    -- written in frontmatter
    local one = _scripted([[
function define(context)
    return {tools = {"read_file", "write_file"}, maxsteps = 12}
end
]])
    assert(script.has(one), "it has one")
    local changed = script.define(one, {})
    assert(#changed.tools == 2, tostring(#changed.tools))
    assert(changed.maxsteps == 12, tostring(changed.maxsteps))
    -- but not what it is called: that is what it was resolved by
    assert(changed.name == "clever", changed.name)
end

function test_a_script_may_add_to_the_prompt_and_to_the_task()
    local one = _scripted([[
function prompt(context)
    return "You also know that the sky is blue."
end
function before(context)
    return "I already looked: there are 3 targets."
end
]])
    assert(script.prompt(one, {}) == "You also know that the sky is blue.")
    assert(script.before(one, {}) == "I already looked: there are 3 targets.")
end

function test_a_script_may_have_the_last_word()
    local one = _scripted([[
function after(context, result)
    return "and that took " .. tostring(result.steps) .. " steps."
end
]])
    assert(script.after(one, {}, {steps = 4}) == "and that took 4 steps.")
end

function test_a_script_which_goes_wrong_is_reported_and_ignored()
    -- an agent which cannot be improved is better than a harness which cannot
    -- run one
    local one = _scripted([[
function define(context)
    error("I am broken")
end
]])
    local changed, errors = script.define(one, {})
    assert(changed == one, "the definition is unchanged")
    assert(errors and errors:find("script failed", 1, true), tostring(errors))
    assert(errors:find("clever", 1, true), errors)
end

function test_a_hook_which_is_not_there_is_not_an_error()
    local one = _scripted("function define(context) return {maxsteps = 5} end\n")
    assert(script.prompt(one, {}) == nil, "no prompt hook")
    assert(script.before(one, {}) == nil)
    assert(script.after(one, {}, {}) == nil)
end

function test_a_script_can_say_what_it_is_doing()
    -- the slow thing a `before` hook does is exactly the thing somebody is
    -- waiting on, @see harness.core.progress
    local progress = import("harness.core.progress", {anonymous = true})
    local one = _scripted([[
import("harness.core.progress")
function before(context)
    progress.stage(context.progress, "reading the project")
    return "done"
end
]])
    local channel = progress.new({label = "clever"})
    assert(script.before(one, {progress = channel}) == "done")
    assert(channel.stage == "reading the project", channel.stage)
end

---------------------------------------------------------------------------------
-- what is on disk and cannot be used
---------------------------------------------------------------------------------

function test_a_broken_agent_is_reported_and_not_skipped()
    -- a file skipped in silence still holds its name, and somebody who wrote a
    -- broken one sees it simply not appear: nothing to fix, nothing to delete
    local dir = _pack({
        ["good.md"] = _agent("good", "Do the thing"),
        ["nodescription.md"] = "---\nname: nodescription\n---\nYou do it.\n",
        ["nobody.md"] = "---\nname: nobody\ndescription: Does nothing\n---\n"})
    local one = agentregistry.new()
    one:adddir(dir, "user")

    assert(one:get("good"), "the good one is loaded")
    assert(not one:get("nodescription"), "and the broken ones are not")
    assert(not one:get("nobody"))

    local broken = one:broken()
    assert(#broken == 2, tostring(#broken))
    local why = {}
    for _, item in ipairs(broken) do
        why[item.name] = item.why
    end
    assert(why["nodescription"]:find("no description", 1, true), why["nodescription"])
    assert(why["nobody"]:find("no instructions", 1, true), why["nobody"])
    -- and it says where, because the point is being able to fix it
    assert(broken[1].filepath and os.isfile(broken[1].filepath), broken[1].filepath)
end

function test_an_agent_which_lost_its_name_says_so()
    -- a pack which brought a name somebody's own agent already has has
    -- contributed nothing, and silence about it is a pack which looks installed
    -- and does nothing
    local mine = _pack({["porter.md"] = _agent("porter", "Mine")})
    local theirs = _pack({["porter.md"] = _agent("porter", "Theirs")})
    local one = agentregistry.new()
    one:adddir(mine, "user")
    one:adddir(theirs, "pack:theirs")

    assert(one:get("porter").description == "Mine", one:get("porter").description)
    local shadowed = one:shadowed()
    assert(#shadowed == 1, tostring(#shadowed))
    assert(shadowed[1].name == "porter" and shadowed[1].source == "pack:theirs",
           string.format("%s/%s", shadowed[1].name, shadowed[1].source))
    assert(shadowed[1].takenby == "user", shadowed[1].takenby)
end

function test_the_listing_says_all_of_it()
    local instance = harness.bootstrap({rootdir = os.tmpdir(), trusted = true})
    local answer = instance:service("commands"):run({harness = instance}, "agents")
    assert(answer.text:find("subagent", 1, true), answer.text)
    assert(answer.text:find("AGENT.md", 1, true), "it says how to write one")
    assert(answer.text:find("/agents install", 1, true), "and how to install one")
end
