# Sessions and context

English | [中文](context.zh.md)

## The session log

Every turn is appended to a log, and that log is the only source of truth:

```
user       {text}
assistant  {text, reasoning, toolcalls, model}
tool       {id, name, arguments, output, iserror, duration, display}
notice     {text, level}      -- local only, never sent to the model
compact    {summary}          -- the compaction boundary
```

The transcript, the resume, the export, the token statistics and what the model
sees are all derived from it, so they can never drift apart.

## Per project

The sessions are stored per project directory, the same way claude code does it:

```
~/.xmake/harness/projects/-Users-ruki-projects-foo/6a86cfc5-bbda-14ce.json
```

So `/sessions` shows the history of the project you are in, and resuming never
scans the sessions of the other projects.

```
/sessions              the recent sessions of this project
/sessions all          every project
/sessions remove <id>  delete one
/resume <id>           resume it, the transcript is replayed
/clear                 start a new one
/export [path]         write the conversation to markdown
```

```bash
xmake ai -c            # continue the last session of this directory
xmake ai -r <id>       # resume a specific one
xmake ai --list=sessions
```

## What fills the window

```
/context
```

```
███░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  12%

  █ system prompt     5.0k
  █ tool schemas      2.2k
  █ your messages       412
  █ model replies       890
  █ tool results       7.1k

  15.6k of 131.1k tokens · mode: auto
  6 old tool results pruned, 2 superseded reads dropped (~18.2k tokens saved)
```

## How the context is optimized

The log keeps everything; what the model sees is an optimized *projection* of
it. Three mechanisms run in order, each cheaper than the next one:

**1. Tool output truncation** — a single tool result is capped at
`tools.maxoutput` (60000 bytes) when it is produced, and the note says what was
cut.

**2. Pruning (the microcompaction)** — above `context.prunethreshold` (55% of
the window), the tool outputs of the older turns are replaced with a short
placeholder:

```
[the output of `read_file` was dropped to save the context: 24188 bytes,
 it is out of the recent context. run it again if you still need it.]
```

The recent turns (`context.keeprecent`) and the last results
(`context.keepresults`) are always kept intact. Reading the same file twice also
drops the older copy. **Nothing is lost from the log** — only the projection
shrinks, and the model is told it can read it again.

**3. Compaction** — above `context.threshold` (82%), the small model writes a
summary of everything before the recent turns, and a `compact` boundary is
inserted into the log. From there the projection starts at the summary.

```
/compact                  do it now
/compact focus on the linker errors    steer the summary
```

## The modes

```
/context full     send the whole history, never prune, never compact
/context auto     the default, prune and compact as needed
```

`full` is what you want for a short, high-stakes session where every detail
matters. The request will fail if the history outgrows the window, so watch
`/context`.

## The settings

```json
{
    "context": {
        "mode": "auto",
        "threshold": 0.82,
        "prunethreshold": 0.55,
        "keeprecent": 6,
        "keepresults": 8,
        "toolresultlimit": 1200,
        "maxfilesize": 262144
    }
}
```

| key | meaning |
| --- | --- |
| `mode` | `auto` or `full` |
| `threshold` | the ratio at which the compaction runs |
| `prunethreshold` | the ratio at which the pruning starts |
| `keeprecent` | how many recent user turns are never touched |
| `keepresults` | how many recent tool results are never pruned |
| `toolresultlimit` | a tool result above this size may be pruned |
| `maxfilesize` | the largest file `read_file` loads at once |

## The token statistics

Every turn reports what it cost, and the status line keeps the running total:

```
25.0k tokens (↑ 24.9k · ↓ 150 · cache 88%) · 28.1s · 3 steps
```

The cache hit rate comes from the provider (deepseek and anthropic report it),
and it is the number to watch: a stable prefix — the system prompt, the tool
schemas, the early history — is what makes the cache hit, which is also why the
pruning never rewrites the recent messages.

`/cost` shows the totals of the session.
