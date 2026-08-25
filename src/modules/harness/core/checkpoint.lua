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

--
-- the way back
--
-- an agent which edits twelve files and gets the eleventh wrong leaves the user
-- with no way to undo it except git — and the work which was in the tree before
-- the session started is exactly the work git does not have.
--
-- so every write keeps what it replaced. the copy goes beside the session, not
-- into it: a session log which carried whole file contents would grow by the
-- size of the project and be re-read in full on every save.
--
-- it undoes edits, and nothing else. commands the agent ran, files it deleted
-- through the shell, anything outside the project — none of that is recorded
-- here, and `/rewind` says as much rather than implying a tidiness it cannot
-- deliver.
--

-- imports
import("harness.util.util")

-- the biggest file worth keeping a copy of
--
-- a checkpoint exists to be cheap. a hundred megabyte artifact which happened
-- to be edited is not worth a hundred megabytes of session directory, and
-- saying so is better than quietly making the session unusable
--
local MAXSIZE = 8 * 1024 * 1024

-- where the copies of one session live
function dir(session)
    return path.join(path.directory(session:filepath()), session:id() .. ".rewind")
end

-- keep what this file holds now, before something replaces it
--
-- @return  the record to put in the log, or nil when there is nothing to keep
--
function save(session, filepath)
    if not session then
        return nil
    end
    local existed = os.isfile(filepath)
    if existed and (os.filesize(filepath) or 0) > MAXSIZE then
        return {path = filepath, toobig = true}
    end

    local record = {path = filepath, existed = existed}
    if existed then
        local seq = (session:events() and #session:events() or 0) + 1
        local copy = path.join(dir(session), string.format("%d-%s", seq, _slug(filepath)))
        local ok = try {
            function ()
                os.mkdir(path.directory(copy))
                os.cp(filepath, copy)
                return true
            end
        }
        if not ok then
            return nil
        end
        record.copy = copy
    end
    return record
end

-- a file name which is a file name on every filesystem
function _slug(filepath)
    return (path.filename(filepath):gsub("[^%w%._%-]", "_"))
end

-- the points a session can be taken back to
--
-- one point per user message: that is what somebody means by "before I asked
-- for this". a point which changed no file is not offered, because going back
-- to it would do nothing
--
-- @return  {{index = 12, prompt = "fix the build", time = ..,
--            files = {"src/a.c"},    -- what going back would put back
--            kept  = {"src/b.c"}}}   -- what it changed and cannot put back
--
function points(session)
    local results = {}
    local current = nil
    for index, event in ipairs(session:events()) do
        if event.kind == "user" and not event.kind_notice then
            current = {index = index, prompt = event.text or "", time = event.time,
                       files = {}, kept = {}, seen = {}}
            table.insert(results, current)
        elseif event.kind == "edit" and current and event.record then
            local filepath = event.record.path
            if not current.seen[filepath] then
                current.seen[filepath] = true

                -- a file a command wrote and which nothing kept a copy of
                -- cannot be put back: it is counted, so the point can say so,
                -- and it is not among the files the point promises
                if event.record.nocopy and event.record.existed then
                    table.insert(current.kept, filepath)
                else
                    table.insert(current.files, filepath)
                end
            end
        end
    end

    -- a point which can undo nothing is not offered, however many files were
    -- written while it was current
    local points = {}
    for _, point in ipairs(results) do
        if #point.files > 0 then
            point.seen = nil
            table.insert(points, point)
        end
    end
    return points
end

-- take the files back to what they were before the given event
--
-- for each file it is the **earliest** copy after that point which is wanted:
-- that is the one holding what the file had when the point was reached. a file
-- written three times has three copies, and the last of them holds the second
-- version — restoring that would undo one edit out of three and look like the
-- rewind half worked
--
-- @return  {restored = {"src/a.c"}, removed = {".."}, failed = {..}}
--
function restore(session, index)
    local result = {restored = {}, removed = {}, failed = {}, skipped = {}}
    local events = session:events()
    local done = {}
    for idx = index, #events do
        local event = events[idx]
        if event.kind == "edit" and event.record and not done[event.record.path] then
            done[event.record.path] = true
            restoreone(event.record, result)
        end
    end
    return result
end

-- put one file back
--
-- public because the web ui reverts one file at a time, @see harness.web.changes
--
function restoreone(record, result)
    if record.toobig then
        table.insert(result.skipped, record.path)
        return result
    end

    -- a command wrote this one and nobody knew which files it was about to
    -- write, so there is no copy of what it replaced, @see harness.fs.observe.
    -- that is not a failure to put it back: it is a file we never held, and
    -- reporting it as one would be claiming a way back which never existed
    if record.nocopy and record.existed then
        table.insert(result.skipped, record.path)
        return result
    end

    -- it did not exist before, so the way back is for it not to exist
    if not record.existed then
        if try { function () os.tryrm(record.path) return true end } then
            table.insert(result.removed, record.path)
        else
            table.insert(result.failed, record.path)
        end
        return result
    end

    if not record.copy or not os.isfile(record.copy) then
        table.insert(result.failed, record.path)
        return result
    end
    if try { function () os.cp(record.copy, record.path) return true end } then
        table.insert(result.restored, record.path)
    else
        table.insert(result.failed, record.path)
    end
    return result
end

-- throw the copies away, e.g. when the session is cleared
function forget(session)
    os.tryrm(dir(session))
    return true
end
