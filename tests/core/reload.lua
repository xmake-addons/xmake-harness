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
-- @file        reload.lua
--

-- imports
import("harness.harness")
import("harness.core.reload", {alias = "reloader"})

function _harness()
    local rootdir = os.tmpfile() .. ".reload"
    os.mkdir(path.join(rootdir, ".xmake-harness", "skills", "made-up"))
    -- the project resources are what is under test here, so the project is
    -- trusted: whether it should be asked about first is tests/trust.lua
    return harness.bootstrap({rootdir = rootdir, trusted = true}), rootdir
end

-- a skill which was not there when the harness started
function _addskill(rootdir, name, description)
    local dir = path.join(rootdir, ".xmake-harness", "skills", name)
    os.mkdir(dir)
    io.writefile(path.join(dir, "SKILL.md"), string.format(
        "---\nname: %s\ndescription: %s\n---\n\nDo the thing.\n", name, description))
end

---------------------------------------------------------------------------------
-- reading it all again
---------------------------------------------------------------------------------

function test_a_skill_written_now_is_usable_now()
    -- the session is the expensive thing in a running harness, and restarting it
    -- to pick up a file is paying with the context to read a directory
    local instance, rootdir = _harness()
    local before = #instance:service("skills"):all()
    _addskill(rootdir, "brand-new", "Use when something brand new happens")

    assert(#instance:service("skills"):all() == before, "it is not there until we look")
    local counted = reloader.everything(instance)
    assert(counted.skills == before + 1, string.format("%d against %d", counted.skills, before + 1))
    assert(instance:service("skills"):get("brand-new"), "and now it is")
end

function test_the_configuration_table_is_filled_and_not_replaced()
    -- everything which was handed a configuration at startup holds this table,
    -- so handing out a new one would leave all of them reading the old
    local instance = _harness()
    local config = instance:config()
    config.temperature = 0.9
    reloader.settings(instance)
    assert(instance:config() == config, "it is the same table")
    assert(config.temperature ~= 0.9, "and it was read again")
end

function test_a_command_which_was_handed_over_survives()
    -- the plugins are not loaded again, so a command one added at startup would
    -- otherwise disappear the first time somebody typed /reload
    local instance = _harness()
    instance:service("commands"):add({name = "from-a-plugin", description = "..",
                                      run = function () end})
    reloader.commands(instance)
    assert(instance:service("commands"):get("from-a-plugin"), "it is still there")
end

function test_a_markdown_command_which_was_deleted_does_not_come_back()
    local instance, rootdir = _harness()
    local dir = path.join(rootdir, ".xmake-harness", "commands")
    os.mkdir(dir)
    io.writefile(path.join(dir, "only-here.md"), "---\ndescription: Only here\n---\nDo $ARGUMENTS\n")
    reloader.commands(instance)
    assert(instance:service("commands"):get("only-here"), "it is read")

    os.rm(path.join(dir, "only-here.md"))
    reloader.commands(instance)
    assert(not instance:service("commands"):get("only-here"), "and it goes when the file goes")
end

function test_a_project_command_shadows_the_builtin_one_and_gives_it_back()
    -- the directories are read in order and the first name wins, so a project
    -- `review.md` is the review command until it is deleted
    local instance, rootdir = _harness()
    local builtin = instance:service("commands"):get("review")
    if not builtin then
        return
    end
    local dir = path.join(rootdir, ".xmake-harness", "commands")
    os.mkdir(dir)
    io.writefile(path.join(dir, "review.md"), "---\ndescription: Mine\n---\nMine $ARGUMENTS\n")
    reloader.commands(instance)
    assert(instance:service("commands"):get("review").source == "project",
           instance:service("commands"):get("review").source)

    os.rm(path.join(dir, "review.md"))
    reloader.commands(instance)
    assert(instance:service("commands"):get("review").source == "builtin",
           instance:service("commands"):get("review").source)
end

---------------------------------------------------------------------------------
-- a skill somebody opens by hand
---------------------------------------------------------------------------------

function test_every_skill_is_a_command()
    -- the model decides on its own whether a skill is worth opening and it does
    -- not always decide to, @see harness.core.reload.skillcommands
    local instance, rootdir = _harness()
    _addskill(rootdir, "picky", "Use when the model will not pick this by itself")
    reloader.everything(instance)

    local command = instance:service("commands"):get("skill:picky")
    assert(command, "there is a command for it")
    assert(command.description:find("will not pick", 1, true), command.description)
    assert(#instance:service("commands"):find("skill:pic") == 1, "and the completion finds it")
end

function test_opening_one_by_hand_says_what_it_is_for()
    local instance, rootdir = _harness()
    _addskill(rootdir, "picky", "Use when it matters")
    reloader.everything(instance)
    local app = {harness = instance}

    local answer = instance:service("commands"):run(app, "skill:picky build the thing")
    assert(answer.kind == "prompt", answer.kind)
    assert(answer.text:find("use_skill", 1, true), answer.text)
    assert(answer.text:find("picky", 1, true), answer.text)
    assert(answer.text:find("build the thing", 1, true), answer.text)
end

function test_opening_one_with_nothing_to_do_is_refused()
    -- loading a skill on its own costs a turn and answers nothing
    local instance, rootdir = _harness()
    _addskill(rootdir, "picky", "Use when it matters")
    reloader.everything(instance)

    local answer = instance:service("commands"):run({harness = instance}, "skill:picky")
    assert(answer.kind == "message", answer.kind)
    assert(answer.text:find("what you want done", 1, true), answer.text)
end

function test_a_skill_which_went_away_is_not_still_a_command()
    local instance, rootdir = _harness()
    _addskill(rootdir, "temporary", "Use when it is here")
    reloader.everything(instance)
    assert(instance:service("commands"):get("skill:temporary"))

    os.rm(path.join(rootdir, ".xmake-harness", "skills", "temporary"))
    reloader.everything(instance)
    assert(not instance:service("commands"):get("skill:temporary"), "and not when it is not")
end

function test_a_plugin_skill_survives_a_reload()
    -- the plugins are not loaded again, so a skill one shipped would otherwise
    -- disappear the first time somebody typed /reload, and the only sign would
    -- be a skill which used to be listed and is not
    local instance = _harness()
    local before = instance:service("skills"):get("xmake-import")
    if not before then
        return
    end
    reloader.everything(instance)
    assert(instance:service("skills"):get("xmake-import"), "it is still there")
    assert(instance:service("commands"):get("skill:xmake-import"), "and can still be opened")
end

function test_a_plugin_subagent_survives_a_reload()
    local instance = _harness()
    if not instance:service("agents"):get("xmake-porter") then
        return
    end
    reloader.everything(instance)
    assert(instance:service("agents"):get("xmake-porter"), "it is still there")
end
