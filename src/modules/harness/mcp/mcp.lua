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
-- @file        mcp.lua
--

--
-- the mcp integration
--
-- the builtin tools stay native: they are lua and they run in process. an mcp
-- server is the other way in — it brings the tools of a third party, and they
-- join the same registry, so the model, the permission policy and the ui treat
-- them exactly like the native ones.
--
-- the servers are declared in the configuration, e.g.
--
--   "mcp": {
--       "servers": {
--           "github":  {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
--                       "envs": {"GITHUB_TOKEN": "ghp_.."}},
--           "sqlite":  {"command": "uvx", "args": ["mcp-server-sqlite", "--db-path", "./app.db"],
--                       "permission": "write"},
--           "disabled": {"command": "..", "enabled": false}
--       }
--   }
--
-- a server is started lazily: nothing is spawned until the model actually calls
-- one of its tools, so a session which never touches them costs nothing.
--

-- imports
import("harness.util.text")
import("harness.mcp.client")

-- the prefix which keeps the tool names apart, e.g. "github__create_issue"
local SEPARATOR = "__"

-- load the servers of the configuration into the tool registry
--
-- @return  the number of the registered tools
--
function load(harness)
    local servers = _servers(harness:config())
    if not servers then
        return 0
    end

    local clients = {}
    local count = 0
    for name, config in table.orderpairs(servers) do
        if config.enabled ~= false then
            local instance = client.new(name, config)
            local tools, errors = _tools(harness, instance, config)
            if tools then
                clients[name] = instance
                count = count + tools
            else
                utils.warning("harness: mcp(%s): %s", name, tostring(errors))
            end
        end
    end
    harness:service("mcp", clients)
    return count
end

-- stop every server we started
function stop(harness)
    for _, instance in pairs(harness:service("mcp") or {}) do
        instance:stop()
    end
end

-- get the configured servers
function _servers(config)
    local servers = (config.mcp or {}).servers
    if type(servers) ~= "table" then
        return nil
    end
    for _, _ in pairs(servers) do
        return servers
    end
end

-- register the tools of one server
--
-- @return  the number of the registered tools, or nil and the errors
--
function _tools(harness, instance, config)
    local tools, errors = instance:tools()
    if not tools then
        return nil, errors
    end
    local registry = harness:service("tools")
    for _, tool in ipairs(tools) do
        registry:add(_definition(instance, tool, config))
    end

    -- the server is only needed again when a tool is called
    if config.keepalive ~= true then
        instance:stop()
    end
    return #tools
end

-- make the harness tool of one mcp tool
function _definition(instance, tool, config)
    local name = instance:name() .. SEPARATOR .. tool.name
    return {
        name = name,
        group = "mcp:" .. instance:name(),
        source = "mcp",
        -- an mcp server is a third party: we cannot know what a tool of it
        -- really does, so it asks the user unless the configuration says
        -- otherwise, @see harness.permission.policy
        permission = config.permission or "exec",
        description = _description(instance, tool),
        parameters = tool.inputSchema or {type = "object", properties = {}},
        run = function (context, args)
            return _call(instance, tool, args)
        end
    }
end

-- the description which the model sees
function _description(instance, tool)
    local description = tool.description or ""
    local server = instance:serverinfo()
    local from = string.format("(from the mcp server `%s`%s)", instance:name(),
        server and server.name and (" · " .. server.name) or "")
    if description == "" then
        return from
    end
    return description .. "\n\n" .. from
end

-- call one mcp tool
function _call(instance, tool, args)
    local output, iserror = instance:calltool(tool.name, args)
    if not output then
        raise("%s", iserror or "the mcp call failed")
    end
    if output == "" then
        output = "(the tool returned nothing)"
    end
    return {
        output = output,
        iserror = iserror and true or false,
        display = {
            title = instance:name() .. SEPARATOR .. tool.name,
            subject = _subject(args),
            summary = string.format("%s · %d line%s", iserror and "failed" or "ok",
                #text.lines(output), #text.lines(output) == 1 and "" or "s"),
            kind = "output",
            output = output
        }
    }
end

-- the short summary of the arguments, for the tool card
function _subject(args)
    if type(args) ~= "table" then
        return nil
    end
    for _, key in ipairs({"path", "query", "url", "name", "id", "command"}) do
        if args[key] then
            return text.truncate(tostring(args[key]), 60)
        end
    end
    for key, value in table.orderpairs(args) do
        if type(value) == "string" or type(value) == "number" then
            return text.truncate(string.format("%s: %s", key, tostring(value)), 60)
        end
    end
end
