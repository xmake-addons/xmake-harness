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
-- @file        prompt.lua
--

-- imports
import("harness.harness")
import("harness.prompt.system")
import("harness.config.config")
import("harness.core.session", {alias = "sessions"})

-- a harness, and a conversation held in the given language
function _built(opt)
    opt = opt or {}
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    if opt.code then
        instance:config().code = opt.code
    end
    if opt.skills then
        -- a registry of exactly these, so the listing under test is not the one
        -- which happens to be installed on the machine running the tests
        instance:service("skills", {enabled = function (self, harnessconfig)
            return opt.skills
        end})
    end
    local session = nil
    if opt.says then
        session = sessions.new({cwd = os.tmpdir()})
        session:append("user", {text = opt.says})
    end
    return system.build(instance, {session = session, mode = "default", agent = opt.agent})
end

-- the named section of a prompt
function _section(text, title)
    local lines = {}
    local keep = false
    for _, line in ipairs(text:split("\n", {strict = true})) do
        if line:startswith("# " .. title) then
            keep = true
        elseif line:startswith("# ") then
            keep = false
        end
        if keep then
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------------
-- the language of the answer is not the language of the code
---------------------------------------------------------------------------------

function test_the_user_language_only_governs_the_answer()
    -- a conversation held in chinese is answered in chinese, and that is all it
    -- decides: the comments which go into the files are a separate question
    local style = _section(_built({says = "帮我加一个函数，别破坏原来的逻辑"}), "Style")
    assert(style:find("answer in Chinese", 1, true), style)
    assert(style:find("not what you write into the files", 1, true), style)
end

function test_english_is_not_singled_out()
    local style = _section(_built({says = "add a function for me please"}), "Style")
    assert(style:find("Answer in the language the user writes in", 1, true), style)
end

function test_the_comments_are_asked_for_in_english()
    local code = _section(_built({says = "帮我加一个函数，别破坏原来的逻辑"}), "Writing the code")
    assert(code:find("Write the comments in English", 1, true), code)
end

function test_what_the_agent_wrote_is_not_a_convention()
    -- otherwise it locks itself in: one file of chinese comments becomes the
    -- reason for the next one, and the rule which was meant to keep the codebase
    -- consistent keeps the mistake instead
    local code = _section(_built(), "Writing the code")
    assert(code:find("never from the ones", 1, true), code)
    assert(code:find("not a convention", 1, true), code)
end

function test_a_project_which_comments_in_another_language_is_left_alone()
    local code = _section(_built({code = {comments = "Chinese"}}), "Writing the code")
    assert(code:find("Write the comments in Chinese", 1, true), code)
end

---------------------------------------------------------------------------------
-- the house style, for when there is nothing to match
---------------------------------------------------------------------------------

function test_the_default_brace_placement()
    assert(config.defaults().code.braces == "sameline", config.defaults().code.braces)
    local code = _section(_built({code = {braces = "sameline"}}), "Writing the code")
    assert(code:find("the opening brace on the same line", 1, true), code)
end

function test_the_brace_placement_can_be_turned_around()
    local code = _section(_built({code = {braces = "newline"}}), "Writing the code")
    assert(code:find("the opening brace on a line of its own", 1, true), code)
end

function test_the_file_still_wins_over_the_house_style()
    -- the default is for the first file of a new project and nothing else: a
    -- harness which reformatted somebody's project to its own taste would be
    -- worse than one with no opinion at all
    local code = _section(_built(), "Writing the code")
    assert(code:find("The file you are editing decides the style", 1, true), code)
    assert(code:find("the file you are editing wins over it", 1, true), code)
end

---------------------------------------------------------------------------------
-- who is told
---------------------------------------------------------------------------------

function test_a_subagent_is_told_too()
    -- a subagent brings its own identity, but the style of the code is a fact
    -- about the codebase and not about whose turn it is to edit it
    local text = _built({agent = {name = "reviewer", prompt = "You review the code."}})
    assert(text:find("You review the code.", 1, true), "the agent keeps its own identity")
    assert(_section(text, "Writing the code") ~= "", "and is told how the code is written")
end


---------------------------------------------------------------------------------
-- the skills, listed by what they are for and not by all they contain
---------------------------------------------------------------------------------

function _listed(description)
    local text = _built({skills = {{name = "one", description = description}}})
    return _section(text, "Skills"):match("`one`: ([^\n]*)")
end

function test_only_the_trigger_is_listed()
    -- a description says both when to use the skill and what it covers, and the
    -- second half is of no use to somebody deciding whether to open it
    assert(_listed("Use when creating a new project. Covers the layout and the templates.")
           == "creating a new project", _listed("Use when creating a new project. Covers the layout and the templates."))
end

function test_the_clause_which_carries_it()
    -- the packs write "Use when <trigger> — <everything it covers>"
    assert(_listed("Use when building Go projects with xmake — the go module integration, "
                   .. "cross-compiling, and the toolchain") == "building Go projects with xmake",
           tostring(_listed("Use when building Go projects with xmake — the go module integration, "
                   .. "cross-compiling, and the toolchain")))
    assert(_listed("Use when hacking on xmake itself - the layout, the tests")
           == "hacking on xmake itself")
end

function test_an_abbreviation_is_not_the_end_of_a_sentence()
    -- "applying the rules (e.g. `mode.debug`)" was listed as "applying the rules (e.g"
    local said = _listed("Use when applying built-in rules (e.g. `mode.debug`, `mode.release`) "
                         .. "or writing a custom rule")
    assert(said:find("mode.release", 1, true), said)
end

function test_a_description_with_nothing_to_cut()
    assert(_listed("Use when the tests fail") == "the tests fail", _listed("Use when the tests fail"))
    assert(_listed("Something else entirely") == "Something else entirely")
end

function test_a_trigger_which_runs_on_is_capped()
    local said = _listed("Use when " .. string.rep("something and ", 30))
    assert(#said < 130, tostring(#said))
    assert(said:endswith("…"), said)
    assert(not said:find(" $"), "it is cut at a word and not mid-word")
end

function test_the_listing_says_it_is_a_listing()
    -- otherwise a model reads a trimmed line as the whole of what the skill is
    -- and rules it out for something it does in fact cover
    local skills = _section(_built({skills = {{name = "one", description = "Use when x. Covers y."}}}), "Skills")
    assert(skills:find("trigger only", 1, true), skills)
    assert(skills:find("use_skill", 1, true), skills)
end

function test_it_is_much_smaller_than_what_it_lists()
    -- fifty skills of full description are three quarters of the system prompt,
    -- and it is sent again every turn
    local skills = {}
    local full = 0
    for idx = 1, 50 do
        local description = string.format("Use when doing the thing number %d — %s", idx,
                                          string.rep("and the detail of it ", 12))
        table.insert(skills, {name = string.format("skill-%d", idx), description = description})
        full = full + #description
    end
    local listed = #_section(_built({skills = skills}), "Skills")
    assert(listed < full / 3, string.format("%d listed against %d of description", listed, full))
end
