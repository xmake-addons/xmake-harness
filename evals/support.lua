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
-- @file        support.lua
--

--
-- what an eval needs to ask a model something and see what it did
--
-- the answer an eval is looking for is almost never in the reply: it is in the
-- file which was written, the tool which was called, the argument it was called
-- with. so the run is driven headlessly and what comes back is the session,
-- which already records all three, @see harness.core.agent
--

-- imports
import("harness.harness")
import("harness.core.agent")
import("harness.core.session", {alias = "sessions"})

-- a throwaway project with the given files in it
--
-- @param files     {["src/main.c"] = "int main() {}\n"}
-- @return          the directory
--
function project(files)
    local rootdir = os.tmpfile() .. ".eval"
    os.mkdir(rootdir)
    for name, content in pairs(files or {}) do
        local filepath = path.join(rootdir, name)
        os.mkdir(path.directory(filepath))
        io.writefile(filepath, content)
    end
    return rootdir
end

-- ask a model to do something, and hand back what it did
--
-- @param opt   {prompt = "..", files = {..}, mode = "acceptedits", rootdir = ".."}
-- @return      {session = .., result = .., rootdir = ".."}
--
function ask(opt)
    opt = opt or {}
    local rootdir = opt.rootdir or project(opt.files)
    local instance = harness.bootstrap({rootdir = rootdir})
    local session = sessions.new({cwd = rootdir})

    -- the edits are accepted without asking, because there is nobody here to
    -- ask: an eval which stopped on a permission prompt would measure nothing
    local result = agent.run(instance, {
        session = session,
        prompt = opt.prompt,
        ui = {},
        signal = {aborted = false},
        mode = opt.mode or "acceptedits"
    })
    return {session = session, result = result, rootdir = rootdir, harness = instance}
end

-- every tool call of a run, in the order they happened
function toolcalls(run)
    local calls = {}
    for _, event in ipairs(run.session:events()) do
        if event.kind == "tool" then
            table.insert(calls, event)
        end
    end
    return calls
end

-- the first call of the given tool, if there was one
function called(run, name)
    for _, call in ipairs(toolcalls(run)) do
        if call.name == name then
            return call
        end
    end
end

-- what the run wrote, as it stands on disk now
--
-- the path comes from the tool arguments and the content from the file, so an
-- edited file is read once with every change in it rather than reconstructed
--
-- @return  {{path = "src/main.c", content = ".."}, ..}
--
function written(run)
    local seen = {}
    local files = {}
    for _, call in ipairs(toolcalls(run)) do
        local relative = (call.arguments or {}).path
        if relative and not call.iserror and (call.name == "write_file" or call.name == "edit_file") then
            if not seen[relative] then
                seen[relative] = true
                local filepath = path.absolute(relative, run.rootdir)
                if os.isfile(filepath) then
                    table.insert(files, {path = relative, content = io.readfile(filepath) or ""})
                end
            end
        end
    end
    return files
end

-- does this text hold a chinese, japanese or korean character
--
-- utf-8 puts them in the three-byte range which starts at 0xE4..0xE9, which is
-- enough to tell "// 属性值" from "// the attribute value" and does not need a
-- table of ranges to do it
--
function hascjk(text)
    return (text or ""):find("[\228-\233][\128-\191][\128-\191]") ~= nil
end

-- the comment lines of a c-like source file
function comments(content)
    local lines = {}
    local inblock = false
    for _, line in ipairs((content or ""):split("\n", {strict = true})) do
        local trimmed = line:trim()
        if inblock then
            table.insert(lines, trimmed)
            if trimmed:find("*/", 1, true) then
                inblock = false
            end
        elseif trimmed:startswith("//") or trimmed:startswith("--") or trimmed:startswith("#") then
            table.insert(lines, trimmed)
        elseif trimmed:startswith("/*") then
            table.insert(lines, trimmed)
            inblock = not trimmed:find("*/", 1, true)
        end
    end
    return lines
end

-- say what went wrong in a way which is worth reading in the report
function fail(format, ...)
    raise(string.format(format, ...))
end
