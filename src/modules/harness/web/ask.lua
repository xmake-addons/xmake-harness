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
-- @file        ask.lua
--

--
-- the questions a conversation puts to the browser
--
-- two kinds ask the same way and wait the same way: a tool call which needs a
-- confirmation, @see harness.tools.pipeline, and a command which needs an
-- answer, @see harness.web.commands. what they have in common is the waiting,
-- and that is what lives here.
--
-- the turn runs in a coroutine of its own, so waiting for a click costs nothing
-- but that coroutine. nothing polls: the answer arrives on another connection
-- and posts a semaphore, and the turn carries on from exactly where it stopped.
--

-- imports
import("core.base.scheduler")
import("harness.ui.dialog")
import("harness.web.events")
import("harness.web.session", {alias = "websession"})

-- ask the browser, and wait there until it answers
--
-- the turn runs in a coroutine of its own, so waiting for a click costs nothing
-- but that coroutine: it is suspended, and the answer resumes it exactly where
-- it stopped. nothing polls and nothing else in the process is held up — the
-- other tabs keep receiving events while this one has a sheet open.
--
function confirm(state, request)
    local value = await(state, function (id)
        return events.ask(id, request)
    end)
    if value == "always" then
        local info = dialog.confirminfo(request.tool or {}, request.args or {})
        return {answer = "always", rule = info.rule}
    elseif value == "allow" then
        return "allow"
    end
    return "the user rejected this tool call, ask them how to continue instead of retrying."
end

-- put a question to the browser and wait there for the answer
--
-- a semaphore and not `co_suspend`/`co_resume`: waiting on one costs nothing
-- until it is posted, and posting it is something another coroutine may do —
-- which is the whole point, because the answer arrives on a different
-- connection than the one the turn is running on
--
-- @param build   build(id) -> the event payload
-- @return        what the browser answered, as a string
--
function await(state, build)
    state.asked = state.asked + 1
    local id = tostring(state.asked)
    local waiting = {semaphore = scheduler.co_semaphore("harness/web/ask/" .. id, 0)}
    state.pending[id] = waiting

    websession.push(state, "ask", build(id))
    waiting.semaphore:wait(-1)
    state.pending[id] = nil
    websession.push(state, "ask.done", {id = id})
    return waiting.answer
end

-- a question from a command, rather than from a tool call
--
-- the options of a command carry lua values — a session, a boolean, a table —
-- and none of those cross to a browser and back. so what crosses is the number
-- of the option, and the value it stands for is looked up here
--
function question(state, request)
    local options = request.options or {{text = "Yes", value = true},
                                        {text = "No", value = false}}
    local answer = await(state, function (id)
        return events.question(id, request, options)
    end)
    local chosen = options[tonumber(answer) or 0]
    return chosen and chosen.value or nil
end

-- somebody clicked
--
-- @return  true, or false when there is nothing waiting for this answer
--
function answer(state, id, value)
    local waiting = state.pending[tostring(id or "")]
    if not waiting then
        return false
    end
    state.pending[tostring(id)] = nil
    waiting.answer = tostring(value or "deny")
    waiting.semaphore:post(1)
    return true
end
