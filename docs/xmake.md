# The xmake enhancement

English | [中文](xmake.zh.md)

The harness is build-system agnostic; the xmake support is the plugin at
`src/modules/harness/plugins/xmake`. It activates itself when the working directory
contains an `xmake.lua`.

## Bringing a project in

A project built with something else is converted in four steps, and the split
between them is the point:

```
/import                     what is here, handed to the xmake-porter subagent
  xmake_import              the targets, as facts — and what could not be worked out
  xmake_import_write        the first draft of the xmake.lua
  xmake_import_verify       configures? builds? the same targets as before?
```

`xmake_import` reads CMake, Visual Studio (`.sln` and `.vcxproj`), Autotools
(`Makefile.am` and `configure.ac`), QMake (`.pro`), Meson, SCons and a
`compile_commands.json` into one neutral model and hands over two lists. The first is the facts —
targets, kinds, sources, includes, defines, dependencies — which have exactly
one right answer and are not worth asking a model for. The second is every place
the reader could not work out on its own, each with its file and line: an
`if(WIN32)` it did not evaluate, a variable it could not expand, a
`find_package` name which is CMake's and not xmake-repo's.

That second list is the conversion. A model given the raw `CMakeLists.txt`
does both halves at once and gets the mechanical one subtly wrong — an expanded
source list, a dependency declared in a subdirectory — in ways nobody notices
until the build runs somewhere else.

### The flags are translated, not copied

A build system written for one compiler states its intentions as that compiler's
flags. Copying them across produces an `xmake.lua` which works on the machine it
was converted on and says nothing about what it wants, so every flag with an api
behind it becomes that api and every flag a mode rule already provides is
dropped:

```cmake
target_compile_options(demo PRIVATE -fvisibility=hidden -Wall -Wextra -O2 -g -std=c++17 -fPIC)
target_link_libraries(demo PRIVATE m pthread z)
```
```lua
target("demo")
    set_kind("binary")
    set_languages("c++17")
    set_warnings("all", "extra")
    set_symbols("hidden")
    add_files("src/main.cpp")
    add_links("z")
    add_syslinks("m", "pthread")
```

`-O2` and `-g` are gone because `mode.debug` and `mode.release` set them, and
their answer is the one which is right on every compiler. `-fPIC` is gone
because xmake already does it for shared libraries. `m` and `pthread` are the
system's; `z` is not, so it stays and comes with a question — most libraries
linked by name should be `add_requires`, and only `xrepo search` can say which.

Nothing is dropped quietly: each of those is a note in the read, so the
conversion can be read against the original and disagreed with. A flag with no
api keeps the compiler it was written for — `add_cxflags("/GR-", {tools = "cl"})` —
because a `/GR-` handed to gcc is an error.

`xmake_import_verify` is not optional: it compares the target list against the
original build system, which is what catches a target that was quietly dropped.
A conversion which builds can still be missing one.

### Checking against the compiler's own record

A `compile_commands.json` is not a build system, which is why it is the most
useful thing here. It is the command line the compiler was actually given, for
every file, with nothing inferred — so `xmake_import_verify` compares the
includes and defines of every file against it:

```
2 files are compiled differently from what `compile_commands.json` records:
- `src/main.c` (demo): missing includedirs vendor, defines EXTRA=2
```

Nothing else catches that. A conversion which builds the right targets with the
wrong `-I` compiles and passes the target comparison. When there is nothing else
to read at all it becomes the source instead: the files which share a set of
flags are grouped into a target, and it says that the names are guesses.

Another build system is another file in `import/`: a module with
`read(dir) -> model` and an entry in the reader table. What every reader does the
same way — the path rule, the link which turns out to be a dependency, the line
continued with a backslash, the flags of a command line, the condition written
down rather than evaluated — is in `import/reader.lua`, so a new one is about
that build system and nothing else.

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
| `xmake_import` | read a cmake/msbuild/meson/scons project as facts |
| `xmake_import_write` | write the first draft of the `xmake.lua` |
| `xmake_import_verify` | does it configure, build, and have the same targets |

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
