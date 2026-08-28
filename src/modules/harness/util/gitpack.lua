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
-- @file        gitpack.lua
--

--
-- the git packs
--
-- the harness fetches a few things which are maintained elsewhere: the skill
-- packs and the xmake documentation. they are never bundled, they are cloned
-- into the harness home when the user asks for them, and updated with a pull.
--

-- imports
import("utils.archive")
import("lib.detect.find_tool")
import("harness.shell.exec")
import("harness.shell.jobs")

-- how long a clone or a pull may take before it is stopped
local TIMEOUT = 600000

-- and how long we wait just to ask whether there is an update
local ASKTIMEOUT = 20000

-- install or update a pack
--
-- @param opt   the options
--              - url       the git url
--              - dir       where it goes
--              - branch    the branch, optional
--              - localdir  a local directory to link instead of cloning
--              - onprogress a function which reports what is happening
--
-- @return      true, or false and the errors
--
function install(opt)
    opt = opt or {}
    local notify = opt.onprogress or function () end
    if opt.archive then
        return _extract(opt, notify)
    end
    if opt.localdir then
        return _link(opt, notify)
    end
    return _clone(opt, notify)
end

-- unpack an archive, e.g. a skill bundle downloaded from a release page
--
-- an archive which holds a single directory is unwrapped: `mypack.zip` almost
-- always contains `mypack/`, and keeping that level would bury the skills one
-- deeper than the layout says
--
function _extract(opt, notify)
    notify(string.format("extracting %s ..", path.filename(opt.archive)))
    os.tryrm(opt.dir)
    os.mkdir(opt.dir)
    local ok, errors = try {
        function ()
            archive.extract(opt.archive, opt.dir)
            return true
        end,
        catch {
            function (errs)
                return false, tostring(errs)
            end
        }
    }
    if not ok then
        os.tryrm(opt.dir)
        return false, string.format("failed to extract %s: %s", opt.archive, tostring(errors))
    end
    _unwrap(opt.dir)
    return true
end

-- lift a lone top level directory out of the way
function _unwrap(dir)
    local entries = os.filedirs(path.join(dir, "*"))
    if #entries ~= 1 or not os.isdir(entries[1]) then
        return
    end
    local inner = entries[1]
    for _, entry in ipairs(os.filedirs(path.join(inner, "*"))) do
        os.mv(entry, path.join(dir, path.filename(entry)))
    end
    os.tryrm(inner)
end

-- link a local directory in place, so the user can develop it
function _link(opt, notify)
    if os.isdir(opt.dir) then
        os.tryrm(opt.dir)
    end
    os.mkdir(path.directory(opt.dir))

    -- a link keeps the edits visible at once, a copy is the fallback for the
    -- filesystems which have none
    if not try { function () os.ln(opt.localdir, opt.dir) return true end } then
        os.cp(opt.localdir, opt.dir)
    end
    notify(string.format("linked from %s", opt.localdir))
    return true
end

-- fetch it in the background instead of waiting for it
--
-- a clone is minutes of network and none of it is anybody's turn to speak. the
-- documentation and the skill packs are both things somebody asked for and then
-- went on working, so the harness goes on working too: the fetch becomes a job
-- like any other, `/jobs` lists it, and what it was for happens when it lands,
-- @see harness.shell.jobs
--
-- @param opt   {url, dir, branch, jobs = <the store>, context, label,
--               onfinish = function (ok, errors) .. end}
--
-- @return      the job, or nil and the reason it could not be started
--
function start(opt)
    local git = find_tool("git")
    if not git then
        return nil, "git is not found, it is required to fetch this."
    end

    local argv, label
    if os.isdir(path.join(opt.dir, ".git")) then
        argv = {"-C", opt.dir, "pull", "--ff-only"}
        label = string.format("updating %s", path.filename(opt.dir))
    else
        -- the directory is cleared before it is started and not after it fails,
        -- because a half-written checkout left by an earlier attempt is what
        -- makes the next one report something which has nothing to do with it
        os.tryrm(opt.dir)
        os.mkdir(path.directory(opt.dir))
        argv = {"clone", "--depth", "1", "--progress"}
        if opt.branch then
            table.insert(argv, "--branch")
            table.insert(argv, opt.branch)
        end
        table.insert(argv, opt.url)
        table.insert(argv, opt.dir)
        label = string.format("cloning %s", opt.url)
    end

    -- `command` is not passed on: it is the shell command to run when there is
    -- one, @see harness.shell.exec._argv, and a job started from a program and
    -- its arguments has none. what it is called is `label`
    local job, errors = jobs.start(opt.jobs, opt.context or {config = {}, cwd = os.curdir()}, {
        program = git.program,
        argv = argv,
        nosandbox = true,
        label = opt.label or label,
        onfinish = function (job)
            local ok = job.status == "exited" and job.exitcode == 0
            local errors
            if not ok then
                errors = (jobs.read(job).text or ""):trim()
                if errors == "" then
                    errors = string.format("git %s", jobs.status(job))
                end
            end
            if opt.onfinish then
                opt.onfinish(ok, errors, job)
            end
        end})
    if not job then
        return nil, errors
    end
    job.command = table.concat(table.join({"git"}, argv), " ")
    return job
end

-- clone or update a git repository
function _clone(opt, notify)
    local git = find_tool("git")
    if not git then
        return false, "git is not found, it is required to fetch this."
    end

    if os.isdir(path.join(opt.dir, ".git")) then
        notify(string.format("updating %s ..", path.filename(opt.dir)))
        local ok, errors = run(git, {"-C", opt.dir, "pull", "--ff-only"}, opt)
        if not ok then
            return false, string.format("failed to update %s: %s", path.filename(opt.dir), tostring(errors))
        end
        return true
    end

    notify(string.format("cloning %s ..", opt.url))
    os.tryrm(opt.dir)
    os.mkdir(path.directory(opt.dir))
    local argv = {"clone", "--depth", "1"}
    if opt.branch then
        table.insert(argv, "--branch")
        table.insert(argv, opt.branch)
    end
    -- `--progress` because git only reports it to a terminal, and this one is
    -- reading the output instead of showing it
    table.insert(argv, "--progress")
    local ok, errors = run(git, table.join(argv, {opt.url, opt.dir}), opt)
    if not ok then
        return false, string.format("failed to clone %s: %s", opt.url, tostring(errors))
    end
    return true
end

-- run one git command
--
-- it goes through the process seam like everything else which spawns something,
-- @see harness.shell.exec: a clone of a large repository over a slow line is a
-- minute of somebody's time, and `os.iorunv` spends that minute with the whole
-- terminal frozen — no spinner, no progress, and no escape, because the key
-- which would interrupt it is never read.
--
-- @param opt   {context = <the tool context>, timeout = .., envs = {..}}
-- @return      true, or false and the reason; the output comes third
--
function run(git, argv, opt)
    opt = opt or {}
    local context = opt.context or {config = {}, cwd = os.curdir()}
    local errors
    local result
    local ok = try {
        function ()
            result = exec.run(context, {
                program = git.program,
                argv = argv,
                envs = opt.envs,
                nosandbox = true,
                timeout = opt.timeout or TIMEOUT})
            return true
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if not ok then
        return false, errors
    end
    -- ctrl+b detaches a slow tool call and lets it finish on its own, which a
    -- clone cannot do: whoever asked for it is waiting to use what it fetches,
    -- and a half-written checkout adopted by nobody is worse than none. so it
    -- stops, and the next attempt starts the clone again from an empty directory
    if result.detached then
        try { function () result.proc:kill() result.proc:wait(1000) result.proc:close() end }
        os.tryrm(result.outfile)
        os.tryrm(result.errfile)
        return false, "it was stopped, run it again to start over"
    end
    if result.timedout then
        return false, string.format("it took longer than %d seconds and was stopped",
                                    (opt.timeout or TIMEOUT) // 1000)
    end
    if result.exitcode ~= 0 then
        return false, (result.output or ""):trim()
    end
    return true, nil, result.output or ""
end

-- is this checkout behind its upstream?
--
-- it asks the remote for one hash and compares it with ours. that is a single
-- round trip and nothing is written: a check is not a fetch, and the user gets
-- to decide whether to take the update
--
-- @return  true when there is something new, false when up to date, and nil
--          when we could not tell (no git, no network, no remote)
--
function behind(dir, opt)
    opt = opt or {}
    if not os.isdir(path.join(dir, ".git")) then
        return nil
    end
    local git = find_tool("git")
    if not git then
        return nil
    end
    local local_head = try { function () return os.iorunv(git.program, {"-C", dir, "rev-parse", "HEAD"}) end }
    if not local_head then
        return nil
    end

    -- one round trip to the remote, and it is the network which decides how long
    -- that takes: a check nobody asked for must never be the reason the terminal
    -- stops answering, so it is short and it can be interrupted like the rest
    local branch = opt.branch or "HEAD"
    local ok, _, remote = run(git, {"-C", dir, "ls-remote", "--quiet", "origin", branch},
        {context = opt.context, timeout = opt.timeout or ASKTIMEOUT,
         envs = {GIT_TERMINAL_PROMPT = "0", GIT_ASKPASS = "true"}})
    local remote_head = ok and remote and remote:match("^(%x+)")
    if not remote_head then
        return nil
    end
    return remote_head ~= local_head:trim()
end

-- get the remote url of a checkout
function remoteurl(dir)
    if not os.isdir(path.join(dir, ".git")) then
        return nil
    end
    local git = find_tool("git")
    if not git then
        return nil
    end
    local url = try { function () return os.iorunv(git.program, {"-C", dir, "remote", "get-url", "origin"}) end }
    return url and url:trim() or nil
end
