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

--
-- what a command did to the tree
--
-- the agent's own writes are recorded as they happen — every one of them keeps
-- a copy of what it replaced, @see harness.core.checkpoint. a command is
-- different: `xmake create -t console hello` writes eleven files and tells us
-- nothing about any of them, and to somebody looking at "what changed" those
-- eleven files are the whole answer.
--
-- so a command is bracketed: what the tree looked like before it ran, what it
-- looks like after, and the difference between the two. it is a stat of each
-- file and not a read: two hundred files cost a millisecond, and the walk which
-- finds them costs forty.
--
-- what it can say honestly is limited, and it says only that much:
--
--   a file which appeared    -> it is new, and undoing it is removing it
--   a file which changed     -> it changed, and we have no copy of the before
--   a file which disappeared -> it is gone, and we cannot bring it back
--
-- the ignored directories are not walked, so a build does not report its own
-- output as a change, @see harness.fs.fs.walk
--
-- it is a heuristic and it says so: the stamp is the modification time and the
-- size, and a file rewritten to the same size within the same second looks
-- unchanged to it. the agent's own writes do not rely on this — they are
-- recorded exactly, as they happen — this is only for what a command did.
--

-- imports
import("harness.fs.fs")

-- the most files we are willing to look at
--
-- past this the walk costs more than the answer is worth, and the answer would
-- be a list nobody reads either
--
local MAXFILES = 20000

-- what the tree holds now
--
-- @return  {["/path/to/file"] = "<mtime>:<size>"}, or nil when it is too big
--
function snapshot(dirpath, opt)
    opt = opt or {}
    if not dirpath or not os.isdir(dirpath) then
        return nil
    end
    local files = fs.walk(dirpath, {maxcount = opt.maxfiles or MAXFILES})
    if #files >= (opt.maxfiles or MAXFILES) then
        return nil
    end
    local seen = {}
    for _, filepath in ipairs(files) do
        seen[filepath] = _stamp(filepath)
    end
    return seen
end

-- the stamp of one file, which changes when the file does
function _stamp(filepath)
    return string.format("%s:%s", tostring(os.mtime(filepath) or 0),
                                  tostring(os.filesize(filepath) or 0))
end

-- what changed since the snapshot was taken
--
-- @return  {created = {".."}, modified = {".."}, removed = {".."}}
--
function changed(dirpath, before, opt)
    local result = {created = {}, modified = {}, removed = {}}
    if not before then
        return result
    end
    local after = snapshot(dirpath, opt)
    if not after then
        return result
    end

    for filepath, stamp in pairs(after) do
        if before[filepath] == nil then
            table.insert(result.created, filepath)
        elseif before[filepath] ~= stamp then
            table.insert(result.modified, filepath)
        end
    end
    for filepath, _ in pairs(before) do
        if after[filepath] == nil then
            table.insert(result.removed, filepath)
        end
    end
    table.sort(result.created)
    table.sort(result.modified)
    table.sort(result.removed)
    return result
end

-- write what a command did into the conversation
--
-- the records have the shape a write leaves behind, so everything which reads
-- them — the changes view, `/rewind` — reads these the same way. what they
-- cannot carry is a copy of the before, because nobody knew which files were
-- about to be written; a record which says so is better than one which claims
-- a way back it does not have.
--
-- @return  the number of files recorded
--
function record(session, result)
    if not session then
        return 0
    end
    local count = 0
    for _, filepath in ipairs(result.created or {}) do
        session:append("edit", {record = {path = filepath, existed = false, bycommand = true}})
        count = count + 1
    end
    for _, filepath in ipairs(result.modified or {}) do
        session:append("edit", {record = {path = filepath, existed = true, bycommand = true,
                                          nocopy = true}})
        count = count + 1
    end
    for _, filepath in ipairs(result.removed or {}) do
        session:append("edit", {record = {path = filepath, existed = true, bycommand = true,
                                          nocopy = true, removed = true}})
        count = count + 1
    end
    return count
end
