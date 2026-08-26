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
-- @file        config.lua
--

--
-- the layered configuration
--
-- the layers are merged in this order (the later wins):
--
--   1. the builtin defaults
--   2. the user config,    ~/.xmake/harness/config.json
--   3. the project config, <project>/.xmake-harness/config.json
--   4. the environment variables, XMAKE_HARNESS_*
--   5. the command line options
--
-- only the user config layer is writable by default, so the api keys are
-- always stored on the user side and never in the project repository.
--

-- imports
import("core.base.json")
import("core.base.option")
import("core.base.global")
import("harness.util.util")
import("harness.config.providers")

-- get the harness home directory, e.g. ~/.xmake/harness
function homedir()
    local dir = os.getenv("XMAKE_HARNESS_HOME")
    if not dir then
        dir = path.join(global.directory(), "harness")
    end
    return dir
end

-- get the user config file path
function userfile()
    return path.join(homedir(), "config.json")
end

-- get the project config file path
function projectfile(rootdir)
    return path.join(rootdir or os.curdir(), ".xmake-harness", "config.json")
end

-- get the builtin default configuration
function defaults()
    return {
        provider = "deepseek",
        providers = {},
        model = nil,
        smallmodel = nil,
        stream = true,
        maxtokens = 8192,
        temperature = 0.0,
        theme = "default",
        language = "auto",
        permission = {
            mode  = "default",
            allow = {},
            deny  = {},
            ask   = {}
        },
        sandbox = {
            enabled = false,
            backend = "auto",
            network = false,
            writabledirs = {}
        },
        context = {
            autocompact = true,
            threshold = 0.82,
            keeprecent = 6,
            maxfilesize = 262144
        },
        tools = {
            disabled = {},
            timeout = 300000,
            maxoutput = 60000
        },
        skills = {
            dirs = {},
            enabled = {},
            disabled = {}
        },
        agents = {
            dirs = {},
            disabled = {}
        },
        plugins = {
            dirs = {},
            disabled = {}
        },
        ui = {
            showreasoning = true,
            showtokens = true,
            showtips = true,
            diffcontext = 3,
            spinner = "dots"
        },
        session = {
            save = true,
            maxhistory = 200
        },
        code = {
            comments = "English",
            braces = "sameline"
        }
    }
end

-- load the configuration
--
-- @param opt   the options, e.g. {rootdir = "/path/to/project", options = {provider = "deepseek"}}
--
function load(opt)
    opt = opt or {}
    local rootdir = opt.rootdir or os.curdir()
    local config = defaults()

    -- merge the user config
    local userconfig = _loadfile(userfile())
    util.tmerge(config, userconfig)

    -- merge the project config
    local projectconfig = _loadfile(projectfile(rootdir))
    util.tmerge(config, projectconfig)

    -- merge the environment variables
    util.tmerge(config, _loadenvs())

    -- merge the command line options
    util.tmerge(config, opt.options or {})

    -- attach the runtime information
    config._rootdir = rootdir
    config._userfile = userfile()
    config._projectfile = projectfile(rootdir)
    return config
end

-- load the config from the given json file
function _loadfile(filepath)
    if not filepath or not os.isfile(filepath) then
        return {}
    end
    local result = try { function () return json.loadfile(filepath) end }
    if type(result) ~= "table" then
        utils.warning("harness: failed to load config file: %s", filepath)
        return {}
    end
    return result
end

-- load the config from the environment variables
--
-- e.g. XMAKE_HARNESS_PROVIDER, XMAKE_HARNESS_MODEL, XMAKE_HARNESS_APIKEY
--
function _loadenvs()
    local config = {}
    local provider = os.getenv("XMAKE_HARNESS_PROVIDER")
    if provider then
        config.provider = provider
    end
    local model = os.getenv("XMAKE_HARNESS_MODEL")
    if model then
        config.model = model
    end
    local smallmodel = os.getenv("XMAKE_HARNESS_SMALL_MODEL")
    if smallmodel then
        config.smallmodel = smallmodel
    end
    local apikey = os.getenv("XMAKE_HARNESS_APIKEY")
    if apikey then
        config.providers = config.providers or {}
        local name = config.provider or "deepseek"
        config.providers[name] = config.providers[name] or {}
        config.providers[name].apikey = apikey
    end
    return config
end

-- save the given key/value to the user config file
--
-- @param key       the dot-separated key, e.g. "providers.deepseek.apikey"
-- @param value     the value, nil to remove it
--
function set(key, value)
    local filepath = userfile()
    local config = _loadfile(filepath)
    util.tset(config, key, value)
    return save(config)
end

-- get the value from the user config file
function get(key)
    return util.tget(_loadfile(userfile()), key)
end

-- save the whole user configuration
function save(config)
    local filepath = userfile()
    os.mkdir(path.directory(filepath))
    config = table.clone(config or {}, 2)
    for k, _ in pairs(config) do
        if type(k) == "string" and k:startswith("_") then
            config[k] = nil
        end
    end
    json.savefile(filepath, config)
    return true
end

-- resolve the provider settings of the given configuration
--
-- @return  {name = "deepseek", kind = "openai", baseurl = "..", apikey = "..",
--           models = {main = "..", small = ".."}, contextsize = 131072}
--
function provider(config, name)
    name = name or config.provider or "deepseek"
    local preset = providers.preset(name) or {}
    local userset = (config.providers or {})[name] or {}
    local result = {}
    util.tmerge(result, preset)
    util.tmerge(result, userset)
    result.name = name
    result.kind = result.kind or "openai"
    result.models = result.models or {}

    -- resolve the api key, the environment variable is the last resort
    if not result.apikey and result.apikeyenv then
        result.apikey = os.getenv(result.apikeyenv)
    end

    -- the model overrides from the top-level configuration
    if config.model then
        result.models.main = config.model
    end
    if config.smallmodel then
        result.models.small = config.smallmodel
    end
    result.models.small = result.models.small or result.models.main
    result.contextsize = result.contextsize or 131072
    return result
end

-- get all the configured/available provider names
function providernames(config)
    local names = {}
    for name, _ in pairs(providers.presets()) do
        table.insert(names, name)
    end
    for name, _ in pairs(config.providers or {}) do
        table.insert(names, name)
    end
    names = util.unique(names)
    table.sort(names)
    return names
end
