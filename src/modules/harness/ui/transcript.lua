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
-- @file        transcript.lua
--

--
-- the transcript
--
-- it renders the permanent part of the screen: the welcome panel, the user
-- messages, the assistant messages and the tool cards. every line it returns is
-- printed once and never touched again, so the scrollback keeps the whole
-- conversation.
--

-- imports
import("core.base.tty")
import("core.base.colors")
import("harness.util.util")
import("harness.util.text")
import("harness.ui.diff")
import("harness.ui.theme")
import("harness.ui.markdown")

-- the xmake logo, it is the one of the xmake cli
function _logo()
    return {
        [[                         _                  ]],
        [[    __  ___ __  __  __ _| | ______          ]],
        [[    \ \/ / |  \/  |/ _  | |/ / __ \         ]],
        [[     >  <  | \__/ | /_| |   <  ___/         ]],
        [[    /_/\_\_|_|  |_|\__ \|_|\_\____|        ]],
        [[                         by ruki, xmake.io  ]]
    }
end

-- colorize one line with the xmake rainbow
function _rainbow(str, seed)
    if theme.isplain() then
        return str
    end
    local results = {}
    local index = 0
    str:gsub(".", function (ch)
        local code = tty.has_color24() and colors.rainbow24(index, seed) or colors.rainbow256(index, seed)
        table.insert(results, colors.translate(string.format("${bright %s}", code), {patch_reset = false}) .. ch)
        index = index + 1
    end)
    return table.concat(results) .. theme.reset()
end

-- render the welcome panel
--
-- @param opt   {provider = .., rootdir = .., skills = 12, tools = 19,
--               session = .., notices = {..}, width = 100}
--
function banner(opt)
    local lines = {""}
    for idx, line in ipairs(_logo()) do
        table.insert(lines, _rainbow(line:rtrim(), 236 + idx * 2))
    end
    table.insert(lines, "")

    local function _info(name, value, dim)
        return theme.styled("dim", "    " .. text.pad(name .. ":", 9))
            .. (dim and theme.styled("dim", value) or theme.styled("text", value))
    end
    local provider = opt.provider
    table.insert(lines, _info("model", provider.models.main or "?")
        .. theme.styled("dim", string.format("  (%s · small: %s)", provider.name, provider.models.small or "?")))
    table.insert(lines, _info("cwd", text.truncate(opt.rootdir, (opt.width or 100) - 18)))
    table.insert(lines, _info("loaded", table.concat(opt.loaded or {}, " · "), true))
    table.insert(lines, "")

    for _, notice in ipairs(opt.notices or {}) do
        table.insert(lines, theme.styled("notice", "    ! " .. notice))
    end
    table.insert(lines, theme.styled("hint", "    /help for the commands · @ to attach a file · ! to run a shell command"))
    table.insert(lines, theme.styled("hint", "    esc interrupts · shift+tab cycles the permission mode"))
    table.insert(lines, "")
    return lines
end

-- render a user message
function user(message, width)
    local lines = {}
    for idx, line in ipairs(text.wrap(message, width - 4)) do
        table.insert(lines, theme.styled("user.bullet", idx == 1 and "› " or "  ") .. theme.styled("user.text", line))
    end
    table.insert(lines, "")
    return lines
end

-- render an assistant message which was not streamed
function assistant(content, width)
    if not content or content:trim() == "" then
        return {}
    end
    local lines = {}
    for idx, line in ipairs(markdown.render(content, {width = width - 2})) do
        table.insert(lines, (idx == 1 and theme.styled("assistant.bullet", "● ") or "  ") .. line)
    end
    table.insert(lines, "")
    return lines
end

-- render one streamed line of an assistant message
--
-- @param first is it the first line of the message? it gets the bullet
--
function assistantline(line, first)
    return (first and theme.styled("assistant.bullet", "● ") or "  ") .. line
end

-- render a tool card
--
-- @param result    the tool result
-- @param opt       {title = "xmake run", width = 100, difflines = 40}
--
function tool(result, opt)
    local width = opt.width or 100
    local display = result.display or {}
    local lines = {_toolheader(result, opt.title or display.title, display.subject, width)}
    if result.iserror then
        _toolerror(lines, result, width)
    else
        if display.summary then
            table.insert(lines, theme.styled("tool.result", "  └ " .. display.summary))
        end
        _toolbody(lines, display, width, opt.difflines)
    end
    table.insert(lines, "")
    return lines
end

-- render the header line of a tool card
function _toolheader(result, title, subject, width)
    local bullet = theme.styled(result.iserror and "tool.error" or "tool.bullet", "● ")
    local header = bullet .. theme.styled("tool.name", title)
    if subject then
        header = header .. theme.styled("tool.args", "(" .. text.truncate(subject, width - #title - 8) .. ")")
    end
    return header
end

-- render the message of a failed tool call
function _toolerror(lines, result, width)
    local outputlines = text.lines(result.output or "")
    for idx = 1, math.min(#outputlines, 6) do
        table.insert(lines, theme.styled("tool.error",
            (idx == 1 and "  └ " or "    ") .. text.truncate(outputlines[idx], width - 6)))
    end
end

-- render what the tool produced, the shape depends on its display kind
function _toolbody(lines, display, width, difflines)
    if display.kind == "diff" and display.diff then
        for _, line in ipairs(diff.render(display.diff, {width = width - 4,
                filepath = display.filepath, maxlines = difflines or 40})) do
            table.insert(lines, "    " .. line)
        end
    elseif display.kind == "output" and display.output then
        local outputlines = text.lines(display.output)
        local maxlines = 8
        for idx = 1, math.min(#outputlines, maxlines) do
            table.insert(lines, theme.styled("tool.result", "    " .. text.truncate(outputlines[idx], width - 6)))
        end
        if #outputlines > maxlines then
            table.insert(lines, theme.styled("dim", string.format("    … +%d lines", #outputlines - maxlines)))
        end
    elseif display.kind == "todos" and display.todos then
        for _, todo in ipairs(display.todos) do
            local marker = todo.status == "completed" and "✔" or (todo.status == "in_progress" and "▸" or "○")
            local style = todo.status == "completed" and "dim" or (todo.status == "in_progress" and "success" or "text")
            table.insert(lines, "    " .. theme.styled(style, marker .. " " .. todo.content))
        end
    end
end

-- render the usage line which closes a turn
function usage(result, elapsed)
    local usage = result.usage
    if not usage then
        return {}
    end
    local total = usage.input + usage.output
    if total <= 0 then
        return {}
    end
    local rate = nil
    if (usage.cachehit or 0) + (usage.cachemiss or 0) > 0 then
        rate = usage.cachehit / (usage.cachehit + usage.cachemiss)
    end
    return {theme.styled("dim", string.format("  %s tokens (↑ %s · ↓ %s%s) · %s · %d step%s",
        util.count(total), util.count(usage.input), util.count(usage.output),
        rate and string.format(" · cache %.0f%%", rate * 100) or "",
        util.duration(elapsed), result.steps, result.steps == 1 and "" or "s")), ""}
end
