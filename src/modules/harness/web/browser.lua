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
-- @file        browser.lua
--

--
-- open a url in whatever the system calls its browser
--
-- there is no api for this: every desktop has its own launcher and the only
-- portable part is that one of them is usually there. so it is a list, tried in
-- order, and the url is handed over as an argument rather than pasted into a
-- command line — a token in a url is exactly the kind of thing a shell would
-- otherwise be free to reinterpret.
--
-- failing to open is not an error. the url has already been printed, and a
-- session which refuses to start because a desktop is missing `xdg-open` would
-- be worse than one the user opens by hand.
--

-- the launchers of each system, best first
function _launchers()
    if is_host("macosx") then
        return {{name = "open"}}
    elseif is_host("windows") then
        -- `start` is a builtin of the shell and not a program, and its first
        -- quoted argument is the window title rather than the url
        return {{name = "cmd", argv = {"/c", "start", ""}},
                {name = "rundll32", argv = {"url.dll,FileProtocolHandler"}}}
    end
    -- linux, the bsds, and a wsl guest which reaches the host's browser
    return {{name = "xdg-open"}, {name = "gio", argv = {"open"}},
            {name = "wslview"}, {name = "x-www-browser"}, {name = "sensible-browser"}}
end

-- open the url
--
-- @return  the launcher which took it, or nil and the reason
--
function open(url, opt)
    opt = opt or {}
    local launchers = opt.launchers or _launchers()
    local run = opt.run or function (program, argv)
        os.runv(program, argv)
    end
    -- no `find_tool` here: it settles what a program is by asking it for its
    -- version, and `open --version` on macos is an error rather than an answer.
    -- a launcher which is not installed fails when it is run, which is the same
    -- answer one step later and never a false negative
    local found = opt.find or function (name)
        return name
    end

    local tried = {}
    for _, launcher in ipairs(launchers) do
        local program = found(launcher.name)
        if program then
            local argv = table.join(launcher.argv or {}, url)
            local errors
            try {
                function ()
                    run(program, argv)
                end,
                catch {
                    function (errs)
                        errors = tostring(errs)
                    end
                }
            }
            if not errors then
                return launcher.name
            end
            table.insert(tried, launcher.name)
        end
    end
    if #tried > 0 then
        return nil, string.format("%s could not open it", table.concat(tried, ", "))
    end
    return nil, "no browser launcher was found on this system"
end
