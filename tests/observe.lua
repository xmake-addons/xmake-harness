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
-- @file        observe.lua
--

-- imports
import("harness.fs.observe")
import("harness.core.session", {alias = "sessions"})

-- a directory with one file in it
function _project()
    local dirpath = os.tmpfile() .. ".proj"
    os.mkdir(path.join(dirpath, "src"))
    io.writefile(path.join(dirpath, "xmake.lua"), "target(\"demo\")\n")
    return dirpath
end

function test_a_file_a_command_created()
    local dirpath = _project()
    local before = observe.snapshot(dirpath)
    io.writefile(path.join(dirpath, "src", "main.c"), "int main() {}\n")

    local result = observe.changed(dirpath, before)
    assert(#result.created == 1, tostring(#result.created))
    assert(result.created[1]:endswith("main.c"), result.created[1])
    assert(#result.modified == 0 and #result.removed == 0)
    os.rmdir(dirpath)
end

function test_a_file_a_command_changed()
    local dirpath = _project()
    local before = observe.snapshot(dirpath)
    io.writefile(path.join(dirpath, "xmake.lua"), "target(\"demo\")\n    set_kind(\"binary\")\n")

    local result = observe.changed(dirpath, before)
    assert(#result.modified == 1, tostring(#result.modified))
    assert(result.modified[1]:endswith("xmake.lua"), result.modified[1])
    os.rmdir(dirpath)
end

function test_a_file_a_command_removed()
    local dirpath = _project()
    local before = observe.snapshot(dirpath)
    os.rm(path.join(dirpath, "xmake.lua"))

    local result = observe.changed(dirpath, before)
    assert(#result.removed == 1, tostring(#result.removed))
    os.rmdir(dirpath)
end

function test_a_command_which_changed_nothing()
    local dirpath = _project()
    local before = observe.snapshot(dirpath)
    local result = observe.changed(dirpath, before)
    assert(#result.created == 0 and #result.modified == 0 and #result.removed == 0)
    os.rmdir(dirpath)
end

function test_what_a_build_writes_is_not_a_change()
    -- the ignored directories are not walked, so a build does not report its
    -- own output as something the conversation changed
    local dirpath = _project()
    local before = observe.snapshot(dirpath)
    os.mkdir(path.join(dirpath, "build"))
    io.writefile(path.join(dirpath, "build", "demo.o"), "junk\n")
    os.mkdir(path.join(dirpath, ".git"))
    io.writefile(path.join(dirpath, ".git", "index"), "junk\n")

    local result = observe.changed(dirpath, before)
    assert(#result.created == 0, table.concat(result.created, ", "))
    os.rmdir(dirpath)
end

function test_a_tree_which_is_too_big_is_not_watched()
    local dirpath = _project()
    assert(observe.snapshot(dirpath, {maxfiles = 1}) == nil, "it gives up rather than crawling")
    os.rmdir(dirpath)
end

function test_the_records_have_the_shape_a_write_leaves()
    local dirpath = _project()
    local session = sessions.new({cwd = dirpath})
    local count = observe.record(session, {
        created = {path.join(dirpath, "new.c")},
        modified = {path.join(dirpath, "xmake.lua")},
        removed = {path.join(dirpath, "gone.c")}})
    assert(count == 3, tostring(count))

    local records = {}
    for _, event in ipairs(session:events()) do
        if event.kind == "edit" then
            table.insert(records, event.record)
        end
    end
    assert(#records == 3, tostring(#records))
    assert(records[1].existed == false, "a new file did not exist before")
    assert(records[1].bycommand, "and it says who wrote it")
    assert(records[2].nocopy, "there is no copy of what a command replaced")
    assert(records[3].removed, "and one which is gone says so")
    os.rmdir(dirpath)
end
