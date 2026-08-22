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
-- @file        language.lua
--

--
-- the language of the user
--
-- the model answers in the language the user writes in, which works most of the
-- time but drifts back to english after a few english tool outputs. so we look
-- at what the user actually types and tell the model explicitly.
--

-- the scripts we detect, they cover the users of xmake
local SCRIPTS = {
    {name = "zh", label = "Chinese",  first = 0x4e00, last = 0x9fff},
    {name = "zh", label = "Chinese",  first = 0x3400, last = 0x4dbf},
    {name = "ja", label = "Japanese", first = 0x3040, last = 0x30ff},
    {name = "ko", label = "Korean",   first = 0xac00, last = 0xd7af},
    {name = "ru", label = "Russian",  first = 0x0400, last = 0x04ff}
}

-- detect the language of the given text
--
-- @return  the language name and its label, e.g. "zh", "Chinese"
--
function detect(str)
    if not str or str == "" then
        return "en", "English"
    end

    local counts = {}
    local total = 0
    try {
        function ()
            for _, code in utf8.codes(str) do
                local name, label = _script(code)
                if name then
                    counts[name] = counts[name] or {count = 0, label = label}
                    counts[name].count = counts[name].count + 1
                end
                if code > 32 then
                    total = total + 1
                end
            end
            return true
        end
    }
    if total == 0 then
        return "en", "English"
    end

    -- one cjk character carries a whole word, so a few of them already mean
    -- that the user is writing in that language
    local best, bestcount = nil, 0
    for name, item in pairs(counts) do
        if item.count > bestcount then
            best, bestcount = name, item.count
        end
    end
    if best and bestcount >= 2 and bestcount / total > 0.1 then
        return best, counts[best].label
    end
    return "en", "English"
end

-- get the script of one code point
function _script(code)
    if code < 0x0400 then
        return nil
    end
    for _, script in ipairs(SCRIPTS) do
        if code >= script.first and code <= script.last then
            return script.name, script.label
        end
    end
    return nil
end

-- detect the language of a session
--
-- the last messages weigh more than the first ones: a user who switches to
-- english should get english back
--
function ofsession(session, opt)
    opt = opt or {}
    local messages = {}
    for _, event in ipairs(session and session:events() or {}) do
        if event.kind == "user" and event.text and event.text ~= "" then
            table.insert(messages, event.text)
        end
    end
    if #messages == 0 then
        return "en", "English"
    end

    local recent = {}
    for idx = math.max(1, #messages - (opt.keeprecent or 3) + 1), #messages do
        table.insert(recent, messages[idx])
    end
    return detect(table.concat(recent, "\n"))
end
