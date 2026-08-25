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
-- @file        rewind.lua
--

--
-- the rewind command: /rewind
--

-- imports
import("harness.util.text")
import("harness.core.checkpoint")

-- the commands of this group
function commands()
    return {
        {name = "rewind", description = "Put the files back the way they were before a request",
         run = _rewind}
    }
end

-- /rewind [n]
function _rewind(app, args)
    local points = checkpoint.points(app.session)
    if #points == 0 then
        return {kind = "message", text = "nothing has been edited in this conversation yet."}
    end

    local which = (args or ""):trim()
    if which == "" then
        return _list(points)
    end

    local index = tonumber(which) or (which == "last" and #points or nil)
    if not index or not points[index] then
        return {kind = "message", iserror = true,
                text = string.format("there is no point %s, `/rewind` lists them.", which)}
    end
    return _restore(app, points[index], index)
end

-- /rewind
function _list(points)
    local lines = {"the files can be put back to how they were before:", ""}
    for index, point in ipairs(points) do
        table.insert(lines, string.format("  %d. %s", index,
            text.truncate((point.prompt or ""):gsub("%s+", " "), 56)))
        table.insert(lines, string.format("     %s", _files(point.files)))
    end
    table.insert(lines, "")
    table.insert(lines, "  /rewind <n> to go back · /rewind last for the most recent one")
    table.insert(lines, "  it undoes the edits, not the commands the agent ran")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- the files of one point, named rather than counted
function _files(files)
    local names = {}
    for index, filepath in ipairs(files) do
        if index > 4 then
            table.insert(names, string.format("and %d more", #files - 4))
            break
        end
        table.insert(names, path.filename(filepath))
    end
    return table.concat(names, ", ")
end

-- /rewind <n>
function _restore(app, point, index)
    local answer = _confirm(app, point, index)
    if not answer then
        return {kind = "message", text = "cancelled, nothing was touched."}
    end

    local result = checkpoint.restore(app.session, point.index)
    local lines = {}
    if #result.restored > 0 then
        table.insert(lines, string.format("%d file%s put back", #result.restored,
            #result.restored == 1 and "" or "s"))
    end
    if #result.removed > 0 then
        table.insert(lines, string.format("%d file%s removed again, they did not exist before",
            #result.removed, #result.removed == 1 and "" or "s"))
    end
    for _, filepath in ipairs(result.skipped) do
        table.insert(lines, string.format("%s was too large to keep a copy of, it is unchanged",
            path.filename(filepath)))
    end
    for _, filepath in ipairs(result.failed) do
        table.insert(lines, string.format("could not put %s back", path.filename(filepath)))
    end

    -- the conversation still holds the work which has just been undone, and the
    -- model would carry on from a tree which no longer matches what it read
    table.insert(lines, "")
    table.insert(lines, "the conversation still describes those edits: tell the agent what you did,")
    table.insert(lines, "or /clear if you want to start the task over.")
    return {kind = "message", text = table.concat(lines, "\n"), iserror = #result.failed > 0}
end

-- ask first: this overwrites files the user may have edited by hand since
function _confirm(app, point, index)
    if not app.ask then
        return true
    end
    return app:ask({
        lines = {string.format("go back to before: %s", text.truncate((point.prompt or ""):gsub("%s+", " "), 56)),
                 string.format("%d file%s: %s", #point.files, #point.files == 1 and "" or "s",
                     _files(point.files))},
        question = "Any change made since then, by the agent or by you, is overwritten. Continue?",
        options = {{text = "Yes, put them back", value = true},
                   {text = "No", value = false}}
    })
end
