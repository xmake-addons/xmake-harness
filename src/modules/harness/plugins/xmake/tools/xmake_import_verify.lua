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
-- @file        xmake_import_verify.lua
--

--
-- check a conversion against the project it came from
--
-- @see harness.plugins.xmake.import.verify
--

-- imports
import("harness.plugins.xmake.import.verify")

-- define the tool
function define()
    return {
        name = "xmake_import_verify",
        group = "xmake",
        permission = "exec",
        description = [[Check a converted project: does it configure, does it build, and does it
have the targets the original had.

Run it after writing the `xmake.lua` and after every fix. A conversion which
builds is not necessarily right — a target which was quietly dropped builds
perfectly — so it compares the target list against the original build system as
well, and says which are missing.

Set `build` to false for the quick answer (configure and compare only).]],
        parameters = {
            type = "object",
            properties = {
                dir    = {type = "string",  description = "The project directory, the working directory by default."},
                build  = {type = "boolean", description = "Build it too, true by default."},
                reader = {type = "string",  description = "Which original to compare against, detected by default."}
            }
        },
        commandline = function (args)
            return string.format("verify the conversion in %s", args.dir or ".")
        end
    }
end

-- run the tool
function run(context, args)
    local rootdir = path.absolute(args.dir or ".", context.cwd)
    if not os.isdir(rootdir) then
        raise("%s is not a directory.", args.dir or ".")
    end

    local result, errors = verify.check(rootdir, {
        context = context,
        build = args.build ~= false,
        reader = args.reader
    })
    if not result then
        raise(tostring(errors))
    end

    local ok = result.configured and (result.built ~= false)
    local missing = #result.missing
    return {
        output = verify.report(result),
        iserror = not ok or missing > 0,
        display = {
            title = "Verify",
            subject = path.relative(rootdir, context.cwd),
            summary = not result.configured and "does not configure"
                or missing > 0 and string.format("%d target%s missing", missing,
                                                 missing == 1 and "" or "s")
                or result.built == false and "does not build"
                or "builds, same targets"
        }
    }
end
