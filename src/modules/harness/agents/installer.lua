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
-- @file        installer.lua
--

--
-- installing packs of subagents
--
-- the same machinery the skills use, @see harness.packs.packs: a pack is a
-- directory of markdown fetched from a git repository or a local directory,
-- kept in `~/.xmake/harness/agents`, never bundled with the harness.
--
-- what is specific to subagents is only where a pack keeps them and what counts
-- as one, which is the kind below and `harness.agents.bundle`.
--

-- imports
import("harness.packs.packs")
import("harness.agents.bundle")

-- what a pack of subagents is
local KIND = {
    name = "agents",
    label = "subagent",
    sources = "agentsources",
    roots = function (packdir) return bundle.roots(packdir) end,
    files = function (packdir) return bundle.agentfiles(packdir) end,
    describe = function (packdir) return bundle.describe(packdir) end
}

-- the kind, for whatever wants to ask the generic machinery directly
function kind()
    return KIND
end

function dir()
    return packs.dir(KIND)
end

function sources(harness)
    return packs.sources(KIND, harness)
end

function register(harness, source)
    return packs.register(KIND, harness, source)
end

function resolve(harness, spec)
    return packs.resolve(KIND, harness, spec)
end

function installed()
    local results = packs.installed(KIND)
    for _, one in ipairs(results) do
        -- the field everything else reads it by
        one.agents = one.count
    end
    return results
end

function packdirs()
    return packs.packdirs(KIND)
end

function isinstalled(name)
    return packs.isinstalled(KIND, name)
end

function install(source, opt)
    return packs.install(KIND, source, opt)
end

function fetch(source, opt)
    return packs.fetch(KIND, source, opt)
end

function remove(name)
    return packs.remove(KIND, name)
end

-- the directories an installed pack keeps its agents in
function agentsdirs(packdir)
    return bundle.roots(packdir)
end

-- load every installed pack into the registry
--
-- it runs after the plain directories, exactly as the skills do, so a pack
-- never takes a name a user's own agent already has
--
function loadall(harness)
    local registry = harness:service("agents")
    if not registry then
        return 0
    end
    local count = 0
    for _, pack in ipairs(installed()) do
        for _, root in ipairs(agentsdirs(pack.dir)) do
            registry:adddir(root, "pack:" .. pack.name)
        end
        count = count + pack.count
    end
    return count
end
