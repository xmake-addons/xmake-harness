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
-- this module owns the state and the loop, everything it draws comes from the
-- ui modules beside it: `transcript`, `statusline`, `completion` and `dialog`.
--

-- imports
import("core.base.tty")
import("core.base.signal")
import("core.base.object")
import("harness.util.util")
import("harness.util.text")
import("harness.ui.theme")
import("harness.ui.diff")
import("harness.ui.editor")
import("harness.ui.dialog")
import("harness.ui.keymap")
import("harness.ui.markdown")
import("harness.ui.terminal")
import("harness.ui.statusline")
import("harness.ui.transcript")
import("harness.ui.completion")
import("harness.core.agent")
import("harness.core.loop")
import("harness.shell.jobs")
import("harness.sandbox.sandbox")
import("harness.config.config", {alias = "harnessconfig"})
import("harness.core.session", {alias = "sessions"})

-- define the application class
local app = app or object {_init = {"harness", "session", "mode", "editor", "signal"}}

-- create a new application
function new(harness, opt)
    opt = opt or {}
    local instance = app {harness, opt.session, opt.mode or (harness:config().permission or {}).mode or "default",
                          editor.new(), {aborted = false}}
    instance._livecount = 0
    instance._cursorup = 0
    instance._state = "idle"
    instance._streambuf = ""
    instance._mdstate = markdown.newstate()
    instance._frame = 0
    instance._word = 0
    instance._tokens = 0
    instance._running = true
    instance._historyfile = path.join(harnessconfig.homedir(), "history.txt")
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
    if self._livecount <= 0 then
        return
    end
    if self._cursorup > 0 then
        tty.cursor_move_down(self._cursorup)
        self._cursorup = 0
    end
    tty.cr()
    tty.cursor_move_up(self._livecount)
    tty.erase_down()
    self._livecount = 0
end

-- draw the live region and place the cursor
function app:_draw(lines, cursorrow, cursorcol)
    tty.cursor_hide()
    for _, line in ipairs(lines) do
        terminal.write(line .. theme.reset() .. "\n")
    end
    self._livecount = #lines
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
    self:_draw(self:_livelines())
end

-- print the permanent lines into the transcript
function app:print(lines)
    -- whatever is on screen next comes after the run, so the run ends here
    if self._run and not self._flushing then
        self._flushing = true
        self:_flushrun()
        self._flushing = false
    end
    if type(lines) == "string" then
        lines = text.lines(lines)
    end
    if #lines == 0 then
        return
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
--
-- @return  the lines, the cursor row and the cursor column
--
function app:_livelines()
    local width = self:width()
    local lines = {}

    -- the run of tool calls which has not been committed to the transcript yet
    for _, line in ipairs(self:_runlines() or {}) do
        table.insert(lines, line)
    end

    -- the tail of the streaming message
    if self._streambuf ~= "" then
        for _, line in ipairs(text.wrap(self._streambuf, width - 2)) do
            table.insert(lines, "  " .. line)
        end
    end

    -- a dialog takes over the region
    if self._dialog then
        if self._state == "working" then
            table.insert(lines, self:_status())
        end
        for _, line in ipairs(self._dialog) do
            table.insert(lines, line)
        end
        return lines
    end
    if self._state == "working" then
        table.insert(lines, self:_status())
        return lines
    end
    return self:_inputlines(lines, width)
end

-- build the input box, the popup and the hints
function app:_inputlines(lines, width)
    table.insert(lines, theme.styled("border", string.rep("─", width)))
    local editorlines, cursorrow, cursorcol = self.editor:render({
        width = width, prompt = theme.styled("prompt", "› ")})
    for _, line in ipairs(editorlines) do
        table.insert(lines, line)
    end
    local inputstart = #lines - #editorlines + 1
    table.insert(lines, theme.styled("border", string.rep("─", width)))

    if self._popup then
        for _, line in ipairs(completion.render(self._popup, width)) do
            table.insert(lines, line)
        end
    end
    table.insert(lines, statusline.hint({
        mode = self.mode,
        usage = self.session:usage(),
        loop = self._loop and loop.describe(self._loop, os.time()) or nil,
        jobs = jobs.running(self.harness:service("jobs")),
        showtokens = (self.harness:config().ui or {}).showtokens}))
    return lines, inputstart + cursorrow - 1, cursorcol
end

-- build the status line of a working turn
function app:_status()
    local elapsed = os.mclock() - (self._starttime or os.mclock())
    self._frame = self._frame + 1
    if elapsed > (self._wordtime or 0) + 12000 then
        self._wordtime = elapsed
        self._word = self._word + 1
    end
    return statusline.status({
        elapsed = elapsed,
        tokens = self._tokens,
        working = self._working,
        command = self._command,
        spinner = (self.harness:config().ui or {}).spinner,
        frame = self._frame,
        word = self._word})
end

--------------------------------------------------------------------------------
-- the transcript
--------------------------------------------------------------------------------

-- print the welcome panel
function app:banner()
    local config = self.harness:config()
    local rootdir = self.harness:rootdir()
    local loaded = {}
    local skills = self.harness:service("skills"):enabled(config)
    if #skills > 0 then
        table.insert(loaded, string.format("%d skills", #skills))
    end
    table.insert(loaded, string.format("%d tools", #self.harness:service("tools"):names()))
    if os.isfile(path.join(rootdir, "xmake.lua")) then
        table.insert(loaded, "xmake project")
    end
    if (config.sandbox or {}).enabled then
        table.insert(loaded, "sandboxed")
    end
    local events = #self.session:events()
    if events > 0 then
        table.insert(loaded, string.format("resumed, %d messages", events))
    end
    self:print(transcript.banner({
        provider = harnessconfig.provider(config),
        rootdir = rootdir,
        loaded = loaded,
        notices = self.harness:service("notices"),
        width = self:width()}))
end

-- print the user message
function app:print_user(message)
    self:print(transcript.user(message, self:width()))
end

-- print an assistant message which was not streamed
function app:print_assistant(content)
    self:print(transcript.assistant(content, self:width()))
end

-- print the result of a tool call
function app:print_tool(result, call)
    local registry = self.harness:service("tools")
    local tool = registry and registry:get(call.name)
    local title = nil
    if tool and tool.commandline and result.args then
        title = tool.commandline(result.args)
    end
    local lines
    try {
        function ()
            lines = transcript.tool(result, {
                title = title,
                width = self:width(),
                difflines = (self.harness:config().ui or {}).difflines})
        end,
        catch {
            function (errs)
                -- a card which cannot be drawn is a bug in the drawing, not a
                -- reason to lose the conversation. say what happened and what
                -- the tool did, in the plainest way there is, and carry on
                lines = {theme.styled("tool.error", string.format("● %s (this card could not be drawn: %s)",
                    call.name or "tool", tostring(errs))),
                         theme.styled("dim", "  " .. text.truncate((result.output or ""):gsub("%s+", " "), 200)), ""}
            end
        }
    }
    self:_toolrun(call, lines)
end

-- add a tool card to the run which is building up
--
-- it is not printed yet: while more of the same kind keep coming they are one
-- line between them, and that line lives in the live region where it can be
-- rewritten, @see _runlines()
--
function app:_toolrun(call, lines)
    local group, verb, noun = transcript.toolgroup(call.name)
    if not group then
        self:print(lines)
        return
    end
    local run = self._run
    if run and run.group == group then
        run.count = run.count + 1
    else
        self:print({})
        self._run = {group = group, verb = verb, noun = noun, count = 1, lines = lines}
    end
    self._dirty = true
end

-- what the pending run looks like
--
-- alone it is still worth its full card: one file read says which file. it is
-- the fourth one which stops being worth a card of its own
--
function app:_runlines()
    local run = self._run
    if not run then
        return nil
    end
    if run.count == 1 then
        return run.lines
    end
    return {transcript.toolrun(run.verb, run.noun, run.count), ""}
end

-- move the pending run into the transcript
function app:_flushrun()
    local lines = self:_runlines()
    self._run = nil
    if lines then
        self:print(lines)
    end
end

-- replay the events of the current session
function app:replay()
    for _, event in ipairs(self.session:events()) do
        if event.kind == "user" then
            self:print_user(event.text or "")
        elseif event.kind == "assistant" then
            self:print_assistant(event.text)
        elseif event.kind == "tool" then
            self:print_tool({output = event.output, iserror = event.iserror,
                display = event.display, args = event.arguments}, {name = event.name})
        end
    end
    self:print({theme.styled("dim", "  ── the session is resumed ──"), ""})
end

--------------------------------------------------------------------------------
-- the streaming
--------------------------------------------------------------------------------

-- build the ui handlers of the agent loop
function app:handlers()
    local this = self
    return {
        on_step_start = function ()
            this._starttime = this._starttime or os.mclock()
        end,
        on_text = function (delta)
            this._tokens = this._tokens + math.max(1, math.floor(#delta / 4))
            this:_stream(delta)
        end,
        on_reasoning = function (delta)
            if (this.harness:config().ui or {}).showreasoning ~= false then
                this:_streamreasoning(delta)
            end
        end,
        on_assistant = function ()
            this:_streamflush()
        end,
        on_tool_start = function (call)
            this._command = call.name == "run_command" or nil
            this._working = statusline.verb(call.name)
        end,
        on_tool_result = function (result, call)
            this._command = nil
            this._working = nil
            this:print_tool(result, call)
        end,
        on_usage = function (usage)
            this._tokens = (usage.output or 0) + (usage.input or 0)
        end,
        on_notice = function (message)
            this:notify(message)
        end,
        on_error = function (errors)
            this:print({theme.styled("error", "  ✗ " .. tostring(errors)), ""})
        end,
        on_mode = function (mode)
            this.mode = mode
        end,
        confirm = function (request)
            return this:confirm(request)
        end,
        ontick = function ()
            return this:tick()
        end
    }
end

-- the periodic tick while the model works and the tools run
--
-- @return  false to abort the current work
--
function app:tick()
    self:refresh()
    while true do
        -- we must not wait for a key here, the streaming has to go on: an
        -- escape sequence which is only half arrived is decoded on the next tick
        local key = terminal.readkey(0)
        if not key then
            break
        end
        if key.name == "escape" or (key.name == "ctrl" and key.ch == "c") then
            self.signal.aborted = true
            self._working = "Interrupting"
            return false
        elseif key.name == "ctrl" and key.ch == "b" then
            -- a command which turned out to be slow does not have to hold the
            -- conversation: it keeps running, and we stop waiting for it
            self.signal.background = true
            self._working = "Backgrounding"
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

-- stream the assistant text, one rendered line at a time
function app:_stream(delta)
    self._streambuf = self._streambuf .. delta
    while true do
        local pos = self._streambuf:find("\n", 1, true)
        if not pos then
            break
        end
        local line = self._streambuf:sub(1, pos - 1)
        self._streambuf = self._streambuf:sub(pos + 1)
        self:print(self:_streamlines(line))
    end
    self:refresh()
end

-- render one streamed markdown line
function app:_streamlines(line)
    local lines = {}
    for _, rendered in ipairs(markdown.renderline(line, self._mdstate, {width = self:width() - 2})) do
        table.insert(lines, transcript.assistantline(rendered, not self._streamstarted))
        self._streamstarted = true
    end
    return lines
end

-- stream the reasoning text
function app:_streamreasoning(delta)
    self._reasonbuf = (self._reasonbuf or "") .. delta
    while true do
        local pos = self._reasonbuf:find("\n", 1, true)
        if not pos then
            break
        end
        local line = self._reasonbuf:sub(1, pos - 1)
        self._reasonbuf = self._reasonbuf:sub(pos + 1)
        if line:trim() ~= "" then
            self:print({theme.styled("reasoning", "  " .. text.truncate(line, self:width() - 4))})
        end
    end
end

-- flush the rest of the streaming buffers
function app:_streamflush()
    if self._streambuf ~= "" then
        self:print(self:_streamlines(self._streambuf))
        self._streambuf = ""
    end
    local rest = markdown.flush(self._mdstate, {width = self:width() - 2})
    if #rest > 0 then
        self:print(rest)
    end
    if self._streamstarted then
        self:print({""})
    end
    self._streamstarted = false
    self._reasonbuf = ""
    self._mdstate = markdown.newstate()
end

--------------------------------------------------------------------------------
-- the dialogs
--------------------------------------------------------------------------------

-- ask the user a question in the live region
--
-- @param request   {lines = {..}, question = "..", options = {{text = .., value = ..}}, footer = ".."}
-- @return          the value of the chosen option
--
function app:ask(request)
    local options = request.options or {{text = "Yes", value = true}, {text = "No", value = false}}
    local selected = 1
    while true do
        request.selected = selected
        request.options = options
        self._dialog = dialog.render(request, self:width())
        self:refresh()

        -- a dialog waits for the user, so it may also collect the rest of a key
        -- which is still in the buffer of the c library, @see terminal.readkey
        local key = terminal.readkey(80, {wait = true})
        local action = key and dialog.action(key, #options)
        if action == "up" then
            selected = selected > 1 and selected - 1 or #options
        elseif action == "down" then
            selected = selected % #options + 1
        elseif action == "accept" then
            return self:_answer(options[selected].value)
        elseif action == "cancel" then
            return self:_answer(options[#options].value)
        elseif type(action) == "number" then
            return self:_answer(options[action].value)
        end
    end
end

-- close the dialog and return the answer
function app:_answer(value)
    self._dialog = nil
    self:_erase()
    return value
end

-- ask the user to confirm a tool call
function app:confirm(request)
    local tool = request.tool
    local info = dialog.confirminfo(tool, request.args or {})
    local answer = self:ask({
        lines = self:_confirmlines(info, request),
        question = info.question,
        footer = self:_confirmfooter(tool, request.reason),
        options = {
            {text = "Yes", value = "allow"},
            {text = info.alwaystext, value = "always"},
            {text = "No, and tell the model what to do differently", value = "deny"}
        }
    })

    if answer == "deny" then
        self:print({theme.styled("dim", "  ✗ rejected"), ""})
        return "the user rejected this tool call, ask them how to continue instead of retrying."
    end
    if answer == "always" then
        self:print({theme.styled("dim", "  ✔ " .. info.alwaysnote), ""})
        return {answer = "always", rule = info.rule}
    end
    return "allow"
end

-- what is about to happen, above the rule of the dialog
function app:_confirmlines(info, request)
    local preview = request.preview
    if preview and preview.kind == "diff" then
        local lines = {theme.styled("tool.name", util.shortpath(preview.filepath, self.harness:rootdir()))}
        for _, line in ipairs(diff.render(preview.diff, {width = self:width() - 6,
                filepath = preview.filepath, maxlines = 24})) do
            table.insert(lines, line)
        end
        return lines
    end
    local lines = {theme.styled("tool.name", info.title)}
    if info.subtitle then
        table.insert(lines, theme.styled("dim", info.subtitle))
    end
    return lines
end

-- why are we asking, and where would it run?
--
-- the policy only stops at what it judges dangerous, so the reason is the most
-- useful thing we can put in front of the user
--
function app:_confirmfooter(tool, reason)
    local parts = {}
    if reason then
        table.insert(parts, reason)
    end
    if tool.permission == "exec" then
        local status = sandbox.status(self.harness:config())
        table.insert(parts, status == "off" and "runs on your machine (/sandbox on)"
            or string.format("runs in the sandbox (%s)", status))
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " · ")
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
    self._dirty = true
    local state = {editor = self.editor, popup = self._popup, mode = self.mode, lastctrlc = 0}
    while true do
        if self._dirty then
            self:refresh()
            self._dirty = false
        end

        -- the idle loop has nothing else to do until a key arrives, so it may
        -- wait for it, @see terminal.readkey. an armed loop is the exception:
        -- something other than the keyboard must be able to wake us up, so we
        -- poll instead of blocking, and only until the loop is due
        -- while something else may finish on its own — a loop which comes due,
        -- a background job — we look up from the keyboard now and then instead
        -- of sleeping on it. the jobs are not polled, they settle themselves,
        -- @see harness.shell.jobs; this is only the screen keeping up
        local armed = self._loop ~= nil
        local watching = armed or jobs.running(self.harness:service("jobs")) > 0
        local key = terminal.readkey(watching and self:_idletimeout(armed) or 200, {wait = not watching})
        if watching and not key then
            self:_showjobs()
            if armed then
                self:_looptick()
            end
        end
        if key then
            self._dirty = true
            state.popup = self._popup
            state.mode = self.mode
            local action = keymap.handle(key, state)
            self._popup = state.popup
            if state.mode ~= self.mode then
                self:setmode(state.mode)
            end
            local input = self:_action(action, state)
            if input ~= nil then
                return input ~= false and input or nil
            end
        end
    end
end

-- apply the action of a key
--
-- @return  the input on submit, false on exit, nil to keep reading
--
function app:_action(action, state)
    if action == "submit" then
        local input = self.editor:text()
        self.editor:addhistory(input)
        self:_savehistory()
        self.editor:clear()
        self:_erase()
        return input
    elseif action == "exit" then
        self:_erase()
        return false
    elseif action == "ctrlc" then
        state.lastctrlc = os.mclock()
    elseif action == "clearscreen" then
        tty.erase_screen()
        tty.cursor_move(1, 1)
        self._livecount = 0
    elseif action == "complete" then
        self._popup = completion.update(self.harness, self.editor)
        if self._popup and #self._popup.items == 1 then
            completion.accept(self._popup, self.editor)
            self._popup = nil
        end
    elseif action == "popup" then
        self._popup = completion.update(self.harness, self.editor)
    elseif action == "popup.up" or action == "popup.down" then
        completion.move(self._popup, action == "popup.up" and "up" or "down")
    elseif action == "popup.complete" then
        -- what was added narrows the candidates, so the popup is rebuilt; when
        -- nothing could be added the tab browses instead
        if completion.extend(self._popup, self.editor) then
            self._popup = completion.update(self.harness, self.editor)
        else
            completion.move(self._popup, "down")
        end
    elseif action == "popup.accept" then
        completion.accept(self._popup, self.editor)
        self._popup = nil
    elseif action == "popup.close" then
        self._popup = nil
    end
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
    self.session:save()
    self.session = session
    self.harness:service("todos", {})
    return self
end

-- load the input history
function app:_loadhistory()
    if not os.isfile(self._historyfile) then
        return
    end
    local history = {}
    for line in io.lines(self._historyfile) do
        local entry = line:gsub("\\n", "\n")
        if entry:trim() ~= "" then
            table.insert(history, entry)
        end
    end
    self.editor:sethistory(history)
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
    self:_flushrun()
    self._state = "idle"

    if result.aborted then
        self:print({theme.styled("notice", "  ⏹ interrupted"), ""})
    end
    if (self.harness:config().ui or {}).showtokens ~= false then
        self:print(transcript.usage(result, os.mclock() - (self._starttime or os.mclock())))
    end
    if not self.session:title() then
        self.session:title(text.truncate(prompt:gsub("%s+", " "), 60))
    end
    return result
end

-- give the terminal back for the duration of one command
--
-- a build wants a real terminal: its own colors and progress, a ctrl+c which
-- reaches it instead of being eaten by our key reader, and an answer when it
-- asks something. so we take the live region down, leave raw mode, and put
-- everything back when it returns
--
-- @return  whatever the command returned
--
function app:runterminal(run)
    self:_erase()
    terminal.rawmode_leave()
    local result, errors
    try {
        function ()
            result = run()
        end,
        catch {
            function (errs)
                errors = errs
            end
        }
    }
    terminal.rawmode_enter()
    self._dirty = true
    if errors then
        raise(errors)
    end
    return result
end

---------------------------------------------------------------------------------
-- the repeating task
---------------------------------------------------------------------------------

-- arm or disarm the loop, @see harness.core.loop
function app:setloop(state)
    self._loop = state
    self._dirty = true
end

-- the armed loop, if any
function app:getloop()
    return self._loop
end

-- how long the idle loop may wait for a key before it looks around
--
-- with a loop armed it is the time left on it, so a task an hour away costs us
-- one wakeup an hour and not eighteen thousand. the second is the resolution of
-- the countdown in the status line. a job only needs the screen to keep up
--
function app:_idletimeout(armed)
    if not armed then
        return 500
    end
    return math.max(50, math.min(1000, loop.remaining(self._loop, os.time()) * 1000))
end

-- say on screen which background jobs have finished
--
-- the model hears about them at its next step, @see harness.core.agent. the
-- screen can say so at once, and it must: a status line which still counts a
-- job that ended ten minutes ago is worse than no status line
--
function app:_showjobs()
    for _, job in ipairs(jobs.finished(self.harness:service("jobs"))) do
        self:print({theme.styled("notice", string.format("  ⏹ background job %s (%s) %s",
            job.id, job.label, jobs.status(job))), ""})
    end
    self._dirty = true
end

-- run one iteration of the loop if it is due
function app:_looptick()
    local state = self._loop
    if not loop.due(state, os.time()) then
        self._dirty = true
        return
    end

    local prompt = loop.begin(state)
    self:print_user(prompt)
    local result = self:send(prompt)

    -- the user may have stopped it while it worked
    if self._loop ~= state then
        return
    end
    local stopped = loop.finished(state, os.time(), result)
    if stopped then
        self:setloop(nil)
        self:print({theme.styled("notice", "  " .. stopped), ""})
    end
    self._dirty = true
end

-- install the interrupt backstop
--
-- we normally read the ctrl+c ourselves, because it should clear the input
-- instead of killing the session. but if the terminal input ever fails, that
-- would leave the user with no way out, so we also listen to the signal itself
--
function app:_installsignal()
    local this = self
    try {
        function ()
            signal.register(signal.SIGINT, function ()
                if this._state == "working" then
                    this.signal.aborted = true
                    this._working = "Interrupting"
                    return
                end
                if this._interrupted and os.mclock() - this._interrupted < 3000 then
                    terminal.rawmode_leave()
                    this.session:save()
                    os.raise("interrupted")
                end
                this._interrupted = os.mclock()
                this.editor:clear()
                this._dirty = true
            end)
        end
    }
end

-- run the application
function app:run(opt)
    opt = opt or {}
    terminal.rawmode_enter()
    terminal.bracketed_paste(true)
    self:_installsignal()

    -- whatever happens in there, the terminal has to come back
    --
    -- we put it in raw mode: no echo, no line editing, no ctrl-c. a session
    -- which dies without undoing that leaves the user in a shell where typing
    -- shows nothing, and they have to know to run `reset`. so the way out is
    -- the same for a clean exit and for a crash, and the conversation is saved
    -- on both paths — losing an hour of work to a bug in drawing a box is not
    -- a trade anybody agreed to
    --
    local errors
    try {
        function ()
            self:_mainloop(opt)
        end,
        catch {
            function (errs)
                errors = tostring(errs)
            end
        }
    }
    self:_shutdown(errors)
end

-- the conversation, until the user leaves
--
-- it is `_mainloop` and not `_loop`: `self._loop` is the armed repeating task,
-- @see setloop(), and a method of that name would answer for it whenever no
-- task is armed — the field is nil, the method is not, and every check for one
-- would find the other
--
function app:_mainloop(opt)
    self:banner()
    if opt.replay then
        self:replay()
    end
    if opt.prompt and opt.prompt ~= "" then
        self:print_user(opt.prompt)
        self:send(opt.prompt)
    end

    while self._running do
        local input = self:readinput()
        if input == nil then
            break
        end
        self:_input(input)
    end
end

-- give the terminal back and put the session away
function app:_shutdown(errors)
    self:_erase()
    terminal.bracketed_paste(false)
    terminal.rawmode_leave()
    jobs.shutdown(self.harness:service("jobs"))
    self.session:save()
    if errors then
        self:print({"", theme.styled("error", "  the session ended with an error:"),
                    theme.styled("error", "  " .. errors), ""})
    end
    self:print({theme.styled("dim", "  session " .. self.session:id() .. " is saved, resume it with `xmake ai -c`"), ""})
end

-- handle one line of input
function app:_input(input)
    if input:trim() == "" then
        return
    end
    if input:startswith("/") then
        self:_runcommand(input:sub(2))
    elseif input:startswith("!") then
        self:_runshell(input:sub(2))
    else
        self:print_user(input)
        self:send(self:_expandfiles(input))
    end
end

-- run a slash command
function app:_runcommand(line)
    local result = self.harness:service("commands"):run(self, line)
    if result.kind == "exit" then
        self._running = false
    elseif result.kind == "prompt" then
        self:print_user("/" .. line)
        self:send(result.text)
    elseif result.kind == "resumed" then
        self:print({theme.styled("dim", "  " .. result.text), ""})
        self:replay()
    elseif result.text then
        self:print({theme.styled(result.iserror and "error" or "dim", text.indent(result.text, "  ")), ""})
    end
end

-- run a shell command directly, e.g. "!xmake build"
function app:_runshell(command)
    local tool = self.harness:service("tools"):get("run_command")
    if not tool then
        return
    end
    self:print({theme.styled("user.bullet", "! ") .. theme.styled("user.text", command)})

    local errors
    local context = {harness = self.harness, config = self.harness:config(), cwd = self.harness:rootdir(),
                     session = self.session, ui = self:handlers(), signal = self.signal, mode = "bypass"}
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
    if not result then
        self:print({theme.styled("error", "  ✗ " .. tostring(errors)), ""})
        return
    end
    self:print_tool(result, {name = "run_command"})
    self.session:append("user", {text = string.format("I ran `%s` in the terminal, the output was:\n\n%s",
        command, result.output)})
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
