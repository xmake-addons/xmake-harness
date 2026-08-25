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
-- @file        settings.lua
--

--
-- the settings a browser may change
--
-- not every key in the configuration: an allow list, in groups, each field
-- saying what it is. a settings page which offered the whole tree would be a
-- config file with worse ergonomics, and one which offered `permission.mode`
-- next to `ui.theme` would invite somebody to turn the safety off by accident.
--
-- a key is never sent back once it is set. the page shows that one is there and
-- lets it be replaced — which is all somebody needs to know, and the one thing
-- an open tab should not be able to read out.
--

-- imports
import("harness.config.config")

-- what the page may set, and how to describe it
local GROUPS = {
    {
        key = "provider",
        title = "Model",
        hint = "The service the agent talks to, and which model it uses for what.",
        fields = {
            {key = "provider", label = "Provider", choices = true},
            {key = "model", label = "Main model", placeholder = "the provider's default"},
            {key = "smallmodel", label = "Small model",
             hint = "titles, summaries and the light subagents"}
        }
    },
    {
        key = "keys",
        title = "API keys",
        hint = "Saved to your home directory, never to the project.",
        fields = {}
    },
    {
        key = "behaviour",
        title = "Behaviour",
        fields = {
            {key = "permission.mode", label = "Permission mode",
             choices = {"default", "acceptedits", "plan", "bypass"},
             hint = "what the agent may do without asking"},
            {key = "context.mode", label = "Context", choices = {"auto", "full"},
             hint = "auto prunes and compacts as the window fills"},
            {key = "ui.difflines", label = "Diff lines", hint = "how much of a diff to show"}
        }
    }
}

-- everything the settings page draws itself from
function describe(harness)
    local harnessconfig = harness:config()
    local groups = {}
    for _, group in ipairs(GROUPS) do
        local fields = {}
        if group.key == "keys" then
            fields = _keyfields(harnessconfig)
        else
            for _, field in ipairs(group.fields) do
                table.insert(fields, _field(harnessconfig, field))
            end
        end
        table.insert(groups, {title = group.title, hint = group.hint, fields = fields})
    end
    return {groups = groups}
end

-- one field, with what it currently holds
function _field(harnessconfig, field)
    local entry = {key = field.key, label = field.label, hint = field.hint,
                   placeholder = field.placeholder}
    if field.choices == true then
        entry.choices = config.providernames(harnessconfig)
    elseif field.choices then
        entry.choices = field.choices
    end
    entry.value = tostring(_get(harnessconfig, field.key) or "")
    return entry
end

-- one field per provider, for its key
--
-- what comes back is whether there is one, never what it is
--
function _keyfields(harnessconfig)
    local fields = {}
    for _, name in ipairs(config.providernames(harnessconfig)) do
        local provider = config.provider(harnessconfig, name)
        local set = provider.apikey and provider.apikey ~= ""
        table.insert(fields, {
            key = string.format("providers.%s.apikey", name),
            label = provider.title or name,
            secret = true,
            value = "",
            placeholder = set and "configured — type to replace" or "not configured",
            hint = provider.apikeyurl
        })
    end
    return fields
end

-- read a dotted key out of the resolved configuration
function _get(harnessconfig, key)
    local node = harnessconfig
    for part in key:gmatch("[^%.]+") do
        if type(node) ~= "table" then
            return nil
        end
        node = node[part]
    end
    return node
end

-- change one setting
--
-- @return  true, or nil and the reason
--
function set(harness, key, value)
    if not _allowed(key) then
        return nil, string.format("`%s` is not a setting this page may change", tostring(key))
    end
    -- an empty secret means "leave it alone": the page sends every field back
    -- when one of them changes, and a blank key box must not wipe a real key
    if key:endswith(".apikey") and (value == nil or value == "") then
        return true
    end
    config.set(key, value)
    return true
end

-- is this one of ours?
function _allowed(key)
    if type(key) ~= "string" then
        return false
    end
    if key:match("^providers%.[%w_%-]+%.apikey$") then
        return true
    end
    for _, group in ipairs(GROUPS) do
        for _, field in ipairs(group.fields) do
            if field.key == key then
                return true
            end
        end
    end
    return false
end
