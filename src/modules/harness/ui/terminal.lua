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
-- @file        terminal.lua
--

--
-- the low level terminal layer
--
-- it provides the cross-platform raw input mode and the key decoding,
-- we only use the xmake runtime interfaces here:
--
--   - windows: tty.term_mode() sets the console mode directly
--   - posix:   the `stty` builtin of the system is used to switch the raw mode
--

-- imports
import("core.base.tty")
import("core.base.bit")
import("core.base.pipe")
import("core.base.bytes")
import("core.base.process")
import("harness.util.text")

-- the windows console mode flags
local ENABLE_PROCESSED_INPUT            = 0x0001
local ENABLE_LINE_INPUT                 = 0x0002
local ENABLE_ECHO_INPUT                 = 0x0004
local ENABLE_WINDOW_INPUT               = 0x0008
local ENABLE_VIRTUAL_TERMINAL_INPUT     = 0x0200
local ENABLE_VIRTUAL_TERMINAL_PROCESSING= 0x0004

-- the saved terminal state
local _STATE = _STATE or {}

-- is a tty?
function isatty()
    return io.isatty()
end

-- get the terminal size, e.g. {width = 120, height = 40}
function size()
    local winsize = os.getwinsize()
    local width = winsize and winsize.width or 0
    local height = winsize and winsize.height or 0
    -- the size is invalid if the stdout is not a tty, e.g. 32767 on macos
    if width <= 0 or width > 1000 then
        width = tonumber(os.getenv("COLUMNS")) or 80
    end
    if height <= 0 or height > 1000 then
        height = tonumber(os.getenv("LINES")) or 24
    end
    return {width = width, height = height}
end

-- enter the raw input mode
function rawmode_enter()
    if _STATE.raw then
        return true
    end
    if not isatty() then
        return false
    end
    if os.host() == "windows" then
        local oldmode = tty.term_mode(1)
        local newmode = bit.band(oldmode, bit.bnot(bit.bor(ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT, ENABLE_PROCESSED_INPUT)))
        newmode = bit.bor(newmode, ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_WINDOW_INPUT)
        tty.term_mode(1, newmode)
        local oldmode_out = tty.term_mode(2)
        tty.term_mode(2, bit.bor(oldmode_out, ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        _STATE.oldmode = oldmode
        _STATE.oldmode_out = oldmode_out
    else
        -- save the current settings, so we can restore them exactly
        local saved = try { function () return os.iorunv("stty", {"-g"}) end }
        if saved then
            _STATE.stty = saved:trim()
        end
        local ok = try {
            function ()
                os.execv("stty", {"raw", "-echo"})
                return true
            end
        }
        if not ok then
            return false
        end
    end
    _STATE.raw = true
    _relay_start()
    os.atexit(rawmode_leave)
    return true
end

-- leave the raw input mode
function rawmode_leave()
    if not _STATE.raw then
        return
    end
    _STATE.raw = false
    _relay_stop()
    if os.host() == "windows" then
        if _STATE.oldmode then
            tty.term_mode(1, _STATE.oldmode)
        end
        if _STATE.oldmode_out then
            tty.term_mode(2, _STATE.oldmode_out)
        end
    else
        local settings = _STATE.stty and {_STATE.stty} or {"sane"}
        try { function () os.execv("stty", settings) end }
    end
end

-- is in the raw mode?
function rawmode()
    return _STATE.raw or false
end

-- write the raw data to the terminal
function write(...)
    io.write(...)
end

-- flush the terminal
function flush()
    io.flush()
end

-- enable/disable the bracketed paste mode
function bracketed_paste(enabled)
    write(enabled and "\027[?2004h" or "\027[?2004l")
    flush()
end

-- has the readable input?
function readable()
    local relay = _STATE.relay
    if relay then
        if relay.pos <= #relay.buffer then
            return true
        end
        return relay.rpipe:wait(pipe.EV_READ, 0) > 0
    end
    return try { function () return io.stdin:readable() end } or false
end

-- start the input relay
--
-- on posix the stdin is a buffered stdio stream, so `select()` cannot see the
-- bytes which the c library already pulled into its own buffer: an escape
-- sequence or a paste arrives in one read and the rest of it becomes invisible.
--
-- we work around it by relaying the terminal through a pipe we own: a small
-- `cat` reads the tty and writes into the pipe, and we poll the pipe, which is
-- unbuffered and pollable. on windows the console is read through the console
-- api directly, so no relay is needed there.
--
function _relay_start()
    if os.host() == "windows" then
        return false
    end
    local program = nil
    for _, filepath in ipairs({"/bin/cat", "/usr/bin/cat"}) do
        if os.isexec(filepath) then
            program = filepath
            break
        end
    end
    if not program then
        return false
    end
    local rpipe, wpipe = pipe.openpair()
    if not rpipe then
        return false
    end
    local proc = process.openv(program, {}, {stdout = wpipe})
    wpipe:close()
    if not proc then
        rpipe:close()
        return false
    end
    _STATE.relay = {rpipe = rpipe, proc = proc, buffer = "", pos = 1, buff = bytes(4096)}
    return true
end

-- stop the input relay
function _relay_stop()
    local relay = _STATE.relay
    if not relay then
        return
    end
    _STATE.relay = nil
    try {
        function ()
            relay.proc:kill()
            relay.proc:wait(500)
            relay.proc:close()
            relay.rpipe:close()
        end
    }
end

-- read the pending bytes of the relay into the buffer
function _relay_fill(relay, timeout)
    if relay.pos <= #relay.buffer then
        return true
    end
    local real, data = relay.rpipe:read(relay.buff)
    if real > 0 then
        relay.buffer = data:str()
        relay.pos = 1
        return true
    elseif real < 0 then
        relay.eof = true
        return false
    end
    if (timeout or 0) <= 0 then
        return false
    end
    local events = relay.rpipe:wait(pipe.EV_READ, timeout)
    if events < 0 then
        relay.eof = true
        return false
    elseif events == 0 then
        return false
    end
    local real2, data2 = relay.rpipe:read(relay.buff)
    if real2 > 0 then
        relay.buffer = data2:str()
        relay.pos = 1
        return true
    elseif real2 < 0 then
        relay.eof = true
    end
    return false
end

-- read one byte from the stdin
--
-- @return  the byte, nil if there is no data, or false on the end of the input
--
function _readbyte(timeout)

    -- read from the relay pipe
    local relay = _STATE.relay
    if relay then
        if _relay_fill(relay, timeout) then
            local ch = relay.buffer:sub(relay.pos, relay.pos)
            relay.pos = relay.pos + 1
            return ch
        end
        if relay.eof then
            return false
        end
        return nil
    end
    return _readbyte_stdio(timeout)
end

-- read one byte from the buffered stdin, it is used on windows
function _readbyte_stdio(timeout)
    timeout = timeout or 0
    local waited = 0
    while true do
        if readable() then
            local ch = try { function () return io.stdin:read(1) end }
            if ch and #ch > 0 then
                return ch
            end
            -- the stdin is readable but returns nothing, it is closed
            return false
        end
        if waited >= timeout then
            return nil
        end
        local step = math.min(4, timeout - waited)
        os.sleep(step)
        waited = waited + step
    end
end

-- read the rest bytes of one utf8 character
function _readutf8(first)
    local byte = first:byte(1)
    local count = 0
    if byte >= 0xf0 then
        count = 3
    elseif byte >= 0xe0 then
        count = 2
    elseif byte >= 0xc0 then
        count = 1
    end
    local result = first
    for _ = 1, count do
        local ch = _readbyte(30)
        if not ch then
            break
        end
        result = result .. ch
    end
    return result
end

-- read the bracketed paste content until the end marker
function _readpaste()
    local buffer = {}
    while true do
        local ch = _readbyte(2000)
        if not ch then
            break
        end
        table.insert(buffer, ch)
        local tail = table.concat(buffer, "", math.max(1, #buffer - 5))
        if tail:endswith("\027[201~") then
            for _ = 1, 6 do
                table.remove(buffer)
            end
            break
        end
    end
    return table.concat(buffer)
end

-- decode the escape sequence, the leading `\027` has been consumed
function _readescape()

    -- a lone escape key? we wait a little while for the rest of the sequence
    local ch = _readbyte(40)
    if not ch then
        return {name = "escape"}
    end

    -- alt + key
    if ch ~= "[" and ch ~= "O" then
        if ch == "\r" or ch == "\n" then
            return {name = "enter", alt = true}
        elseif ch == "\127" or ch == "\8" then
            return {name = "backspace", alt = true}
        elseif ch == "\027" then
            return {name = "escape"}
        end
        return {name = "char", ch = _readutf8(ch), alt = true}
    end

    -- read the parameters of the csi sequence
    local params = {}
    local final = nil
    while true do
        local c = _readbyte(60)
        if not c then
            break
        end
        if c:match("[%d;%?]") then
            table.insert(params, c)
        else
            final = c
            break
        end
    end
    local param = table.concat(params)
    local seq = (ch == "O" and "O" or "[") .. param .. (final or "")

    -- the bracketed paste
    if seq == "[200~" then
        return {name = "paste", text = _readpaste()}
    end

    -- the modifiers, e.g. "1;5C" -> ctrl + right
    local modifier = tonumber(param:match(";(%d+)$") or "1") or 1
    local ctrl = (modifier - 1) % 8 >= 4
    local shift = (modifier - 1) % 2 == 1
    local alt = (modifier - 1) % 4 >= 2

    local keymaps = {
        ["A"] = "up", ["B"] = "down", ["C"] = "right", ["D"] = "left",
        ["H"] = "home", ["F"] = "end", ["Z"] = "shifttab"
    }
    if final and keymaps[final] then
        local name = keymaps[final]
        if name == "shifttab" then
            return {name = "tab", shift = true}
        end
        return {name = name, ctrl = ctrl, shift = shift, alt = alt}
    end
    local numkeys = {
        ["1"] = "home", ["2"] = "insert", ["3"] = "delete",
        ["4"] = "end", ["5"] = "pageup", ["6"] = "pagedown",
        ["7"] = "home", ["8"] = "end"
    }
    local num = param:match("^(%d+)")
    if final == "~" and num and numkeys[num] then
        return {name = numkeys[num], ctrl = ctrl, shift = shift, alt = alt}
    end
    return {name = "unknown", sequence = seq}
end

-- read one key from the terminal
--
-- @param timeout   the timeout in milliseconds, 0 for non-blocking
-- @return          the key table, e.g. {name = "char", ch = "a"}, {name = "ctrl", ch = "c"}
--
function readkey(timeout)
    local ch = _readbyte(timeout or 0)
    if ch == false then
        return {name = "eof"}
    end
    if not ch then
        return nil
    end
    local byte = ch:byte(1)
    if ch == "\027" then
        return _readescape()
    elseif ch == "\r" or ch == "\n" then
        return {name = "enter"}
    elseif ch == "\t" then
        return {name = "tab"}
    elseif ch == "\127" or ch == "\8" then
        return {name = "backspace"}
    elseif byte < 32 then
        -- the control characters, e.g. ctrl-c is 0x03
        return {name = "ctrl", ch = string.char(byte + 96)}
    end
    return {name = "char", ch = _readutf8(ch)}
end

-- get the readable name of the given key, e.g. "ctrl+c"
function keyname(key)
    if not key then
        return ""
    end
    if key.name == "ctrl" then
        return "ctrl+" .. (key.ch or "")
    elseif key.name == "char" then
        return (key.alt and "alt+" or "") .. (key.ch or "")
    end
    local prefix = ""
    if key.ctrl then
        prefix = prefix .. "ctrl+"
    end
    if key.alt then
        prefix = prefix .. "alt+"
    end
    if key.shift then
        prefix = prefix .. "shift+"
    end
    return prefix .. key.name
end
