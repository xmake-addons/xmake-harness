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
-- @file        attachments.lua
--

-- imports
import("harness.core.attachments")

-- a project with the given files in it
function _project(files)
    local rootdir = os.tmpfile() .. ".attach"
    os.mkdir(rootdir)
    for name, content in pairs(files or {}) do
        os.mkdir(path.directory(path.join(rootdir, name)))
        io.writefile(path.join(rootdir, name), content)
    end
    return rootdir
end

-- a store which may spill
function _store()
    local dir = os.tmpfile() .. ".store"
    os.mkdir(dir)
    return attachments.new({dir = dir}), dir
end

-- text of the given number of lines
function _lines(count, prefix)
    local out = {}
    for index = 1, count do
        table.insert(out, string.format("%s%d", prefix or "line ", index))
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------------
-- what is worth putting aside
---------------------------------------------------------------------------------

function test_a_short_paste_is_just_typed()
    -- replacing three words with a label takes something away from the person
    -- who pasted them
    assert(not attachments.worthkeeping("xmake build"))
    assert(not attachments.worthkeeping(_lines(4)))
    assert(not attachments.worthkeeping(""))
    assert(not attachments.worthkeeping(nil))
end

function test_a_long_one_is_a_thing_with_a_shape()
    assert(attachments.worthkeeping(_lines(40)))
    assert(attachments.worthkeeping(string.rep("x", 4096)))
end

---------------------------------------------------------------------------------
-- the label which stands in for it
---------------------------------------------------------------------------------

function test_the_label_says_what_it_is_standing_in_for()
    local store = _store()
    local entry, label = attachments.capture(store, _lines(2413))
    assert(entry.ref == 1)
    assert(entry.lines == 2413, tostring(entry.lines))
    assert(label == "[Pasted text #1, 2413 lines]", label)
end

function test_one_line_is_not_lines()
    local store = _store()
    local _, label = attachments.capture(store, "only this")
    assert(label == "[Pasted text #1, 1 line]", label)
end

function test_they_are_numbered_in_the_order_they_arrived()
    local store = _store()
    local _, first = attachments.capture(store, _lines(20))
    local _, second = attachments.capture(store, _lines(30))
    assert(first:find("#1", 1, true), first)
    assert(second:find("#2", 1, true), second)
    assert(#attachments.all(store) == 2)
end

function test_a_label_which_was_deleted_is_not_sent()
    -- that is the whole point of it being text: the person edits the line
    local store = _store()
    attachments.capture(store, _lines(20))
    assert(#attachments.referenced(store, "have a look at this") == 0)
    assert(#attachments.referenced(store, "[Pasted text #1, 20 lines]") == 1)
end

function test_a_label_moved_around_the_sentence_still_counts()
    local store = _store()
    local _, label = attachments.capture(store, _lines(20))
    local said = string.format("why does %s fail on windows?", label)
    assert(#attachments.referenced(store, said) == 1)
end

function test_a_label_nobody_made_is_ignored()
    local store = _store()
    assert(#attachments.referenced(store, "[Pasted text #9, 4 lines]") == 0)
end

function test_the_same_label_twice_attaches_once()
    local store = _store()
    local _, label = attachments.capture(store, _lines(20))
    assert(#attachments.referenced(store, label .. " and again " .. label) == 1)
end

---------------------------------------------------------------------------------
-- what goes out with the message
---------------------------------------------------------------------------------

function test_a_message_with_nothing_attached_is_itself()
    assert(attachments.expand("just a question") == "just a question")
    assert(attachments.expand("") == "")
    assert(attachments.expand(nil) == nil)
end

function test_the_paste_goes_out_with_the_words()
    local store = _store()
    local _, label = attachments.capture(store, _lines(20, "log "))
    local sent = attachments.expand("why does this fail? " .. label, {store = store})
    assert(sent:find("why does this fail?", 1, true))
    assert(sent:find("### Pasted text #1", 1, true), sent)
    assert(sent:find("log 17", 1, true), sent)
end

function test_a_paste_too_big_to_send_is_named_and_not_dropped()
    local store, dir = _store()
    local huge = _lines(40000, "a very long line of log output number ")
    local entry, label = attachments.capture(store, huge)

    -- it went to disk rather than staying in the process
    assert(entry.spilled, "it spilled")
    assert(os.isfile(entry.filepath), entry.filepath)
    assert(path.directory(entry.filepath) == dir)

    local sent = attachments.expand(label, {store = store})
    assert(sent:find("too large to include", 1, true), sent)
    assert(sent:find(entry.filepath, 1, true), sent)
    assert(sent:find("read_file", 1, true), sent)

    -- and enough of it to tell what it is
    assert(sent:find("It begins:", 1, true), sent)
    assert(sent:find("number 1$", 1, true) or sent:find("number 1\n", 1, true), "the head is there")
end

---------------------------------------------------------------------------------
-- the files named with @
---------------------------------------------------------------------------------

function test_a_named_file_goes_out_with_the_words()
    local rootdir = _project({["src/main.c"] = "int main(void) { return 0; }\n"})
    local sent = attachments.expand("what does @src/main.c do?", {rootdir = rootdir})
    assert(sent:find("### src/main.c", 1, true), sent)
    assert(sent:find("int main(void)", 1, true), sent)
end

function test_a_file_which_is_not_there_is_not_invented()
    local rootdir = _project({})
    local sent = attachments.expand("look at @nope.c", {rootdir = rootdir})
    assert(sent == "look at @nope.c", sent)
end

function test_the_same_file_named_twice_goes_once()
    local rootdir = _project({["a.txt"] = "hello\n"})
    local sent = attachments.expand("@a.txt and @a.txt", {rootdir = rootdir})
    local count = 0
    for _ in sent:gmatch("### a%.txt") do
        count = count + 1
    end
    assert(count == 1, tostring(count))
end

function test_a_file_too_big_to_quote_is_named_rather_than_dropped()
    -- it used to match, be read, fail a size check and go out as nothing at
    -- all: no content, no mention, no way for anybody to tell
    local rootdir = _project({["big.json"] = _lines(20000, "  \"key\": \"value number ")})
    local sent = attachments.expand("what is in @big.json?", {rootdir = rootdir})
    assert(sent:find("### big.json", 1, true), sent)
    assert(sent:find("too large to include", 1, true), sent)
    assert(sent:find("read_file", 1, true), sent)
    assert(sent:find(path.join(rootdir, "big.json"), 1, true), sent)

    -- the head of it, so the model can tell what it is looking at
    assert(sent:find("It begins:", 1, true), sent)
    assert(sent:find("value number 3", 1, true), sent)

    -- but not the whole megabyte
    assert(#sent < 64 * 1024, tostring(#sent))
end

function test_a_binary_file_is_named_and_never_quoted()
    local rootdir = _project({["a.png"] = "\137PNG\r\n\026\n\0\0\0garbage"})
    local sent = attachments.expand("what is @a.png?", {rootdir = rootdir})
    assert(sent:find("binary file", 1, true), sent)
    assert(not sent:find("garbage", 1, true), sent)
end

function test_ten_files_do_not_take_the_whole_window()
    local files = {}
    for index = 1, 10 do
        files[string.format("f%d.txt", index)] = _lines(2000, "padding padding padding ")
    end
    local rootdir = _project(files)
    local said = {}
    for index = 1, 10 do
        table.insert(said, string.format("@f%d.txt", index))
    end
    local sent = attachments.expand("read " .. table.concat(said, " "), {rootdir = rootdir})

    -- every one of them is mentioned, and together they stay inside the budget
    for index = 1, 10 do
        assert(sent:find(string.format("### f%d.txt", index), 1, true), tostring(index))
    end
    assert(#sent < 256 * 1024, tostring(#sent))
end

function test_the_pastes_and_the_files_both_go()
    local rootdir = _project({["a.txt"] = "the file\n"})
    local store = _store()
    local _, label = attachments.capture(store, _lines(20, "the paste "))
    local sent = attachments.expand(label .. " next to @a.txt",
                                    {rootdir = rootdir, store = store})
    assert(sent:find("the paste 3", 1, true), sent)
    assert(sent:find("the file", 1, true), sent)
end
