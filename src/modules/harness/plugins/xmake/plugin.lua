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
-- @file        plugin.lua
--

--
-- the xmake enhancement plugin
--
-- the harness itself knows nothing about xmake, this plugin adds everything:
--
--   - the xmake tools: configure, build, run, test, show, lua, xrepo
--   - the xmake skill pack from https://github.com/xmake-io/xmake-skills,
--     registered as a source and fetched on demand, never bundled
--   - the xmake documentation search
--   - the `xmake-builder` subagent
--   - the project facts in the system prompt
--
-- it is loaded automatically when it is enabled, and a project which does not
-- use xmake simply never sees these tools.
--

-- imports
import("harness.util.text")
import("harness.util.util")
import("harness.shell.exec")
import("harness.config.config")
import("harness.skills.installer")

-- describe the plugin
function define()
    return {
        name = "xmake",
        description = "The xmake build enhancement: the tools, the skills, the docs and the builder agent."
    }
end

-- apply the plugin to the harness
function apply(harness, definition)
    local settings = (harness:config().plugins or {}).xmake or {}
    if settings.enabled == false then
        return
    end

    -- register the tools
    local tools = harness:service("tools")
    for _, tool in ipairs(_tools(harness)) do
        tools:add(tool)
    end

    -- register the agents of this plugin
    harness:service("agents"):adddir(path.join(definition.dir, "agents"), "plugin:xmake")

    -- register the xmake skill pack
    --
    -- it is maintained in its own repository and it is NOT bundled here: the
    -- user installs it with `/skills install xmake` when they want it, and
    -- updates it with `/skills update xmake`
    --
    installer.register(harness, {
        name = "xmake-skills",
        url = "https://github.com/xmake-io/xmake-skills.git",
        description = "The xmake build skills: the packages, the rules, the toolchains, the packaging, .."
    })
    installer.register(harness, {
        name = "xmake",
        url = "https://github.com/xmake-io/xmake-skills.git",
        packname = "xmake-skills",
        description = "The xmake build skills (an alias of xmake-skills)"
    })

    -- an existing claude code checkout is reused as is, so one copy serves both
    local skillsdir = _skillsdir(settings)
    if skillsdir then
        harness:service("skills"):adddir(skillsdir, "plugin:xmake")
    end

    -- tell the user once that the skills are available but not installed
    local hasskills = skillsdir ~= nil or installer.isinstalled("xmake-skills")
    if os.isfile(path.join(harness:rootdir(), "xmake.lua")) and not hasskills then
        harness:service("notices", table.join(harness:service("notices") or {},
            {"the xmake skills are not installed yet, run `/skills install xmake` to get the build recipes"}))
    end

    -- contribute the project facts to the system prompt
    harness:on("prompt/environment", function (lines, opt)
        local rootdir = harness:rootdir()
        if os.isfile(path.join(rootdir, "xmake.lua")) then
            table.insert(lines, string.format("xmake project: yes (%s)", _xmakeversion()))
            local targets = _targets(rootdir)
            if #targets > 0 then
                table.insert(lines, string.format("xmake targets: %s", table.concat(targets, ", ")))
            end
        end
        return lines
    end, {owner = "xmake"})

    harness:on("prompt/sections", function (sections, opt)
        local rootdir = harness:rootdir()
        if not os.isfile(path.join(rootdir, "xmake.lua")) then
            return sections
        end
        table.insert(sections, {name = "xmake", content = _promptsection(hasskills)})
        return sections
    end, {owner = "xmake"})
end

-- the system prompt section of the xmake projects
function _promptsection(hasskills)
    local lines = {"# Building with xmake", "",
        "This project is built with xmake, use the `xmake_*` tools instead of the raw",
        "shell commands, they report the errors in a structured way:", "",
        "- `xmake_config` to configure (the modes, the toolchains, the options)",
        "- `xmake_build` to build, it is the fastest way to check that your change compiles",
        "- `xmake_run` / `xmake_test` to run the targets and the tests",
        "- `xmake_show` to inspect the project: the targets, the options, the toolchains",
        "- `xmake_lua` to run a small lua script inside the xmake runtime, prefer it over",
        "  writing the shell/python scripts: it is cross-platform and has no dependency",
        "- `xrepo` to search and inspect the c/c++ packages", "",
        "Rules which matter in an `xmake.lua`:", "",
        "- the description scope (`target`, `add_files`, ..) is declarative, the script",
        "  scope (`on_load`, `on_build`, ..) is imperative, never mix them",
        "- add the dependencies with `add_requires`/`add_packages`, not with the manual",
        "  include and link flags",
        "- prefer the builtin rules (`mode.debug`, `mode.release`, ..) over the hand-written flags"}
    if hasskills then
        table.insert(lines, "")
        table.insert(lines, "The `xmake-*` skills hold the detailed recipes, load the matching one with")
        table.insert(lines, "`use_skill` before doing the work.")
    end
    return table.concat(lines, "\n")
end

-- get the xmake version
function _xmakeversion()
    local version = _g.xmakeversion
    if version == nil then
        local result = try { function () return os.iorunv(exec.xmakeprogram(), {"--version"}) end }
        version = result and (result:match("xmake v([%d%.%+]+)") or "unknown") or "unknown"
        _g.xmakeversion = version
    end
    return "v" .. version
end

-- get the target names of the project, we parse them from the xmake.lua files
-- directly so we never trigger a configure
function _targets(rootdir)
    local targets = {}
    local files = {path.join(rootdir, "xmake.lua")}
    for _, filepath in ipairs(os.files(path.join(rootdir, "*", "xmake.lua"))) do
        table.insert(files, filepath)
    end
    for _, filepath in ipairs(files) do
        if os.isfile(filepath) then
            local content = io.readfile(filepath) or ""
            for name in content:gmatch("target%s*%(%s*[\"']([%w%._%-]+)[\"']") do
                table.insert(targets, name)
            end
        end
    end
    return util.unique(targets)
end

-- find the xmake skills directory
function _skillsdir(settings)
    local candidates = {}
    if settings.skillsdir then
        table.insert(candidates, settings.skillsdir)
    end
    table.insert(candidates, path.join(config.homedir(), "skills", "xmake-skills", "skills"))
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if home then
        table.insert(candidates, path.join(home, ".claude", "xmake-skills", "skills"))
    end
    for _, dir in ipairs(candidates) do
        if os.isdir(dir) then
            return dir
        end
    end
end

-- run the xmake command and make the tool result
function _runxmake(context, argv, opt)
    opt = opt or {}
    local result = exec.run(context, {
        program = exec.xmakeprogram(),
        argv = argv,
        cwd = opt.cwd,
        timeout = opt.timeout,
        envs = {XMAKE_COLORTERM = "nocolor"}})
    local output = result.output
    if output == "" then
        output = result.exitcode == 0 and "(no output)" or string.format("(no output, exited with %d)", result.exitcode)
    end
    if result.exitcode ~= 0 then
        output = output .. string.format("\n\n[xmake %s exited with %d]", argv[1] or "", result.exitcode)
    end
    local lines = text.lines(output)
    return {
        output = output,
        iserror = result.exitcode ~= 0,
        display = {
            title = opt.title or ("xmake " .. (argv[1] or "")),
            subject = opt.subject,
            summary = opt.summary or string.format("%s · %d line%s", result.exitcode == 0 and "ok" or "failed",
                #lines, #lines == 1 and "" or "s"),
            kind = "output",
            output = output
        }
    }
end

-- the tools of this plugin
function _tools(harness)
    return {
        {
            name = "xmake_config",
            group = "xmake",
            permission = "exec",
            description = [[Configure the xmake project, it is `xmake f <args> -y`.

e.g. `-m debug`, `-m release`, `--toolchain=clang`, `-p android --ndk=..`, `--myopt=true`.
Run it before building when the mode, the platform, the toolchain or an option changes.]],
            parameters = {
                type = "object",
                properties = {
                    args = {type = "string", description = "The configure arguments, e.g. `-m debug --toolchain=clang`."}
                }
            },
            run = function (context, args)
                local argv = {"f", "-y"}
                for _, item in ipairs(_splitargs(args.args or "")) do
                    table.insert(argv, item)
                end
                return _runxmake(context, argv, {title = "Configure", subject = args.args})
            end
        },
        {
            name = "xmake_build",
            group = "xmake",
            permission = "exec",
            description = [[Build the xmake project.

It is the fastest way to verify a change. On a failure the compiler output is
returned as is, do not guess the error, read it.]],
            parameters = {
                type = "object",
                properties = {
                    target  = {type = "string",  description = "The target to build, all the targets by default."},
                    rebuild = {type = "boolean", description = "Rebuild everything, false by default."},
                    verbose = {type = "boolean", description = "Show the compiler command lines, false by default."}
                }
            },
            run = function (context, args)
                local argv = {"build"}
                if args.rebuild then
                    table.insert(argv, "-r")
                end
                if args.verbose then
                    table.insert(argv, "-v")
                end
                if args.target and args.target ~= "" then
                    table.insert(argv, args.target)
                end
                return _runxmake(context, argv, {title = "Build", subject = args.target or "all", timeout = 1800000})
            end
        },
        {
            name = "xmake_run",
            group = "xmake",
            permission = "exec",
            description = "Run a target of the xmake project, it is `xmake run <target> <args>`.",
            parameters = {
                type = "object",
                properties = {
                    target = {type = "string", description = "The target name, the default target if it is empty."},
                    args   = {type = "string", description = "The arguments passed to the program."}
                }
            },
            run = function (context, args)
                local argv = {"run"}
                if args.target and args.target ~= "" then
                    table.insert(argv, args.target)
                end
                for _, item in ipairs(_splitargs(args.args or "")) do
                    table.insert(argv, item)
                end
                return _runxmake(context, argv, {title = "Run", subject = args.target})
            end
        },
        {
            name = "xmake_test",
            group = "xmake",
            permission = "exec",
            description = "Run the tests of the xmake project, it is `xmake test [name]`.",
            parameters = {
                type = "object",
                properties = {
                    name = {type = "string", description = "The test name or the pattern, all the tests by default."}
                }
            },
            run = function (context, args)
                local argv = {"test"}
                if args.name and args.name ~= "" then
                    table.insert(argv, args.name)
                end
                return _runxmake(context, argv, {title = "Test", subject = args.name or "all", timeout = 1800000})
            end
        },
        {
            name = "xmake_show",
            group = "xmake",
            permission = "read",
            description = [[Inspect the xmake project and the xmake installation.

- `targets`     list the targets
- `target:<name>` show one target: the files, the deps, the flags
- `options`     list the options
- `toolchains`  list the toolchains
- `info`        show the project information
- `envs`        show the xmake environment variables]],
            parameters = {
                type = "object",
                properties = {
                    what = {type = "string", description = "One of `targets`, `target:<name>`, `options`, `toolchains`, `info`, `envs`."}
                },
                required = {"what"}
            },
            run = function (context, args)
                local what = args.what or "info"
                local argv = {"show"}
                if what == "targets" then
                    table.insert(argv, "-l")
                    table.insert(argv, "targets")
                elseif what:startswith("target:") then
                    table.insert(argv, "-t")
                    table.insert(argv, what:sub(8))
                elseif what == "info" then
                    -- the default output
                elseif what ~= "" then
                    table.insert(argv, "-l")
                    table.insert(argv, what)
                end
                return _runxmake(context, argv, {title = "Show", subject = what})
            end
        },
        {
            name = "xmake_lua",
            group = "xmake",
            permission = "exec",
            description = [[Run a lua script inside the xmake runtime.

This is the right way to write the temporary scripts: no python, no bash, no extra
dependency, and it works the same on windows, macos and linux. The whole xmake
script api is available (`os`, `io`, `path`, `import(..)`, ..).

e.g. `print(os.host()); import("core.project.project"); for _, t in pairs(project.targets()) do print(t:name()) end`]],
            parameters = {
                type = "object",
                properties = {
                    script = {type = "string", description = "The lua code to run."},
                    file   = {type = "string", description = "A lua script file to run instead of the inline code."}
                }
            },
            run = function (context, args)
                if args.file and args.file ~= "" then
                    return _runxmake(context, {"lua", args.file}, {title = "Lua", subject = args.file})
                end
                local script = args.script or ""
                if script == "" then
                    raise("the script is empty!")
                end
                local scriptfile = os.tmpfile() .. ".lua"
                io.writefile(scriptfile, script)
                local result = _runxmake(context, {"lua", scriptfile}, {title = "Lua", subject = text.truncate(script:gsub("%s+", " "), 60)})
                os.tryrm(scriptfile)
                return result
            end
        },
        {
            name = "xrepo",
            group = "xmake",
            permission = "exec",
            description = [[Search and inspect the c/c++ packages of the xmake package repository.

e.g. `search zlib`, `info zlib`, `install zlib`, `list`.
Use it before adding an `add_requires(..)` to check the real package name and version.]],
            parameters = {
                type = "object",
                properties = {
                    command = {type = "string", description = "The xrepo command, e.g. `search zlib`."}
                },
                required = {"command"}
            },
            run = function (context, args)
                local argv = {"lua", "private.xrepo"}
                for _, item in ipairs(_splitargs(args.command)) do
                    table.insert(argv, item)
                end
                return _runxmake(context, argv, {title = "xrepo", subject = args.command, timeout = 600000})
            end
        },
        {
            name = "xmake_docs",
            group = "xmake",
            permission = "read",
            description = [[Search the xmake documentation.

It searches the local clone of https://github.com/xmake-io/xmake-docs if it is
available, so the answers come from the real documentation instead of the memory.]],
            parameters = {
                type = "object",
                properties = {
                    keyword = {type = "string",  description = "The keyword to search, e.g. `add_requires`."},
                    limit   = {type = "integer", description = "The maximum number of matches, 20 by default."}
                },
                required = {"keyword"}
            },
            run = function (context, args)
                local docsdir = _docsdir(context.config)
                if not docsdir then
                    return {
                        output = "the local xmake documentation is not available.\n"
                            .. "clone it with `git clone --depth 1 https://github.com/xmake-io/xmake-docs "
                            .. path.join(config.homedir(), "docs", "xmake-docs") .. "`,\n"
                            .. "or use fetch_url with https://xmake.io/api/description/ instead.",
                        iserror = true
                    }
                end
                local searchtool = context.harness:service("tools"):get("search_text")
                return searchtool.run(context, {
                    pattern = args.keyword,
                    path = docsdir,
                    include = "*.md",
                    limit = args.limit or 20})
            end
        }
    }
end

-- find the xmake documentation directory
function _docsdir(harnessconfig)
    local settings = (harnessconfig.plugins or {}).xmake or {}
    local candidates = {}
    if settings.docsdir then
        table.insert(candidates, settings.docsdir)
    end
    table.insert(candidates, path.join(config.homedir(), "docs", "xmake-docs"))
    for _, dir in ipairs(candidates) do
        if os.isdir(dir) then
            return dir
        end
    end
end

-- split the argument string, it keeps the quoted parts together
function _splitargs(str)
    local results = {}
    for item in (str or ""):gmatch("%S+") do
        table.insert(results, item)
    end
    return results
end
