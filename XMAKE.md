# xmake-harness

A generic AI agent harness written in pure xmake lua, shipped as an xmake addon which
provides one command: `xmake ai`.

## Layout

```
addon.lua                 the addon manifest, the payloads live in src/
src/plugins/ai            the `xmake ai` task
src/modules/harness       the framework, imported as `harness.*`
  cli/ core/ llm/ tools/ skills/ agents/ commands/ prompt/ context/
  permission/ sandbox/ hooks/ fs/ shell/ ui/ util/ assets/ plugins/
  http/ web/               the web ui: an http+sse server and its page
                           web/session   the conversation and its listeners
                           web/turns     a message, a /command, a !command
                           web/ask       the questions a turn stops to put
                           web/looper    the armed /loop, and its ticking
                           web/changes   what the conversation changed
  web/assets/              the page itself, plain html/css/es modules
  core/reload   read the config, the skills, the agents and the commands again
  config/trust  what this directory is allowed to tell the agent
tests/                    the unit tests, `xmake l tests/run.lua`
                          a file may define `teardown()` — it runs after its
                          tests, e.g. to stop a server it kept up across them
evals/                    the behavioural evals, `xmake l evals/run.lua`
                          they call a real model, so they cost money and the
                          same one can pass four times out of five: what they
                          report is a rate, and a rate which drops after a
                          prompt change is the finding
docs/                     the documentation
```

## Working on it

```bash
source scripts/srcenv.profile     # symlink the plugins/modules into ~/.xmake, no install
xmake ai                          # run it
xmake l tests/run.lua             # the tests, they never call a model
xmake l evals/run.lua             # the evals, they only call a model
XMAKE_HARNESS_DEBUG=1 xmake ai --print "hi"    # log the llm traffic
```

## Rules which matter here

- **The xmake lua sandbox has no `pcall`, `error`, `setmetatable`, `select`, `next`.**
  Use `utils.trycall(f, nil, ...)` / `try{}`, `raise()`, and `core.base.object` instead.
- **No third-party dependency, ever.** The http transport drives `curl` through a pipe,
  the terminal input is relayed through a pipe on posix, the tokenizer is a heuristic.
- Keep the framework build-system agnostic: anything xmake specific belongs in
  `src/modules/harness/plugins/xmake`.
- Every file carries the apache header and follows the xmake source style: the
  `-- imports` block, the comment above each function, `_private` module functions.
- The ui never prints directly: it goes through the app renderers so the live region
  stays consistent.
- A new capability means a seam: an interface, an implementation and a consumer.
  @see docs/architecture.md
