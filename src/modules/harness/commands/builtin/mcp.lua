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
-- the mcp commands: /mcp
--

-- imports
import("harness.util.text")
import("harness.mcp.mcp")

-- the commands of this group
function commands()
    return {
        {name = "mcp", description = "List the mcp servers and their tools, /mcp reload to reconnect", run = _mcp}
    }
end

-- /mcp [reload]
function _mcp(app, args)
    if (args or ""):trim() == "reload" then
        local count = mcp.load(app.harness)
        return {kind = "message", text = string.format("the mcp servers are reloaded, %d tools are available", count)}
    end

    local servers = (app.harness:config().mcp or {}).servers or {}
    local lines = {}
    local count = 0
    for name, config in table.orderpairs(servers) do
        count = count + 1
        table.insert(lines, _serverline(name, config))
        for _, line in ipairs(_toolines(app, name)) do
            table.insert(lines, line)
        end
    end
    if count == 0 then
        return {kind = "message", text = _help()}
    end
    table.insert(lines, "")
    table.insert(lines, "the servers start when a tool of them is called · `/mcp reload` reconnects")
    return {kind = "message", text = table.concat(lines, "\n")}
end

-- render one server
function _serverline(name, config)
    local command = table.concat(table.join({config.command or "?"}, config.args or {}), " ")
    return string.format("  %s %s %s", text.pad(name, 16),
        config.enabled == false and "[disabled]" or "[enabled] ", text.truncate(command, 60))
end

-- render the tools of one server
function _toolines(app, name)
    local results = {}
    for _, tool in ipairs(app.harness:service("tools"):tools()) do
        if tool.group == "mcp:" .. name then
            table.insert(results, string.format("      %s %s", text.pad(tool.name, 28),
                text.truncate((tool.description or ""):gsub("\n.*", ""), 60)))
        end
    end
    return results
end

-- what to write into the configuration
function _help()
    return [[no mcp server is configured.

add one to the harness configuration, e.g.

  "mcp": {
      "servers": {
          "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "envs": {"GITHUB_TOKEN": "ghp_xxx"}
          }
      }
  }

its tools then join the registry as `github__<tool>`, and they follow the same
permission rules as the native ones.]]
end
