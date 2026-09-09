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
-- @file        diffview.lua
--

--
-- the diff command: /diff
--
-- the column beside the conversation holding what this conversation changed
-- opens by itself on the first edit, @see harness.ui.app. this is how you take
-- it away again, put one particular file in it, or bring it back afterwards.
--
-- it only opens where there is room, and says so where there is not: a terminal
-- split in two below a hundred and twenty columns is two columns too narrow to
-- read either of them.
--

-- imports
import("harness.ui.split")
import("harness.core.changes")

-- the commands of this group
function commands()
    return {
        {name = "diff", description = "Hide or show the changes beside the conversation",
         run = _diff}
    }
end

-- /diff [file] | /diff off | /diff last
function _diff(app, args)
    if not app.opensplit then
        return {kind = "message", iserror = true,
                text = "the diff pane needs the interactive tui, run `xmake ai`."}
    end

    local what = (args or ""):trim()
    if what == "off" or what == "hide" or what == "close" then
        if not app:closesplit() then
            return {kind = "message", text = "the diff pane is not open."}
        end
        return {kind = "message", text = "the diff pane is hidden."}
    end

    -- with it already open, a bare `/diff` closes it again: it is one key to
    -- look and the same key to stop looking
    if what == "" and app:splitstate() then
        app:closesplit()
        return {kind = "message", text = "the diff pane is hidden, `/diff` brings it back."}
    end

    local listing = changes.list({harness = app.harness, session = app.session})
    if #listing.files == 0 and what == "" then
        return {kind = "message", text = "this conversation has not changed anything yet."}
    end

    -- `/diff last` shows the last edit of a file rather than everything this
    -- conversation did to it, which is the difference between "what changed"
    -- and "what changed just now"
    local base = "session"
    if what == "last" or what == "session" then
        base = what == "last" and "last" or "session"
        what = ""
    end

    local file = nil
    if what ~= "" then
        file = _match(listing, what)
        if not file then
            local names = {}
            for _, one in ipairs(listing.files) do
                table.insert(names, one.path)
            end
            return {kind = "message", iserror = true, text = string.format(
                "`%s` is not a file this conversation changed.\nit changed: %s",
                what, #names > 0 and table.concat(names, ", ") or "nothing")}
        end
    end

    local ok, errors = app:opensplit({file = file, base = base})
    if not ok then
        return {kind = "message", text = errors, iserror = true}
    end
    return {kind = "message", text = string.format(
        "%d file%s beside the conversation. `/diff <file>` for one of them, `/diff` to hide it.",
        #listing.files, #listing.files == 1 and "" or "s")}
end

-- which of the changed files this names
--
-- the whole path, the end of it, or the name: somebody looking at a list of
-- them types the shortest thing which can only mean one
--
function _match(listing, what)
    for _, one in ipairs(listing.files) do
        if one.path == what then
            return one.path
        end
    end
    for _, one in ipairs(listing.files) do
        if one.path:endswith(what) or one.path:endswith("/" .. what) then
            return one.path
        end
    end
    for _, one in ipairs(listing.files) do
        if one.path:find(what, 1, true) then
            return one.path
        end
    end
end
