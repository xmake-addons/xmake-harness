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
-- @file        guards.lua
--

--
-- the loop guards
--
-- a model can get stuck in two ways, and neither resolves itself:
--
--   it repeats the very same round of tool calls, waiting for a different
--   answer from the same question
--
--   every tool it tries fails, and it keeps trying variations of the same
--   broken idea
--
-- both burn tokens and the user's patience, so the turn stops and says which of
-- the two happened. the wording goes to the model as well, so a session which
-- continues afterwards knows what it must not do again.
--

-- create the guards of one turn
function new(config)
    local settings = (config or {}).agent or {}
    return {
        maxrepeats = settings.maxrepeats or 3,
        maxerrors = settings.maxerrors or 3,
        signature = nil,
        repeats = 0,
        errors = 0
    }
end

-- is this round of tool calls the same as the previous one?
--
-- an iterative fix — edit, build, edit, build — is not stuck: its rounds differ.
-- only the identical round repeated back to back counts
--
-- @return  the reason to stop, or nil to go on
--
function repeated(guards, toolcalls)
    local parts = {}
    for _, call in ipairs(toolcalls or {}) do
        table.insert(parts, string.format("%s:%s", call.name, call.arguments_text or ""))
    end
    table.sort(parts)
    local signature = table.concat(parts, "|")

    guards.repeats = (signature == guards.signature) and (guards.repeats + 1) or 0
    guards.signature = signature
    if guards.repeats + 1 < guards.maxrepeats then
        return nil
    end
    return string.format("the same tool calls were repeated %d times, this is not getting anywhere.\n"
        .. "stop retrying: tell the user what blocks you, or try something different.", guards.repeats + 1)
end

-- did this step get anything done?
--
-- @param count     how many tools ran
-- @param failures  how many of them failed
--
-- @return  the reason to stop, or nil to go on
--
function progressing(guards, count, failures)
    if count == 0 or failures < count then
        guards.errors = 0
        return nil
    end
    guards.errors = guards.errors + 1
    if guards.errors < guards.maxerrors then
        return nil
    end
    return string.format("every tool call failed %d times in a row.\n"
        .. "stop retrying: tell the user what fails and what you need from them.", guards.errors)
end
