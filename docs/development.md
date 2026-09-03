# Development

English | [中文](development.zh.md)

## Running from source

```bash
git clone https://github.com/xmake-io/xmake-harness.git
cd xmake-harness
source scripts/srcenv.profile     # links the plugins and the modules into ~/.xmake
xmake ai
```

The profile creates three symlinks, so every edit takes effect immediately with no
reinstall:

```
~/.xmake/plugins/ai       -> src/plugins/ai
~/.xmake/plugins/harness  -> src/plugins/harness
~/.xmake/modules/harness  -> src/modules/harness
```

Remove them with `source scripts/srcenv.profile --unlink`.

## The layout

```
addon.lua                     the addon manifest
src/plugins/ai                the `xmake ai` task
src/modules/harness           the framework
  cli/                        the entries: the tui, the headless runner, the management
  core/                       the context, the session, the agent loop
  llm/                        the transport and the providers
  tools/                      the registry, the pipeline, the builtin tools
  skills/ agents/ commands/   the registries of the markdown assets
  prompt/ context/            the system prompt and the compaction
  permission/ sandbox/ hooks/ the policy seams
  fs/ shell/                  the filesystem and the process seams
  ui/                         the terminal, the theme, the editor, the renderers
  assets/                     the builtin agents, commands and skills
  plugins/                    the builtin plugins: xmake, cmake
tests/                        the unit tests, grouped by what they are about
  fixtures/import/            one small project per build system, with sources
```

## The tests

```bash
xmake l tests/run.lua                # all of them
xmake l tests/run.lua text           # one file
xmake l tests/run.lua import/        # one group
xmake l tests/run.lua replay loop    # several
```

They are grouped by what they are about — `core/`, `tools/`, `ui/`, `web/`,
`skills/`, `agents/`, `import/`, `xmake/`, `llm/` — and the group is part of the
name a failure is reported under, so a red line says where to look.

Most of them cover the pure logic: the text layout, the diff, the frontmatter, the
regex translation, the config merge, the session projection, the permission rules.

The rest drive **whole turns** — the step loop, the tool pipeline, the guards, the
streaming renderer — against a recorded model instead of a real one. None of the
tests reach the network.

### Converting a real project

`tests/fixtures/import/<name>` is one small project — a static library and a
binary which uses it — written the way each build system writes it, with real
sources beside it. Every reader is checked against a project rather than a
snippet, and the conversion is **built**:

```
cmake  autotools  qmake  meson  scons  bazel  vcxproj  ndkbuild  makefile  compiledb
```

The library is what makes it a test: a conversion which loses the dependency
compiles and fails to link, and one which loses the include directory fails to
compile — neither of which a test on the model alone would notice. Two of them
are not built here and say why in the table: an `Android.mk` links the ndk's
`log`, and a compile database has no target names to check against.

Adding a build system means adding a directory there; `tests/import/fixtures.lua`
covers it without being changed.

### Recording a model

The `replay` adapter answers from a file. That is what makes the layer above the
llm seam testable at all: driving a turn used to mean paying for a completion and
accepting whatever it decided to do that time.

Record a real session:

```bash
xmake ai --config=providers.deepseek.record=/tmp/cassette.json
xmake ai "read xmake.lua and say what it builds"
xmake ai --config=providers.deepseek.record=      # stop recording
```

Play it back, with no key and no network:

```json
{"provider": "replay",
 "providers": {"replay": {"kind": "replay", "cassette": "/tmp/cassette.json",
                          "models": {"main": "recorded", "small": "recorded"}}}}
```

A cassette is a list of turns, and a hand-written one is usually clearer than a
recording — this is how a test makes a model do something a real one rarely
would, like asking for the very same thing twelve times over:

```json
{"turns": [
  {"content": "let me look",
   "toolcalls": [{"name": "read_file", "arguments": "{\"path\": \"xmake.lua\"}"}]},
  {"content": "it builds one target."}
]}
```

`tests/replay.lua` is the worked example: it drives tool calls, several rounds,
the step budget and every one of the guards.

## Debugging

```bash
XMAKE_HARNESS_DEBUG=1 xmake ai --print "hi"     # log every request/response
tail -f ~/.xmake/harness/debug.log
```

`xmake ai --doctor` (or `/doctor` in the tui) checks curl, git, the api key, the
loaded assets, the sandbox backends and the terminal.

The sessions are plain json in `~/.xmake/harness/sessions/`, `xmake ai --list=sessions`
lists them and `xmake ai -r <id>` replays one in the tui.

## The runtime constraints

The harness runs inside the xmake lua sandbox, where the following are **not**
available: `pcall`/`xpcall`, `error`, `setmetatable`/`getmetatable`, `rawget`,
`select`, `next`, `require`, `io.popen`, the sockets with tls.

Use instead:

| instead of | use |
| --- | --- |
| `pcall(f, a)` | `utils.trycall(f, nil, a)` or `try {function () .. end, catch {..}}` |
| `error("..")` | `raise("..")` |
| `setmetatable` | `import("core.base.object")` and `object {_init = {..}}` |
| a http client | `harness.llm.transport` (curl through a pipe) |
| a process spawn | `harness.shell.exec` |
| `print` for the ui | the app renderers, so the live region stays consistent |

The module state is per import instance; use `_g` for a module level cache.

## The style

Follow the xmake source style: the apache header on every file, the lower case
function names, the `_private` prefix for the module locals, the comment above every
function saying what it does and why, and the `-- imports` block at the top.
