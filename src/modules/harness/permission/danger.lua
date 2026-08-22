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
-- @file        danger.lua
--

--
-- the command classifier
--
-- the agent runs a lot of commands, and asking for every single one is noise:
-- `ls`, `git status` and `xmake build` are what it does all day. what deserves
-- a question is the command which is hard to undo, reaches outside the project
-- or changes the machine.
--
-- so we look at what the command really is: it is split into its sub-commands,
-- and each of them is checked against the rules below. anything we cannot read
-- with confidence is treated as dangerous, never the other way around.
--

-- imports
import("harness.permission.paths")

-- the programs which are dangerous whatever their arguments are
local PROGRAMS = {
    sudo       = "it runs as another user",
    doas       = "it runs as another user",
    su         = "it switches the user",
    dd         = "it writes raw blocks",
    mkfs       = "it formats a filesystem",
    fdisk      = "it changes the partitions",
    shutdown   = "it shuts the machine down",
    reboot     = "it reboots the machine",
    halt       = "it halts the machine",
    shred      = "it destroys files beyond recovery",
    crontab    = "it changes the scheduled jobs",
    systemctl  = "it controls the system services",
    launchctl  = "it controls the system services",
    killall    = "it kills the processes by name",
    pkill      = "it kills the processes by name",
    chown      = "it changes the ownership",
    passwd     = "it changes a password",
    eval       = "it runs a command it builds at runtime"
}

-- the `<program> <subcommand>` pairs which are dangerous
local SUBCOMMANDS = {
    ["git push"]     = "it pushes to a remote",
    ["git reset"]    = "it can throw away the local work",
    ["git clean"]    = "it deletes the untracked files",
    ["git rebase"]   = "it rewrites the history",
    ["git filter-branch"] = "it rewrites the whole history",
    ["npm publish"]  = "it publishes a package",
    ["cargo publish"] = "it publishes a package",
    ["docker rm"]    = "it removes a container",
    ["docker rmi"]   = "it removes an image",
    ["docker system"] = "it prunes the docker data",
    ["xmake global"] = "it changes the global xmake configuration"
}

-- the programs which install something into the machine
local INSTALLERS = {
    ["brew"] = true, ["apt"] = true, ["apt-get"] = true, ["yum"] = true, ["dnf"] = true,
    ["pacman"] = true, ["apk"] = true, ["port"] = true, ["choco"] = true, ["scoop"] = true,
    ["winget"] = true, ["snap"] = true, ["gem"] = true, ["pip"] = true, ["pip3"] = true,
    ["npm"] = true, ["pnpm"] = true, ["yarn"] = true, ["cargo"] = true, ["go"] = true,
    ["xrepo"] = true, ["uv"] = true, ["uvx"] = true, ["pipx"] = true
}

-- the wrappers which run another program
--
-- `LANG=C rm -rf /` and `timeout 5 rm -rf /` are the `rm` they hide, so we look
-- past them before judging anything
--
local WRAPPERS = {
    env = true, timeout = true, nice = true, nohup = true, stdbuf = true,
    command = true, exec = true, time = true, xargs = true, ["setsid"] = true,
    ["ionice"] = true, ["taskset"] = true, ["unbuffer"] = true, ["script"] = true
}

-- the flags of the wrappers which take a value, so we skip that value too
local WRAPPERFLAGS = {
    timeout = {["-k"] = true, ["--kill-after"] = true, ["-s"] = true, ["--signal"] = true},
    nice    = {["-n"] = true},
    ionice  = {["-c"] = true, ["-n"] = true},
    xargs   = {["-n"] = true, ["-P"] = true, ["-I"] = true, ["-d"] = true},
    env     = {["-u"] = true, ["--unset"] = true}
}

-- the programs which run what their arguments tell them to
local FINDLIKE = {find = true, fd = true}

-- the directories which never belong to a project
local SYSTEMDIRS = {"/etc", "/usr", "/bin", "/sbin", "/boot", "/dev", "/System", "/Library", "/Windows"}

-- check the given command
--
-- @param command   the command line
-- @param opt       the options, e.g. {cwd = "/path/to/project", extra = {"rm *"}}
--
-- @return          the reason to ask, or nil when it is an ordinary command
--
function check(command, opt)
    opt = opt or {}
    command = (command or ""):trim()
    if command == "" then
        return "the command is empty"
    end

    -- the user rules win, they are the whole reason to have them
    for _, pattern in ipairs(opt.extra or {}) do
        if _matchglob(command, pattern) then
            return string.format("it matches the dangerous pattern `%s`", pattern)
        end
    end

    -- a download piped into a shell runs whatever the server sends back
    if _ispipedshell(command) then
        return "it runs a script it downloads"
    end
    for _, part in ipairs(subcommands(command)) do
        local reason = _checkone(part, opt)
        if reason then
            return reason
        end
    end
    return nil
end

-- split a command line into its sub-commands
--
-- `a && b | c; d` are four commands, and every one of them may be dangerous on
-- its own. the substitutions are included too, `echo $(rm -rf /)` runs the `rm`
--
function subcommands(command)
    local results = {}
    local current = {}
    local idx = 1
    local quote = nil
    while idx <= #command do
        local ch = command:sub(idx, idx)
        local two = command:sub(idx, idx + 1)
        if quote then
            if ch == quote then
                quote = nil
            end
            table.insert(current, ch)
            idx = idx + 1
        elseif ch == "\"" or ch == "'" then
            quote = ch
            table.insert(current, ch)
            idx = idx + 1
        elseif two == "&&" or two == "||" then
            table.insert(results, table.concat(current))
            current = {}
            idx = idx + 2
        elseif ch == ";" or ch == "|" or ch == "\n" then
            table.insert(results, table.concat(current))
            current = {}
            idx = idx + 1
        elseif two == "$(" or ch == "`" then
            -- the substitutions are commands of their own
            local closing = ch == "`" and "`" or ")"
            local endidx = command:find(closing, idx + (ch == "`" and 1 or 2), true)
            local inner = command:sub(idx + (ch == "`" and 1 or 2), (endidx or #command + 1) - 1)
            for _, part in ipairs(subcommands(inner)) do
                table.insert(results, part)
            end
            idx = (endidx or #command) + 1
        else
            table.insert(current, ch)
            idx = idx + 1
        end
    end
    table.insert(results, table.concat(current))

    local commands = {}
    for _, part in ipairs(results) do
        part = part:trim()
        if part ~= "" then
            table.insert(commands, part)
        end
    end
    return commands
end

-- check one sub-command
function _checkone(command, opt)
    local words = _unwrap(_words(command))
    local program = path.filename(words[1] or ""):lower()
    if program == "" then
        return nil
    end

    if PROGRAMS[program] then
        return PROGRAMS[program]
    end

    local subcommand = words[2] and (program .. " " .. words[2]:lower()) or nil
    if subcommand and SUBCOMMANDS[subcommand] then
        return SUBCOMMANDS[subcommand]
    end
    if (program == "git" or program == "gh") and _hasdangerousflag(words) then
        return "it uses a flag which rewrites or skips the checks"
    end
    if INSTALLERS[program] and _isinstall(words) then
        return "it installs something into your machine"
    end
    if program == "rm" or program == "rmdir" or program == "unlink" then
        return _checkremove(words, opt)
    end
    if program == "chmod" and _hasflag(words, "r") then
        return "it changes the permissions recursively"
    end
    if FINDLIKE[program] then
        return _checkfind(words, opt)
    end
    if program == "mv" or program == "cp" then
        return _checkpaths(words, opt, "it writes outside the project") or _checkredirect(command, opt)
    end
    return _checkredirect(command, opt)
end

-- look past the wrappers to the program which really runs
--
-- an environment assignment (`LANG=C`), a wrapper (`timeout 5`) or a chain of
-- them hides the command behind it, and the whole point of the check is what
-- ends up running
--
function _unwrap(words)
    local idx = 1
    local guard = 0
    while idx <= #words and guard < 16 do
        guard = guard + 1
        local word = words[idx]

        -- an environment assignment, e.g. `LANG=C`
        if word:match("^[%w_]+=") then
            idx = idx + 1
        else
            local program = path.filename(word):lower()
            if not WRAPPERS[program] then
                break
            end

            -- skip the flags of the wrapper, and the values they take
            idx = idx + 1
            local flags = WRAPPERFLAGS[program] or {}
            while idx <= #words and words[idx]:startswith("-") do
                local takesvalue = flags[words[idx]]
                idx = idx + 1
                if takesvalue then
                    idx = idx + 1
                end
            end

            -- `timeout 5 rm ..`: the duration is not a program
            if program == "timeout" and words[idx] and words[idx]:match("^[%d%.]+[smhd]?$") then
                idx = idx + 1
            end
        end
    end

    local results = {}
    for index = idx, #words do
        table.insert(results, words[index])
    end
    return #results > 0 and results or words
end

-- check a `find`
--
-- `find . -delete` and `find . -exec rm {} +` are deletions with another name
--
function _checkfind(words, opt)
    for index, word in ipairs(words) do
        if word == "-delete" then
            return "it deletes the files it finds"
        end
        if word == "-exec" or word == "-execdir" or word == "-ok" then
            local inner = {}
            for rest = index + 1, #words do
                table.insert(inner, words[rest])
            end
            local reason = #inner > 0 and _checkone(table.concat(inner, " "), opt) or nil
            return reason or "it runs a command on every file it finds"
        end
    end
    return _checkpaths(words, opt, "it looks outside the project")
end

-- has the command one of the flags which change more than it says?
function _hasdangerousflag(words)
    local flags = {["--force"] = true, ["-f"] = true, ["--amend"] = true,
                   ["--no-verify"] = true, ["--hard"] = true, ["--force-with-lease"] = true}
    for index = 2, #words do
        if flags[words[index]:lower()] then
            return true
        end
    end
    return false
end

-- is it an install sub-command?
function _isinstall(words)
    local verbs = {install = true, add = true, upgrade = true, uninstall = true, remove = true, publish = true}
    for idx = 2, math.min(#words, 4) do
        if verbs[words[idx]:lower()] then
            return true
        end
    end
    return false
end

-- check a removal
function _checkremove(words, opt)
    if _hasflag(words, "r") and _hasflag(words, "f") then
        return "it deletes a directory tree without asking"
    end
    return _checkpaths(words, opt, "it deletes files outside the project")
end

-- check the paths of a command
function _checkpaths(words, opt, reason)
    for idx = 2, #words do
        local word = words[idx]
        if not word:startswith("-") then
            local target = _unquote(word)
            for _, dir in ipairs(SYSTEMDIRS) do
                if target:startswith(dir) then
                    return string.format("%s (%s)", reason, target)
                end
            end
            if path.is_absolute(target) and opt.cwd and not paths.inworkspace(opt.cwd, target) then
                return string.format("%s (%s)", reason, target)
            end
        end
    end
    return nil
end

-- check a redirection, e.g. `echo x > /etc/hosts`
function _checkredirect(command, opt)
    for target in command:gmatch(">>?%s*([^%s|;&]+)") do
        target = _unquote(target)
        for _, dir in ipairs(SYSTEMDIRS) do
            if target:startswith(dir) then
                return string.format("it writes to %s", target)
            end
        end
        if path.is_absolute(target) and opt.cwd and not paths.inworkspace(opt.cwd, target) then
            return string.format("it writes to %s, outside the project", target)
        end
    end
    return nil
end

-- does the command download something and run it?
function _ispipedshell(command)
    local downloads = command:find("curl%s") or command:find("wget%s")
    if not downloads then
        return false
    end
    return command:find("|%s*[%w/]*sh%f[%W]") ~= nil or command:find("|%s*[%w/]*bash%f[%W]") ~= nil
        or command:find("|%s*[%w/]*zsh%f[%W]") ~= nil or command:find("|%s*[%w/]*python%d?%f[%W]") ~= nil
end

-- split a command into its words
function _words(command)
    local results = {}
    for word in command:gmatch("%S+") do
        table.insert(results, word)
    end
    return results
end

-- has the command the given short flag?
--
-- e.g. "r" matches `-r`, `-R`, `-rf` and `--recursive`
--
function _hasflag(words, flag)
    local long = {r = "recursive", f = "force"}
    for _, word in ipairs(words) do
        if word:startswith("--") then
            if long[flag] and word:sub(3) == long[flag] then
                return true
            end
        elseif word:startswith("-") and word:sub(2):lower():find(flag:lower(), 1, true) then
            return true
        end
    end
    return false
end

-- strip the quotes of a word
function _unquote(word)
    if (word:startswith("\"") and word:endswith("\"")) or (word:startswith("'") and word:endswith("'")) then
        return word:sub(2, #word - 1)
    end
    return word
end

-- match a glob against the command
function _matchglob(str, pattern)
    local luapattern = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"):gsub("%*", ".*") .. "$"
    return str:match(luapattern) ~= nil
end
