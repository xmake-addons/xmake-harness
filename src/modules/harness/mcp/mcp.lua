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
import("core.base.json")
import("harness.util.text")
import("harness.mcp.client")

-- the prefix which keeps the tool names apart, e.g. "github__create_issue"
local SEPARATOR = "__"

-- how many mcp tools we are willing to put in front of the model at once
--
-- under this they are ordinary tools and using one is a single step, which is
-- what somebody who configured one small server wants. over it the schemas
-- start to cost more than the tools are worth: they are in every request of
-- every turn, whether or not anything reaches for them, so past here they go
-- behind `mcp_list` and `mcp_call` and are paid for when they are used
local MAXDIRECT = 8

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
    local found = {}
    local count = 0
    for name, config in table.orderpairs(servers) do
        if config.enabled ~= false then
            local instance = client.new(name, config, {
                config = harness:config(),
                cwd = config.cwd or harness:rootdir()
            })
            local tools, errors = instance:tools()
            if tools then
                clients[name] = instance
                table.insert(found, {name = name, instance = instance,
                                     config = config, tools = tools})
                count = count + #tools
            else
                utils.warning("harness: mcp(%s): %s", name, tostring(errors))
            end
        end
    end
    harness:service("mcp", clients)
    if count == 0 then
        return 0
    end

    -- a few of them are ordinary tools: the model sees them, and using one is
    -- one step. a lot of them go behind a door instead, because their schemas
    -- are in *every* request of every turn — twenty tools somebody reaches for
    -- once an hour is twenty schemas paid for all of it, @see MAXDIRECT
    if count <= MAXDIRECT then
        for _, one in ipairs(found) do
            _direct(harness, one)
        end
    else
        _gateway(harness, found)
    end
    for _, one in ipairs(found) do
        -- the server is only needed again when a tool is called
        if one.config.keepalive ~= true then
            one.instance:stop()
        end
    end
    return count
end

-- register the tools of one server, each as itself
function _direct(harness, one)
    local registry = harness:service("tools")
    for _, tool in ipairs(one.tools) do
        registry:add(_definition(one.instance, tool, one.config))
    end
end

-- register the door in front of all of them
--
-- two tools and not one with an `op`, because they are two different questions
-- as far as permission is concerned: looking at a list costs nothing and must
-- not ask, and calling somebody else's tool is the thing which must, @see
-- harness.permission.policy
--
function _gateway(harness, found)
    local registry = harness:service("tools")
    local names = {}
    for _, one in ipairs(found) do
        table.insert(names, string.format("%s (%d)", one.name, #one.tools))
    end

    registry:add({
        name = "mcp_list",
        group = "mcp",
        source = "mcp",
        permission = "none",
        description = string.format(
            [[List the tools the external MCP servers offer, with their arguments.

The servers are: %s. Their tools are not in your tool list — there are too many
of them to carry in every request — so look here first, then call one with
`mcp_call`.]], table.concat(names, ", ")),
        parameters = {
            type = "object",
            properties = {
                server = {type = "string",
                          description = "Only this server's tools, all of them by default."}
            }
        },
        run = function (context, args)
            return _listing(found, args.server)
        end
    })

    registry:add({
        name = "mcp_call",
        group = "mcp",
        source = "mcp",
        -- an mcp server is a third party: we cannot know what a tool of it
        -- really does, so it asks the user, @see harness.permission.policy
        permission = "exec",
        description = [[Call one of the tools an external MCP server offers.

Use `mcp_list` first: the server and tool names, and the arguments each takes,
come from there.]],
        parameters = {
            type = "object",
            properties = {
                server    = {type = "string", description = "The server, from `mcp_list`."},
                tool      = {type = "string", description = "The tool, from `mcp_list`."},
                arguments = {type = "object", description = "What to pass it."}
            },
            required = {"server", "tool"}
        },
        run = function (context, args)
            return _gatewaycall(found, args)
        end
    })
end

-- what the servers offer, as the model reads it
function _listing(found, only)
    local lines = {}
    for _, one in ipairs(found) do
        if not only or only == "" or only == one.name then
            for _, tool in ipairs(one.tools) do
                table.insert(lines, string.format("- server=%s tool=%s — %s",
                    one.name, tool.name,
                    text.oneline(tool.description or ""):trim()))
                local properties = (tool.inputSchema or {}).properties
                if _any(properties) then
                    table.insert(lines, string.format("    arguments: %s",
                        json.encode(properties)))
                end
            end
        end
    end
    if #lines == 0 then
        return {output = only and string.format("there is no mcp server called `%s`.", only)
                              or "the mcp servers offer no tools."}
    end
    return {output = table.concat(lines, "\n")}
end

-- is there anything in that table?
--
-- `next` is not in the sandbox, so this is how one asks
function _any(tbl)
    if type(tbl) ~= "table" then
        return false
    end
    for _, _ in pairs(tbl) do
        return true
    end
    return false
end

-- call one of them through the door
function _gatewaycall(found, args)
    for _, one in ipairs(found) do
        if one.name == args.server then
            for _, tool in ipairs(one.tools) do
                if tool.name == args.tool then
                    return _call(one.instance, tool, args.arguments or {})
                end
            end
            return {output = string.format("the server `%s` has no tool called `%s`, "
                .. "`mcp_list` says what it has.", args.server, tostring(args.tool)),
                    iserror = true}
        end
    end
    return {output = string.format("there is no mcp server called `%s`, `mcp_list` "
        .. "says which there are.", tostring(args.server)), iserror = true}
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
