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
-- @file        looper.lua
--

--
-- the armed `/loop`, and what makes it tick
--
-- the terminal fires one from its idle loop, between keystrokes; a browser has
-- no idle loop of its own, so one coroutine waits here for the next iteration
-- to be due. a `/loop` which armed and then never ran would be worse than no
-- `/loop` at all.
--
-- nothing is polled. there are three reasons to be waiting and each has its own
-- way to sleep through it, @see arm().
--

-- imports
import("core.base.scheduler")
import("harness.core.loop")
import("harness.web.session", {alias = "websession"})

-- the armed `/loop`, and what makes it tick
--
-- the terminal fires it from its idle loop, between keystrokes; a browser has
-- no idle loop of its own, so one coroutine waits here for the next iteration
-- to be due. it waits on a semaphore rather than counting the seconds down:
-- stopping the loop posts it, so `/loop stop` is noticed at once instead of
-- whenever the next tick happened to come round
--
-- @param runturn  run one iteration and return its result, @see harness.web.turns
--
--                 it is handed in rather than imported: a turn pushes events
--                 through the conversation and the conversation is what arms
--                 this, so importing it back would be a circle
--
function arm(state, runturn)
    if state.ticking then
        return
    end
    state.ticking = true
    state.loopwake = scheduler.co_semaphore("harness/web/loop", 0)

    scheduler.co_start(function ()
        while state.loop do
            local armed = state.loop

            -- three reasons to be here, and a way to sleep through each of
            -- them: a turn is running (the end of it posts the semaphore), the
            -- next iteration is not due yet (the time it is due), or it is due
            -- now. never a spin: a coroutine which never yields is a process
            -- which never does anything else
            if state.working then
                state.loopwake:wait(30000)
            else
                local remaining = loop.remaining(armed, os.time())
                if remaining > 0 then
                    state.loopwake:wait(math.floor(remaining * 1000))
                end
            end

            if state.loop ~= armed then
                break
            end
            if loop.due(armed, os.time()) and not state.working then
                local result = runturn(state, loop.begin(armed))

                -- the loop may have been stopped while the iteration ran, and
                -- what stopped it decided already
                if state.loop == armed then
                    local stopped = loop.finished(armed, os.time(), result)
                    if stopped then
                        unarm(state)
                        websession.push(state, "notice", {text = stopped})
                    end
                    websession.push(state, "loop", websession.loopstate(state))
                end
            end
        end
        state.ticking = nil
    end)
end

-- take the loop away
function unarm(state)
    state.loop = nil
    state.harness:service("loop", nil)
    try { function () state.harness:service("tools"):remove("loop_stop") end }
    if state.loopwake then
        state.loopwake:post(1)
    end
end
