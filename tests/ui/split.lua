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
-- @file        split.lua
--

-- imports
import("harness.harness")
import("harness.fs.fs")
import("harness.ui.split")
import("harness.ui.app", {alias = "uiapp"})
import("harness.util.text")
import("harness.core.session", {alias = "sessions"})

-- a conversation which changed two files
function _changed()
    local rootdir = os.tmpfile() .. ".split"
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
    return {harness = instance, session = session, rootdir = rootdir}
end

-- the pane, as plain text
function _plain(state, one, opt)
    opt = opt or {}
    local lines = split.render(state, {harness = one.harness, session = one.session,
                                       width = opt.width or 52, height = opt.height or 24})
    local out = {}
    for _, line in ipairs(lines) do
        table.insert(out, (line:gsub("\027%[[%d;]*m", "")))
    end
    return out, table.concat(out, "\n")
end

---------------------------------------------------------------------------------
-- where it may open
---------------------------------------------------------------------------------

function test_it_does_not_open_where_there_is_no_room()
    -- eighty columns split in two is two columns too narrow to read either
    assert(not split.available(80), "eighty is not enough")
    assert(not split.available(119))
    assert(split.available(120), "and a hundred and twenty is")
    assert(split.available(204))

    local why = split.unavailable(80)
    assert(why:find("80", 1, true) and why:find("120", 1, true), why)
end

function test_the_two_columns_add_up_to_the_terminal()
    for _, width in ipairs({120, 160, 204, 300}) do
        -- the separator column belongs to the pane, so the transcript never
        -- writes into the column the border is drawn in
        assert(split.leftwidth(width) + split.panewidth(width) + 1 == width,
               string.format("%d: %d + %d", width, split.leftwidth(width),
                             split.panewidth(width)))
        assert(split.leftwidth(width) >= 60,
               string.format("%d leaves only %d for the conversation", width,
                             split.leftwidth(width)))
    end
end

function test_a_very_wide_terminal_does_not_give_the_pane_everything()
    -- past a point more columns should go to the conversation, not to a diff
    -- which was already wide enough
    assert(split.panewidth(400) <= 96, tostring(split.panewidth(400)))
    assert(split.leftwidth(400) > split.panewidth(400), "the conversation keeps the rest")
end

---------------------------------------------------------------------------------
-- what it shows
---------------------------------------------------------------------------------

function test_it_says_how_much_changed()
    local one = _changed()
    local _, said = _plain(split.new({}), one)
    assert(said:find("2 files changed", 1, true), said)
    assert(said:find("src/main.c", 1, true), said)
    assert(said:find("README.md", 1, true), said)
end

function test_it_shows_the_file_which_changed_last()
    -- a pane which showed the first file of the conversation would be showing
    -- the oldest thing in it
    local one = _changed()
    local lines = _plain(split.new({}), one)
    local marked = nil
    for _, line in ipairs(lines) do
        if line:startswith("▸") then
            marked = line
        end
    end
    assert(marked and marked:find("README.md", 1, true), tostring(marked))
end

function test_it_shows_the_file_which_was_asked_for()
    local one = _changed()
    local _, said = _plain(split.new({file = "src/main.c"}), one)
    -- the diff of that file, not of the other one
    assert(said:find("argc", 1, true), said)
    assert(not said:find("it greets you", 1, true), said)
end

function test_the_diff_has_the_line_numbers_and_the_signs()
    local one = _changed()
    local lines = _plain(split.new({file = "src/main.c"}), one)
    local added, removed = false, false
    for _, line in ipairs(lines) do
        if line:match("^%s*%d+%s%+") then
            added = true
        end
        if line:match("^%s*%d+%s%-") then
            removed = true
        end
    end
    assert(added, table.concat(lines, "\n"))
    assert(removed, table.concat(lines, "\n"))
end

function test_every_line_fits_the_pane()
    -- a line which overflows wraps into the conversation, which is the one
    -- thing a column beside it must never do
    local one = _changed()
    for _, width in ipairs({46, 52, 89}) do
        local lines = _plain(split.new({file = "src/main.c"}), one, {width = width})
        for index, line in ipairs(lines) do
            assert(text.width(line) <= width,
                   string.format("width %d, line %d is %d: %q", width, index,
                                 text.width(line), line))
        end
    end
end

function test_it_fills_the_height_it_was_given()
    -- the pane is painted row by row, so a short answer has to say so for
    -- every row it owns or the rows below keep what was there before
    local one = _changed()
    for _, height in ipairs({8, 24, 40}) do
        local lines = _plain(split.new({}), one, {height = height})
        assert(#lines == height, string.format("%d rows for a height of %d", #lines, height))
    end
end

function test_a_conversation_which_changed_nothing()
    local rootdir = os.tmpfile() .. ".empty"
    os.mkdir(rootdir)
    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    local one = {harness = instance, session = sessions.new({cwd = rootdir})}
    local _, said = _plain(split.new({}), one)
    assert(said:find("0 files changed", 1, true), said)
    assert(said:find("nothing has been changed yet", 1, true), said)
end

function test_a_long_diff_says_there_is_more()
    local rootdir = os.tmpfile() .. ".long"
    os.mkdir(rootdir)
    local before = {}
    local after = {}
    for index = 1, 200 do
        table.insert(before, string.format("line %d", index))
        table.insert(after, string.format("line %d changed", index))
    end
    io.writefile(path.join(rootdir, "big.txt"), table.concat(before, "\n") .. "\n")

    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    local session = sessions.new({cwd = rootdir})
    fs.writetext(path.join(rootdir, "big.txt"), table.concat(after, "\n") .. "\n",
                 {session = session, cwd = rootdir, harness = instance,
                  config = instance:config()})

    local one = {harness = instance, session = session}
    local _, said = _plain(split.new({}), one, {height = 20})
    assert(said:find("more below", 1, true), said)
end

---------------------------------------------------------------------------------
-- when it opens by itself
---------------------------------------------------------------------------------

-- an application over a conversation, without a terminal under it
function _app(one)
    return uiapp.new(one.harness, {session = one.session})
end

function test_nothing_changed_yet_means_nothing_to_open()
    local rootdir = os.tmpfile() .. ".quiet"
    os.mkdir(rootdir)
    local instance = harness.bootstrap({rootdir = rootdir, trusted = true})
    local a = _app({harness = instance, session = sessions.new({cwd = rootdir})})
    assert(not a:_haschanges())
end

function test_the_first_edit_is_what_opens_it()
    local one = _changed()
    local a = _app(one)
    assert(a:_haschanges())
end

function test_the_answer_is_only_looked_for_once()
    local one = _changed()
    local a = _app(one)
    assert(a:_haschanges())

    -- the log is scanned from where the last scan stopped, so a second ask
    -- costs nothing and must still say the same thing
    assert(a:_haschanges())
end

function test_closing_it_keeps_it_closed()
    local one = _changed()
    local a = _app(one)
    a._split = split.new({})
    a:closesplit()
    assert(a._splitclosed)

    -- it would otherwise come straight back on the next edit, which is the
    -- pane arguing with somebody who has just told it to go away
    a:_autosplit()
    assert(a:splitstate() == nil)
end

function test_asking_for_it_again_undoes_the_closing()
    local one = _changed()
    local a = _app(one)
    a._split = split.new({})
    a:closesplit()
    assert(a._splitclosed)

    -- whether it can open is the terminal running the tests talking; what is
    -- being asserted is that having opened, it has stopped being closed
    if a:opensplit({}) then
        assert(a:splitstate() ~= nil)
        assert(not a._splitclosed)
    else
        assert(a:splitstate() == nil)
        assert(a._splitclosed)
    end
end

function test_a_narrow_terminal_keeps_it_shut()
    local one = _changed()
    local a = _app(one)
    local ok, why = a:opensplit({})

    -- either the terminal running the tests is wide enough or it is not, and
    -- both are correct answers; what must hold is that it says which
    if ok then
        assert(a:splitstate() ~= nil)
    else
        assert(why and why:find("columns", 1, true), tostring(why))
    end
end
