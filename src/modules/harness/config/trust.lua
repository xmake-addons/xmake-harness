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
-- @file        trust.lua
--

--
-- do we run what this directory tells us to
--
-- a project can carry instructions for the agent and code for the harness: an
-- `AGENTS.md` goes into the system prompt, `.xmake-harness/skills` are loaded on
-- demand, `.xmake-harness/plugins` is lua which runs in process. all of it is
-- useful and all of it belongs to whoever wrote the repository.
--
-- so cloning something and running `xmake ai` inside it used to be enough to
-- hand a stranger the system prompt and a lua interpreter. the fix is not to
-- drop the feature — a project which describes itself to the agent is the whole
-- point — it is to ask once, and to ask only where there is something to ask
-- about: a directory with none of these files never sees a prompt.
--

-- imports
import("core.base.json")
import("harness.config.config")

-- the project resources which are only read once the project is trusted
local RESOURCES = {
    {kind = "instructions", paths = {"XMAKE.md", "AGENTS.md", "CLAUDE.md",
                                     ".xmake-harness/HARNESS.md"}},
    {kind = "configuration", paths = {".xmake-harness/config.json"}},
    {kind = "skills",        paths = {".xmake-harness/skills"}},
    {kind = "subagents",     paths = {".xmake-harness/agents"}},
    {kind = "commands",      paths = {".xmake-harness/commands"}},
    {kind = "plugins",       paths = {".xmake-harness/plugins"}}
}

-- where the answers are kept
function storefile()
    return path.join(config.homedir(), "trust.json")
end

-- what this directory would have us read, if we let it
--
-- @return  {"instructions", "plugins"}, and the files they were found in
--
function requires(rootdir)
    rootdir = rootdir or os.curdir()
    local kinds = {}
    local found = {}
    for _, resource in ipairs(RESOURCES) do
        for _, name in ipairs(resource.paths) do
            local filepath = path.join(rootdir, name)
            if os.isfile(filepath) or (os.isdir(filepath) and not os.emptydir(filepath)) then
                if not table.contains(kinds, resource.kind) then
                    table.insert(kinds, resource.kind)
                end
                table.insert(found, name)
                break
            end
        end
    end
    return kinds, found
end

-- what was decided about this directory before
--
-- @return  true, false, or nil when nobody has been asked
--
function remembered(rootdir)
    local store = _load()
    local answer = store[_key(rootdir)]
    if type(answer) == "boolean" then
        return answer
    end
    return nil
end

-- keep the answer for the next time
function remember(rootdir, trusted)
    local store = _load()
    store[_key(rootdir)] = trusted and true or false
    _save(store)
    return trusted
end

-- forget it again, e.g. `xmake ai --forget-trust`
function forget(rootdir)
    local store = _load()
    store[_key(rootdir)] = nil
    _save(store)
end

-- everything which has been decided, for `/trust`
function all()
    return _load()
end

-- resolve whether this run trusts the project
--
-- @param opt   {rootdir = "..", override = true|false|nil, ask = function (kinds, found) .. end}
-- @return      true or false, and true when somebody was asked
--
function resolve(opt)
    opt = opt or {}
    local rootdir = opt.rootdir or os.curdir()

    -- an explicit answer from the command line settles it without asking and
    -- without being written down: `--trust` is for a single run in a script
    if opt.override ~= nil then
        return opt.override, false
    end

    -- nothing here asks for trust, so there is nothing to ask about
    local kinds, found = requires(rootdir)
    if #kinds == 0 then
        return true, false
    end

    local answer = remembered(rootdir)
    if answer ~= nil then
        return answer, false
    end

    -- nobody to ask, e.g. a pipe or the ci: the safe answer is the quiet one
    if not opt.ask then
        return false, false
    end
    return opt.ask(kinds, found) and true or false, true
end

-- the key of a directory in the store
function _key(rootdir)
    return path.absolute(rootdir or os.curdir())
end

-- read the store
function _load()
    local filepath = storefile()
    if not os.isfile(filepath) then
        return {}
    end
    local store = try {function () return json.loadfile(filepath) end}
    return type(store) == "table" and store or {}
end

-- write it back
function _save(store)
    local filepath = storefile()
    os.mkdir(path.directory(filepath))
    try {function () json.savefile(filepath, store) end}
end
