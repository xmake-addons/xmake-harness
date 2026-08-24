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
-- @file        display.lua
--

-- imports
import("harness.ui.theme")
import("harness.ui.dialog")
import("harness.ui.transcript")

-- a command whose meaning lives entirely in the part xmake would eat
local COMMAND = 'rm -rf $(cat /tmp/targets)'

-- strip the colors, what is left is what the user reads
function _plain(str)
    return (str:gsub("\027%[[%d;]*m", ""))
end

function test_a_style_does_not_reinterpret_the_text()
    -- `print` and `cprint` hand the string to vformat, which reads `$(..)` as an
    -- xmake variable and replaces it with nothing. the styling must not
    local styled = theme.styled("tool.name", COMMAND)
    assert(_plain(styled) == COMMAND, _plain(styled))
end

function test_the_confirmation_shows_the_whole_command()
    -- this is the one that matters: the user is about to approve this line, and
    -- `rm -rf ` reads far milder than `rm -rf $(cat /tmp/targets)`
    local info = dialog.confirminfo({name = "run_command", group = "shell"}, {command = COMMAND})
    assert(info.title == COMMAND, info.title)

    local lines = dialog.render({
        lines = {theme.styled("tool.name", info.title)},
        question = info.question,
        options = {{text = "Yes", value = "allow"}, {text = "No", value = "deny"}},
        selected = 1}, 80)
    local shown = _plain(table.concat(lines, "\n"))
    assert(shown:find(COMMAND, 1, true), "the dialog dropped part of the command:\n" .. shown)
end

function test_the_tool_card_shows_the_whole_command()
    local card = transcript.tool({name = "run_command",
        display = {title = "Run", subject = COMMAND}}, {width = 100})
    local shown = _plain(table.concat(card, "\n"))
    assert(shown:find("$(cat /tmp/targets)", 1, true), "the card dropped the substitution:\n" .. shown)
end

function test_the_other_shell_expansions_survive_too()
    for _, command in ipairs({"echo ${HOME}", "echo `date`", "ls $HOME/x", "echo $(( 1 + 2 ))"}) do
        local styled = _plain(theme.styled("dim", command))
        assert(styled == command, string.format("%q became %q", command, styled))
    end
end
