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
-- @file        checkpoint.lua
--

-- imports
import("harness.fs.fs")
import("harness.core.checkpoint")
import("harness.core.session", {alias = "sessions"})

-- a project with two files in it, and a session which writes to them
function _project()
    local dir = os.tmpfile() .. ".proj"
    os.tryrm(dir)
    os.mkdir(dir)
    io.writefile(path.join(dir, "a.txt"), "the original a\n")
    io.writefile(path.join(dir, "b.txt"), "the original b\n")
    local session = sessions.new({cwd = dir})
    return dir, session, {session = session}
end

-- what the file holds now
function _read(dir, name)
    local filepath = path.join(dir, name)
    return os.isfile(filepath) and io.readfile(filepath) or nil
end

function test_a_write_keeps_what_it_replaced()
    local dir, session, context = _project()
    session:append("user", {text = "change a"})
    fs.writetext(path.join(dir, "a.txt"), "the new a\n", context)
    assert(_read(dir, "a.txt") == "the new a\n")

    local edits = 0
    for _, event in ipairs(session:events()) do
        if event.kind == "edit" then
            edits = edits + 1
            assert(event.record.existed, "it knew the file was there")
            assert(os.isfile(event.record.copy), "the copy must be on disk")
        end
    end
    assert(edits == 1, tostring(edits))
    checkpoint.forget(session)
    os.tryrm(dir)
end

function test_going_back_restores_the_content()
    local dir, session, context = _project()
    session:append("user", {text = "change both"})
    fs.writetext(path.join(dir, "a.txt"), "the new a\n", context)
    fs.writetext(path.join(dir, "b.txt"), "the new b\n", context)

    local points = checkpoint.points(session)
    assert(#points == 1 and #points[1].files == 2, tostring(#points))
    local result = checkpoint.restore(session, points[1].index)
    assert(#result.restored == 2, tostring(#result.restored))
    assert(_read(dir, "a.txt") == "the original a\n", tostring(_read(dir, "a.txt")))
    assert(_read(dir, "b.txt") == "the original b\n")
    checkpoint.forget(session)
    os.tryrm(dir)
end

function test_a_file_written_three_times_goes_back_to_the_start()
    -- the edits are undone newest first, so the oldest copy is the one which
    -- ends up on disk
    local dir, session, context = _project()
    session:append("user", {text = "keep changing a"})
    for idx = 1, 3 do
        fs.writetext(path.join(dir, "a.txt"), string.format("version %d\n", idx), context)
    end
    assert(_read(dir, "a.txt") == "version 3\n")
    checkpoint.restore(session, checkpoint.points(session)[1].index)
    assert(_read(dir, "a.txt") == "the original a\n", tostring(_read(dir, "a.txt")))
    checkpoint.forget(session)
    os.tryrm(dir)
end

function test_a_file_which_did_not_exist_is_removed_again()
    local dir, session, context = _project()
    session:append("user", {text = "add a file"})
    fs.writetext(path.join(dir, "new.txt"), "brand new\n", context)
    assert(_read(dir, "new.txt") == "brand new\n")

    checkpoint.restore(session, checkpoint.points(session)[1].index)
    assert(_read(dir, "new.txt") == nil, "the way back from a file which was not there is for it to go")
    checkpoint.forget(session)
    os.tryrm(dir)
end

function test_only_the_edits_after_the_point_are_undone()
    -- the first request is kept, the second one is undone
    local dir, session, context = _project()
    session:append("user", {text = "first request"})
    fs.writetext(path.join(dir, "a.txt"), "wanted\n", context)
    session:append("user", {text = "second request"})
    fs.writetext(path.join(dir, "b.txt"), "unwanted\n", context)

    local points = checkpoint.points(session)
    assert(#points == 2, tostring(#points))
    checkpoint.restore(session, points[2].index)
    assert(_read(dir, "a.txt") == "wanted\n", "the earlier request must survive")
    assert(_read(dir, "b.txt") == "the original b\n", tostring(_read(dir, "b.txt")))
    checkpoint.forget(session)
    os.tryrm(dir)
end

function test_a_request_which_changed_nothing_is_not_offered()
    -- going back to it would do nothing at all
    local dir, session, context = _project()
    session:append("user", {text = "just a question"})
    session:append("assistant", {text = "an answer"})
    assert(#checkpoint.points(session) == 0)
    os.tryrm(dir)
end

function test_a_write_without_a_session_still_writes()
    -- the fs is used outside a conversation too, and it must not need one
    local dir = os.tmpfile() .. ".proj"
    os.tryrm(dir)
    os.mkdir(dir)
    fs.writetext(path.join(dir, "x.txt"), "hello\n")
    assert(_read(dir, "x.txt") == "hello\n")
    os.tryrm(dir)
end

function test_the_copies_can_be_thrown_away()
    local dir, session, context = _project()
    session:append("user", {text = "change a"})
    fs.writetext(path.join(dir, "a.txt"), "new\n", context)
    assert(os.isdir(checkpoint.dir(session)))
    checkpoint.forget(session)
    assert(not os.isdir(checkpoint.dir(session)))
    os.tryrm(dir)
end

---------------------------------------------------------------------------------
-- what a command did, which is not ours to undo
---------------------------------------------------------------------------------

function test_a_file_a_command_changed_is_skipped_and_not_failed()
    -- there is no copy of what it replaced, because nobody knew which files it
    -- was about to write, @see harness.fs.observe. saying "could not put it
    -- back" would be claiming a way back which never existed
    local result = {restored = {}, removed = {}, failed = {}, skipped = {}}
    checkpoint.restoreone({path = "/tmp/whatever.c", existed = true, nocopy = true,
                           bycommand = true}, result)
    assert(#result.skipped == 1, tostring(#result.skipped))
    assert(#result.failed == 0, "it is not a failure")
end

function test_a_file_a_command_created_is_still_undone()
    -- this one we can undo: it did not exist, so the way back is for it not to
    local dirpath = os.tmpfile() .. ".proj"
    os.mkdir(dirpath)
    local filepath = path.join(dirpath, "made.c")
    io.writefile(filepath, "int main() {}\n")

    local result = {restored = {}, removed = {}, failed = {}, skipped = {}}
    checkpoint.restoreone({path = filepath, existed = false, bycommand = true}, result)
    assert(#result.removed == 1, tostring(#result.removed))
    assert(not os.isfile(filepath), "it is gone again")
    os.rmdir(dirpath)
end

function test_a_point_promises_only_what_it_can_put_back()
    local rootdir = os.tmpfile() .. ".proj"
    os.mkdir(rootdir)
    local session = sessions.new({cwd = rootdir})

    session:append("user", {text = "make me a project"})
    session:append("edit", {record = {path = path.join(rootdir, "mine.c"), existed = false}})
    session:append("edit", {record = {path = path.join(rootdir, "theirs.c"), existed = true,
                                      nocopy = true, bycommand = true}})

    local points = checkpoint.points(session)
    assert(#points == 1, tostring(#points))
    assert(#points[1].files == 1, "one file can be put back")
    assert(points[1].files[1]:endswith("mine.c"), points[1].files[1])
    assert(#points[1].kept == 1, "and one cannot, which the point says")
    assert(points[1].kept[1]:endswith("theirs.c"), points[1].kept[1])
    os.rmdir(rootdir)
end

function test_a_point_which_can_undo_nothing_is_not_offered()
    local rootdir = os.tmpfile() .. ".proj"
    os.mkdir(rootdir)
    local session = sessions.new({cwd = rootdir})
    session:append("user", {text = "run the build"})
    session:append("edit", {record = {path = path.join(rootdir, "theirs.c"), existed = true,
                                      nocopy = true, bycommand = true}})
    assert(#checkpoint.points(session) == 0, "there is nothing to go back to")
    os.rmdir(rootdir)
end
