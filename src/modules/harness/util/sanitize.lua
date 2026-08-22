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
-- @file        sanitize.lua
--

--
-- the output sanitizer
--
-- whatever a tool prints goes straight back into the model, and a lot of it is
-- not ours: a compiler message, a file we just read, the output of a command
-- someone else wrote. that text can carry more than it looks like:
--
--   - the escape sequences repaint the terminal and can hide what is really
--     there, so a tool result may look different to the user than to the model
--   - the bidi overrides reorder what a human reads while the bytes say
--     something else, which is the trojan-source trick
--   - the stray control characters break our own rendering
--
-- so every tool result is scrubbed before it reaches the model or the screen.
-- it is a cheap defence against a prompt injection which arrives through a
-- build log or a source file.
--

-- the bidirectional overrides, they make the text read differently than it is
--
-- U+202A..U+202E and U+2066..U+2069, written as their utf8 bytes
local BIDI = {
    "\226\128\170", "\226\128\171", "\226\128\172", "\226\128\173", "\226\128\174",
    "\226\129\166", "\226\129\167", "\226\129\168", "\226\129\169"
}

-- the zero width characters which can hide text inside a word
local INVISIBLE = {
    "\226\128\139", -- U+200B zero width space
    "\226\128\140", -- U+200C zero width non-joiner
    "\226\128\141", -- U+200D zero width joiner
    "\239\187\191"  -- U+FEFF zero width no-break space
}

-- scrub the given text
--
-- @param str   the text
-- @param opt   the options, e.g. {keepansi = false}
--              - keepansi  keep the escape sequences, e.g. for a diff we render
--                          ourselves
--
function clean(str, opt)
    if type(str) ~= "string" or str == "" then
        return str
    end
    opt = opt or {}

    -- the escape sequences: csi, osc and the single character ones
    if not opt.keepansi then
        str = str:gsub("\027%[[%d;?]*[ -/]*[@-~]", "")
        str = str:gsub("\027%][^\007\027]*[\007\027]?", "")
        str = str:gsub("\027[@-Z\\-_]", "")
    end

    -- the control characters, the newline and the tab are the only ones a tool
    -- result has any business carrying
    --
    -- the escape byte survives when the caller keeps the sequences, otherwise
    -- stripping it would leave the parameters behind as plain text
    if opt.keepansi then
        str = str:gsub("[%z\001-\008\011\012\014-\026\028-\031\127]", "")
    else
        str = str:gsub("[%z\001-\008\011\012\014-\031\127]", "")
    end

    for _, sequence in ipairs(BIDI) do
        str = str:gsub(sequence, "")
    end
    for _, sequence in ipairs(INVISIBLE) do
        str = str:gsub(sequence, "")
    end

    -- a lone carriage return is a progress bar rewriting its line, the last
    -- state of it is the one which matters
    str = str:gsub("\r\n", "\n"):gsub("\r", "\n")
    return str
end

-- does the given text carry anything we would scrub?
function isdirty(str)
    return type(str) == "string" and clean(str) ~= str
end
