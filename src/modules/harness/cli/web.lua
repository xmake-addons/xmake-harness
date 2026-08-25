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
-- @file        web.lua
--

--
-- `xmake ai --web`
--
-- the same harness with a browser in front of it instead of a terminal. it
-- serves on the loopback only and prints a url which carries a token: a service
-- which can edit files and run commands is not something to leave reachable,
-- and a page in another tab can reach `127.0.0.1` exactly as well as its owner
-- can.
--

-- imports
import("core.base.scheduler")
import("harness.ui.theme")
import("harness.ui.transcript")
import("harness.web.browser")
import("harness.web.app", {alias = "webapp"})
import("harness.web.session", {alias = "websession"})
import("harness.http.server", {alias = "httpserver"})

-- start the web ui and stay up until interrupted
function run(harness, options)
    options = options or {}
    local state = websession.new(harness, {mode = options.mode or "acceptedits"})
    local server = httpserver.new({
        addr = options.addr or "127.0.0.1",
        port = tonumber(options.port) or 9736,
        token = _token()
    })
    webapp.mount(server, state)

    local port, errors = httpserver.start(server)
    if not port then
        raise(errors)
    end

    local url = string.format("http://%s:%d/?token=%s", server.addr, port, server.token)
    _announce(harness, url)
    if not options.nobrowser and options.browser ~= false then
        _open(url)
    end
    _wait(server)
    return true
end

-- a secret for this run and no other
--
-- it is not a password: it is the thing which makes the difference between
-- "the person who started this" and "anything else which can open a socket",
-- and it lives only as long as the process
--
function _token()
    local parts = {}
    for _ = 1, 4 do
        table.insert(parts, string.format("%08x", math.random(0, 0xffffffff)))
    end
    return table.concat(parts)
end

-- say where it is
--
-- `io.write` and not `print`: the url carries a token and the project path is
-- whatever the user called their directory, and print runs its arguments
-- through `vformat`, which would read `$(..)` in either of them as its own
--
function _announce(harness, url)
    io.write("\n")
    for _, line in ipairs(transcript.logo()) do
        io.write("  ", line, "\n")
    end
    io.write("\n")
    io.write("  ", theme.styled("dim", "web ui  "), theme.styled("md.ref", url), "\n")
    io.write("  ", theme.styled("dim", "project "), harness:rootdir(), "\n\n")
    io.write(theme.styled("dim", "  the url carries the key to this session, it is not for sharing"), "\n")
    io.write(theme.styled("dim", "  ctrl+c to stop"), "\n\n")
    io.flush()
end

-- open it, if this machine has anything to open it with
--
-- it happens in a coroutine because a launcher is a program like any other and
-- may take its time; the server is already accepting by now, so the tab it
-- opens finds something there
--
function _open(url)
    scheduler.co_start(function ()
        local opened, errors = browser.open(url)
        if not opened then
            io.write(theme.styled("dim", string.format("  open it yourself: %s", errors)), "\n\n")
            io.flush()
        end
    end)
end

-- stay up
--
-- the accept loop lives in its own coroutine, so this one only has to keep the
-- process alive and let the scheduler run everything else
--
function _wait(server)
    while server.running do
        os.sleep(500)
    end
end
