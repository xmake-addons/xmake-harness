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
-- @file        skills.lua
--

--
-- does the listing still send the model to the right skill
--
-- the listing was cut to a fifth of its size: what a skill says it is for is
-- now its first clause and no more, @see harness.prompt.system._trigger. that
-- saves eight kilobytes of every request and it is worth exactly nothing if a
-- model which used to find `xmake-cross-compilation` now does not.
--
-- so this is the eval to run before and after touching how skills are listed,
-- and what to compare is the rate.
--

-- imports
import("support")

-- what should send the model to which skill
local ROUTES = {
    {ask = "how do I cross-compile this project for android?",     skill = "xmake-cross-compilation"},
    {ask = "add zlib as a dependency of this project",             skill = "xmake-packages"},
    {ask = "start a new c++ project here from a template",         skill = "xmake-templates"},
    {ask = "the build is slow, what can I do about it?",           skill = "xmake-build-optimization"},
    {ask = "how do I add unit tests to this xmake project?",       skill = "xmake-tests"}
}

-- ask one question and see which skill it opened
--
-- the model is told to look before it acts, because what is measured here is
-- the routing and not its willingness to answer from memory
--
function _routed(route)
    local run = support.ask({
        prompt = route.ask .. "\n\n(load the skill which covers this first, then answer in one line)",
        files = {["xmake.lua"] = "target(\"demo\")\n    set_kind(\"binary\")\n    add_files(\"src/*.c\")\n",
                 ["src/main.c"] = "int main(void) { return 0; }\n"}
    })
    local call = support.called(run, "use_skill")
    return call and (call.arguments or {}).name or nil
end

-- every question reaches the skill which answers it
--
-- one eval and not five, because what is being measured is the listing as a
-- whole: a change which fixes one route and breaks another has not helped
--
function eval_the_listing_routes_to_the_right_skill()
    local missed = {}
    for _, route in ipairs(ROUTES) do
        local opened = _routed(route)
        if opened ~= route.skill then
            table.insert(missed, string.format("\"%s\" opened %s and not %s",
                                               route.ask, opened or "nothing", route.skill))
        end
    end
    if #missed > 0 then
        support.fail("%d of %d routed elsewhere: %s", #missed, #ROUTES,
                     table.concat(missed, "; "))
    end
end
