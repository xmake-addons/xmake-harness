# The xmake enhancement

English | [中文](xmake.zh.md)

The harness is build-system agnostic; the xmake support is the plugin at
`src/modules/harness/plugins/xmake`. It activates itself when the working directory
contains an `xmake.lua`.

## The tools

| tool | what it runs |
| --- | --- |
| `xmake_config` | `xmake f <args> -y` — the mode, the platform, the toolchain, the options |
| `xmake_build` | `xmake build [-r] [-v] [target]` |
| `xmake_run` | `xmake run <target> <args>` |
| `xmake_test` | `xmake test [name]` |
| `xmake_show` | `xmake show` — the targets, one target, the options, the toolchains |
| `xmake_lua` | run a lua snippet inside the xmake runtime |
| `xrepo` | search/info/install the c/c++ packages |
| `xmake_docs` | search a local clone of [xmake-docs](https://github.com/xmake-io/xmake-docs) |

`xmake_lua` is the reason the agent never needs python or bash for a temporary
script: the whole xmake script api (`os`, `io`, `path`, `import`) is available and it
behaves the same on windows, macos and linux.

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
