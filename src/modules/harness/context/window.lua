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
-- @file        window.lua
--

--
-- the context window
--
-- the session log is never lossy: it keeps every event exactly as it happened.
-- what the model sees is a *projection* of that log, and this module is where
-- the projection is optimized so a long session keeps working:
--
--   1. the tool outputs of the old steps are pruned to a short placeholder
--      (the microcompaction, it is reversible: the log still has them)
--   2. the repeated reads of the same file keep only the last content
--   3. when even that is not enough, `context/compact` replaces the history
--      with a summary
--
-- the modes:
--
--   auto    prune and compact automatically (the default)
--   full    never touch the projection, the whole history goes to the model
--
-- `/context` renders the breakdown this module computes.
--

-- imports
import("harness.util.util")
import("harness.util.tokens")
import("harness.config.config")

-- get the context limit of the current provider
function limit(harness)
    local provider = config.provider(harness:config())
    return provider.contextsize or 131072
end

-- get the context settings
function settings(harness)
    local defaults = {
        mode = "auto",
        threshold = 0.82,
        hardthreshold = 0.92,
        prunethreshold = 0.55,
        keeprecent = 6,
        keepresults = 8,
        keepminimum = 4,
        toolresultlimit = 1200,
        hardresultlimit = 600
    }
    util.tmerge(defaults, harness:config().context or {})
    return defaults
end

-- optimize the projected messages
--
-- @param harness   the harness context
-- @param session   the session
-- @param messages  the projected messages, @see session:messages()
-- @return          the optimized messages and the stats
--
function optimize(harness, session, messages)
    local config = settings(harness)
    local stats = {pruned = 0, prunedtokens = 0, deduped = 0}
    if config.mode == "full" then
        return messages, stats
    end

    local used = tokens.calibrated(messages, _model(harness))
    local ratio = used / limit(harness)
    if ratio < config.prunethreshold then
        return _enforce(harness, messages, stats, config)
    end

    -- find the boundary: the recent messages are always kept intact
    local boundary = _boundary(messages, config.keeprecent)

    -- the last read of every file wins, the older ones are dropped
    local lastread = {}
    for idx = #messages, 1, -1 do
        local message = messages[idx]
        if message.role == "tool" and message.toolname == "read_file" and message.toolpath then
            if lastread[message.toolpath] then
                message._superseded = true
            else
                lastread[message.toolpath] = idx
            end
        end
    end

    local results = {}
    for idx, message in ipairs(messages) do
        if idx <= boundary and message.role == "tool" then
            local content = message.content or ""
            local keepintact = (#messages - idx) < config.keepresults
            if message._superseded and not keepintact then
                stats.deduped = stats.deduped + 1
                stats.prunedtokens = stats.prunedtokens + tokens.estimate(content)
                message = _placeholder(message, "it was read again later, the newer content is below")
            elseif #content > config.toolresultlimit and not keepintact then
                stats.pruned = stats.pruned + 1
                stats.prunedtokens = stats.prunedtokens + tokens.estimate(content) - 20
                message = _placeholder(message, string.format("%d bytes, it is out of the recent context", #content))
            end
        end
        message._superseded = nil
        table.insert(results, message)
    end
    results, stats = _enforce(harness, results, stats, config)
    stats.used = tokens.calibrated(results, _model(harness))
    return results, stats
end

-- the hard backstop
--
-- the pruning above is polite: it keeps the recent turns whole and stops when
-- it has done enough. that is not always enough — a single step can bring back
-- a huge tool output, and a request over the window is a hard error from the
-- provider, not a degraded answer.
--
-- so once we are over the hard limit we stop being polite: every tool result is
-- cut down, and if that still does not fit we drop whole turns from the front
-- until it does. losing the oldest turns beats failing the request.
--
function _enforce(harness, messages, stats, config)
    local model = _model(harness)
    local hard = math.floor(limit(harness) * (config.hardthreshold or 0.92))
    if tokens.calibrated(messages, model) <= hard then
        return messages, stats
    end

    -- every tool result, recent ones included
    local results = {}
    for _, message in ipairs(messages) do
        if message.role == "tool" and #(message.content or "") > (config.hardresultlimit or 600) then
            message = _placeholder(message, string.format("%d bytes, the context is full", #message.content))
            stats.pruned = stats.pruned + 1
        end
        table.insert(results, message)
    end
    if tokens.calibrated(results, model) <= hard then
        stats.enforced = true
        return results, stats
    end

    -- still too big: drop from the front, one whole turn at a time
    local keepminimum = config.keepminimum or 4
    while tokens.calibrated(results, model) > hard and #results > keepminimum do
        local dropped = _droptoturn(results)
        if dropped == 0 then
            break
        end
        stats.dropped = (stats.dropped or 0) + dropped
    end
    stats.enforced = true
    return results, stats
end

-- drop the first turn of the projection
--
-- a turn starts at a user message and owns everything until the next one, so
-- the assistant messages never lose the tool results they belong to
--
-- @return  how many messages went away
--
function _droptoturn(messages)
    local boundary = nil
    for idx = 2, #messages do
        if messages[idx].role == "user" then
            boundary = idx
            break
        end
    end
    boundary = boundary or 2
    local count = boundary - 1
    for _ = 1, count do
        table.remove(messages, 1)
    end
    return count
end

-- the model of this session, the calibration is per model
function _model(harness)
    local provider = config.provider(harness:config())
    return (provider.models or {}).main or "unknown"
end

-- replace a tool result with a short placeholder
function _placeholder(message, reason)
    local result = table.clone(message, 1)
    result.content = string.format("[the output of `%s` was dropped to save the context: %s. "
        .. "run it again if you still need it.]", message.toolname or "the tool", reason)
    return result
end

-- get the index below which the messages may be pruned
function _boundary(messages, keeprecent)
    local turns = 0
    for idx = #messages, 1, -1 do
        if messages[idx].role == "user" then
            turns = turns + 1
            if turns >= keeprecent then
                return idx - 1
            end
        end
    end
    return 0
end

-- compute the breakdown of the context window
--
-- @return  {limit = .., total = .., ratio = .., sections = {{name = .., tokens = ..}}}
--
function breakdown(harness, session, opt)
    opt = opt or {}
    local sections = {}
    local prompt = opt.prompt
    if not prompt then
        local system = import("harness.prompt.system", {anonymous = true})
        prompt = system.build(harness, {mode = opt.mode, session = session})
    end
    local schemas = harness:service("tools"):schemas({})
    local messages = opt.messages or session:messages()
    local optimized, stats = optimize(harness, session, messages)

    table.insert(sections, {name = "system prompt", tokens = tokens.estimate(prompt), style = "md.h2"})
    table.insert(sections, {name = "tool schemas", tokens = tokens.estimate_tools(schemas), style = "code.func"})

    local usertokens, assistanttokens, tooltokens = 0, 0, 0
    for _, message in ipairs(optimized) do
        local count = tokens.estimate_message(message)
        if message.role == "user" then
            usertokens = usertokens + count
        elseif message.role == "tool" then
            tooltokens = tooltokens + count
        else
            assistanttokens = assistanttokens + count
        end
    end
    table.insert(sections, {name = "your messages", tokens = usertokens, style = "user.text"})
    table.insert(sections, {name = "model replies", tokens = assistanttokens, style = "assistant.bullet"})
    table.insert(sections, {name = "tool results", tokens = tooltokens, style = "tool.result"})

    local total = 0
    for _, section in ipairs(sections) do
        total = total + section.tokens
    end
    local contextlimit = limit(harness)
    return {
        limit = contextlimit,
        total = total,
        ratio = total / contextlimit,
        sections = sections,
        stats = stats,
        mode = settings(harness).mode,
        compacted = _compactcount(session)
    }
end

-- count the compactions of the session
function _compactcount(session)
    local count = 0
    for _, event in ipairs(session:events()) do
        if event.kind == "compact" then
            count = count + 1
        end
    end
    return count
end

-- render the breakdown to the terminal lines
function render(result, opt)
    opt = opt or {}
    local theme = import("harness.ui.theme", {anonymous = true})
    local text = import("harness.util.text", {anonymous = true})
    local width = math.min(opt.width or 80, 72)
    local barwidth = width - 12
    local lines = {}

    -- the usage bar, every section gets its share
    local bar = {}
    local filled = 0
    for _, section in ipairs(result.sections) do
        local blocks = math.floor(section.tokens / result.limit * barwidth + 0.5)
        if blocks > 0 then
            table.insert(bar, theme.styled(section.style or "text", string.rep("█", blocks)))
            filled = filled + blocks
        end
    end
    table.insert(bar, theme.styled("dim", string.rep("░", math.max(0, barwidth - filled))))
    table.insert(lines, table.concat(bar) .. string.format("  %.0f%%", result.ratio * 100))
    table.insert(lines, "")

    for _, section in ipairs(result.sections) do
        if section.tokens > 0 then
            table.insert(lines, string.format("  %s %s %s",
                theme.styled(section.style or "text", "█"),
                text.pad(section.name, 16),
                text.pad(util.count(section.tokens), 8, "right")))
        end
    end
    table.insert(lines, "")
    table.insert(lines, string.format("  %s of %s tokens · mode: %s",
        util.count(result.total), util.count(result.limit), result.mode))
    if result.stats and (result.stats.pruned > 0 or result.stats.deduped > 0) then
        table.insert(lines, string.format("  %d old tool results pruned, %d superseded reads dropped (~%s tokens saved)",
            result.stats.pruned, result.stats.deduped, util.count(result.stats.prunedtokens)))
    end
    if result.compacted > 0 then
        table.insert(lines, string.format("  the conversation was compacted %d time%s",
            result.compacted, result.compacted == 1 and "" or "s"))
    end
    return lines
end
