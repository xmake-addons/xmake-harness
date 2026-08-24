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
-- @file        updates.lua
--

--
-- the upstream checks
--
-- the skill packs and the documentation are maintained in their own
-- repositories: they move on their own, and a copy which was fetched two months
-- ago keeps answering with what was true two months ago. nobody notices,
-- because nothing ever says so.
--
-- so we look, and only look. asking the remote for one hash is a single round
-- trip and writes nothing; whether to take the update stays the user's call,
-- which is the same rule the fetch itself follows.
--
-- the looking happens in the background and the telling happens at the next
-- start, from the cache. that trade is deliberate: a check costs a couple of
-- seconds against the network, and making somebody wait that long to be told
-- about a skill pack — every single launch — is a worse deal than hearing about
-- it one session later.
--

-- imports
import("core.base.json")
import("core.base.semver")
import("core.base.scheduler")
import("core.package.addon")
import("core.package.repository")
import("harness.util.gitpack")
import("harness.config.config")

-- how long a check is good for
local INTERVAL = 24 * 3600

-- where the answers are kept
function cachefile()
    return path.join(config.homedir(), "updates.json")
end

-- read what we know
function load()
    local filepath = cachefile()
    if not os.isfile(filepath) then
        return {}
    end
    local data = try { function () return json.loadfile(filepath) end }
    return type(data) == "table" and data or {}
end

-- write it back
function save(state)
    local filepath = cachefile()
    os.mkdir(path.directory(filepath))
    try { function () json.savefile(filepath, state) return true end }
    return state
end

-- what is known to be out of date, without touching the network
--
-- @return  {{name = "xmake-skills", dir = "..", command = "/skills update xmake-skills"}}
--
function stale(harness)
    local state = load()
    local results = {}
    for _, entry in ipairs(_watched(harness)) do
        local known = state[entry.name]
        if known and known.behind and os.isdir(entry.dir) then
            table.insert(results, entry)
        end
    end
    return results
end

-- forget what we knew about one of them, e.g. right after it was updated
function clear(name)
    local state = load()
    state[name] = nil
    return save(state)
end

-- ask the remotes, in the background
--
-- it runs in its own coroutine so the session never waits for it: the answer is
-- for the next start, not for this one
--
function refresh(harness, opt)
    opt = opt or {}
    if (harness:config().updates or {}).check == false then
        return
    end
    scheduler.co_start(function ()
        try { function () _refresh(harness, opt) end }
    end)
end

-- the checking itself
function _refresh(harness, opt)
    local state = load()
    local interval = opt.interval or (harness:config().updates or {}).interval or INTERVAL
    local changed = false
    for _, entry in ipairs(_watched(harness)) do
        local known = state[entry.name] or {}
        if os.time() - (known.checked or 0) >= interval then
            local behind = gitpack.behind(entry.dir, {branch = entry.branch})
            -- nil means we could not tell — no git, no network, no remote — and
            -- guessing either way would be worse than saying nothing
            if behind ~= nil then
                state[entry.name] = {checked = os.time(), behind = behind}
                changed = true
            end
        end
    end
    if changed then
        save(state)
    end
end

-- everything worth watching
--
-- the packs are found on disk, and a plugin adds whatever else it maintains the
-- same way, e.g. the xmake documentation clone
--
function _watched(harness)
    local results = {}
    local installer = import("harness.skills.installer", {anonymous = true})
    for _, pack in ipairs(installer.installed()) do
        if pack.isgit then
            table.insert(results, {name = pack.name, dir = pack.dir,
                                   command = "/skills update " .. pack.name})
        end
    end
    for _, entry in ipairs(harness:service("updatesources") or {}) do
        if os.isdir(entry.dir) then
            table.insert(results, entry)
        end
    end
    return results
end

-- is there a newer release of the harness itself?
--
-- the addon is published in the xmake repositories, so both halves of the
-- question are already on disk: the installed version is in the addon registry,
-- and the released ones are the `add_versions` of its definition in the
-- repository clone. no network, nothing to cache, nothing to wait for.
--
-- it only tells. installing means replacing the code which is running, and that
-- is a decision to be taken by the person whose machine it is, in a terminal
-- where they can see what happens — never in the background of a session which
-- was started to do something else entirely
--
-- @return  {name = "xmake-harness", installed = "v1.0.0", latest = "v1.0.1",
--           command = "xmake addon -i xmake-harness"}, or nil
--
function selfupdate()
    local name, installed = _installed()
    if not name then
        return nil
    end
    local latest = _released(name)
    if not latest or not _newer(latest, installed) then
        return nil
    end
    return {name = name, installed = installed, latest = latest,
            command = string.format("xmake addon -i %s", name)}
end

-- which addon are we, and which version of it is running
function _installed()
    local name = try { function () return addon.owner(os.scriptdir()) end }
    if not name then
        return nil
    end
    local info = try { function () return addon.addons()[addon.dirname(name)] end }
    return name, info and info.version or nil
end

-- the newest version the repositories offer
--
-- the definition is read rather than interpreted: `add_versions` is a line, and
-- running somebody's package script to learn a version number would be a much
-- larger promise than this feature is making
--
function _released(name)
    local latest = nil
    for _, filepath in ipairs(_definitions(name)) do
        for version in (io.readfile(filepath) or ""):gmatch("add_versions%s*%(%s*[\"']([^\"']+)[\"']") do
            if _newer(version, latest) then
                latest = version
            end
        end
    end
    return latest
end

-- where the repositories keep this addon's definition
function _definitions(name)
    local results = {}
    local dirname = addon.dirname(name)
    for _, isglobal in ipairs({true, false}) do
        local dir = try { function () return repository.directory(isglobal) end }
        for _, repodir in ipairs(dir and os.dirs(path.join(dir, "*")) or {}) do
            local filepath = path.join(repodir, "addons", dirname:sub(1, 1), dirname, "xmake.lua")
            if os.isfile(filepath) then
                table.insert(results, filepath)
            end
        end
    end
    return results
end

-- is the first version newer than the second?
function _newer(version, than)
    if not version then
        return false
    elseif not than then
        return true
    end
    -- a version which semver cannot read is compared as text: it is a notice,
    -- not a resolver, and being wrong about an odd tag costs a wrong hint
    local result = try { function () return semver.compare(version, than) end }
    if result ~= nil then
        return result > 0
    end
    return version > than
end

-- a plugin registers something else it keeps up to date
function watch(harness, entry)
    assert(entry and entry.name and entry.dir and entry.command, "harness: invalid update source!")
    local results = harness:service("updatesources") or {}
    table.insert(results, entry)
    harness:service("updatesources", results)
    return entry
end
