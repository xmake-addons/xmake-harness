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
-- @file        setup.lua
--

--
-- the configuration entries of the command line
--
-- the api keys always land in the user configuration, never in the project.
--

-- imports
import("harness.util.util")
import("harness.util.text")
import("harness.config.config")

-- set a user config value, e.g. --config=providers.deepseek.apikey=sk-xxx
function setconfig(assignment)
    local key, value = assignment:match("^([^=]+)=(.*)$")
    if not key then
        cprint("%s = ${bright}%s", assignment, tostring(config.get(assignment)))
        return true
    end
    local parsed = util.tovalue(value)
    config.set(key, parsed)
    cprint("${bright green}%s${clear} = %s ${dim}(saved to %s)${clear}", key, tostring(parsed), config.userfile())
    return true
end

-- set the api key of the current provider
function setapikey(context, apikey)
    local name = context:config().provider
    config.set(string.format("providers.%s.apikey", name), apikey)
    cprint("${bright green}the api key of %s is saved to %s", name, config.userfile())
    return true
end

-- make sure we have a key to talk to the model
--
-- @return  true when we can go on
--
function ensurekey(context, opt)
    opt = opt or {}
    local provider = config.provider(context:config())
    if provider.apikey and provider.apikey ~= "" then
        return true
    end
    if opt.interactive then
        wizard(context)
        provider = config.provider(context:config())
        if provider.apikey and provider.apikey ~= "" then
            return true
        end
    end
    raise("the api key of the provider(%s) is not configured!\n"
        .. "run `xmake ai --apikey=<your key>` or `xmake ai --setup` first.", provider.name)
end

-- the interactive setup wizard
function wizard(context)
    local harnessconfig = context:config()
    cprint("")
    cprint("${bright}welcome to xmake ai${clear}")
    cprint("${dim}the configuration is saved to %s, it never touches your project.${clear}", config.userfile())
    cprint("")

    local name = _askprovider(harnessconfig)
    config.set("provider", name)
    harnessconfig.provider = name
    _askapikey(harnessconfig, name)

    cprint("")
    cprint("${bright green}the setup is done${clear}, run `xmake ai` to start.")
    cprint("")
    return true
end

-- ask which provider to use
function _askprovider(harnessconfig)
    local names = config.providernames(harnessconfig)
    cprint("the available providers:")
    for idx, name in ipairs(names) do
        local provider = config.provider(harnessconfig, name)
        cprint("  ${bright}%d${clear}. %s ${dim}%s%s${clear}", idx, text.pad(name, 14),
            provider.models.main or "", (provider.apikey and provider.apikey ~= "") and "  (key configured)" or "")
    end
    cprint("")
    io.write(string.format("choose the provider [%s]: ", harnessconfig.provider))
    io.flush()

    local answer = (io.read("l") or ""):trim()
    if answer == "" then
        return harnessconfig.provider
    end
    local name = names[tonumber(answer) or 0] or answer
    if not config.provider(harnessconfig, name) then
        raise("unknown provider: %s", answer)
    end
    return name
end

-- ask for the api key of the given provider
function _askapikey(harnessconfig, name)
    local provider = config.provider(harnessconfig, name)
    if provider.apikeyurl then
        cprint("${dim}get an api key at %s${clear}", provider.apikeyurl)
    end
    io.write(string.format("the api key of %s%s: ", name,
        (provider.apikey and provider.apikey ~= "") and " (enter to keep the current one)" or ""))
    io.flush()

    local apikey = (io.read("l") or ""):trim()
    if apikey == "" then
        return
    end
    config.set(string.format("providers.%s.apikey", name), apikey)
    harnessconfig.providers = harnessconfig.providers or {}
    harnessconfig.providers[name] = harnessconfig.providers[name] or {}
    harnessconfig.providers[name].apikey = apikey
end
