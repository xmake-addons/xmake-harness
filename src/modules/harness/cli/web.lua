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
import("harness.core.session", {alias = "sessions"})
import("harness.http.server", {alias = "httpserver"})

-- start the web ui and stay up until interrupted
function run(harness, options)
    options = options or {}
    local state = websession.new(harness, {
        mode = options.mode or "acceptedits",
        session = _session(harness, options)})
    local addr = _addr(options)
    local server = httpserver.new({
        addr = addr,
        port = tonumber(options.port) or 9736,
        token = _token()
    })
    webapp.mount(server, state)

    local port, errors = httpserver.start(server)
    if not port then
        raise(errors)
    end

    local url = string.format("http://%s:%d/?token=%s",
        server.addr == "0.0.0.0" and "127.0.0.1" or server.addr, port, server.token)
    _announce(harness, url, state.session:title() or "new conversation",
              _elsewhere(server, port))
    if not options.nobrowser and options.browser ~= false then
        _open(url)
    end
    _wait(server)
    return true
end

-- where to listen
--
-- the loopback, because a service which edits files and runs commands is not
-- something to put on a network by accident. `--host` says otherwise on
-- purpose: `--host=0.0.0.0` for every interface, or one address to pick just
-- one of them. the token is still required either way, and it is the only thing
-- between the page and anybody who can reach the port.
--
function _addr(options)
    local host = options.host or options.addr
    if not host or tostring(host):trim() == "" then
        return "127.0.0.1"
    end
    host = tostring(host):trim()
    if host == "all" or host == "any" or host == "*" then
        return "0.0.0.0"
    end
    return host
end

-- the addresses somebody else could use, when we are listening for them
--
-- printed because the url which works here — `127.0.0.1` — is the one url which
-- does *not* work from another machine, and copying it over and wondering why
-- is a rite of passage nobody needs
--
function _elsewhere(server, port)
    if server.addr ~= "0.0.0.0" then
        return nil
    end
    local urls = {}
    for _, address in ipairs(_addresses()) do
        table.insert(urls, string.format("http://%s:%d/?token=%s", address, port, server.token))
    end
    return urls
end

-- the addresses of this machine, as another machine would name it
function _addresses()
    local found = {}
    local out = try {
        function ()
            if is_host("windows") then
                return os.iorunv("ipconfig", {})
            end
            return os.iorunv("ifconfig", {})
        end
    }
    for address in tostring(out or ""):gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
        -- the whole loopback range and not just its most famous address: a vpn
        -- or a tunnel puts others in there, and none of them help anybody else
        if not address:startswith("127.") then
            table.insert(found, address)
        end
    end
    for address in tostring(out or ""):gmatch("IPv4[^:]*:%s*(%d+%.%d+%.%d+%.%d+)") do
        if not address:startswith("127.") then
            table.insert(found, address)
        end
    end
    return table.unique(found)
end

-- which conversation this page opens on
--
-- the last one of this project, unlike the terminal, which starts a new one
-- unless it is told otherwise. a browser is a window somebody leaves open: it
-- is restarted by a reload, by a crash, by a laptop waking up, and finding an
-- empty conversation each time — with the list of what was changed gone with it
-- — is not what "restart" is supposed to mean.
--
-- `--new` starts a fresh one, and so does the button in the page.
--
function _session(harness, options)
    if options["new"] then
        return nil
    end
    if options.resume ~= nil and tostring(options.resume):trim() ~= "" then
        local session, errors = sessions.load(tostring(options.resume):trim(), harness:rootdir())
        if not session then
            raise(errors)
        end
        return session
    end
    return sessions.last(harness:rootdir())
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
function _announce(harness, url, session, elsewhere)
    io.write("\n")
    for _, line in ipairs(transcript.logo()) do
        io.write("  ", line, "\n")
    end
    io.write("\n")
    io.write("  ", theme.styled("dim", "web ui  "), theme.styled("md.ref", url), "\n")
    io.write("  ", theme.styled("dim", "project "), harness:rootdir(), "\n")
    io.write("  ", theme.styled("dim", "session "), session, "\n\n")
    if elsewhere then
        for _, other in ipairs(elsewhere) do
            io.write("  ", theme.styled("dim", "or      "), theme.styled("md.ref", other), "\n")
        end
        io.write("\n")
        io.write(theme.styled("notice",
            "  it is listening on every interface: anything which can reach this machine"), "\n")
        io.write(theme.styled("notice",
            "  can reach the harness, and only the token is in the way"), "\n")
    end
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
