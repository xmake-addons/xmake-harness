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
-- @file        keymap.lua
--

--
-- the key bindings of the input box
--
-- it turns one key into one action on the editor, and returns what the
-- application has to do about it: nothing, submit, exit or interrupt.
--

-- imports
import("harness.permission.policy")

-- the editing keys, they only change the text
local EDITS = {
    backspace = function (editor, key)
        if key.alt then
            editor:deleteword()
        else
            editor:backspace()
        end
    end,
    delete = function (editor) editor:delete() end,
    left   = function (editor, key) editor:move("left", {word = key.ctrl or key.alt}) end,
    right  = function (editor, key) editor:move("right", {word = key.ctrl or key.alt}) end,
    home   = function (editor) editor:move("home") end,
    ["end"] = function (editor) editor:move("end") end,
    paste  = function (editor, key) editor:insert(key.text) end,
    char   = function (editor, key) editor:insert(key.ch) end
}

-- the control keys, e.g. ctrl+u
local CONTROLS = {
    d = function (editor) editor:delete() end,
    u = function (editor) editor:deletelinestart() end,
    k = function (editor) editor:deletelineend() end,
    w = function (editor) editor:deleteword() end,
    y = function (editor) editor:yank() end,
    a = function (editor) editor:move("home") end,
    e = function (editor) editor:move("end") end,
    j = function (editor) editor:newline() end
}

-- handle one key
--
-- @param key       the key, @see harness.ui.terminal.readkey
-- @param state     {editor = .., popup = .., mode = "default", lastctrlc = 0}
--
-- @return          the action: nil, "submit", "exit", "ctrlc", "complete",
--                  "clearscreen", "popup", "mode"
--
function handle(key, state)
    local editor = state.editor

    -- the input is closed, e.g. the stdin is piped and drained
    if key.name == "eof" then
        return "exit"
    end

    -- the completion popup takes the navigation keys first
    if state.popup then
        local action = _popupkey(key, state)
        if action then
            return action
        end
    end

    if key.name == "enter" then
        return _enter(editor, key)
    elseif key.name == "ctrl" then
        return _control(editor, key, state)
    elseif key.name == "tab" then
        if key.shift then
            state.mode = policy.nextmode(state.mode)
            return "mode"
        end
        return "complete"
    elseif key.name == "up" or key.name == "down" then
        return _updown(editor, key)
    elseif key.name == "escape" then
        state.popup = nil
        editor:clear()
        return
    end

    local edit = EDITS[key.name]
    if edit then
        edit(editor, key)
        if key.name == "char" or key.name == "backspace" then
            return "popup"
        end
    end
end

-- the keys which drive the completion popup
function _popupkey(key, state)
    if key.name == "up" then
        return "popup.up"
    elseif key.name == "down" then
        return "popup.down"
    elseif key.name == "tab" and not key.shift then
        -- tab completes as far as it is certain, and only cycles once there is
        -- nothing left to add, the way a shell does it
        return "popup.complete"
    elseif key.name == "escape" then
        return "popup.close"
    elseif key.name == "enter" then
        -- the input already is the selected item? then the user is done with
        -- the popup and wants to send it, not to complete it again
        local item = state.popup.items[state.popup.selected]
        if item and item.text == _completed(state) then
            state.popup = nil
            return
        end
        return "popup.accept"
    end
end

-- what the selected item would replace
--
-- a command popup replaces the whole input, an argument or a file popup only
-- the word before the cursor. comparing against the wrong one of the two makes
-- the enter key vanish into the popup: it accepts the word which is already
-- there, closes, and the line the user meant to send is still sitting in the
-- editor, @see harness.ui.completion.accept
--
function _completed(state)
    if state.popup.kind == "command" then
        return state.editor:text():trim()
    end
    return (state.editor:wordbefore()) or ""
end

-- the enter key: send, or add a new line
function _enter(editor, key)
    if key.alt then
        editor:newline()
        return
    end
    local input = editor:text()
    if input:trim() == "" then
        return
    end

    -- a trailing backslash continues the input on the next line
    if input:endswith("\\") then
        editor:backspace()
        editor:newline()
        return
    end
    return "submit"
end

-- the control keys
function _control(editor, key, state)
    local ch = key.ch
    if ch == "c" then
        if editor:isempty() and os.mclock() - (state.lastctrlc or 0) < 2000 then
            return "exit"
        end
        editor:clear()
        state.popup = nil
        return "ctrlc"
    elseif ch == "d" and editor:isempty() then
        return "exit"
    elseif ch == "l" then
        return "clearscreen"
    end
    local control = CONTROLS[ch]
    if control then
        control(editor)
    end
end

-- the up/down keys: move in the input, or browse the history at the edges
function _updown(editor, key)
    local direction = key.name
    if editor:move(direction) then
        return
    end
    editor:browsehistory(direction == "up" and "prev" or "next")
end
