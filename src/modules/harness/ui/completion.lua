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
-- @file        completion.lua
--

--
-- the completion popup of the input box
--
-- it completes the slash commands and the file paths, and renders itself into
-- the live region.
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")

-- the maximum number of the visible items
local MAX_VISIBLE = 8

-- update the popup for the current input
--
-- @param harness   the harness context
-- @param editor    the input editor
-- @return          the popup, or nil when there is nothing to complete
--
function update(harness, editor)
    local input = editor:text()

    -- the slash commands, only at the very beginning of the input
    if input:startswith("/") then
        local name, args = input:sub(2):match("^(%S+)%s+(.*)$")
        if name then
            return _arguments(harness, name, args)
        end
        return _commands(harness, input:sub(2))
    end

    -- the files, after an `@`
    local word = editor:wordbefore()
    if word and word:startswith("@") then
        return _files(harness, word:sub(2))
    end
end

-- the command items
function _commands(harness, prefix)
    local items = {}
    for _, command in ipairs(harness:service("commands"):find(prefix)) do
        table.insert(items, {text = "/" .. command.name, description = command.description})
    end
    if #items == 0 then
        return nil
    end
    return {items = items, selected = 1, kind = "command"}
end

-- the argument items of a command which completes its own arguments
--
-- a command says what its arguments are with `complete(harness, args)`, e.g.
-- `/xmake bu` offers `build`. the ones which do not are left alone: an unknown
-- argument list is better completed by nothing than by the wrong thing
--
function _arguments(harness, name, args)
    local command = harness:service("commands"):get(name)
    if not command or not command.complete then
        return nil
    end
    local items = command.complete(harness, args)
    if not items or #items == 0 then
        return nil
    end
    return {items = items, selected = 1, kind = "argument"}
end

-- the file items
function _files(harness, prefix)
    local rootdir = harness:rootdir()
    local dir = path.directory(prefix)
    local name = path.filename(prefix)
    local searchdir = (dir and dir ~= "." and dir ~= "") and path.join(rootdir, dir) or rootdir
    if not os.isdir(searchdir) then
        return nil
    end

    local items = {}
    for _, filepath in ipairs(os.filedirs(path.join(searchdir, "*"))) do
        local filename = path.filename(filepath)
        if not filename:startswith(".") and (name == "" or filename:lower():startswith(name:lower())) then
            local isdir = os.isdir(filepath)
            table.insert(items, {
                text = "@" .. path.relative(filepath, rootdir) .. (isdir and "/" or ""),
                description = isdir and "directory" or util.filesize(os.filesize(filepath) or 0)})
        end
        if #items >= 30 then
            break
        end
    end
    if #items == 0 then
        return nil
    end
    table.sort(items, function (a, b) return a.text < b.text end)
    return {items = items, selected = 1, kind = "file"}
end

-- move the selection
function move(popup, direction)
    if direction == "up" then
        popup.selected = popup.selected > 1 and popup.selected - 1 or #popup.items
    else
        popup.selected = popup.selected % #popup.items + 1
    end
    return popup
end

-- accept the selected item into the editor
function accept(popup, editor)
    local item = popup.items[popup.selected]
    if not item then
        return
    end
    if popup.kind == "command" then
        editor:settext(item.text .. " ")
    else
        editor:replaceword(item.text)
    end
end

-- extend the input by the part which every candidate shares
--
-- `/xm` becomes `/xmake` because both `/xmake` and `/xmake-docs` start with it,
-- and there it stops: guessing which of the two was meant is the popup's job,
-- not the tab key's
--
-- @return  true when something was added
--
function extend(popup, editor)
    local prefix = _commonprefix(popup.items)
    local current = popup.kind == "command" and editor:text():trim() or (editor:wordbefore() or "")
    if #prefix <= #current then
        return false
    end
    if popup.kind == "command" then
        editor:settext(prefix)
    else
        editor:replaceword(prefix)
    end
    return true
end

-- the longest prefix which every item starts with
function _commonprefix(items)
    local prefix = items[1] and items[1].text or ""
    for _, item in ipairs(items) do
        while prefix ~= "" and not item.text:startswith(prefix) do
            prefix = prefix:sub(1, #prefix - 1)
        end
    end
    return prefix
end

-- render the popup
function render(popup, width)
    local lines = {}
    local start = math.max(1, popup.selected - MAX_VISIBLE + 1)
    for idx = start, math.min(#popup.items, start + MAX_VISIBLE - 1) do
        local item = popup.items[idx]
        local active = idx == popup.selected
        local line = string.format("  %s %s", active and "❯" or " ", text.pad(item.text, 24))
        if item.description then
            line = line .. theme.styled("dim", text.truncate(item.description, math.max(10, width - 32)))
        end
        table.insert(lines, theme.styled(active and "select.active" or "select.normal", line))
    end
    if #popup.items > MAX_VISIBLE then
        table.insert(lines, theme.styled("dim", string.format("    … %d more", #popup.items - MAX_VISIBLE)))
    end
    return lines
end
