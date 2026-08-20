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
-- @file        edit_file.lua
--

-- imports
import("harness.fs.fs")
import("harness.ui.diff")
import("harness.util.util")

-- define the tool
function define()
    return {
        name = "edit_file",
        group = "fs",
        permission = "write",
        description = [[Replace an exact string in a file.

- `old_string` must appear exactly once in the file, otherwise add more surrounding
  lines to make it unique, or set `replace_all` to true.
- The whitespace and the indentation must match the file content exactly.
- Read the file before editing it.]],
        parameters = {
            type = "object",
            properties = {
                path        = {type = "string",  description = "The file path to edit."},
                old_string  = {type = "string",  description = "The exact text to replace."},
                new_string  = {type = "string",  description = "The new text, it can be empty to delete the old text."},
                replace_all = {type = "boolean", description = "Replace all the occurrences, false by default."}
            },
            required = {"path", "old_string", "new_string"}
        },
        preview = function (context, args)
            local filepath = fs.resolve(context, args.path)
            local oldtext = os.isfile(filepath) and io.readfile(filepath) or ""
            local newtext = _replace(oldtext, args)
            if not newtext then
                return nil
            end
            return {kind = "diff", filepath = filepath, diff = diff.compute(oldtext, newtext)}
        end
    }
end

-- replace the text
function _replace(oldtext, args)
    local old = args.old_string or ""
    local new = args.new_string or ""
    if old == "" then
        return nil
    end
    local count = 0
    local pos = 1
    while true do
        local s = oldtext:find(old, pos, true)
        if not s then
            break
        end
        count = count + 1
        pos = s + #old
    end
    if count == 0 then
        return nil, 0
    end
    if count > 1 and not args.replace_all then
        return nil, count
    end
    local newtext
    if args.replace_all then
        newtext = _replaceall(oldtext, old, new)
    else
        local s, e = oldtext:find(old, 1, true)
        newtext = oldtext:sub(1, s - 1) .. new .. oldtext:sub(e + 1)
    end
    return newtext, count
end

-- replace all the occurrences of the plain text
function _replaceall(str, old, new)
    local results = {}
    local pos = 1
    while true do
        local s, e = str:find(old, pos, true)
        if not s then
            break
        end
        table.insert(results, str:sub(pos, s - 1))
        table.insert(results, new)
        pos = e + 1
    end
    table.insert(results, str:sub(pos))
    return table.concat(results)
end

-- run the tool
function run(context, args)
    local filepath = fs.resolve(context, args.path)
    fs.checkwritable(context, filepath)
    if not os.isfile(filepath) then
        raise("%s does not exist, use write_file to create it.", args.path)
    end
    local oldtext = io.readfile(filepath) or ""
    local newtext, count = _replace(oldtext, args)
    if not newtext then
        if count == 0 then
            raise("the old_string is not found in %s, please read the file again and match the exact text.", args.path)
        end
        raise("the old_string appears %d times in %s, please add more context to make it unique, or set replace_all to true.", count, args.path)
    end
    if newtext == oldtext then
        raise("the old_string and the new_string are identical, nothing to do.")
    end
    fs.writetext(filepath, newtext)

    local result = diff.compute(oldtext, newtext)
    local shortpath = util.shortpath(filepath, context.cwd)
    return {
        output = string.format("Updated %s (%s%s)", shortpath, diff.summary(result),
            count > 1 and string.format(", %d occurrences", count) or ""),
        display = {
            title = "Update",
            subject = shortpath,
            summary = diff.summary(result),
            kind = "diff",
            filepath = filepath,
            diff = result
        }
    }
end
