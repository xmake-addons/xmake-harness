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
-- @file        use_skill.lua
--

-- imports
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "use_skill",
        group = "core",
        permission = "read",
        description = [[Load a skill: the detailed instructions of a specific task.

The available skills are listed in the system prompt. Load a skill before doing
the work it covers, its content is authoritative and overrides your assumptions.]],
        parameters = {
            type = "object",
            properties = {
                name = {type = "string", description = "The skill name, e.g. `xmake-packages`."}
            },
            required = {"name"}
        }
    }
end

-- run the tool
function run(context, args)
    local skills = context.harness:service("skills")
    if not skills then
        raise("no skill registry is available!")
    end
    local skill = skills:get(args.name)
    if not skill then
        local names = {}
        for _, item in ipairs(skills:all()) do
            table.insert(names, item.name)
        end
        raise("the skill(%s) does not exist! the available skills: %s", args.name, table.concat(names, ", "))
    end
    local content = skills:content(skill)
    context.harness:emit("skill/loaded", skill)
    return {
        output = string.format("# Skill: %s\n\n%s", skill.name, content),
        display = {
            title = "Skill",
            subject = skill.name,
            summary = skill.description and skill.description:sub(1, 80) or ""
        }
    }
end
