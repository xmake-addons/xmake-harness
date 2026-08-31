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
        maxfruitless = settings.maxfruitless or 4,
        signature = nil,
        repeats = 0,
        errors = 0,
        fruitless = 0
    }
end

-- is this round of tool calls the same as the previous one?
--
-- an iterative fix — edit, build, edit, build — is not stuck: its rounds differ.
-- only the identical round repeated back to back counts
--
-- @return  {code = "repeated-tool-calls", text = ".."}, or nil to go on
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
    return {
        code = "repeated-tool-calls",
        text = string.format("the same tool calls were repeated %d times, this is not getting anywhere.\n"
            .. "stop retrying: tell the user what blocks you, or try something different.", guards.repeats + 1)
    }
end

-- is it looking for something which is not there?
--
-- the repeat guard catches the same call made twice and nothing else, and the
-- shape this actually takes is a search which finds nothing, tried again with
-- a slightly different pattern, and again — every round different, so the
-- signature never matches, and the model goes on rephrasing a question the
-- project has no answer to.
--
-- what stops it is not another pattern, it is being told that the answer is
-- empty and to look somewhere else
--
-- @param results  the tool results of this step
--
-- @return  {code = "nothing-found", text = ".."}, or nil to go on
--
local LOOKING = {glob_files = true, search_text = true, list_dir = true,
                 grep = true, find_files = true}

function fruitless(guards, results)
    local looked = 0
    local found = 0
    for _, result in ipairs(results or {}) do
        local name = result.name or (result.call or {}).name
        if LOOKING[name] then
            looked = looked + 1
            local output = tostring(result.output or "")
            -- a search which found something says so by saying anything else
            if not result.iserror and output:trim() ~= ""
               and not output:startswith("(no ") and not output:startswith("(nothing") then
                found = found + 1
            end
        end
    end
    if looked == 0 then
        return nil
    end
    if found > 0 then
        guards.fruitless = 0
        return nil
    end
    guards.fruitless = guards.fruitless + 1
    if guards.fruitless < guards.maxfruitless then
        return nil
    end
    guards.fruitless = 0
    return {
        code = "nothing-found",
        text = string.format("%d searches in a row found nothing.\n"
            .. "the answer is that it is not there. stop rephrasing the pattern: list the "
            .. "directory to see what is actually in it, or tell the user what you cannot find.",
            guards.maxfruitless)
    }
end

-- did this step get anything done?
--
-- @param count     how many tools ran
-- @param failures  how many of them failed
--
-- @return  {code = "all-tools-failed", text = ".."}, or nil to go on
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
    return {
        code = "all-tools-failed",
        text = string.format("every tool call failed %d times in a row.\n"
            .. "stop retrying: tell the user what fails and what you need from them.", guards.errors)
    }
end
