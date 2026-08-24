# The terminal ui

English | [中文](tui.zh.md)

## The rendering model

The screen is split in two parts:

- **the transcript** — printed to stdout and never touched again, so the terminal
  scrollback keeps the whole conversation and the mouse selection works
- **the live region** — the last few lines (the streaming tail, the status line, the
  input box, the completion popup, the hints), erased and redrawn on every change

There is no alternate screen and no full repaint, which is why it behaves like a
normal cli program while still feeling like an app.

The assistant text is rendered *while it streams*: every completed line is
rendered as markdown and printed permanently, the partial line stays in the live
region.

The markdown renderer covers the headings, the lists (including the task lists),
the block quotes, the rules, the tables (aligned, with box drawing) and the
fenced code blocks, which are syntax highlighted per language. The inline
markup — bold, italic, strikethrough, code and links — is styled too.

## The input

The terminal is put into a non-canonical mode (`-icanon -echo -isig -ixon`), so
every keystroke reaches the harness directly while the output post-processing is
left alone.

The keys are read through a small relay process on posix, because the stdin of
the c library buffers whole chunks and `select()` cannot see what is already
buffered — which would swallow the escape sequences and the fast bursts. If the
relay cannot run, the harness falls back to reading the stdin directly and
drains that buffer itself. `XMAKE_HARNESS_INPUT=stdio` forces the fallback, and
`/doctor` reports which one is in use.

## The keys

| key | action |
| --- | --- |
| `enter` | send the message (or accept the completion) |
| `alt+enter`, `ctrl+j`, trailing `\` | insert a new line |
| `shift+tab` | cycle the permission mode |
| `tab` | complete as far as the candidates agree, then browse them |
| `esc` | interrupt the current work / close the popup / clear the input |
| `ctrl+c` | clear the input, twice to exit |
| `ctrl+d` | exit when the input is empty |
| `ctrl+l` | clear the screen |
| `up`/`down` | move in the input, or browse the history at the edges |
| `ctrl+a`/`ctrl+e` | the start/end of the line |
| `ctrl+w`, `alt+backspace` | delete the word before the cursor |
| `ctrl+u`/`ctrl+k` | delete to the start/end of the line |
| `ctrl+y` | yank what was deleted |
| `/` | the slash command completion |
| `@` | the file completion, the file is attached to the message |
| `!<command>` | run a shell command directly and put its output into the conversation |

Typing while the model works queues the text into the input box for the next turn.

## Where an answer comes from

An answer about code rests on somewhere in the code, so the agent is asked to say
where: `src/main.cpp:42`. Most terminals turn that into something you can click,
which is worth having on its own.

The part which is not decoration is the check. A model which cites a line it
never read is more convincing than one which says nothing, and just as wrong —
the citation looks the same either way. The file is right there, so we look:

- the file exists and the line is inside it → the citation is a link
- the file does not exist, or the file is shorter than that → it is rendered in
  the error color instead

Nothing is added to the text, only colored: the citations are marked after the
lines have been wrapped, and one extra character would push the wrapping out by
one column.

A url with a port (`http://host:8080`) and a version number (`1.2:3`) read
exactly like a file and a line, and neither is one. The line counts are
remembered for as long as the files do not change, so a long answer full of
citations reads each file once.

## The slash commands

| command | what it does |
| --- | --- |
| `/help` | the commands and the shortcuts |
| `/clear` | start a new session |
| `/model [name]`, `/model small <name>` | show or switch the model |
| `/provider [name]` | show or switch the llm provider |
| `/config [key] [value]` | show or set the user configuration |
| `/status` | the provider, the model, the session, the counts |
| `/cost` | the token usage and the cache hit rate |
| `/context [full\|auto]` | the context breakdown and the optimization mode |
| `/compact [focus]` | compact the conversation into a summary |
| `/xmake [args]` | run xmake here, without tokens (the xmake plugin) |
| `/loop <interval> <task>`, `/loop stop` | repeat a task on a schedule |
| `/jobs`, `/jobs kill <id>` | the background jobs |
| `/permissions [mode]` | show or switch the permission mode |
| `/sandbox [on\|off\|backend]` | show or toggle the command sandbox |
| `/theme [name]` | switch the ui theme |
| `/skills [install\|update\|remove]` | the skill packs, @see [skills](skills.md) |
| `/agents`, `/tools`, `/plugins` | what is loaded |
| `/sessions [all\|remove <id>]`, `/resume [id]` | the session history, @see [context](context.md) |
| `/export [path]` | export the conversation to markdown |
| `/init` | write the project instruction file |
| `/cwd [dir]` | show or change the working directory |
| `/doctor` | check the environment |

A markdown file in `~/.xmake/harness/commands/` or `<project>/.xmake-harness/commands/`
becomes a command whose body is sent as the prompt, with `$ARGUMENTS` substituted.

## The theme

Every color is a named style resolved from the theme, never a hardcoded escape:

```json
{"ui": {"theme": "default", "colors": {"assistant.bullet": "${bright cyan}", "diff.addline": "${on#22}"}}}
```

The color tags are the xmake ones: `${red}`, `${bright green}`, `${dim}`, `${#33}`
(256 color), `${on#22}` (256 color background), `${on;30;60;30}` (truecolor
background), `${color.success}` (the xmake theme colors).

Builtin themes: `default`, `dark`, `light`, `plain` (no colors at all).

The palette follows claude code: pink-magenta keywords, green strings, blue
functions and numbers, yellow types, dim comments, a dark green/red background
for the diff lines. It is defined twice — for the 256 color terminals and for
the basic ones — and the right one is picked from the terminal capabilities.

## The permission dialog

When a tool needs a confirmation, a dialog appears in the live region with what
is about to happen inside it:

```
  ╭─ Edit file ────────────────────────────────────────────────╮
  │ src/main.c                                                 │
  │    12   int main(void) {                                   │
  │    13 - printf("hello");                                   │
  │    13 + printf("hello world");                             │
  │                                                            │
  │ Do you want to make this edit to main.c?                   │
  │ ❯ 1. Yes                                                   │
  │   2. Yes, and accept all the file edits of this session    │
  │   3. No, and tell the model what to do differently (esc)   │
  ╰────────────────────────────────────────────────────────────╯
```

`up`/`down` + `enter`, the number keys, or `y`/`n`.

The wording follows what the tool does: an edit shows the diff and offers to
accept all the edits of the session (the same as `shift+tab`), a command shows
the command line and offers to allow that program from now on, a network tool
shows the url.

For the commands the footer always states where it will run:

```
  ╭─ Run command ──────────────────────────────────────────────╮
  │ rm -rf build                                               │
  │ remove the build directory                                 │
  │                                                            │
  │ Do you want to run this command?                           │
  │ ❯ 1. Yes                                                   │
  │   2. Yes, and do not ask again for `rm` commands           │
  │   3. No, and tell the model what to do differently (esc)   │
  │                                                            │
  │ the command runs directly on your machine (the sandbox is  │
  │ off, /sandbox on)                                          │
  ╰────────────────────────────────────────────────────────────╯
```

The same dialog asks before anything is downloaded, e.g. a skill pack.

## The repeating task

Some work is not one question but the same question on a schedule: watch the ci
every half hour, re-run the build every ten minutes until it is green.

```
/loop 30m check whether the ci is green, and tell me what broke if it is not
```

The first iteration runs immediately — you just asked for it, waiting the first
half hour out would only look broken — and every one after it is scheduled from
the moment the previous one *ended*, so an iteration slower than the interval
never stacks up behind itself.

The interval takes `s`, `m`, `h` and combinations of them: `90s`, `30m`, `2h`,
`1h30m`. A bare number is refused, because nobody agrees on whether `30` means
seconds or minutes, and the shortest interval is 10s.

Each iteration is a normal turn in the same conversation, so the loop remembers
what the previous ones found, and the prompt cache makes the repeats cheap.

An armed loop spends money while you are not looking, so it says so: the status
line carries `loop every 30m · next in 12m · 3 runs` and counts down. It stops
when you say `/loop stop`, when you press `esc` during an iteration — that means
stop, not skip this one — and by itself after three iterations in a row fail.
`/loop` on its own shows what is armed. It lives in the session it was armed in,
nothing is written to disk, and quitting is enough to be rid of it.
