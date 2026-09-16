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
-- `xmake ai mcp ...` — one mcp server, on its own
--
-- an mcp server which does not work fails in the least useful way there is: the
-- harness starts, the tools are quietly missing, and the model says it cannot
-- do the thing. finding out why means reading a warning which went past during
-- startup, and the loop for fixing it is "edit the config, start the whole
-- assistant, watch the warning" — which is a slow loop for a spelling mistake
-- in a command line.
--
-- so a server can be talked to directly: started, asked what it has, and one of
-- its tools called with arguments you typed. no model, no conversation, no
-- tokens.
--
-- this module is imported only when the first word is `mcp`, @see harness.cli.ai.
--

-- imports
import("core.base.json")
import("harness.util.text")
import("harness.mcp.client")

-- the verbs, and what each of them takes
local VERBS = {
    {name = "list",  usage = "xmake ai mcp list",
     about = "the servers in the configuration, and whether they answer"},
    {name = "tools", usage = "xmake ai mcp tools <server>",
     about = "what one of them offers, with its arguments"},
    {name = "call",  usage = "xmake ai mcp call <server> <tool> [json]",
     about = "call one tool and print what came back"},
    {name = "serve", usage = "xmake ai mcp serve",
     about = "run the example server on stdio, to test the other end"}
}

-- is this word one of ours?
function isverb(word)
    for _, verb in ipairs(VERBS) do
        if verb.name == word then
            return true
        end
    end
    return false
end

-- run `xmake ai mcp <verb> ...`
function run(context, args, options)
    local verb = args[1]

    -- it is answered before anything else: serving needs no configuration, no
    -- tools and no harness, and whatever a bootstrap printed would land in the
    -- middle of the json-rpc it is about to speak
    if verb == "serve" then
        return import("harness.mcp.example", {anonymous = true}).serve()
    end
    if verb == "list" then
        return _list(context())
    elseif verb == "tools" then
        return _tools(context(), args[2])
    elseif verb == "call" then
        return _call(context(), args[2], args[3], table.concat(table.slice(args, 4), " "))
    end
    return usage()
end

-- what there is to do
function usage(mistaken)
    cprint("")
    if mistaken then
        cprint("${color.error}`%s` is not one of the things `mcp` does.${clear}", mistaken)

        -- and it may not have been meant as one at all: a sentence which
        -- happens to start with this word is a question, and there has to be a
        -- way to ask it which does not begin by arguing about grammar
        cprint("${dim}(to ask it as a question instead: xmake ai --print '<the question>')${clear}")
        cprint("")
    end
    cprint("${bright}xmake ai mcp${clear} — talk to one mcp server without a model")
    cprint("")
    for _, verb in ipairs(VERBS) do
        cprint("  ${bright}%-46s${clear} %s", verb.usage, verb.about)
    end
    cprint("")
    cprint("  ${dim}e.g. xmake ai mcp call demo echo '{\"text\":\"hello\"}'${clear}")
    cprint("")
    return true
end

-- the servers in the configuration
--
-- each of them is started, asked, and stopped. that is the whole question
-- somebody has when they are looking at this list: does it answer
--
function _list(harness)
    local servers = _servers(harness)
    if not servers then
        cprint("")
        cprint("${dim}no mcp servers configured.${clear}")
        cprint("${dim}there is an example one to try: `xmake ai mcp serve` and the config in%s${clear}",
               " docs/mcp.md")
        cprint("")
        return true
    end

    cprint("")
    for name, config in table.orderpairs(servers) do
        if config.enabled == false then
            cprint("  ${bright}%-16s${clear} ${dim}disabled${clear}", name)
        else
            local instance = client.new(name, config)
            local tools, errors = _ask(instance)
            if tools then
                local info = instance:serverinfo() or {}
                cprint("  ${bright}%-16s${clear} ${color.success}ok${clear}  ${dim}%d tool%s%s${clear}",
                    name, #tools, #tools == 1 and "" or "s",
                    info.name and ("  " .. info.name .. " " .. (info.version or "")) or "")
            else
                cprint("  ${bright}%-16s${clear} ${color.error}%s${clear}", name, tostring(errors))
            end
            instance:stop()
        end
        cprint("    ${dim}%s${clear}", _command(config))
    end
    cprint("")
    return true
end

-- what one server offers
function _tools(harness, name)
    local instance, ours = _client(harness, name)
    if not instance then
        cprint("${color.error}%s${clear}", ours)
        return true
    end

    local tools, asked = _ask(instance)
    if not tools then
        cprint("${color.error}%s${clear}", tostring(asked))
        _release(instance, ours)
        return true
    end

    cprint("")
    for _, tool in ipairs(tools) do
        cprint("  ${bright}%s${clear}(%s)", tool.name, _arguments(tool))
        if tool.description and tool.description ~= "" then
            cprint("    ${dim}%s${clear}", text.truncate(text.oneline(tool.description), 92))
        end
    end
    cprint("")
    cprint("  ${dim}%d tool%s · `xmake ai mcp call %s <tool> '{..}'`${clear}",
           #tools, #tools == 1 and "" or "s", name)
    cprint("")
    _release(instance, ours)
    return true
end

-- one tool, called
function _call(harness, name, tool, arguments)
    local instance, ours = _client(harness, name)
    if not instance then
        cprint("${color.error}%s${clear}", ours)
        return true
    end
    if not tool then
        cprint("${color.error}say which tool${clear}, `xmake ai mcp tools %s` lists them", name)
        _release(instance, ours)
        return true
    end

    local args = {}
    if arguments and arguments:trim() ~= "" then
        args = try { function () return json.decode(arguments) end }
        if type(args) ~= "table" then
            cprint("${color.error}the arguments are not json${clear}: %s", arguments)
            _release(instance, ours)
            return true
        end
    end

    local started = os.mclock()
    local output, failed = _ask(instance, tool, args)
    _release(instance, ours)

    -- nothing came back at all: the server did not answer, or it answered with
    -- something which is not a result. that is a broken server and not a failed
    -- tool, and the two look nothing alike once you know which you are looking at
    if output == nil then
        cprint("${color.error}%s${clear}", tostring(failed))
        return true
    end

    print(output)

    -- a tool which said it failed said so *in* its result, which is how the
    -- model would have received it. saying "ok" over the top of that would hide
    -- the one thing somebody calling `fail` is checking
    cprint("${dim}%s in %dms%s${clear}", tool, os.mclock() - started,
           failed and "  ${color.error}the tool reported an error${clear}" or "")
    return true
end

-- start a server and ask it something, without letting it take the cli down
--
-- a server which is not there, or which answers with nonsense, is the ordinary
-- case here: it is what somebody is running this to find out
--
function _ask(instance, tool, args)
    local result, errors
    try {
        function ()
            if tool then
                result, errors = instance:calltool(tool, args)
            else
                result, errors = instance:tools()
            end
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    return result, errors
end

-- the client of one configured server
--
-- the one the harness already started, when it started: bringing the server up
-- happens during the bootstrap, and a second copy of it would be a second
-- process answering questions about the first.
--
-- a fresh one when it did not, which is the case somebody is here about: the
-- server which failed at startup fails again, here, with its message in front
-- of them instead of in a warning which went past
--
-- @return  the client, whether it is ours to stop, or nil and why not
--
function _client(harness, name)
    if not name then
        return nil, "say which server, `xmake ai mcp list` shows them"
    end
    local loaded = (harness:service("mcp") or {})[name]
    if loaded then
        return loaded, false
    end

    local servers = _servers(harness) or {}
    local config = servers[name]
    if not config then
        local names = {}
        for known in table.orderpairs(servers) do
            table.insert(names, known)
        end
        return nil, string.format("there is no mcp server called `%s`%s", name,
            #names > 0 and (", there is: " .. table.concat(names, ", ")) or "")
    end
    return client.new(name, config), true
end

-- stop it, if starting it was our doing
--
-- one the harness started belongs to the harness, and this process is about to
-- end anyway: stopping it here would be taking away something we borrowed
--
function _release(instance, ours)
    if ours then
        instance:stop()
    end
end

-- the configured servers, or nil
function _servers(harness)
    local servers = (harness:config().mcp or {}).servers
    if type(servers) ~= "table" then
        return nil
    end
    for _, _ in pairs(servers) do
        return servers
    end
end

-- how a server is started, as one line
function _command(config)
    if config.url then
        return config.url
    end
    return string.format("%s %s", config.command or "?",
                         table.concat(config.args or {}, " "))
end

-- the arguments of one tool, as a signature
function _arguments(tool)
    local schema = tool.inputSchema or tool.input_schema or {}
    local required = {}
    for _, name in ipairs(schema.required or {}) do
        required[name] = true
    end
    local parts = {}
    for name, property in table.orderpairs(schema.properties or {}) do
        table.insert(parts, string.format("%s%s: %s", name, required[name] and "" or "?",
                                          property.type or "any"))
    end
    return table.concat(parts, ", ")
end
