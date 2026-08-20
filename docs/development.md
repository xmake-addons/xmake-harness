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
tests/                        the unit tests
```

## The tests

```bash
xmake l tests/run.lua                # all of them
xmake l tests/run.lua text           # one file
```

The tests only cover the pure logic (the text layout, the diff, the frontmatter, the
regex translation, the config merge, the session projection, the permission rules) —
they never call a model.

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
