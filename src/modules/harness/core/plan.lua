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
-- @file        plan.lua
--

--
-- the plan the agent asks to carry out
--
-- the plan mode used to be two sentences in the system prompt and a policy
-- which said no to everything which writes. that is half of it: the agent knows
-- not to touch anything, and then it writes a plan into the conversation and
-- keeps going, because nothing ever told it the planning was over.
--
-- so the plan is a thing rather than a paragraph. the agent submits it, the
-- person approves it or does not, and approving it is what ends the plan mode —
-- one decision, recorded where the rest of the conversation is recorded, and
-- readable afterwards by anything which wants to show what was agreed.
--
-- what is here is the plan and the decision. how it is asked belongs to
-- whatever is asking, @see harness.tools.builtin.submit_plan: a terminal draws
-- a dialog and a browser draws a card, and neither of them is this module's
-- business.
--
-- @param state  {harness = .., session = ..}, whichever front end holds them
--

-- imports
import("harness.util.text")

-- how much of a plan is worth keeping
--
-- a plan is a page. one which is a chapter is one the agent wrote instead of
-- thinking, and the person approving it cannot read it either
local MAXBYTES = 64 * 1024

-- what a plan says, read off the markdown the agent wrote
--
-- the title is the first heading or the first line, and the steps are the list
-- items. nothing is required of the agent beyond writing a plan the way anybody
-- writes one: what is not there simply is not shown
--
-- @return  {title = .., steps = {..}, text = ..}
--
function parse(content)
    local plain = text.strip(tostring(content or "")):trim()
    plain = text.cut(plain, MAXBYTES)

    local title, steps = nil, {}
    for line in (plain .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = line:trim()
        local heading = trimmed:match("^#+%s+(.+)$")
        local step = trimmed:match("^[%-%*%+]%s+(.+)$") or trimmed:match("^%d+[%.%)]%s+(.+)$")
        if heading and not title then
            title = heading
        elseif step then
            table.insert(steps, (step:gsub("^%[.%]%s*", "")))
        elseif not title and trimmed ~= "" and not step then
            title = trimmed
        end
    end
    return {title = title or "the plan", steps = steps, text = plain}
end

-- the agent submitted one
--
-- it goes in the log because that is where everything else about this
-- conversation goes: it survives a restart, `/resume` brings it back, and the
-- web ui can draw what was agreed without having been running at the time
--
-- @return  the plan
--
function submit(state, content)
    local one = parse(content)
    one.at = os.time()
    if state and state.session then
        state.session:append("plan", {title = one.title, steps = one.steps, text = one.text})
        try { function () state.session:save() end }
    end
    return one
end

-- what was decided about it
--
-- @param decision   "approved" or "rejected"
--
function decide(state, one, decision)
    if state and state.session then
        state.session:append("plan.decision",
            {title = (one or {}).title, decision = decision})
        try { function () state.session:save() end }
    end
    return decision
end

-- the last plan of this conversation, and what became of it
--
-- @return  the plan with `decision` on it, or nil
--
function current(state)
    local one, decision
    for _, event in ipairs(state and state.session and state.session:events() or {}) do
        if event.kind == "plan" then
            one = {title = event.title, steps = event.steps or {}, text = event.text}
            decision = nil
        elseif event.kind == "plan.decision" and one then
            decision = event.decision
        end
    end
    if one then
        one.decision = decision
    end
    return one
end

-- one line which says what it is, for a status line or a list
function describe(one)
    if not one then
        return nil
    end
    local count = #(one.steps or {})
    if count == 0 then
        return one.title
    end
    return string.format("%s (%d step%s)", one.title, count, count == 1 and "" or "s")
end
