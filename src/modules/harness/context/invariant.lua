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
-- @file        invariant.lua
--

--
-- what must be true of the messages we send
--
-- the log is the truth, but the model never sees the log: it sees a projection
-- which has been pruned of stale tool output, compacted into a summary, and —
-- when even that does not fit — had whole turns dropped off the front. four
-- transformations, each of which can quietly produce a conversation which is
-- not a conversation.
--
-- the failures are not loud. a tool result whose call was dropped is rejected
-- by the provider with a message about an id nobody recognises; an assistant
-- turn whose results were dropped makes the model answer about work it cannot
-- see. both read as "the model got worse" rather than as "we sent nonsense",
-- which is the worst kind of bug to own.
--
-- so the projection is checked before it goes out. it costs one pass over a few
-- dozen messages, against a request which is about to take seconds
--

-- check the messages which are about to be sent
--
-- @return  the violations, e.g. {{code = "orphan-tool-result", text = ".."}}
--
function check(messages)
    local violations = {}
    local pending = {}
    local announced = {}

    for index, message in ipairs(messages or {}) do
        if message.role == "assistant" then
            _closeturn(violations, pending, index)
            for _, call in ipairs(message.toolcalls or {}) do
                if call.id then
                    pending[call.id] = {index = index, name = call.name}
                    announced[call.id] = true
                end
            end
        elseif message.role == "tool" then
            local id = message.toolcallid
            if not id then
                _add(violations, "tool-result-without-id",
                    string.format("the tool result at %d says which call it answers nowhere", index))
            elseif not announced[id] then
                -- the assistant turn which asked for this was dropped, and the
                -- provider will refuse the whole request over it
                _add(violations, "orphan-tool-result",
                    string.format("the tool result at %d answers the call(%s), which nothing asked for",
                        index, id))
            else
                pending[id] = nil
            end
        elseif message.role == "user" then
            _closeturn(violations, pending, index)
        end
    end
    _closeturn(violations, pending, #(messages or {}) + 1)
    return violations
end

-- a turn is over: every call it made should have been answered by now
--
-- the exception is the call which is still running, and that one is never in a
-- request: we assemble the next request after the results are in
--
function _closeturn(violations, pending, index)
    for id, call in pairs(pending) do
        _add(violations, "unanswered-tool-call",
            string.format("the call(%s) to `%s` at %d was never answered, but the turn moved on at %d",
                id, call.name or "?", call.index, index))
        pending[id] = nil
    end
end

-- record one violation
function _add(violations, code, text)
    table.insert(violations, {code = code, text = text})
    return violations
end

-- one line which says what is wrong, for the log and the screen
function describe(violations)
    if #violations == 0 then
        return nil
    end
    local parts = {}
    for _, violation in ipairs(violations) do
        table.insert(parts, violation.text)
    end
    return string.format("the conversation sent to the model is not well formed (%d problem%s):\n  %s",
        #violations, #violations == 1 and "" or "s", table.concat(parts, "\n  "))
end
