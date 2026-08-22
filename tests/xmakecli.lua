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
-- @file        xmakecli.lua
--

-- imports
import("harness.harness")
import("harness.ui.editor")
import("harness.ui.keymap")
import("harness.ui.completion")
import("harness.commands.builtin.xmakecli")
import("harness.commands.registry", {alias = "commandregistry"})

function test_a_bare_command_builds()
    -- a bare `xmake` in a terminal builds, so a bare `/xmake` does too
    local arguments = xmakecli.argv("")
    assert(#arguments == 1 and arguments[1] == "build")
    assert(xmakecli.argv("   ")[1] == "build")
end

function test_the_arguments_pass_through()
    local arguments = xmakecli.argv("f -m debug --toolchain=clang")
    assert(table.concat(arguments, "|") == "f|-m|debug|--toolchain=clang")
end

function test_the_quotes_survive()
    -- `/xmake run myapp --arg="a b"` must reach xmake as one argument
    local arguments = xmakecli.argv('run myapp --arg="a b"')
    assert(arguments[#arguments] == "--arg=a b", table.concat(arguments, "|"))
end

function test_the_subcommands_complete()
    local complete = xmakecli.command().complete
    local items = complete(nil, "bu")
    assert(#items == 1 and items[1].text == "build")
    assert(items[1].description ~= nil, "the completion must say what it does")
end

function test_the_completion_offers_everything_for_an_empty_prefix()
    local items = xmakecli.command().complete(nil, "")
    assert(#items > 10)
end

function test_the_flags_are_not_completed()
    -- they are xmake's own business and they change with the version
    assert(xmakecli.command().complete(nil, "build -") == nil)
    assert(xmakecli.command().complete(nil, "f -m ") == nil)
end

function test_an_unknown_subcommand_completes_to_nothing()
    assert(#xmakecli.command().complete(nil, "zzz") == 0)
end

-- a harness whose only command is /xmake
function _harness()
    local instance = harness.bootstrap({rootdir = os.tmpdir()})
    local commands = commandregistry.new()
    commands:add(xmakecli.command())
    commands:add({name = "cost", description = "no arguments here"})
    instance:service("commands", commands)
    return instance
end

-- the popup for the given input
function _popup(input)
    local box = editor.new()
    box:settext(input)
    return completion.update(_harness(), box)
end

function test_the_command_name_still_completes()
    local popup = _popup("/xma")
    assert(popup and popup.kind == "command", "the name completion must not be broken")
    assert(popup.items[1].text == "/xmake")
end

function test_the_arguments_complete_after_the_name()
    local popup = _popup("/xmake ru")
    assert(popup and popup.kind == "argument", "the arguments must complete too")
    assert(popup.items[1].text == "run")
end

function test_a_command_without_arguments_completes_to_nothing()
    -- an unknown argument list is better completed by nothing than by the wrong thing
    assert(_popup("/cost something") == nil)
end

function test_an_argument_is_accepted_into_the_word()
    local box = editor.new()
    box:settext("/xmake bui")
    local popup = completion.update(_harness(), box)
    completion.accept(popup, box)
    assert(box:text() == "/xmake build", box:text())
end

-- the key handling of one popup
function _handle(input, key)
    local box = editor.new()
    box:settext(input)
    local state = {editor = box, popup = completion.update(_harness(), box), mode = "default", lastctrlc = 0}
    return keymap.handle(key, state), state
end

function test_enter_sends_a_finished_argument()
    -- the popup is still open on `/xmake clean`, and it must not eat the enter
    local action = _handle("/xmake clean", {name = "enter"})
    assert(action == "submit", tostring(action))
end

function test_enter_completes_an_unfinished_argument()
    local action = _handle("/xmake cle", {name = "enter"})
    assert(action == "popup.accept", tostring(action))
end

function test_enter_sends_a_finished_command()
    local action = _handle("/cost", {name = "enter"})
    assert(action == "submit", tostring(action))
end

function test_the_arrows_still_drive_the_argument_popup()
    local action = _handle("/xmake ", {name = "down"})
    assert(action == "popup.down", tostring(action))
end

-- press tab on the given input, the way the app does
function _tab(input)
    local box = editor.new()
    box:settext(input)
    local instance = _harness()
    local popup = completion.update(instance, box)
    local state = {editor = box, popup = popup, mode = "default", lastctrlc = 0}
    assert(keymap.handle({name = "tab"}, state) == "popup.complete")
    if completion.extend(popup, box) then
        popup = completion.update(instance, box)
    else
        completion.move(popup, "down")
    end
    return box:text(), popup
end

function test_tab_completes_an_unambiguous_argument()
    assert(_tab("/xmake bui") == "/xmake build")
end

function test_tab_stops_where_the_candidates_disagree()
    -- /xmake and /xmake-docs share `/xmake` and nothing more
    assert(_tab("/xma") == "/xmake")
end

function test_tab_browses_when_there_is_nothing_to_add()
    local text, popup = _tab("/xmake ")
    assert(text == "/xmake ", "an empty word has no common prefix to add")
    assert(popup.selected == 2, "so the tab moves to the next candidate instead")
end

function test_tab_leaves_a_finished_word_alone()
    assert(_tab("/xmake build") == "/xmake build")
end
