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
-- @file        script.lua
--

--
-- an agent which is more than a prompt
--
-- most subagents are a markdown file and should stay one: a prompt, a list of
-- tools, and nothing to go wrong. some are not — an agent whose first act is
-- always the same command is an agent which should arrive knowing the answer,
-- and one whose tools depend on what is in the directory cannot list them in
-- frontmatter.
--
-- so a bundle may put an `agent.lua` beside its `AGENT.md`, and export any of:
--
--   define(context)            -- change the definition: tools, model, maxsteps
--   prompt(context)            -- text appended to the system prompt
--   before(context)            -- text appended to the task, e.g. what it found
--   after(context, result)     -- the last word on the report
--
-- every one of them is optional, every one runs inside a `try`, and a script
-- which raises is reported and then ignored: an agent which cannot be improved
-- is better than a harness which cannot run one.
--
-- `context` carries `{harness, agent, prompt, cwd, progress}` — the progress
-- channel included, so a script which does something slow can say so and have
-- it appear in whatever is watching, @see harness.core.progress
--

-- imports
import("harness.core.progress")

-- load the script of an agent, if it has one
--
-- @param definition   the agent, @see harness.agents.registry
-- @return             the module, or nil
--
function load(definition)
    if not definition or not definition.dir then
        return nil
    end
    if definition._script ~= nil then
        return definition._script or nil
    end
    local filepath = path.join(definition.dir, "agent.lua")
    if not os.isfile(filepath) then
        definition._script = false
        return nil
    end
    local module = import("agent", {rootdir = definition.dir, anonymous = true, try = true})
    definition._script = module or false
    return module or nil
end

-- does this agent have one?
function has(definition)
    return load(definition) ~= nil
end

-- run one of its hooks
--
-- @return  what the hook returned, or nil and the errors
--
function call(definition, name, ...)
    local module = load(definition)
    if not module or type(module[name]) ~= "function" then
        return nil
    end
    local result, errors
    local args = {...}
    try {
        function ()
            result = module[name](table.unpack(args))
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if errors then
        return nil, string.format("the agent(%s) script failed in `%s`: %s",
                                  definition.name, name, tostring(errors))
    end
    return result
end

-- the definition, after the script has had its say
--
-- it may change the tools, the model, the step budget — the things frontmatter
-- states, when they depend on something frontmatter cannot see
--
-- @return  the definition to use, and whatever went wrong
--
function define(definition, context)
    local changed, errors = call(definition, "define", context)
    if type(changed) ~= "table" then
        return definition, errors
    end
    local result = table.clone(definition)
    for key, value in pairs(changed) do
        -- the name is what it was resolved by and is not the script's to change
        if key ~= "name" and key ~= "dir" and key ~= "filepath" then
            result[key] = value
        end
    end
    return result, errors
end

-- what the script adds to the system prompt
function prompt(definition, context)
    local text, errors = call(definition, "prompt", context)
    return type(text) == "string" and text or nil, errors
end

-- what the script has already found out, added to the task
--
-- this is the useful one: an agent whose first three steps are always the same
-- commands can run them here instead, and start with the answers
--
function before(definition, context)
    progress.stage(context and context.progress, "preparing")
    local text, errors = call(definition, "before", context)
    return type(text) == "string" and text or nil, errors
end

-- the last word on the report
function after(definition, context, result)
    local text, errors = call(definition, "after", context, result)
    return type(text) == "string" and text or nil, errors
end
