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
-- @file        app.lua
--

--
-- the terminal application
--
-- the screen is split in two parts:
--
--   the transcript   printed to the stdout and never touched again, so the
--                    terminal scrollback keeps the whole conversation
--   the live region  the last few lines: the streaming tail, the status line,
--                    the input box and the hints, they are erased and redrawn
--
-- this is why the ui feels like claude code but still works in any terminal:
-- we never enter the alternate screen and we never repaint the history.
--

-- imports
import("core.base.object")
import("core.base.tty")
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.diff")
import("harness.ui.editor")
import("harness.ui.markdown")
import("harness.ui.terminal")
import("harness.core.agent")
import("harness.config.config")
import("harness.context.compact")
import("harness.permission.policy")
import("harness.core.session", {alias = "sessions"})

-- the spinner frames and the working words
local SPINNERS = {
    dots = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
    star = {"✻", "✽", "✻", "✢", "·", "✢"},
    line = {"|", "/", "-", "\\"}
}
local WORDS = {"Thinking", "Working", "Harmonizing", "Pondering", "Digging", "Composing",
               "Assembling", "Tinkering", "Wrangling", "Reticulating"}

-- define the application class
local app = app or object {_init = {"harness", "session", "mode", "editor", "signal"}}

-- create a new application
function new(harness, opt)
    opt = opt or {}
    local instance = app {harness, opt.session, opt.mode or (harness:config().permission or {}).mode or "default",
                          editor.new(), {aborted = false}}
    instance._livelines = 0
    instance._cursorup = 0
    instance._state = "idle"
    instance._streambuf = ""
    instance._mdstate = markdown.newstate()
    instance._wordidx = 1
    instance._spinneridx = 1
    instance._tokens = 0
    instance._running = true
    instance._historyfile = path.join(config.homedir(), "history.txt")
    if not instance.session then
        instance.session = sessions.new({cwd = harness:rootdir()})
    end
    instance:_loadhistory()
    return instance
end

-- get the terminal width
function app:width()
    return math.max(40, terminal.size().width)
end

--------------------------------------------------------------------------------
-- the live region
--------------------------------------------------------------------------------

-- erase the live region
function app:_erase()
    if self._livelines <= 0 then
        return
    end
    if self._cursorup > 0 then
        tty.cursor_move_down(self._cursorup)
        self._cursorup = 0
    end
    tty.cr()
    tty.cursor_move_up(self._livelines)
    tty.erase_down()
    self._livelines = 0
end

-- draw the live region
function app:_draw(lines, cursorrow, cursorcol)
    tty.cursor_hide()
    for _, line in ipairs(lines) do
        terminal.write(line .. theme.reset() .. "\n")
    end
    self._livelines = #lines
    self._cursorup = 0
    if cursorrow then
        local up = #lines - cursorrow + 1
        if up > 0 then
            tty.cursor_move_up(up)
        end
        tty.cursor_move_to_col((cursorcol or 0) + 1)
        self._cursorup = up
        tty.cursor_show()
    end
    terminal.flush()
end

-- redraw the live region
function app:refresh()
    if not io.isatty() then
        return
    end
    self:_erase()
    local lines, cursorrow, cursorcol = self:_livelines_build()
    self:_draw(lines, cursorrow, cursorcol)
end

-- print the permanent lines into the transcript
function app:print(lines)
    if type(lines) == "string" then
        lines = text.lines(lines)
    end
    self:_erase()
    for _, line in ipairs(lines) do
        terminal.write(line .. theme.reset() .. "\n")
    end
    terminal.flush()
end

-- print a notice line
function app:notify(message, style)
    self:print({theme.styled(style or "notice", "  " .. message)})
end

-- build the lines of the live region
function app:_livelines_build()
    local width = self:width()
    local lines = {}

    -- the streaming tail
    if self._streambuf ~= "" then
        for _, line in ipairs(text.wrap(self._streambuf, width - 2)) do
            table.insert(lines, "  " .. line)
        end
    end

    if self._state == "working" then
        table.insert(lines, self:_statusline())
        if self._confirm then
            for _, line in ipairs(self._confirm.lines or {}) do
                table.insert(lines, line)
            end
            return lines
        end
        return lines
    end

    -- the input box
    table.insert(lines, theme.styled("border", string.rep("─", width)))
    local editorlines, cursorrow, cursorcol = self.editor:render({
        width = width, prompt = theme.styled("prompt", "› ")})
    for _, line in ipairs(editorlines) do
        table.insert(lines, line)
    end
    local inputstart = #lines - #editorlines + 1
    table.insert(lines, theme.styled("border", string.rep("─", width)))

    -- the completion popup
    if self._popup then
        for _, line in ipairs(self:_popuplines()) do
            table.insert(lines, line)
        end
    end

    -- the hint line
    table.insert(lines, self:_hintline())
    return lines, inputstart + cursorrow - 1, cursorcol
end

-- build the status line, e.g. "✻ Harmonizing… (12s · ↓ 1.2k tokens · esc to interrupt)"
function app:_statusline()
    local elapsed = os.mclock() - (self._starttime or os.mclock())
    local frames = SPINNERS[(self.harness:config().ui or {}).spinner or "star"] or SPINNERS.star
    self._spinneridx = self._spinneridx % #frames + 1
    if elapsed > (self._wordtime or 0) + 12000 then
        self._wordtime = elapsed
        self._wordidx = self._wordidx % #WORDS + 1
    end
    local parts = {util.duration(elapsed)}
    if self._tokens > 0 then
        table.insert(parts, string.format("↓ %s tokens", util.count(self._tokens)))
    end
    table.insert(parts, "esc to interrupt")
    return theme.styled("spinner", frames[self._spinneridx] .. " " .. (self._working or WORDS[self._wordidx]) .. "…")
        .. theme.styled("dim", string.format(" (%s)", table.concat(parts, " · ")))
end

-- build the hint line
function app:_hintline()
    local badges = {
        default     = {style = "hint",        text = "⏵ default mode"},
        acceptedits = {style = "badge.accept", text = "⏵⏵ accept edits on"},
        plan        = {style = "badge.plan",   text = "⏸ plan mode on"},
        bypass      = {style = "badge.bypass", text = "⏵⏵ bypass permissions"}
    }
    local badge = badges[self.mode] or badges.default
    local parts = {theme.styled(badge.style, "  " .. badge.text) ..
                   theme.styled("hint", " (shift+tab to cycle)")}
    table.insert(parts, theme.styled("hint", "/ for commands"))
    table.insert(parts, theme.styled("hint", "@ for files"))
    local usage = self.session:usage()
    if (usage.input or 0) > 0 and (self.harness:config().ui or {}).showtokens ~= false then
        local rate = self.session:cacherate()
        table.insert(parts, theme.styled("hint", string.format("%s↑ %s↓%s",
            util.count(usage.input), util.count(usage.output),
            rate and string.format(" · cache %.0f%%", rate * 100) or "")))
    end
    return table.concat(parts, theme.styled("hint", " · "))
end

--------------------------------------------------------------------------------
-- the transcript
--------------------------------------------------------------------------------

-- print the banner
function app:banner()
    local provider = config.provider(self.harness:config())
    local width = self:width()
    self:print({
        "",
        theme.styled("assistant.bullet", " ✻ ") .. theme.styled("title", "xmake ai") ..
            theme.styled("dim", string.format("  ·  %s · %s", provider.name, provider.models.main or "?")),
        theme.styled("dim", string.format("   %s", self.harness:rootdir())),
        "",
        theme.styled("hint", "   /help for the commands · @ to attach a file · esc to interrupt"),
        ""})
end

-- print the user message
function app:print_user(message)
    local width = self:width()
    local lines = {}
    for idx, line in ipairs(text.wrap(message, width - 4)) do
        table.insert(lines, theme.styled("user.bullet", idx == 1 and "› " or "  ") .. theme.styled("user.text", line))
    end
    table.insert(lines, "")
    self:print(lines)
end

-- print the assistant message which is not streamed
function app:print_assistant(content)
    if not content or content:trim() == "" then
        return
    end
    local width = self:width()
    local lines = {}
    local rendered = markdown.render(content, {width = width - 2})
    for idx, line in ipairs(rendered) do
        table.insert(lines, (idx == 1 and (theme.styled("assistant.bullet", "● ")) or "  ") .. line)
    end
    table.insert(lines, "")
    self:print(lines)
end

-- print the tool call result
function app:print_tool(result, call)
    local width = self:width()
    local display = result.display or {}
    local title = display.title or call.name
    local subject = display.subject
    local lines = {}
    local bullet = result.iserror and theme.styled("tool.error", "● ") or theme.styled("tool.bullet", "● ")
    local header = bullet .. theme.styled("tool.name", title)
    if subject then
        header = header .. theme.styled("tool.args", "(" .. text.truncate(subject, width - #title - 8) .. ")")
    end
    table.insert(lines, header)

    if result.iserror then
        for _, line in ipairs(text.wrap(result.output or "", width - 6)) do
            table.insert(lines, theme.styled("tool.error", "  └ " .. line))
            break
        end
        local rest = text.lines(result.output or "")
        for idx = 2, math.min(#rest, 6) do
            table.insert(lines, theme.styled("tool.error", "    " .. text.truncate(rest[idx], width - 6)))
        end
    else
        if display.summary then
            table.insert(lines, theme.styled("tool.result", "  └ " .. display.summary))
        end
        if display.kind == "diff" and display.diff then
            for _, line in ipairs(diff.render(display.diff, {width = width - 4, filepath = display.filepath,
                    maxlines = (self.harness:config().ui or {}).difflines or 40})) do
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
    table.insert(lines, "")
    self:print(lines)
end

--------------------------------------------------------------------------------
-- the agent handlers
--------------------------------------------------------------------------------

-- build the ui handlers of the agent loop
function app:handlers()
    local this = self
    return {
        on_step_start = function (info)
            this._starttime = this._starttime or os.mclock()
        end,
        on_text = function (delta)
            this._tokens = this._tokens + math.max(1, math.floor(#delta / 4))
            this:_stream(delta)
        end,
        on_reasoning = function (delta)
            if (this.harness:config().ui or {}).showreasoning == false then
                return
            end
            this._tokens = this._tokens + math.max(1, math.floor(#delta / 4))
            this:_streamreasoning(delta)
        end,
        on_assistant = function (event)
            this:_streamflush()
        end,
        on_tool_start = function (call)
            this._working = _toolverb(call.name)
        end,
        on_tool_result = function (result, call)
            this._working = nil
            this:print_tool(result, call)
        end,
        on_usage = function (usage, total)
            this._tokens = (usage.output or 0) + (usage.input or 0)
        end,
        on_notice = function (message)
            this:notify(message)
        end,
        on_error = function (errors)
            this:print({theme.styled("error", "  ✗ " .. tostring(errors)), ""})
        end,
        confirm = function (request)
            return this:confirm(request)
        end,
        ontick = function ()
            return this:tick()
        end
    }
end

-- get the working verb of the given tool
function _toolverb(name)
    local verbs = {
        read_file = "Reading", write_file = "Writing", edit_file = "Editing",
        search_text = "Searching", glob_files = "Globbing", list_dir = "Listing",
        run_command = "Running", run_agent = "Delegating", use_skill = "Learning",
        fetch_url = "Fetching", todo_write = "Planning"
    }
    return verbs[name]
end

-- the periodic tick during the model streaming and the long tool calls
--
-- @return  false to abort the current work
--
function app:tick()
    self:refresh()
    while true do
        local key = terminal.readkey(0)
        if not key then
            break
        end
        if key.name == "eof" then
            break
        end
        if key.name == "escape" or (key.name == "ctrl" and key.ch == "c") then
            self.signal.aborted = true
            self._working = "Interrupting"
            return false
        elseif key.name == "char" then
            -- the user is queuing the next message while we work
            self.editor:insert(key.ch)
        elseif key.name == "paste" then
            self.editor:insert(key.text)
        elseif key.name == "backspace" then
            self.editor:backspace()
        end
    end
    return true
end

-- stream the assistant text
function app:_stream(delta)
    self._streambuf = self._streambuf .. delta
    local width = self:width()
    while true do
        local pos = self._streambuf:find("\n", 1, true)
        if not pos then
            break
        end
        local line = self._streambuf:sub(1, pos - 1)
        self._streambuf = self._streambuf:sub(pos + 1)
        local rendered = markdown.renderline(line, self._mdstate, {width = width - 2})
        local lines = {}
        for _, item in ipairs(rendered) do
            if not self._streamstarted then
                self._streamstarted = true
                table.insert(lines, theme.styled("assistant.bullet", "● ") .. item)
            else
                table.insert(lines, "  " .. item)
            end
        end
        self:print(lines)
    end
    self:refresh()
end

-- stream the reasoning text
function app:_streamreasoning(delta)
    self._reasonbuf = (self._reasonbuf or "") .. delta
    local width = self:width()
    while true do
        local pos = self._reasonbuf:find("\n", 1, true)
        if not pos then
            break
        end
        local line = self._reasonbuf:sub(1, pos - 1)
        self._reasonbuf = self._reasonbuf:sub(pos + 1)
        if line:trim() ~= "" then
            self:print({theme.styled("reasoning", "  " .. text.truncate(line, width - 4))})
        end
    end
end

-- flush the rest of the streaming buffer
function app:_streamflush()
    if self._streambuf ~= "" then
        local rendered = markdown.renderline(self._streambuf, self._mdstate, {width = self:width() - 2})
        local lines = {}
        for _, item in ipairs(rendered) do
            if not self._streamstarted then
                self._streamstarted = true
                table.insert(lines, theme.styled("assistant.bullet", "● ") .. item)
            else
                table.insert(lines, "  " .. item)
            end
        end
        self._streambuf = ""
        self:print(lines)
    end
    if self._streamstarted then
        self:print({""})
    end
    self._streamstarted = false
    self._reasonbuf = ""
    self._mdstate = markdown.newstate()
end

--------------------------------------------------------------------------------
-- the permission dialog
--------------------------------------------------------------------------------

-- ask the user to confirm the tool call
function app:confirm(request)
    local width = self:width()
    local tool = request.tool

    -- show the preview above the dialog
    local lines = {}
    table.insert(lines, theme.styled("tool.pending", "● ") .. theme.styled("tool.name", tool.name) ..
        theme.styled("tool.args", "(" .. text.truncate(tostring(request.signature:match("%((.*)%)$") or ""), width - 20) .. ")"))
    if request.preview and request.preview.kind == "diff" then
        for _, line in ipairs(diff.render(request.preview.diff, {width = width - 4, filepath = request.preview.filepath, maxlines = 30})) do
            table.insert(lines, "    " .. line)
        end
    end
    self:print(lines)

    local choices = {
        {key = "1", text = "Yes", value = "allow"},
        {key = "2", text = string.format("Yes, and do not ask again for %s", tool.name), value = "always"},
        {key = "3", text = "No, and tell the model what to do instead", value = "deny"}
    }
    local selected = 1
    local answer = nil
    while not answer do
        local dialog = {}
        table.insert(dialog, theme.styled("border", "  ╭" .. string.rep("─", math.min(width - 4, 60)) .. ""))
        table.insert(dialog, theme.styled("tool.pending", "  │ Do you want to run this tool?"))
        for idx, choice in ipairs(choices) do
            local marker = idx == selected and "❯" or " "
            local style = idx == selected and "select.active" or "select.normal"
            table.insert(dialog, "  │ " .. theme.styled(style, string.format("%s %s. %s", marker, choice.key, choice.text)))
        end
        table.insert(dialog, theme.styled("border", "  ╰" .. string.rep("─", math.min(width - 4, 60))))
        self._confirm = {lines = dialog}
        self:refresh()

        local key = terminal.readkey(80)
        if key then
            if key.name == "up" then
                selected = selected > 1 and selected - 1 or #choices
            elseif key.name == "down" then
                selected = selected % #choices + 1
            elseif key.name == "enter" then
                answer = choices[selected].value
            elseif key.name == "escape" or (key.name == "ctrl" and key.ch == "c") then
                answer = "deny"
            elseif key.name == "char" then
                for idx, choice in ipairs(choices) do
                    if key.ch == choice.key then
                        selected = idx
                        answer = choice.value
                    end
                end
                if key.ch == "y" then
                    answer = "allow"
                elseif key.ch == "n" then
                    answer = "deny"
                end
            end
        end
    end
    self._confirm = nil
    self:_erase()
    if answer == "deny" then
        self:print({theme.styled("dim", "    ✗ rejected by the user"), ""})
        return "the user rejected this tool call, ask them how to continue instead of retrying."
    end
    self:print({theme.styled("dim", answer == "always" and "    ✔ allowed, and it will not ask again" or "    ✔ allowed"), ""})
    return answer
end

--------------------------------------------------------------------------------
-- the input loop
--------------------------------------------------------------------------------

-- read one input from the user
--
-- @return  the input text, or nil if the user wants to exit
--
function app:readinput()
    self._state = "idle"
    self._starttime = nil
    self._tokens = 0
    local lastctrlc = 0
    self._dirty = true
    while true do
        if self._dirty then
            self:refresh()
            self._dirty = false
        end
        local key = terminal.readkey(60)
        if key then
            self._dirty = true
            local action = self:_handlekey(key, lastctrlc)
            if action == "submit" then
                local input = self.editor:text()
                self.editor:addhistory(input)
                self:_savehistory()
                self.editor:clear()
                self:_erase()
                return input
            elseif action == "exit" then
                self:_erase()
                return nil
            elseif action == "ctrlc" then
                lastctrlc = os.mclock()
            end
        end
    end
end

-- handle one key in the idle state
function app:_handlekey(key, lastctrlc)
    local name = key.name

    -- the input is closed, e.g. the stdin is piped and drained
    if name == "eof" then
        return "exit"
    end

    -- the completion popup is open
    if self._popup then
        if name == "up" then
            self._popup.selected = self._popup.selected > 1 and self._popup.selected - 1 or #self._popup.items
            return
        elseif name == "down" or (name == "tab" and not key.shift) then
            self._popup.selected = self._popup.selected % #self._popup.items + 1
            return
        elseif name == "enter" then
            -- the input is already complete? submit it instead of completing again
            local current = self.editor:text():trim()
            local item = self._popup.items[self._popup.selected]
            if item and item.text == current and self._popup.selected == 1 then
                self._popup = nil
            else
                self:_acceptcompletion()
                return
            end
        elseif name == "escape" then
            self._popup = nil
            return
        end
    end

    if name == "enter" then
        if key.alt then
            self.editor:newline()
            return
        end
        local input = self.editor:text()
        if input:trim() == "" then
            return
        end
        -- a trailing backslash continues the input on the next line
        if input:endswith("\\") then
            self.editor:backspace()
            self.editor:newline()
            return
        end
        return "submit"
    elseif name == "ctrl" then
        local ch = key.ch
        if ch == "c" then
            if self.editor:isempty() and os.mclock() - lastctrlc < 2000 then
                return "exit"
            end
            self.editor:clear()
            self._popup = nil
            return "ctrlc"
        elseif ch == "d" then
            if self.editor:isempty() then
                return "exit"
            end
            self.editor:delete()
        elseif ch == "l" then
            tty.erase_screen()
            tty.cursor_move(1, 1)
            self._livelines = 0
        elseif ch == "u" then
            self.editor:deletelinestart()
        elseif ch == "k" then
            self.editor:deletelineend()
        elseif ch == "w" then
            self.editor:deleteword()
        elseif ch == "y" then
            self.editor:yank()
        elseif ch == "a" then
            self.editor:move("home")
        elseif ch == "e" then
            self.editor:move("end")
        elseif ch == "j" then
            self.editor:newline()
        end
    elseif name == "tab" then
        if key.shift then
            self:setmode(policy.nextmode(self.mode))
        else
            self:_complete()
        end
    elseif name == "backspace" then
        if key.alt then
            self.editor:deleteword()
        else
            self.editor:backspace()
        end
        self:_updatepopup()
    elseif name == "delete" then
        self.editor:delete()
    elseif name == "left" then
        self.editor:move("left", {word = key.ctrl or key.alt})
    elseif name == "right" then
        self.editor:move("right", {word = key.ctrl or key.alt})
    elseif name == "home" then
        self.editor:move("home")
    elseif name == "end" then
        self.editor:move("end")
    elseif name == "up" then
        if not self.editor:move("up") then
            self.editor:browsehistory("prev")
        end
    elseif name == "down" then
        if not self.editor:move("down") then
            self.editor:browsehistory("next")
        end
    elseif name == "escape" then
        self._popup = nil
        self.editor:clear()
    elseif name == "paste" then
        self.editor:insert(key.text)
    elseif name == "char" then
        self.editor:insert(key.ch)
        self:_updatepopup()
    end
end

-- start the completion
function app:_complete()
    self:_updatepopup(true)
    if self._popup and #self._popup.items == 1 then
        self:_acceptcompletion()
    end
end

-- update the completion popup
function app:_updatepopup(force)
    local input = self.editor:text()
    local word = self.editor:wordbefore()

    -- the command completion
    if input:startswith("/") and not input:find("%s") then
        local prefix = input:sub(2)
        local items = {}
        for _, command in ipairs(self.harness:service("commands"):find(prefix)) do
            table.insert(items, {text = "/" .. command.name, description = command.description})
        end
        self._popup = #items > 0 and {items = items, selected = 1, kind = "command"} or nil
        return
    end

    -- the file completion
    if word and word:startswith("@") then
        local prefix = word:sub(2)
        local items = self:_findfiles(prefix)
        self._popup = #items > 0 and {items = items, selected = 1, kind = "file"} or nil
        return
    end
    if not force then
        self._popup = nil
    end
end

-- find the files for the completion
function app:_findfiles(prefix)
    local rootdir = self.harness:rootdir()
    local dir = path.directory(prefix)
    local name = path.filename(prefix)
    local searchdir = (dir and dir ~= "." and dir ~= "") and path.join(rootdir, dir) or rootdir
    local items = {}
    if not os.isdir(searchdir) then
        return items
    end
    for _, filepath in ipairs(os.filedirs(path.join(searchdir, "*"))) do
        local filename = path.filename(filepath)
        if not filename:startswith(".") and (name == "" or filename:lower():startswith(name:lower())) then
            local relative = path.relative(filepath, rootdir)
            table.insert(items, {
                text = "@" .. relative .. (os.isdir(filepath) and "/" or ""),
                description = os.isdir(filepath) and "directory" or util.filesize(os.filesize(filepath) or 0)})
        end
        if #items >= 30 then
            break
        end
    end
    table.sort(items, function (a, b) return a.text < b.text end)
    return items
end

-- accept the selected completion
function app:_acceptcompletion()
    local popup = self._popup
    if not popup then
        return
    end
    local item = popup.items[popup.selected]
    if item then
        if popup.kind == "command" then
            self.editor:settext(item.text .. " ")
        else
            self.editor:replaceword(item.text)
        end
    end
    self._popup = nil
end

-- build the completion popup lines
function app:_popuplines()
    local popup = self._popup
    local lines = {}
    local width = self:width()
    local maxitems = 8
    local start = math.max(1, popup.selected - maxitems + 1)
    for idx = start, math.min(#popup.items, start + maxitems - 1) do
        local item = popup.items[idx]
        local style = idx == popup.selected and "select.active" or "select.normal"
        local line = string.format("  %s %s", idx == popup.selected and "❯" or " ",
            text.pad(item.text, 24))
        if item.description then
            line = line .. theme.styled("dim", text.truncate(item.description, width - 32))
        end
        table.insert(lines, theme.styled(style, line))
    end
    if #popup.items > maxitems then
        table.insert(lines, theme.styled("dim", string.format("    … %d more", #popup.items - maxitems)))
    end
    return lines
end

--------------------------------------------------------------------------------
-- the session control
--------------------------------------------------------------------------------

-- set the permission mode
function app:setmode(mode)
    self.mode = mode
    util.tset(self.harness:config(), "permission.mode", mode)
    return self
end

-- start a new session
function app:newsession()
    self.session:save()
    self.session = sessions.new({cwd = self.harness:rootdir()})
    self.harness:service("todos", {})
    return self.session
end

-- set the current session
function app:setsession(session)
    self.session = session
    return self
end

-- load the input history
function app:_loadhistory()
    if os.isfile(self._historyfile) then
        local history = {}
        for line in io.lines(self._historyfile) do
            local entry = line:gsub("\\n", "\n")
            if entry:trim() ~= "" then
                table.insert(history, entry)
            end
        end
        self.editor:sethistory(history)
    end
end

-- save the input history
function app:_savehistory()
    local lines = {}
    for _, entry in ipairs(self.editor:history()) do
        table.insert(lines, (entry:gsub("\n", "\\n")))
    end
    os.mkdir(path.directory(self._historyfile))
    io.writefile(self._historyfile, table.concat(lines, "\n"))
end

--------------------------------------------------------------------------------
-- the main loop
--------------------------------------------------------------------------------

-- send one prompt to the model
function app:send(prompt)
    self._state = "working"
    self._starttime = os.mclock()
    self._tokens = 0
    self.signal.aborted = false
    self._streamstarted = false
    self._mdstate = markdown.newstate()

    local result = agent.run(self.harness, {
        session = self.session,
        prompt = prompt,
        ui = self:handlers(),
        signal = self.signal,
        mode = self.mode
    })
    self:_streamflush()
    self._state = "idle"

    if result.aborted then
        self:print({theme.styled("notice", "  ⏹ interrupted"), ""})
    end
    if (self.harness:config().ui or {}).showtokens ~= false and result.usage then
        local usage = result.usage
        local total = usage.input + usage.output
        if total > 0 then
            local rate = nil
            if (usage.cachehit or 0) + (usage.cachemiss or 0) > 0 then
                rate = usage.cachehit / (usage.cachehit + usage.cachemiss)
            end
            self:print({theme.styled("dim", string.format("  %s tokens (↑ %s · ↓ %s%s) · %s · %d step%s",
                util.count(total), util.count(usage.input), util.count(usage.output),
                rate and string.format(" · cache %.0f%%", rate * 100) or "",
                util.duration(os.mclock() - (self._starttime or os.mclock())),
                result.steps, result.steps == 1 and "" or "s")), ""})
        end
    end

    -- generate the session title from the first message
    if not self.session:title() then
        self.session:title(text.truncate(prompt:gsub("%s+", " "), 60))
    end
    return result
end

-- run the application
function app:run(opt)
    opt = opt or {}
    terminal.rawmode_enter()
    terminal.bracketed_paste(true)
    self:banner()

    -- replay the resumed session
    if opt.replay then
        self:replay()
    end

    -- the initial prompt from the command line
    if opt.prompt and opt.prompt ~= "" then
        self:print_user(opt.prompt)
        self:send(opt.prompt)
    end

    while self._running do
        local input = self:readinput()
        if input == nil then
            break
        end
        if input:trim() ~= "" then
            if input:startswith("/") then
                self:_runcommand(input:sub(2))
            elseif input:startswith("!") then
                -- run a shell command directly
                self:_runshell(input:sub(2))
            else
                local prompt = self:_expandfiles(input)
                self:print_user(input)
                self:send(prompt)
            end
        end
    end

    self:_erase()
    terminal.bracketed_paste(false)
    terminal.rawmode_leave()
    self.session:save()
    self:print({theme.styled("dim", "  session " .. self.session:id() .. " is saved, resume it with `xmake ai -c`"), ""})
end

-- run a slash command
function app:_runcommand(line)
    local result = self.harness:service("commands"):run(self, line)
    if result.kind == "exit" then
        self._running = false
    elseif result.kind == "prompt" then
        self:print_user("/" .. line)
        self:send(result.text)
    elseif result.text then
        self:print({theme.styled(result.iserror and "error" or "dim",
            text.indent(result.text, "  ")), ""})
    end
end

-- run a shell command directly, e.g. "!xmake build"
function app:_runshell(command)
    local registry = self.harness:service("tools")
    local tool = registry:get("run_command")
    if not tool then
        return
    end
    self:print({theme.styled("user.bullet", "! ") .. theme.styled("user.text", command)})
    local context = {harness = self.harness, config = self.harness:config(), cwd = self.harness:rootdir(),
                     session = self.session, ui = self:handlers(), signal = self.signal, mode = "bypass"}
    local errors
    local result = try {
        function ()
            return tool.run(context, {command = command})
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    if result then
        self:print_tool(result, {name = "run_command"})
        self.session:append("user", {text = string.format("I ran `%s` in the terminal, the output was:\n\n%s",
            command, result.output)})
    else
        self:print({theme.styled("error", "  ✗ " .. tostring(errors)), ""})
    end
end

-- expand the @file references of the input
function app:_expandfiles(input)
    local rootdir = self.harness:rootdir()
    local attachments = {}
    for reference in input:gmatch("@([%w%._%-/\\]+)") do
        local filepath = path.absolute(reference, rootdir)
        if os.isfile(filepath) then
            local content = io.readfile(filepath) or ""
            if #content < 131072 then
                table.insert(attachments, string.format("### %s\n\n```\n%s\n```", reference, content))
            end
        end
    end
    if #attachments == 0 then
        return input
    end
    return input .. "\n\n" .. table.concat(attachments, "\n\n")
end

-- replay the events of the current session
function app:replay()
    for _, event in ipairs(self.session:events()) do
        if event.kind == "user" then
            self:print_user(event.text or "")
        elseif event.kind == "assistant" then
            self:print_assistant(event.text)
        elseif event.kind == "tool" then
            self:print_tool({output = event.output, iserror = event.iserror, display = event.display},
                {name = event.name})
        end
    end
    self:print({theme.styled("dim", "  ── the session is resumed ──"), ""})
end
