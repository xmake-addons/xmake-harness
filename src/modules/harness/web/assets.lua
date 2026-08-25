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
-- @file        assets.lua
--

--
-- the files the page is made of
--
-- they sit beside this module and ship with the addon: no build step, no
-- bundler, no versions to keep in step. what the browser gets is what is on
-- disk, which also means editing the css and reloading is the whole
-- development loop.
--

-- imports
import("harness.http.server", {alias = "httpserver"})

-- where the files are
function dir()
    return path.join(os.scriptdir(), "assets")
end

-- the page itself
--
-- the token is written into the page rather than asked for: the user opened a
-- url which carried it, and making them paste it again into a field would be
-- ceremony without a gain — anyone who can read the url can read the field
--
function page(request, server)
    local html = io.readfile(path.join(dir(), "index.html"))
    if not html then
        return {status = 500, contenttype = "text/plain", content = "the page is missing"}
    end
    local token = server.token or ""
    html = html:gsub("__HARNESS_TOKEN__", (token:gsub("%%", "%%%%")))

    -- the page comes with the token in a cookie as well as in its own source,
    -- so that it can take it out of the address bar and still be reloadable:
    -- a url with a live secret in it sits in the history and in every
    -- screenshot, and it only ever needed to be there for this one request
    local headers
    if token ~= "" then
        headers = {["Set-Cookie"] = string.format(
            "harness-token=%s; Path=/; SameSite=Strict; HttpOnly", token)}
    end
    return {status = 200, contenttype = "text/html; charset=utf-8", content = html,
            headers = headers}
end

-- one file below /assets/
--
-- the name is taken apart and put back together rather than used: a path is
-- the one thing a browser sends which is chosen by whoever sent it, and
-- `/assets/../../../.ssh/id_rsa` is a request somebody will make one day
--
function file(urlpath)
    local name = path.filename(urlpath:gsub("^/assets/", ""))
    if name == "" or name:find("%.%.") then
        return {status = 404, contenttype = "text/plain", content = "not found"}
    end
    local filepath = path.join(dir(), name)
    if not os.isfile(filepath) then
        return {status = 404, contenttype = "text/plain", content = "not found"}
    end
    return {status = 200, contenttype = httpserver.mimetype(filepath),
            content = io.readfile(filepath, {encoding = "binary"}) or ""}
end
