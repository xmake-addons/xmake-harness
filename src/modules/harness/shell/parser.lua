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
-- @file        parser.lua
--

--
-- the small, conservative shell parser used by permission checks
--
-- This is deliberately an analysis parser, not a shell implementation. It
-- produces enough structure to judge commands and their file effects. Anything
-- it cannot parse with confidence is marked opaque so callers can ask instead
-- of silently allowing it.
--

-- the operators are longest first
local OPERATORS = {"2>&1", "1>&2", "&&", "||", ">>", "2>", "1>", "<&", ";", "|", "&", ">", "<", "(", ")"}

-- get the shell dialect
function dialect(opt)
    if type(opt) == "string" then
        return opt
    end
    if type(opt) == "table" and opt.dialect then
        return opt.dialect
    end
    local host = os.host()
    return host == "windows" and "cmd" or "posix"
end

-- tokenize a shell command while preserving operators and quoted words
--
-- @return  {tokens = {{kind = "word"|"op", text = ".."}}, opaque = bool}
function lex(command, opt)
    command = tostring(command or "")
    local kind = dialect(opt)
    local tokens = {}
    local value = {}
    local quote = nil
    local escaped = false
    local started = false
    local opaque = false
    local substitution = 0
    local backtick = false
    local index = 1

    local function pushword()
        if started then
            table.insert(tokens, {kind = "word", text = table.concat(value)})
            value = {}
            started = false
        end
    end

    local function add(ch)
        table.insert(value, ch)
        started = true
    end

    while index <= #command do
        local ch = command:sub(index, index)
        local two = command:sub(index, index + 1)

        if escaped then
            add(ch)
            escaped = false
            index = index + 1
        elseif quote then
            if ch == quote then
                quote = nil
                started = true
                index = index + 1
            elseif ch == "\\" and kind == "posix" and quote == '"' then
                escaped = true
                started = true
                index = index + 1
            elseif ch == "`" and kind == "powershell" and quote == '"' then
                escaped = true
                started = true
                index = index + 1
            else
                add(ch)
                index = index + 1
            end
        elseif kind == "cmd" and ch == "^" then
            escaped = true
            started = true
            index = index + 1
        elseif kind == "posix" and ch == "\\" then
            escaped = true
            started = true
            index = index + 1
        elseif kind == "powershell" and ch == "`" then
            escaped = true
            started = true
            index = index + 1
        elseif ch == "'" or ch == '"' then
            quote = ch
            started = true
            index = index + 1
        elseif kind ~= "cmd" and two == "$(" then
            local depth = 1
            local endindex = index + 2
            while endindex <= #command and depth > 0 do
                local innerch = command:sub(endindex, endindex)
                if innerch == "(" then
                    depth = depth + 1
                elseif innerch == ")" then
                    depth = depth - 1
                end
                endindex = endindex + 1
            end
            add(command:sub(index, endindex - 1))
            if depth > 0 then
                opaque = true
            end
            index = endindex
        elseif kind ~= "cmd" and ch == "`" then
            add(ch)
            backtick = not backtick
            index = index + 1
        elseif substitution > 0 and ch == ")" then
            add(ch)
            substitution = substitution - 1
            index = index + 1
        elseif ch == " " or ch == "\t" or ch == "\r" or ch == "\n" then
            if substitution == 0 and not backtick then
                pushword()
                if ch == "\n" then
                    table.insert(tokens, {kind = "op", text = ";"})
                end
            else
                add(ch)
            end
            index = index + 1
        elseif substitution == 0 and not backtick then
            local found = nil
            for _, op in ipairs(OPERATORS) do
                if command:sub(index, index + #op - 1) == op then
                    found = op
                    break
                end
            end
            if found then
                pushword()
                table.insert(tokens, {kind = "op", text = found})
                index = index + #found
            else
                add(ch)
                index = index + 1
            end
        else
            add(ch)
            index = index + 1
        end
    end

    pushword()
    if quote or escaped or substitution > 0 or backtick then
        opaque = true
    end
    return {tokens = tokens, opaque = opaque, dialect = kind}
end

-- parse a script into command nodes and their redirections
--
-- @return {commands = {{words = {}, redirects = {}, separator = "&&"}}, opaque = bool}
function parse(command, opt)
    local result = lex(command, opt)
    local commands = {}
    local words = {}
    local redirects = {}
    local pending = nil
    local separator = nil

    local function flush()
        if #words > 0 or #redirects > 0 then
            table.insert(commands, {words = words, redirects = redirects, separator = separator})
        end
        words = {}
        redirects = {}
        pending = nil
        separator = nil
    end

    for _, token in ipairs(result.tokens) do
        if token.kind == "op" then
            local op = token.text
            if pending then
                -- A shell operator cannot be the filename after `>`. Keep
                -- parsing the following command, but force confirmation for
                -- this malformed/ambiguous construct instead of swallowing it
                -- into the preceding command.
                result.opaque = true
                pending = nil
                flush()
                separator = op
            elseif op == ">" or op == ">>" or op == "<" or op == "2>" or op == "1>"
                or op == "<&" then
                pending = op
            elseif op == "2>&1" or op == "1>&2" then
                table.insert(redirects, {operator = op, target = op:sub(4), descriptor = op})
            else
                flush()
                separator = op
            end
        elseif pending then
            table.insert(redirects, {operator = pending, target = token.text, descriptor = pending})
            pending = nil
        else
            table.insert(words, token.text)
        end
    end
    local dangling_redirect = pending ~= nil
    flush()
    if dangling_redirect then
        result.opaque = true
    end
    result.commands = commands
    return result
end

-- return the words of the first command, for legacy callers
function words(command, opt)
    local result = parse(command, opt)
    local first = result.commands[1]
    return first and first.words or {}, result.opaque
end

-- return command fragments in source order, for legacy permission checks
function subcommands(command, opt)
    local result = parse(command, opt)
    local output = {}
    for _, node in ipairs(result.commands) do
        if #node.words > 0 then
            local commandline = table.concat(node.words, " ")
            for _, redirect in ipairs(node.redirects or {}) do
                commandline = commandline .. " " .. redirect.operator .. " " .. redirect.target
            end
            table.insert(output, commandline)
            for _, word in ipairs(node.words) do
                local start = word:find("$(", 1, true)
                if start then
                    local depth = 1
                    local finish = start + 2
                    while finish <= #word and depth > 0 do
                        local nestedch = word:sub(finish, finish)
                        if nestedch == "(" then
                            depth = depth + 1
                        elseif nestedch == ")" then
                            depth = depth - 1
                        end
                        finish = finish + 1
                    end
                    if depth == 0 then
                        local nested = word:sub(start + 2, finish - 2)
                        for _, part in ipairs(subcommands(nested, opt)) do
                            table.insert(output, part)
                        end
                    end
                end
            end
        end
    end
    return output, result.opaque
end
