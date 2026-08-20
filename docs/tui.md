# The terminal ui

## The rendering model

The screen is split in two parts:

- **the transcript** — printed to stdout and never touched again, so the terminal
  scrollback keeps the whole conversation and the mouse selection works
- **the live region** — the last few lines (the streaming tail, the status line, the
  input box, the completion popup, the hints), erased and redrawn on every change

There is no alternate screen and no full repaint, which is why it behaves like a
normal cli program while still feeling like an app.

The assistant text is rendered *while it streams*: every completed line is rendered
as markdown and printed permanently, the partial line stays in the live region.

## The keys

| key | action |
| --- | --- |
| `enter` | send the message (or accept the completion) |
| `alt+enter`, `ctrl+j`, trailing `\` | insert a new line |
| `shift+tab` | cycle the permission mode |
| `tab` | complete the command or the file |
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
| `/context` | how much of the context window is used |
| `/compact [focus]` | compact the conversation into a summary |
| `/permissions [mode]` | show or switch the permission mode |
| `/sandbox [on\|off\|backend]` | show or toggle the command sandbox |
| `/theme [name]` | switch the ui theme |
| `/skills`, `/agents`, `/tools`, `/plugins` | what is loaded |
| `/sessions`, `/resume <id>` | the session history |
| `/export [path]` | export the conversation to markdown |
| `/init` | write the project instruction file |
| `/cwd [dir]` | show or change the working directory |
| `/doctor` | check the environment |
| `/xmake-skills` | install or update the xmake skills (xmake plugin) |

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

Builtin themes: `default`, `light`, `plain` (no colors at all).

## The permission dialog

When a tool needs a confirmation, the diff or the command is printed into the
transcript first, then the dialog appears in the live region:

```
● edit_file(src/main.c)
    12   int main(void) {
    13 - printf("hello");
    13 + printf("hello world");

  ╭──────────────────────────────────────────
  │ Do you want to run this tool?
  │ ❯ 1. Yes
  │   2. Yes, and do not ask again for edit_file
  │   3. No, and tell the model what to do instead
  ╰──────────────────────────────────────────
```

`up`/`down` + `enter`, or the number keys, or `y`/`n`. Choosing "do not ask again"
adds an allow rule for the rest of the session.
