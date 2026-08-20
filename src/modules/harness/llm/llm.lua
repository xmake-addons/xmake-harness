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
-- @file        llm.lua
--

--
-- the llm seam
--
-- every provider implements the same three interfaces:
--
--   buildrequest(provider, req)  -> {url = .., headers = .., body = ..}
--   parsechunk(state, obj)       -> the normalized streaming events
--   parseresponse(obj)           -> the normalized result
--
-- so a new llm service is added by dropping a new module into `llm/providers`,
-- no other part of the harness needs to know about it.
--

-- imports
import("core.base.json")
import("harness.llm.transport")

-- get the provider module of the given kind
--
-- it is resolved dynamically, so a new provider is plugged in by only dropping
-- a new module into `harness/llm/providers/<kind>.lua`
--
function provider_module(kind)
    kind = kind or "openai"
    local module = import("harness.llm.providers." .. kind, {anonymous = true, try = true})
    if not module then
        module = import("harness.llm.providers.openai", {anonymous = true})
    end
    return module
end

-- complete the given request
--
-- @param provider  the provider settings, e.g. {kind = "openai", baseurl = "..", apikey = ".."}
-- @param req       the request, e.g. {model = "..", system = "..", messages = {..}, tools = {..}}
-- @param handlers  the streaming handlers
--                  - ontext(text)          the assistant text delta
--                  - onreasoning(text)     the reasoning/thinking delta
--                  - ontoolcall(event)     the tool call events
--                  - onusage(usage)        the token usage
--                  - ontick()              return false to abort the request
--
-- @return          {content = "..", reasoning = "..", toolcalls = {..}, usage = {..},
--                   finishreason = "..", aborted = false, errors = nil}
--
function complete(provider, req, handlers)
    handlers = handlers or {}
    local module = provider_module(provider.kind)
    if not provider.apikey or provider.apikey == "" then
        local name = provider.name or provider.kind
        return {errors = string.format("the api key of the provider(%s) is not configured!\n"
            .. "set it with `xmake ai --apikey=<your key>`, or `/config providers.%s.apikey <your key>` in the tui.",
            name, name)}
    end

    local request = module.buildrequest(provider, req)
    local body = json.encode(request.body)

    -- the streams do get cut and the servers do throttle, so the transport
    -- errors are retried before we give up
    local maxretries = provider.retries or 2
    local retried = 0
    local state, result, response
    while true do
        state = {}
        result = {content = "", reasoning = "", toolcalls = {}, usage = nil}
        response = _post(module, provider, request, body, state, result, req, handlers)
        if response.aborted or not _shouldretry(response, result) or retried >= maxretries then
            break
        end
        retried = retried + 1
        if handlers.onretry then
            handlers.onretry(retried, response)
        end
        os.sleep(500 * retried)
    end

    if response.aborted then
        result.aborted = true
        result.usage = result.usage or state.usage
        return result
    end
    result = _finish(module, response, req, state, result, handlers)
    result.retried = retried > 0 and retried or nil
    return result
end

-- send one request and stream it
function _post(module, provider, request, body, state, result, req, handlers)
    return transport.post({
        url = request.url,
        headers = request.headers,
        body = body,
        timeout = provider.timeout,
        proxy = provider.proxy,
        insecure = provider.insecure
    }, {
        online = function (line)
            if not req.stream then
                return
            end
            _onssline(module, state, result, line, handlers)
        end,
        ontick = handlers.ontick
    })
end


-- should the request be retried?
function _shouldretry(response, result)
    if result.content ~= "" or (result.toolcalls and #result.toolcalls > 0) then
        return false
    end
    if response.status == 0 then
        return true
    end
    return response.status == 429 or response.status >= 500
end

-- handle the finished response
function _finish(module, response, req, state, result, handlers)

    -- the non-streaming mode, or an error response
    if not req.stream or (response.status ~= 0 and response.status ~= 200) then
        local obj = _decode(response.body)
        if response.status ~= 200 and response.status ~= 0 then
            local errors = obj and module.parseerror(obj)
            result.errors = string.format("http %d: %s", response.status, errors or _summary(response.body) or response.stderr or "request failed")
            return result
        end
        if not obj then
            result.errors = response.stderr or _summary(response.body) or "invalid response"
            return result
        end
        local parsed = module.parseresponse(obj)
        result.content = parsed.content or ""
        result.reasoning = parsed.reasoning or ""
        result.toolcalls = parsed.toolcalls or {}
        result.usage = parsed.usage
        result.finishreason = parsed.finishreason
        if handlers.ontext and result.content ~= "" then
            handlers.ontext(result.content)
        end
        if handlers.onusage and result.usage then
            handlers.onusage(result.usage)
        end
        return result
    end

    -- collect the streaming tool calls
    result.toolcalls = _collect_toolcalls(state)
    result.usage = result.usage or state.usage
    if result.content == "" and #result.toolcalls == 0 and not result.errors then
        local obj = _decode(response.body)
        local errors = obj and module.parseerror(obj)
        if errors then
            result.errors = errors
        elseif response.errors then
            result.errors = response.errors
        elseif response.stderr and response.stderr ~= "" then
            result.errors = response.stderr
        else
            result.errors = string.format("the model returned an empty response (http %d), please retry.", response.status)
        end
    end
    return result
end

-- handle one server-sent-event line
function _onssline(module, state, result, line, handlers)
    if line == "" or line:startswith(":") then
        return
    end
    if line:startswith("event:") then
        state.event = line:sub(7):trim()
        return
    end
    if not line:startswith("data:") then
        return
    end
    local data = line:sub(6):trim()
    if data == "[DONE]" then
        state.done = true
        return
    end
    local obj = _decode(data)
    if not obj then
        return
    end
    for _, event in ipairs(module.parsechunk(state, obj)) do
        if event.kind == "text" then
            result.content = result.content .. event.text
            if handlers.ontext then
                handlers.ontext(event.text)
            end
        elseif event.kind == "reasoning" then
            result.reasoning = result.reasoning .. event.text
            if handlers.onreasoning then
                handlers.onreasoning(event.text)
            end
        elseif event.kind == "usage" then
            state.usage = event.usage
            result.usage = event.usage
            if handlers.onusage then
                handlers.onusage(event.usage)
            end
        elseif event.kind == "finish" then
            result.finishreason = event.reason
        elseif event.kind == "error" then
            result.errors = event.message
        elseif handlers.ontoolcall then
            handlers.ontoolcall(event)
        end
    end
end

-- collect the tool calls from the streaming state
function _collect_toolcalls(state)
    local toolcalls = {}
    local indexes = {}
    for index, _ in pairs(state.toolcalls or {}) do
        table.insert(indexes, index)
    end
    table.sort(indexes)
    for _, index in ipairs(indexes) do
        local item = state.toolcalls[index]
        if item.name and item.name ~= "" then
            table.insert(toolcalls, {
                index = index,
                id = item.id or string.format("call_%d", index),
                name = item.name,
                arguments_text = item.arguments_text
            })
        end
    end
    return toolcalls
end

-- decode the json text safely
function _decode(text)
    if not text or text == "" then
        return nil
    end
    local obj = try { function () return json.decode(text) end }
    if type(obj) == "table" then
        return obj
    end
    return nil
end

-- get the short summary of the raw body for the error reporting
function _summary(body)
    if not body or body == "" then
        return nil
    end
    body = body:trim()
    if #body > 500 then
        body = body:sub(1, 500) .. ".."
    end
    return body
end

-- decode the arguments of the given tool call
function decode_arguments(toolcall)
    if toolcall.arguments then
        return toolcall.arguments
    end
    local text = toolcall.arguments_text
    if not text or text:trim() == "" then
        return {}
    end
    local obj = try { function () return json.decode(text) end }
    if type(obj) == "table" then
        return obj
    end
    return nil, string.format("invalid tool arguments: %s", text)
end
