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
-- the memory command: /memory
--
-- the harness writes things down about a project by itself, @see
-- harness.core.remember. this is how somebody sees what it decided and takes it
-- back — a memory nobody can list is a memory nobody can correct, and it is in
-- every prompt of every turn until they do.
--

-- imports
import("harness.core.memory")

-- the commands of this group
function commands()
    return {
        {name = "memory", description = "What was learned about this project, and forget one",
         run = _memory}
    }
end

-- /memory | /memory add <fact> | /memory forget <n|text> | /memory clear [scope]
function _memory(app, args)
    local what, rest = (args or ""):trim():match("^(%S*)%s*(.*)$")
    if what == "add" or what == "remember" then
        return _add(app, rest)
    elseif what == "forget" or what == "remove" then
        return _forget(app, rest)
    elseif what == "clear" then
        return _clear(app, rest)
    elseif what ~= "" then
        return {kind = "message", iserror = true, text =
            "`/memory` lists them, `/memory add <fact>`, `/memory forget <n>`, `/memory clear`."}
    end
    return _list(app)
end

-- what is remembered, by scope, numbered so one can be named
function _list(app)
    local lines = {}
    local index = 0
    for _, scope in ipairs(memory.scopes()) do
        local entries = memory.entries(app.harness, scope)
        if #entries > 0 then
            table.insert(lines, string.format("%s (%s)", scope,
                memory.filepath(app.harness, scope)))
            for _, entry in ipairs(entries) do
                index = index + 1
                table.insert(lines, string.format("  %d. %s", index, entry))
            end
            table.insert(lines, "")
        end
    end
    if index == 0 then
        return {kind = "message", text =
            "nothing has been learned about this project yet.\n"
            .. "it writes things down by itself as the conversations go; "
            .. "`/memory add <fact>` says one now."}
    end
    table.insert(lines, "`/memory forget <n>` takes one back, `/memory add <fact>` adds one.")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- /memory add [user] <fact>
function _add(app, rest)
    local scope, fact = _scopeof(rest)
    if fact == "" then
        return {kind = "message", iserror = true,
                text = "say what to remember, e.g. `/memory add the tests are run with `xmake test``."}
    end
    local ok, errors = memory.remember(app.harness, scope, fact)
    if not ok then
        return {kind = "message", iserror = true, text = errors}
    end
    return {kind = "message", text = string.format("remembered, in the %s memory.", scope)}
end

-- /memory forget <n|text>
--
-- the numbers are the ones `/memory` printed, which run across both scopes:
-- somebody reading a list picks the fourth line, not the second line of the
-- second list
--
function _forget(app, rest)
    rest = rest:trim()
    if rest == "" then
        return {kind = "message", iserror = true, text = "say which one, e.g. `/memory forget 2`."}
    end

    local index = tonumber(rest)
    if index then
        local scope, at = _locate(app.harness, index)
        if not scope then
            return {kind = "message", iserror = true,
                    text = string.format("there is no memory %d.", index)}
        end
        return _forgotten(memory.forget(app.harness, scope, at))
    end

    for _, scope in ipairs(memory.scopes()) do
        local gone = memory.forget(app.harness, scope, rest)
        if gone then
            return _forgotten(gone)
        end
    end
    return {kind = "message", iserror = true,
            text = string.format("there is nothing like `%s` remembered.", rest)}
end

-- which scope and which position that number is
function _locate(harness, index)
    local seen = 0
    for _, scope in ipairs(memory.scopes()) do
        local entries = memory.entries(harness, scope)
        if index <= seen + #entries then
            return scope, index - seen
        end
        seen = seen + #entries
    end
    return nil
end

-- what to say about the one which went
function _forgotten(gone, errors)
    if not gone then
        return {kind = "message", iserror = true, text = errors or "it could not be forgotten."}
    end
    return {kind = "message", text = string.format("forgotten: %s", gone)}
end

-- /memory clear [scope]
function _clear(app, rest)
    local scope = rest:trim()
    if scope == "" then
        scope = "project"
    end
    if not memory.isscope(scope) then
        return {kind = "message", iserror = true,
                text = string.format("`%s` is not a scope, it is `project` or `user`.", scope)}
    end
    local count = #memory.entries(app.harness, scope)
    local ok, errors = memory.clear(app.harness, scope)
    if not ok then
        return {kind = "message", iserror = true, text = errors}
    end
    return {kind = "message", text = string.format("the %s memory is empty (%d forgotten).",
                                                   scope, count)}
end

-- read a leading scope off the arguments, if there is one
function _scopeof(rest)
    local first, remainder = rest:trim():match("^(%S*)%s*(.*)$")
    if memory.isscope(first) then
        return first, remainder:trim()
    end
    return "project", rest:trim()
end
