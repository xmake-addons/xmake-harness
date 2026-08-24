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
-- @file        dialog.lua
--

--
-- the dialogs of the live region
--
-- a dialog shows what is about to happen, asks one question and offers the
-- numbered answers, in the same frameless style as the tool cards.
--

-- imports
import("harness.util.text")
import("harness.ui.theme")
import("harness.permission.danger")

-- render a question
--
-- @param request   {lines = {..}, question = "..", options = {{text = .., value = ..}},
--                   selected = 1, footer = ".."}
--
function render(request, width)
    local lines = {}
    for _, line in ipairs(request.lines or {}) do
        table.insert(lines, " " .. line)
    end
    table.insert(lines, theme.styled("border", string.rep("╌", math.min(width - 2, 78))))
    table.insert(lines, " " .. theme.styled("text", request.question or "Do you want to proceed?"))
    for idx, option in ipairs(request.options or {}) do
        local active = idx == (request.selected or 1)
        table.insert(lines, " " .. theme.styled(active and "select.active" or "select.normal",
            string.format("%s %d. %s", active and "❯" or " ", idx, option.text)))
    end
    table.insert(lines, "")
    table.insert(lines, " " .. theme.styled("hint", request.footer
        and (request.footer .. " · esc to cancel") or "esc to cancel"))
    return lines
end

-- get the wording of a tool confirmation
--
-- the title is what the tool is really going to do, not its internal name: a
-- command shows its command line, an edit shows its file
--
function confirminfo(tool, args)
    local commandline = tool.commandline and tool.commandline(args) or nil
    if commandline or tool.name == "run_command" or tool.group == "shell" then
        return _commandinfo(tool, args, commandline or args.command or "")
    elseif tool.name == "edit_file" or tool.name == "write_file" then
        return _fileinfo(tool, args)
    elseif tool.permission == "network" then
        return {
            title = string.format("fetch %s", args.url or ""),
            question = "Do you want to fetch this url?",
            alwaystext = "Yes, and do not ask again for the network requests",
            alwaysnote = "the network requests will not ask again",
            rule = tool.name
        }
    end
    local subject = args.path or args.pattern or args.name or args.target or ""
    return {
        title = subject ~= "" and string.format("%s(%s)", tool.name, subject) or tool.name,
        question = string.format("Do you want to run `%s`?", tool.name),
        alwaystext = string.format("Yes, and do not ask again for `%s`", tool.name),
        alwaysnote = string.format("`%s` will not ask again", tool.name),
        rule = tool.name
    }
end

-- the wording of a command
function _commandinfo(tool, args, commandline)
    local scope = _scope(commandline)
    local info = {
        title = commandline,
        subtitle = args.description,
        question = "Do you want to run it?"
    }

    -- there is nothing to grant when we cannot name what we would be granting,
    -- so the offer is simply not made, @see _scope()
    if scope then
        info.alwaystext = string.format("Yes, and do not ask again for `%s`", scope)
        info.alwaysnote = string.format("`%s` will not ask again", scope)
        info.rule = string.format("%s(%s*)", tool.name, scope)
    end
    return info
end

-- what "do not ask again" would cover, or nil when nothing can be named
--
-- `xmake build` and `git status` are more useful scopes than `xmake` alone, and
-- reading them off the front of the line works for a command which is one
-- command. it works for nothing else: `for f in ...; do rm -rf $f; done` reads
-- as the program `for` with the subcommand `f`, and granting `for f*` would
-- wave through every loop the agent ever writes.
--
-- an exact rule is no way out either, because `*` in a rule is a wildcard: the
-- command `rm *.tmp` becomes the rule `rm *`, which is worse than what it was
-- meant to cover. so when the line is not a single plain command, no scope is
-- offered at all — the user can still say yes, once, which is the honest answer
--
function _scope(commandline)
    return danger.scope(commandline)
end

-- the wording of a file change
function _fileinfo(tool, args)
    local filename = path.filename(args.path or "")
    local iscreate = (tool.name == "write_file" and not os.isfile(args.path or ""))
    return {
        title = string.format("%s %s", iscreate and "create" or "edit", args.path or ""),
        question = string.format("Do you want to %s %s?", iscreate and "create" or "make this edit to", filename),
        alwaystext = "Yes, and accept all the file edits of this session (shift+tab)",
        alwaysnote = "the file edits will not ask again",
        rule = "@acceptedits"
    }
end

-- decode one key into a dialog action
--
-- @return  "up", "down", "accept", "cancel", the index of an option, or nil
--
function action(key, count)
    if key.name == "up" or (key.name == "ctrl" and key.ch == "p") then
        return "up"
    elseif key.name == "down" or key.name == "tab" or (key.name == "ctrl" and key.ch == "n") then
        return "down"
    elseif key.name == "enter" then
        return "accept"
    elseif key.name == "escape" or (key.name == "ctrl" and key.ch == "c") then
        return "cancel"
    elseif key.name == "char" then
        local index = tonumber(key.ch)
        if index and index >= 1 and index <= count then
            return index
        elseif key.ch == "y" then
            return 1
        elseif key.ch == "n" then
            return "cancel"
        end
    end
end
