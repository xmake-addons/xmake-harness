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
-- @file        submit_plan.lua
--

--
-- the way out of the plan mode
--
-- the plan mode says no to everything which writes, which leaves the agent with
-- nowhere to go when it has finished planning: it writes the plan into the
-- conversation and carries on reading files, because nothing ever told it the
-- planning was over.
--
-- this is what tells it. the agent submits the plan, the person answers, and
-- the answer is what ends the mode — approving a plan is the same gesture as
-- accepting an edit, so it goes through the same dialog, @see harness.ui.dialog
--

-- imports
import("harness.core.plan")

-- define the tool
function define()
    return {
        name = "submit_plan",
        group = "core",
        permission = "none",
        description = [[Present the finished plan to the user and ask to carry it out.

Call it only in the plan mode, and only once the plan is complete: it is what
ends the planning. Write the plan as markdown — a title, then the steps as a
list, in the order you would do them. Say what you would change and where, not
how you investigated.

If the user approves, the plan mode ends and you carry the plan out. If they do
not, you are still planning: read what they say and revise it.]],
        parameters = {
            type = "object",
            properties = {
                plan = {type = "string",
                        description = "The plan, as markdown: a title and the steps."}
            },
            required = {"plan"}
        }
    }
end

-- run the tool
function run(context, args)
    if (context.mode or "default") ~= "plan" then
        return {output = "the plan mode is not active, so there is nothing to approve: "
                      .. "just do the work.", iserror = true}
    end
    if not (context.ui and context.ui.confirm) then
        return {output = "there is nobody to show the plan to, so it cannot be approved.",
                iserror = true}
    end

    local state = {harness = context.harness, session = context.session}
    local one = plan.submit(state, args.plan)
    local answer = context.ui.confirm({
        tool = {name = "submit_plan", group = "core", permission = "none"},
        args = args,
        plan = one
    })

    -- "always" is the same yes with the edits accepted as they go: the person
    -- who has just read the whole plan is not the person who wants to be asked
    -- about each file in it
    local approved = answer == "allow" or answer == true
        or (type(answer) == "table" and answer.answer == "always")
    plan.decide(state, one, approved and "approved" or "rejected")
    if not approved then
        return {output = "the user did not approve the plan. you are still in the plan mode: "
                      .. "ask what they want changed, and do not start any of it.",
                display = {summary = "the plan was not approved"}}
    end

    _leaveplan(context, type(answer) == "table" and answer.answer == "always")
    return {output = "the user approved the plan. the plan mode is over: carry it out, "
                  .. "step by step, in the order you wrote.",
            display = {title = one.title, summary = plan.describe(one)}}
end

-- the plan mode is over
--
-- the mode lives in the config and the front ends are told about it, which is
-- exactly what accepting all the edits of a session does, @see
-- harness.tools.pipeline
--
function _leaveplan(context, acceptedits)
    context.config.permission = context.config.permission or {}
    context.config.permission.mode = acceptedits and "acceptedits" or "default"
    context.mode = context.config.permission.mode
    if context.ui.on_mode then
        context.ui.on_mode(context.mode)
    end
end
