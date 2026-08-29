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
-- @file        events.lua
--

--
-- the agent, as seen from a browser
--
-- the turn loop talks to whoever is watching through a set of callbacks — the
-- terminal draws them, and here they become json pushed down an event stream.
-- the harness itself does not know the difference, which is the whole reason a
-- second front end is a small piece of work rather than a fork.
--
-- what goes over the wire is **structured, not rendered**. the terminal turns a
-- tool result into a card of box characters because that is what a terminal
-- has; a browser has a document, and pre-rendering html here would hand it the
-- terminal's idea of a layout and take away its own. so a diff crosses as its
-- hunks, a todo list as its items, and the page decides what they look like.
--

-- imports
import("core.base.json")
import("harness.util.text")
import("harness.ui.dialog")
import("harness.web.html")

-- build the ui callbacks which feed one browser
--
-- @param push  push(name, payload) — one event to whoever is listening
--
function handlers(push)

    -- what has arrived of the answer being written, and how much of it has
    -- been rendered already, @see harness.web.html.complete
    local writing = {text = "", rendered = 0}

    return {
        on_step_start = function (info)
            push("step", {step = info.step, model = info.model})
        end,
        -- the deltas cross as plain text and the finished blocks cross as
        -- html, so an answer is formatted while it is still being written and
        -- only the tail — a sentence, at most — is unformatted
        on_text = function (delta)
            push("text", {delta = delta})
            writing.text = writing.text .. (delta or "")
            local upto = html.complete(writing.text)
            if upto > writing.rendered then
                writing.rendered = upto
                push("text.block", {html = html.render(writing.text:sub(1, upto)), upto = upto})
            end
        end,
        on_reasoning = function (delta)
            push("reasoning", {delta = delta})
        end,
        -- the finished message comes with its markdown rendered whole
        --
        -- the blocks were rendered as they were finished, but a message is
        -- rendered once more at the end: the tail which was still plain text
        -- belongs to it, and one render of the whole is the same document
        -- rather than a document assembled out of pieces
        on_assistant = function (event)
            writing.text = ""
            writing.rendered = 0
            push("assistant", {text = event.text or "", html = html.render(event.text or "")})
        end,
        on_tool_start = function (call)
            push("tool.start", {id = call.id, name = call.name})
        end,
        on_tool_result = function (result, call)
            push("tool.result", toolresult(result, call))
        end,
        on_usage = function (usage, total)
            push("usage", {turn = usage, total = total})
        end,
        on_retry = function (count)
            -- into the status and not the conversation, @see harness.core.agent
            push("retry", {count = count})
        end,

        -- a subagent works for minutes and used to say nothing at all while it
        -- did: what it is doing goes into the status line, and what it found
        -- comes back as the tool result like any other
        subagent = function (definition, opt)
            local label = (opt or {}).description
            label = (label and label ~= "" and label) or definition.name
            return {
                on_step_start = function (state)
                    push("agent", {agent = definition.name, label = label,
                                   step = state.step or 1})
                end,
                on_tool_start = function (call)
                    push("agent", {agent = definition.name, label = label,
                                   tool = call.name})
                end,
                on_retry = function (count)
                    push("agent", {agent = definition.name, label = label,
                                   retry = count})
                end
            }
        end,
        on_notice = function (text)
            push("notice", {text = text})
        end,
        on_error = function (text)
            push("error", {text = text})
        end,
        on_context = function (stats)
            push("context", stats)
        end,
        -- the permission mode changed under us: answering "accept all the file
        -- edits" is a mode change, and a page which went on showing the old one
        -- would be telling the user something which is no longer true
        on_mode = function (mode)
            push("mode", {mode = mode})
        end
    }
end

-- one tool result, in the shape a page can lay out
--
-- it is public because a logged tool event has the same shape as a live one and
-- has to reach the page looking the same: a conversation which was resumed
-- shows the cards it showed the first time round, @see harness.web.session
--
function toolresult(result, call)
    local display = result.display or {}
    local event = {
        id = result.id or (call or {}).id,
        name = result.name or (call or {}).name,
        iserror = result.iserror or false,
        title = display.title,
        subject = display.subject,
        summary = display.summary,
        kind = display.kind
    }
    if display.kind == "diff" and display.diff then
        event.diff = _diff(display)
    elseif display.kind == "todos" then
        event.todos = display.todos
    elseif display.kind == "output" then
        event.output = text.strip(display.output)
    elseif result.iserror then
        event.output = text.strip(result.output)
    end
    return event
end

-- a diff as its lines, each one saying what it is
--
-- the terminal paints them; the page may want to fold them, number them or hide
-- the unchanged ones, and it cannot do any of that with a picture
--
function _diff(display)
    local lines = {}
    for _, line in ipairs(display.diff or {}) do
        table.insert(lines, {kind = line.kind, text = line.text,
                             oldline = line.oldline, newline = line.newline})
    end
    return {filepath = display.filepath, lines = lines}
end

-- one event as a line of json
--
-- the stream carries one json object per event and nothing else: a browser
-- parses it in one call, and a field added later cannot break the parsing of
-- the fields already there
--
function encode(payload)
    local encoded, errors
    try {
        function ()
            encoded = json.encode(_wire(payload or {}, true))
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    if encoded then
        return encoded
    end

    -- something in there could not be written, and an empty answer would let
    -- the page draw an empty everything and say nothing about why. it says why
    -- the first line of it: the rest is a traceback through the encoder, which
    -- is for the log and not for a sentence in a page
    local reason = tostring(errors or "this could not be encoded"):split("\n", {plain = true})[1]
    return string.format("{\"errors\":%s}", json.encode(reason))
end

-- an empty list is still a list
--
-- lua has one table type where json has two, so a conversation with no messages
-- in it crosses as `{}` and reaches the page as an object. `for (const m of {})`
-- is a TypeError, and one of those in the middle of drawing the page takes the
-- rest of the page with it — which is exactly how a working harness ends up
-- looking like one which answers nothing.
--
-- so every table which could be a list is marked as one on its way out. it is
-- done here, at the one place where lua tables become json, rather than at each
-- of the twenty places which build them: the next list somebody adds is right
-- without having to know about this.
--
function _wire(value, isroot)
    if type(value) ~= "table" then
        return value
    end
    local count = 0
    local highest = 0
    local keyed = false
    for key, item in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            keyed = true
        elseif key > highest then
            highest = key
        end
        value[key] = _wire(item)
    end

    -- a list is 1..n with nothing missing, and anything else is a map
    --
    -- a table keyed by line numbers has none of the keys json needs for an
    -- array, and calling it one makes the encoder refuse to write it at all —
    -- "excessively sparse array" — which used to come back as an empty answer
    --
    -- the root of an event is an object even when it is empty: `ping` carries
    -- nothing, and nothing is `{}` rather than `[]`
    if not keyed and highest == count and (count > 0 or not isroot) then
        json.mark_as_array(value)
    end
    return value
end

-- a question a command asks, as the page has to draw it
--
-- the terminal renders the request's `lines` itself and they may carry its
-- escape codes, so they are stripped: a browser is not a terminal and an escape
-- code in a document is noise at best
--
function question(id, request, options)
    local payload = {
        id = id,
        question = request.question or "?",
        subtitle = request.footer,
        options = {}
    }
    local lines = {}
    for _, line in ipairs(request.lines or {}) do
        table.insert(lines, text.strip(tostring(line)))
    end
    if #lines > 0 then
        payload.title = table.concat(lines, "\n")
    end
    for index, option in ipairs(options or {}) do
        table.insert(payload.options, {text = text.strip(tostring(option.text or "?")),
                                       value = tostring(index)})
    end
    return payload
end

-- one confirmation, as the page has to draw it
--
-- the wording is the terminal's, @see harness.ui.dialog.confirminfo: a
-- confirmation which said one thing in a terminal and another in a browser
-- would be two policies wearing one name. what differs is only the shape — the
-- terminal gets lines it can paint, the page gets the parts and lays them out.
--
function ask(id, request)
    local tool = request.tool or {}
    local info = dialog.confirminfo(tool, request.args or {})
    local payload = {
        id = id,
        title = info.title,
        subtitle = info.subtitle,
        question = info.question,
        reason = request.reason,
        options = {{text = "Yes", value = "allow"}}
    }
    if info.alwaystext then
        table.insert(payload.options, {text = info.alwaystext, value = "always"})
    end
    table.insert(payload.options, {text = "No, and tell the model what to do differently",
                                   value = "deny"})

    -- an edit is judged by its diff and nothing else, so it crosses whole
    local preview = request.preview
    if preview and preview.kind == "diff" then
        payload.diff = _diff({filepath = preview.filepath, diff = preview.diff})
    end
    return payload
end
