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
-- @file        memory.lua
--

--
-- what is worth knowing next time
--
-- a conversation ends and everything it worked out goes with it. the next one
-- starts by finding out again that the tests are run with `xmake test -g unit`,
-- that this project never uses exceptions, that the person prefers the comment
-- above the function and not beside it. it is the same discovery every time,
-- paid for every time, and the only reason it happens is that nothing wrote it
-- down.
--
-- so something writes it down. a memory is one line of markdown in a file the
-- system prompt already reads, which is the whole trick: there is no new
-- retrieval mechanism, no store to query, no embedding of anything. it is a
-- list, it is in the prompt, and a person can open it in an editor and delete
-- the line they disagree with.
--
-- there are two of them. the project one is checked in and belongs to the
-- project — everybody working on it learns the same thing. the user one is in
-- the harness home and belongs to the person: their habits are theirs, and a
-- commit which told everybody about them would be a surprise.
--
-- what decides *what* goes in here is not this module, @see
-- harness.core.remember: this is the file, the lines in it, and putting one
-- more line in without losing the others.
--

-- imports
import("harness.util.text")
import("harness.config.config", {alias = "harnessconfig"})

-- how many lines one memory may be
--
-- a memory is a fact, and a fact is a sentence. a paragraph is a note somebody
-- wrote instead of deciding what the fact was
local MAXLENGTH = 400

-- and how many of them we keep
--
-- every one of them is in every system prompt of every turn, so the list is a
-- budget and not an archive. past this the oldest go: a fact which has not been
-- restated in two hundred memories is a fact about a project which has moved on
local MAXENTRIES = 200

-- the heading the file is written under
local HEADING = "# Memory"

-- where the two of them live
--
-- @param scope   "project" or "user"
--
function filepath(harness, scope)
    if scope == "user" then
        return path.join(harnessconfig.homedir(), "MEMORY.md")
    end
    return path.join(harness:rootdir(), ".xmake-harness", "MEMORY.md")
end

-- the scopes there are, in the order they are offered
function scopes()
    return {"project", "user"}
end

-- is that a scope?
function isscope(scope)
    return scope == "project" or scope == "user"
end

-- what is remembered in one of them
--
-- @return  {"the tests are run with `xmake test`", ..}
--
function entries(harness, scope)
    -- whatever is in the file reaches the system prompt, and the file is one a
    -- person is invited to edit — with whatever editor, from whatever paste. a
    -- stray byte in it must cost a mangled word and not the whole conversation,
    -- which is what the provider charges for one: `400 invalid unicode code point`
    local content = text.utf8only(_read(filepath(harness, scope)))
    local found = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local entry = line:trim():match("^[%-%*]%s+(.+)$")
        if entry and entry ~= "" then
            table.insert(found, entry)
        end
    end
    return found
end

-- everything remembered, both scopes at once
--
-- @return  {{scope = "project", text = ".."}, ..}
--
function all(harness)
    local found = {}
    for _, scope in ipairs(scopes()) do
        for _, entry in ipairs(entries(harness, scope)) do
            table.insert(found, {scope = scope, text = entry})
        end
    end
    return found
end

-- remember one thing
--
-- @return  true when it was written, or false and why not
--
function remember(harness, scope, entry)
    entry = _tidy(entry)
    if not entry then
        return false, "there is nothing to remember"
    end
    if not isscope(scope) then
        return false, string.format("`%s` is not a scope, it is `project` or `user`", tostring(scope))
    end

    local kept = entries(harness, scope)
    for _, known in ipairs(kept) do
        -- the same thing again is not a second thing. it happens constantly:
        -- the fact which was worth writing down once is the fact which keeps
        -- coming up, and a list of it twenty times is a list nobody reads
        if known:lower() == entry:lower() then
            return false, "it is already remembered"
        end
    end

    table.insert(kept, entry)
    while #kept > MAXENTRIES do
        table.remove(kept, 1)
    end
    return _write(harness, scope, kept)
end

-- forget one, by what it says or by where it is in the list
--
-- @return  the entry which went, or nil and why not
--
function forget(harness, scope, which)
    local kept = entries(harness, scope)
    local index = tonumber(which)
    if not index then
        local needle = tostring(which or ""):lower():trim()
        if needle == "" then
            return nil, "say which one"
        end
        for at, entry in ipairs(kept) do
            if entry:lower():find(needle, 1, true) then
                index = at
                break
            end
        end
    end
    if not index or not kept[index] then
        return nil, string.format("there is nothing like `%s` remembered", tostring(which))
    end

    local gone = table.remove(kept, index)
    local ok, errors = _write(harness, scope, kept)
    if not ok then
        return nil, errors
    end
    return gone
end

-- forget all of one scope
function clear(harness, scope)
    if not isscope(scope) then
        return false, string.format("`%s` is not a scope", tostring(scope))
    end
    return _write(harness, scope, {})
end

-- the section of the system prompt, or nil when nothing is remembered
--
-- it is a section and not a file read, because the two scopes are one list as
-- far as the model is concerned: which file a fact came from is our business
--
function prompt(harness)
    local found = all(harness)
    if #found == 0 then
        return nil
    end
    local lines = {"# What you learned before", "",
                   "These were worked out in the earlier conversations about this project.",
                   "Follow them, and say so if one of them turns out to be wrong.", ""}
    for _, entry in ipairs(found) do
        table.insert(lines, "- " .. entry.text)
    end
    return table.concat(lines, "\n")
end

-- one line, as it will be written
--
-- @return  the entry, or nil when there is nothing in it
--
function _tidy(entry)
    if type(entry) ~= "string" then
        return nil
    end

    -- it is a list item wherever it came from: the model writes "- " in front
    -- of things without being asked, and a file of "- - fact" is a file nobody
    -- wants to look at
    --
    -- `text.oneline` and not `gsub("%s+", " ")`: `%s` is `isspace()`, 0xA0 is a
    -- space to `isspace()`, and 0xA0 is also the middle byte of 标, 配 and a few
    -- hundred others — so the obvious version rewrites the inside of a chinese
    -- character and writes a file which is no longer utf-8, @see harness.util.text
    entry = text.oneline(entry:trim():gsub("^[%-%*]%s+", "")):trim()
    if entry == "" then
        return nil
    end

    -- and `text.cut` and not `sub`, for the same reason at the other end
    return text.cut(entry, MAXLENGTH):trim()
end

-- read one of the files, or nothing
function _read(file)
    if not os.isfile(file) then
        return ""
    end
    return try { function () return io.readfile(file) end } or ""
end

-- write the whole list back
--
-- the file is rewritten rather than appended to, so the list is the truth and
-- the file is a rendering of it. whatever somebody typed around it by hand is
-- lost — which is why the file says, in it, what it is for
--
function _write(harness, scope, kept)
    local file = filepath(harness, scope)
    local lines = {HEADING, "",
        "What the agent worked out about this project, kept between the",
        "conversations. Edit it: a line which is wrong here is wrong every time.",
        ""}
    for _, entry in ipairs(kept) do
        table.insert(lines, "- " .. entry)
    end

    local ok = try {
        function ()
            os.mkdir(path.directory(file))
            io.writefile(file, table.concat(lines, "\n") .. "\n")
            return true
        end
    }
    if not ok then
        return false, string.format("`%s` could not be written", file)
    end
    return true
end
