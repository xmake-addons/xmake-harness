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
-- @file        mouse.lua
--

-- imports
import("harness.harness")
import("harness.fs.fs")
import("harness.ui.split")
import("harness.ui.terminal")
import("harness.ui.app", {alias = "uiapp"})
import("harness.core.session", {alias = "sessions"})

-- a conversation which changed two files, and an application over it
function _app()
    local rootdir = os.tmpfile() .. ".mouse"
    os.mkdir(path.join(rootdir, "src"))
    io.writefile(path.join(rootdir, "src", "main.c"), "int main(void)\n{\n    return 0;\n}\n")
    io.writefile(path.join(rootdir, "README.md"), "# demo\n")

    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    local session = sessions.new({cwd = rootdir})
    local context = {session = session, cwd = rootdir, harness = instance,
                     config = instance:config()}
    fs.writetext(path.join(rootdir, "src", "main.c"),
                 "int main(int argc, char **argv)\n{\n    return argc;\n}\n", context)
    fs.writetext(path.join(rootdir, "README.md"), "# demo\n\nit greets you.\n", context)

    -- the pane is put on by hand: the tests do not run on a terminal, and what
    -- is being tested is what happens once it is there
    local instance_app = uiapp.new(instance, {session = session})
    instance_app._split = split.new({})
    split.render(instance_app._split, {harness = instance, session = session,
                                       width = 60, height = 24})
    return instance_app
end

-- the row of the pane which drew this file
function _rowof(pane, filepath)
    for row, drawn in pairs(pane.hits or {}) do
        if drawn == filepath then
            return row
        end
    end
end

-- a press of the left button inside the pane
function _click(row)
    return {name = "mouse", action = "press", button = "left", row = row,
            col = split.leftwidth(terminal.size().width) + 5}
end

---------------------------------------------------------------------------------
-- what the terminal reports
---------------------------------------------------------------------------------

function test_a_button_going_down_and_coming_up()
    local down = terminal.mousekey(0, 12, 34, true)
    assert(down.name == "mouse")
    assert(down.action == "press")
    assert(down.button == "left")
    assert(down.col == 12 and down.row == 34)

    local up = terminal.mousekey(0, 12, 34, false)
    assert(up.action == "release")
end

function test_the_other_buttons()
    assert(terminal.mousekey(1, 1, 1, true).button == "middle")
    assert(terminal.mousekey(2, 1, 1, true).button == "right")
end

function test_the_wheel_is_not_a_button()
    local up = terminal.mousekey(64, 5, 9, true)
    assert(up.action == "wheel")
    assert(up.button == "wheelup")
    assert(terminal.mousekey(65, 5, 9, true).button == "wheeldown")
end

function test_the_modifiers_come_with_it()
    assert(terminal.mousekey(4, 1, 1, true).shift)
    assert(terminal.mousekey(8, 1, 1, true).alt)
    assert(terminal.mousekey(16, 1, 1, true).ctrl)

    -- and the button is still the button underneath them
    assert(terminal.mousekey(16, 1, 1, true).button == "left")
end

function test_the_mouse_merely_crossing_the_window()
    assert(terminal.mousekey(32, 1, 1, true).motion)
    assert(not terminal.mousekey(0, 1, 1, true).motion)
end

---------------------------------------------------------------------------------
-- where the pane says things are
---------------------------------------------------------------------------------

function test_the_pane_remembers_which_row_drew_which_file()
    local pane = _app():splitstate()
    assert(_rowof(pane, "src/main.c"))
    assert(_rowof(pane, "README.md"))
    assert(_rowof(pane, "src/main.c") ~= _rowof(pane, "README.md"))
end

function test_a_row_which_drew_nothing()
    local pane = _app():splitstate()
    assert(split.at(pane, 1) == nil)
    assert(split.at(pane, 900) == nil)
end

function test_the_border_column_belongs_to_the_pane()
    local width = 200
    assert(split.inside(width, split.leftwidth(width) + 1))
    assert(not split.inside(width, split.leftwidth(width)))
    assert(not split.inside(width, 1))
end

---------------------------------------------------------------------------------
-- and what the clicking does
---------------------------------------------------------------------------------

function test_one_click_changes_nothing()
    local a = _app()
    local pane = a:splitstate()
    assert(a:_onmouse(_click(_rowof(pane, "src/main.c"))) == false)
    assert(pane.file == nil)
end

function test_two_clicks_show_that_file()
    local a = _app()
    local pane = a:splitstate()
    local row = _rowof(pane, "src/main.c")
    a:_onmouse(_click(row))
    assert(a:_onmouse(_click(row)))
    assert(pane.file == "src/main.c")
end

function test_the_third_click_starts_a_new_pair()
    local a = _app()
    local pane = a:splitstate()
    local first = _rowof(pane, "src/main.c")
    local second = _rowof(pane, "README.md")
    a:_onmouse(_click(first))
    a:_onmouse(_click(first))
    assert(pane.file == "src/main.c")

    -- one click on the other file is one click, not the second of a pair
    assert(a:_onmouse(_click(second)) == false)
    assert(pane.file == "src/main.c")
    assert(a:_onmouse(_click(second)))
    assert(pane.file == "README.md")
end

function test_two_clicks_on_different_rows_are_two_clicks()
    local a = _app()
    local pane = a:splitstate()
    a:_onmouse(_click(_rowof(pane, "src/main.c")))
    assert(a:_onmouse(_click(_rowof(pane, "README.md"))) == false)
    assert(pane.file == nil)
end

function test_the_diff_starts_at_the_top_of_the_file_it_switches_to()
    local a = _app()
    local pane = a:splitstate()
    pane.top = 12
    local row = _rowof(pane, "src/main.c")
    a:_onmouse(_click(row))
    a:_onmouse(_click(row))
    assert(pane.top == 0)
end

function test_the_transcript_is_not_ours()
    local a = _app()
    local pane = a:splitstate()
    local click = _click(_rowof(pane, "src/main.c"))
    click.col = 3
    assert(a:_onmouse(click) == false)
    assert(a:_onmouse(click) == false)
    assert(pane.file == nil)
end

function test_a_row_with_no_file_on_it_is_not_ours()
    local a = _app()
    local click = _click(1)
    assert(a:_onmouse(click) == false)
    assert(a:_onmouse(click) == false)
end

function test_the_wheel_scrolls_the_diff()
    local a = _app()
    local pane = a:splitstate()
    pane.top = 0
    local wheel = _click(6)
    wheel.action = "wheel"
    wheel.button = "wheeldown"
    assert(a:_onmouse(wheel))
    assert(pane.top > 0)

    local back = pane.top
    wheel.button = "wheelup"
    assert(a:_onmouse(wheel))
    assert(pane.top < back)
end

function test_the_wheel_does_not_scroll_past_the_top()
    local a = _app()
    local pane = a:splitstate()
    local wheel = _click(6)
    wheel.action = "wheel"
    wheel.button = "wheelup"
    a:_onmouse(wheel)
    a:_onmouse(wheel)
    assert(pane.top == 0)
end

function test_nothing_happens_while_the_pane_is_shut()
    local a = _app()
    a:closesplit()
    assert(a:_onmouse(_click(3)) == false)
end
