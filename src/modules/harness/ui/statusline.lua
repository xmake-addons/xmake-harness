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
-- @file        statusline.lua
--

--
-- the status and hint lines of the live region
--

-- imports
import("harness.util.util")
import("harness.ui.theme")

-- the spinner frames
local SPINNERS = {
    dots = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
    star = {"✻", "✽", "✻", "✢", "·", "✢"},
    line = {"|", "/", "-", "\\"}
}

-- the words which describe what the model is doing
local WORDS = {"Thinking", "Working", "Harmonizing", "Pondering", "Digging", "Composing",
               "Assembling", "Tinkering", "Wrangling", "Reticulating"}

-- get the working verb of the given tool
function verb(name)
    local verbs = {
        read_file = "Reading", write_file = "Writing", edit_file = "Editing",
        search_text = "Searching", glob_files = "Globbing", list_dir = "Listing",
        run_command = "Running", run_agent = "Delegating", use_skill = "Learning",
        fetch_url = "Fetching", todo_write = "Planning"
    }
    return verbs[name]
end

-- render the status line, e.g. "✻ Harmonizing… (12s · ↓ 1.2k tokens · esc to interrupt)"
--
-- @param state {elapsed = 12000, tokens = 1200, working = "Reading",
--               spinner = "star", frame = 3, word = 1}
--
function status(state)
    local frames = SPINNERS[state.spinner or "star"] or SPINNERS.star
    local frame = frames[(state.frame or 0) % #frames + 1]
    local word = state.working or WORDS[(state.word or 0) % #WORDS + 1]
    local parts = {util.duration(state.elapsed or 0)}
    if (state.tokens or 0) > 0 then
        table.insert(parts, string.format("↓ %s tokens", util.count(state.tokens)))
    end
    table.insert(parts, "esc to interrupt")
    return theme.styled("spinner", frame .. " " .. word .. "…")
        .. theme.styled("dim", string.format(" (%s)", table.concat(parts, " · ")))
end

-- get the number of the working words, the caller cycles through them
function wordcount()
    return #WORDS
end

-- render the hint line below the input box
--
-- @param state {mode = "default", usage = {..}, showtokens = true}
--
function hint(state)
    local badges = {
        default     = {style = "hint",         text = "⏵ default mode"},
        acceptedits = {style = "badge.accept", text = "⏵⏵ accept edits on"},
        plan        = {style = "badge.plan",   text = "⏸ plan mode on"},
        bypass      = {style = "badge.bypass", text = "⏵⏵ bypass permissions"}
    }
    local badge = badges[state.mode] or badges.default
    local parts = {theme.styled(badge.style, "  " .. badge.text) .. theme.styled("hint", " (shift+tab to cycle)")}
    table.insert(parts, theme.styled("hint", "/ for commands"))
    table.insert(parts, theme.styled("hint", "@ for files"))

    if state.loop then
        table.insert(parts, theme.styled("badge.plan", state.loop))
    end

    local usage = state.usage or {}
    if state.showtokens ~= false and (usage.input or 0) > 0 then
        local rate = nil
        if (usage.cachehit or 0) + (usage.cachemiss or 0) > 0 then
            rate = usage.cachehit / (usage.cachehit + usage.cachemiss)
        end
        table.insert(parts, theme.styled("hint", string.format("%s↑ %s↓%s",
            util.count(usage.input), util.count(usage.output),
            rate and string.format(" · cache %.0f%%", rate * 100) or "")))
    end
    return table.concat(parts, theme.styled("hint", " · "))
end
