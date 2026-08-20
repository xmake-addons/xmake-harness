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
-- @file        util.lua
--

-- imports
import("core.base.hashset")

-- the counter for generating the unique id
local counter = 0

-- generate an unique id, e.g. "01923ab8-4f2c"
function uuid()
    counter = counter + 1
    local now = os.time()
    local clock = math.floor(os.mclock())
    return string.format("%08x-%04x-%04x", now, clock % 0xffff, (counter * 7919 + now * 13) % 0xffff)
end

-- get the current timestamp in milliseconds
function now()
    return math.floor(os.mclock())
end

-- format the timestamp to the iso8601 string
function isotime(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t or os.time())
end

-- humanize the duration, e.g. 1234 -> "1.2s", 90000 -> "1m 30s"
function duration(ms)
    ms = math.max(0, ms or 0)
    if ms < 1000 then
        return string.format("%dms", math.floor(ms))
    end
    local secs = ms / 1000
    if secs < 60 then
        return string.format("%.1fs", secs)
    end
    local mins = math.floor(secs / 60)
    secs = math.floor(secs % 60)
    if mins < 60 then
        return string.format("%dm %ds", mins, secs)
    end
    local hours = math.floor(mins / 60)
    mins = mins % 60
    return string.format("%dh %dm", hours, mins)
end

-- humanize the count, e.g. 12345 -> "12.3k"
function count(n)
    n = n or 0
    if n < 1000 then
        return tostring(math.floor(n))
    elseif n < 1000000 then
        return string.format("%.1fk", n / 1000)
    end
    return string.format("%.1fM", n / 1000000)
end

-- humanize the file size
function filesize(bytes)
    bytes = bytes or 0
    if bytes < 1024 then
        return string.format("%dB", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1fKB", bytes / 1024)
    end
    return string.format("%.1fMB", bytes / (1024 * 1024))
end

-- get the value of the nested table by the dot-separated key, e.g. "providers.deepseek.apikey"
function tget(tbl, key)
    local node = tbl
    for name in key:gmatch("[^%.]+") do
        if type(node) ~= "table" then
            return nil
        end
        node = node[name]
    end
    return node
end

-- set the value of the nested table by the dot-separated key
function tset(tbl, key, value)
    local node = tbl
    local names = {}
    for name in key:gmatch("[^%.]+") do
        table.insert(names, name)
    end
    for idx = 1, #names - 1 do
        local name = names[idx]
        if type(node[name]) ~= "table" then
            node[name] = {}
        end
        node = node[name]
    end
    node[names[#names]] = value
    return tbl
end

-- merge the source table into the destination table deeply, the source wins
function tmerge(dst, src)
    if type(src) ~= "table" then
        return dst
    end
    dst = dst or {}
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" and not _isarray(v) then
            tmerge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

-- is the given table an array?
function _isarray(tbl)
    if type(tbl) ~= "table" then
        return false
    end
    local n = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" then
            return false
        end
        n = n + 1
    end
    return n > 0
end

-- parse the boolean value from the string
function tobool(value, default)
    if value == nil or value == "" then
        return default
    end
    if type(value) == "boolean" then
        return value
    end
    value = tostring(value):lower()
    if value == "true" or value == "yes" or value == "y" or value == "1" or value == "on" then
        return true
    elseif value == "false" or value == "no" or value == "n" or value == "0" or value == "off" then
        return false
    end
    return default
end

-- parse the value string to the lua value, e.g. "true" -> true, "123" -> 123
function tovalue(value)
    if value == nil then
        return nil
    end
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    elseif value == "nil" or value == "null" then
        return nil
    end
    local num = tonumber(value)
    if num ~= nil then
        return num
    end
    return value
end

-- get the relative path to the given root directory for displaying
function shortpath(filepath, rootdir)
    if not filepath then
        return ""
    end
    rootdir = rootdir or os.curdir()
    local relative = path.relative(filepath, rootdir)
    if relative and not relative:startswith("..") then
        return relative
    end
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if home and filepath:startswith(home) then
        return "~" .. filepath:sub(#home + 1)
    end
    return filepath
end

-- deduplicate the array in place order
function unique(values)
    local results = {}
    local seen = hashset.new()
    for _, value in ipairs(values or {}) do
        if not seen:has(value) then
            seen:insert(value)
            table.insert(results, value)
        end
    end
    return results
end
