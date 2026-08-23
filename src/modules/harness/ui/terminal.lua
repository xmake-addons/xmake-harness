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

-- is the terminal interactive?
--
-- we check the stdin, because that is the side we read from: the stdout may
-- well be a terminal while the stdin is a pipe or a closed descriptor
--
function isatty()
    local ok = try { function () return io.stdin:isatty() end }
    if ok == nil then
        return io.isatty()
    end
    return ok and io.isatty()
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
        if not _setmode() then
            return false
        end
    end
    _STATE.raw = true
    _STATE.pending = ""
    os.atexit(rawmode_leave)
    return true
end

-- set the non-canonical input mode
--
-- `min 1 time 0` makes a read wait for one byte instead of returning empty: the
-- c library latches its end-of-file flag on an empty read and would then never
-- ask the terminal again. the reader thread is the one which blocks on it.
--
-- we never use `stty raw`: it would also disable the output post-processing,
-- and then every `\n` we write moves down without returning to the column 0
--
function _setmode()
    return try {
        function ()
            os.execv("stty", {"-icanon", "-echo", "-isig", "-ixon", "min", "1", "time", "0"})
            return true
        end
    } or false
end

-- leave the raw input mode
function rawmode_leave()
    if not _STATE.raw then
        return
    end
    _STATE.raw = false
    _STATE.pending = ""
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

-- get the name of the input backend which is in use
function inputbackend()
    return string.format("stdin%s", _STATE.raw and " (raw)" or "")
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
    if _STATE.pending and _STATE.pending ~= "" then
        return true
    end
    return try { function () return io.stdin:readable() end } or false
end

-- read one byte from the stdin, without waiting for it
--
-- `io.stdin:readable()` is a `select()` on the terminal, so it only tells us
-- about the bytes the c library has not pulled in yet
--
-- @return  the byte, or nil if the terminal has nothing for us right now
--
function _readbyte(timeout)
    timeout = timeout or 0
    -- the clock decides when we are done, never the sum of what we asked for
    --
    -- `os.sleep(4)` yields to the scheduler and comes back when the scheduler
    -- gets around to us, which is rarely in four milliseconds. counting the
    -- requested milliseconds instead of the elapsed ones made a 500ms timeout
    -- take five seconds: long enough for the caller to think nothing happened
    -- at all, and for a countdown driven by it to skip whole seconds
    --
    local deadline = os.mclock() + timeout
    while true do
        if readable() then
            local ch = try { function () return io.stdin:read(1) end }
            if ch and #ch > 0 then
                return ch
            end
            return nil
        end
        local left = deadline - os.mclock()
        if left <= 0 then
            return nil
        end
        os.sleep(math.min(4, left))
    end
end

-- wait for one byte from the stdin
--
-- the read waits until the user types something, which is exactly what the idle
-- input loop wants: it has nothing else to do until then
--
function _waitbyte()
    local ch = try { function () return io.stdin:read(1) end }
    if ch and #ch > 0 then
        return ch
    end
    return nil
end

-- read the next byte of a sequence which is already on its way
--
-- a key like an arrow arrives as several bytes at once, and the c library pulls
-- all of them into its own buffer on the first read: `readable()` cannot see
-- them there any more, but `io.stdin:read(0)` can, it peeks the buffer.
--
-- @note the peek waits when the buffer is empty too, so it is only used where
--       waiting is acceptable, @see readkey()
--
function _morebyte()
    if readable() then
        return _readbyte(0)
    end
    if try { function () return io.stdin:read(0) end } then
        return _waitbyte()
    end
    return nil
end

-- read one byte for the given options
--
-- @param timeout   how long we may poll for it, in milliseconds
-- @param opt       the options, e.g. {wait = true}
--                  - wait  the caller has nothing else to do until a key
--                          arrives, so we may wait for it
--
function _nextbyte(timeout, opt)
    opt = opt or {}
    if opt.more then
        return _morebyte()
    end
    local ch = _readbyte(timeout)
    if ch or not opt.wait then
        return ch
    end
    return _waitbyte()
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
        local ch = _nextbyte(30, {more = true})
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
        local ch = _nextbyte(2000, {more = true})
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
function _readescape(opt)

    -- the rest of the sequence is already in the buffer of the c library, but a
    -- lone escape key has nothing behind it: we may only look into that buffer
    -- when waiting there is acceptable, @see _nextbyte()
    local ch = _nextbyte(40, opt and opt.wait and {more = true} or nil)
    if not ch then
        return {name = "escape"}
    end

    -- a csi sequence, e.g. "\027[1;5C", or an ss3 one, e.g. "\027OA"
    if ch == "[" or ch == "O" then
        return _readcsi(ch)
    end
    return _altkey(ch)
end

-- decode an alt + key combination
function _altkey(ch)
    if ch == "\r" or ch == "\n" then
        return {name = "enter", alt = true}
    elseif ch == "\127" or ch == "\8" then
        return {name = "backspace", alt = true}
    elseif ch == "\027" then
        return {name = "escape"}
    end
    return {name = "char", ch = _readutf8(ch), alt = true}
end

-- read and decode a csi sequence, the leading "\027[" has been consumed
function _readcsi(intro)
    local params = {}
    local final = nil
    while true do
        local ch = _nextbyte(60, {more = true})
        if not ch then
            break
        end
        if ch:match("[%d;%?]") then
            table.insert(params, ch)
        else
            final = ch
            break
        end
    end

    local param = table.concat(params)
    local sequence = (intro == "O" and "O" or "[") .. param .. (final or "")
    if sequence == "[200~" then
        return {name = "paste", text = _readpaste()}
    end
    return _csikey(param, final, sequence)
end

-- get the key of the given csi parameters
function _csikey(param, final, sequence)

    -- the modifiers, e.g. "1;5C" is ctrl + right
    local modifier = tonumber(param:match(";(%d+)$") or "1") or 1
    local key = {
        ctrl  = (modifier - 1) % 8 >= 4,
        shift = (modifier - 1) % 2 == 1,
        alt   = (modifier - 1) % 4 >= 2
    }

    -- the keys which end the sequence themselves, e.g. "\027[A"
    local finalkeys = {
        A = "up", B = "down", C = "right", D = "left",
        H = "home", F = "end", Z = "shifttab"
    }
    local name = final and finalkeys[final]
    if name == "shifttab" then
        return {name = "tab", shift = true}
    elseif name then
        key.name = name
        return key
    end

    -- the keys which are numbered, e.g. "\027[3~" is delete
    local numberkeys = {
        ["1"] = "home", ["2"] = "insert", ["3"] = "delete",
        ["4"] = "end", ["5"] = "pageup", ["6"] = "pagedown",
        ["7"] = "home", ["8"] = "end"
    }
    local number = param:match("^(%d+)")
    if final == "~" and number and numberkeys[number] then
        key.name = numberkeys[number]
        return key
    end
    return {name = "unknown", sequence = sequence}
end

-- read one key from the terminal
--
-- @param timeout   the timeout in milliseconds, 0 for non-blocking
-- @param opt       the options, e.g. {wait = true}
--                  - wait  wait for the key instead of giving up. the idle
--                          input loop waits, the loop which runs while the
--                          model works must not: it has to keep the ui alive
--
-- @return          the key table, e.g. {name = "char", ch = "a"}, {name = "ctrl", ch = "c"}
--
function readkey(timeout, opt)
    local ch = _nextbyte(timeout or 0, opt)
    if not ch then
        return nil
    end
    local byte = ch:byte(1)
    if ch == "\027" then
        return _readescape(opt)
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
