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
-- @file        context.lua
--

--
-- the harness context
--
-- it is the shared runtime of one harness instance: the configuration, the
-- registries(tools/skills/agents/commands), the seams(sandbox/permission) and
-- the event bus.
--
-- everything else is a plugin which registers itself on the context, so the
-- harness has no privileged core: a plugin can add tools, skills, agents,
-- commands, prompt sections, llm providers and event listeners.
--

-- imports
import("core.base.object")

-- define the context class
local context = context or object {_init = {"_config", "_events", "_services"}}

-- create a new context
function new(config)
    local instance = context {config or {}, {}, {}}
    instance._rootdir = config and config._rootdir or os.curdir()
    return instance
end

-- get the configuration
function context:config()
    return self._config
end

-- get the project root directory
function context:rootdir()
    return self._rootdir
end

-- set the project root directory
function context:rootdir_set(rootdir)
    self._rootdir = rootdir
end

-- get/set a service, e.g. ctx:service("tools"), ctx:service("tools", registry)
function context:service(name, instance)
    if instance ~= nil then
        self._services[name] = instance
        return instance
    end
    return self._services[name]
end

-- get all the service names
function context:services()
    local names = {}
    for name, _ in pairs(self._services) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- register an event listener
--
-- @param name      the event name, e.g. "tool/pre-execute"
-- @param listener  the listener function
-- @param opt       the options, e.g. {prepend = true, owner = "xmake"}
--
function context:on(name, listener, opt)
    opt = opt or {}
    local listeners = self._events[name]
    if not listeners then
        listeners = {}
        self._events[name] = listeners
    end
    local item = {listener = listener, owner = opt.owner}
    if opt.prepend then
        table.insert(listeners, 1, item)
    else
        table.insert(listeners, item)
    end
    return self
end

-- emit an event to all the listeners, the return values are ignored
function context:emit(name, ...)
    for _, item in ipairs(self._events[name] or {}) do
        item.listener(...)
    end
end

-- emit an event and stop at the first non-nil result
function context:bail(name, ...)
    for _, item in ipairs(self._events[name] or {}) do
        local result = item.listener(...)
        if result ~= nil then
            return result
        end
    end
end

-- emit a waterfall event, every listener may rewrite the value
--
-- @param name      the event name
-- @param value     the value passed through the listeners
-- @return          the rewritten value
--
function context:waterfall(name, value, ...)
    for _, item in ipairs(self._events[name] or {}) do
        local result = item.listener(value, ...)
        if result ~= nil then
            value = result
        end
    end
    return value
end

-- remove all the listeners of the given owner
function context:off(owner)
    for name, listeners in pairs(self._events) do
        local results = {}
        for _, item in ipairs(listeners) do
            if item.owner ~= owner then
                table.insert(results, item)
            end
        end
        self._events[name] = results
    end
end

-- get the event names
function context:eventnames()
    local names = {}
    for name, _ in pairs(self._events) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end
