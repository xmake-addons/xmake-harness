# The xmake enhancement

English | [中文](xmake.zh.md)

The harness is build-system agnostic; the xmake support is the plugin at
`src/modules/harness/plugins/xmake`. It activates itself when the working directory
contains an `xmake.lua`.

## The tools

| tool | what it runs |
| --- | --- |
| `xmake_create` | `xmake create [-l lang] [-t template] [-P dir] [name]` — scaffold from a template, or list them |
| `xmake_config` | `xmake f <args>` — the mode, the platform, the toolchain, the options |
| `xmake_build` | `xmake build [-r] [-v] [target]` |
| `xmake_run` | `xmake run <target> <args>` |
| `xmake_test` | `xmake test [name]` |
| `xmake_show` | `xmake show` — the targets, one target, the options, the toolchains |
| `xmake_lua` | run a lua snippet inside the xmake runtime |
| `xrepo` | search/info/install the c/c++ packages |
| `xmake_docs` | look an api up in the [official documentation](https://github.com/xmake-io/xmake-docs) |

`xmake_create` is what starts a new project, a new library or a new target. Around
seventy templates ship with xmake and the template addons add more, so the first
`xmake.lua` and the first source file are fetched rather than invented — which is
also how a new project gets your layout instead of the model's. The
`xmake-templates` skill holds the catalogue; the tool only runs the command.

`xmake_config`, `xmake_build`, `xmake_run`, `xmake_test` and `xmake_show` take a
`dir`, which becomes `-P <dir>`. Every tool otherwise runs in the directory the
session was started in, which would leave a project just created in a
subdirectory as the one project the agent cannot build.

Every xmake call carries `-y`, so the confirmations — generating a missing
`xmake.lua`, installing the packages of `add_requires` — never wait for an answer
nobody is there to give. It goes directly after the task name, because the last
argument of most tasks is a value: `xmake build demo -y` reads `-y` as a second
target and refuses it.

`xmake_lua` is the reason the agent never needs python or bash for a temporary
script: the whole xmake script api (`os`, `io`, `path`, `import`) is available and it
behaves the same on windows, macos and linux.

## The command line, without tokens

`/xmake` runs xmake itself, in your terminal, exactly as you would type it:

```
/xmake                     the same as a bare `xmake`: build
/xmake f -m debug          configure
/xmake build -vD           build, verbose
/xmake run -d myapp        run under the debugger
/xmake clean, test, show, project -k compile_commands, ...
```

The arguments are passed through untouched, so everything you know about the
xmake command line is still true here, and `tab` completes the subcommand.

The point is what it does *not* do: the output goes to your screen and nowhere
else. It costs no tokens, and the model never sees it. That is the difference
from `!xmake build`, which hands the output to the model afterwards, and from the
`xmake_build` tool, which the model runs by itself. This one is yours — a build
you run to see for yourself, without a second terminal.

For the duration of the command the terminal is given back: raw mode off, the
live region taken down, so xmake gets its own colors and progress bar, `ctrl+c`
reaches it, and it can ask you something. When it fails, the summary says who
did not see the output, because the next thought after a broken build is usually
to ask the agent about it — and it was not watching.

## The skills

The plugin registers the [xmake-skills](https://github.com/xmake-io/xmake-skills)
repository, ~50 skills covering the packages, the rules, the toolchains, the c++
modules, the cross compilation, the packaging, the build cache, the distributed
builds and the language-specific setups.

```bash
xmake ai --command=xmake-skills      # clone or update them (or /xmake-skills in the tui)
```

It looks for them in this order: `plugins.xmake.skillsdir`,
`~/.xmake/harness/skills/xmake-skills/skills`, `~/.claude/xmake-skills/skills`.

## The documentation

"How do I do X in `xmake.lua`" is the most common question an agent has, and the
answer it invents from memory is often a plausible api which does not exist.

It works with nothing installed: the page which describes the api is fetched
from the upstream documentation and cached under `~/.xmake/harness/docs/cache`
(a couple of hundred kilobytes, refreshed weekly). The first lookup costs a
second, every one after it is instant.

Two places are consulted before the network, and only two: the checkout you
configured, and the one `/xmake-docs` cloned. The harness never goes looking
around your home directory for something which might be an unrelated fork or a
two-year-old copy — a wrong answer from a stale checkout is worse than fetching
the page.

```json
{"plugins": {"xmake": {"docsdir": "/path/to/your/xmake-docs"}}}
```

`/xmake-docs` clones the whole documentation, which is what you want offline:

```
/xmake-docs            clone or update the whole documentation (it asks first)
/xmake-docs status     where it is and how many apis it knows
```

The tool then has two modes, and the precise one is cheap:

```lua
xmake_docs(api = "add_files")     -- one section: the prototype and the parameters
xmake_docs(keyword = "qt.widgetapp")  -- a search, when the api name is unknown
```

An unknown api answers with the closest names instead of nothing, and the
Chinese translation is used when the user writes in Chinese. An existing
checkout (`~/projects/**/xmake-docs`, a configured `plugins.xmake.docsdir`) is
reused as is, so nobody pays for a second copy.

## The agent

`xmake-builder` — a subagent which fixes a broken build by iterating build → read the
error → fix → build, with the xmake tools and the xmake skills. The main agent
delegates to it with `run_agent`.

## The prompt

When the project has an `xmake.lua`, the plugin adds:

- the environment facts: the xmake version and the target names (parsed from the
  `xmake.lua` files directly, so nothing is configured behind your back)
- a short section on which tools to prefer and the rules which matter in an
  `xmake.lua` (the description scope vs the script scope, `add_requires` instead of
  the manual flags, the builtin rules)

## Configuration

```json
{"plugins": {"xmake": {"enabled": true, "skillsdir": "/path/to/skills", "docsdir": "/path/to/xmake-docs"}}}
```

## Adding another build system

Copy `plugins/cmake/plugin.lua`: ~140 lines register three tools and one prompt fact.
That is the whole contract.
