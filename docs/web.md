# The web ui

English | [中文](web.zh.md)

```bash
$ xmake ai --web
```

It starts a small http server on the loopback, prints a url which carries a
token, and opens your default browser on it. The same harness is behind it as in
the terminal: the same tools, the same skills, the same permission modes, the
same session files. It is a second front end, not a second agent.

```
  web ui  http://127.0.0.1:9736/?token=e07091070…
  project /path/to/your/project
```

| option        | what it does                                        |
|---------------|-----------------------------------------------------|
| `--web`       | serve the web ui instead of the terminal ui          |
| `--port=N`    | the port to take, `9736` by default (the first free one from there) |
| `--nobrowser` | do not open the browser, just print the url          |
| `--cwd=DIR`   | the project to open, the current directory by default |
| `--mode=M`    | the permission mode to start in, `acceptedits` by default |

## What is in it

- **Chat** — the conversation. The answers stream in, a tool which is still
  running shows a card straight away (a build is not a freeze), the finished
  ones fold open, and what a reasoning model thought on the way there goes into
  its own folded block. An edit appears as its diff, and the turn ends with the
  list of every file it touched.
- **Changes** — the working tree as **git** sees it: the files on the left, the
  diff of the one you picked on the right, syntax highlighted, with a button to
  put any of them back. It is not a record of what the agent did — see below.
- **History** — the conversations of this project. Opening one resumes it, and
  every open tab moves with it.
- **Settings** — the project directory, the theme, the provider, the models and
  the api keys, in that order.

The theme follows your system by default and can be pinned to light or dark. It
is the page's own business and is never sent to the harness.

On a phone the rail moves to the bottom where a thumb is, and the changes view
becomes one column instead of two.

## The slash commands

Everything the terminal has: type `/` in the box and the list appears, filtered
as you type, with tab or enter to take one.

They are the *same* commands — `/compact`, `/context`, `/cost`, `/model`,
`/permissions`, `/rewind`, `/skills`, `/xmake` and whatever a plugin adds — run
through an adapter rather than reimplemented, so a command only has to be
written once and works in both places. `/xmake build` runs the build here too;
without a terminal to hand over, the output comes back as a card in the
conversation.

A command which asks you something asks it the same way a tool does, in the
conversation.

## Attaching a file

`@` in the box completes the files of the project — `git ls-files` when there is
a repository, so what git ignores stays out of the way — and the file is
attached to what you send, exactly as it is in the terminal. Both front ends
call the same expansion, so `@src/main.c` means one thing and not two.

## The changes view is git

It runs `git status` and `git diff` and shows what they say. Nothing in it is
remembered by the page:

- an edit you made in your editor shows up beside the ones the agent made
- **revert** is `git checkout -- <file>` (and, for a file git never knew about,
  removing it), not an undo stack of our own
- reloading the page, restarting the harness or starting a new conversation
  changes nothing about what it shows

If the project is not a git repository the view says so and asks you to
`git init` — there is nothing to diff against otherwise. The syntax colours come
from the harness's own highlighter, the one the terminal uses.

## No third party, anywhere

There is no framework, no bundler and no build step. The page is plain html, css
and es modules, served from `src/modules/harness/web/assets`: editing a file and
reloading the page is the whole development loop.

The markdown is rendered by the harness — the same parser the terminal uses —
and crosses as html, so there is no second renderer in the browser to drift from
the first one.

The events cross as [server-sent events](https://developer.mozilla.org/docs/Web/API/Server-sent_events),
which browsers speak natively and reconnect by themselves. Nothing is replayed
onto a reconnected stream: a page which comes back asks for the state again, so
there is one history and not a second one kept for reconnections.

## The confirmations

The permission modes work exactly as they do in the terminal, and the same
policy decides what needs one: `ls`, `git status` and `xmake build` run, while
what is hard to undo, reaches outside the project or cannot be read at all asks
first, @see the permission modes in the configuration.

The question appears **in the conversation**, where the rest of the turn is —
not as a sheet over the page. It carries the diff when it is an edit, the same
answers as the terminal including *do not ask again*, and once answered it stays
where it was and says what was answered.

The turn waits on the answer without costing anything while it waits, and the
question is pushed to every open tab: answering it in one closes it in all of
them. Pressing stop, or escape, while a question is open answers it with a no.

The button at the bottom left of the composer is the permission mode, and
clicking it cycles the same three shift+tab cycles in the terminal.

## What it costs to leave open

Nothing but a socket. There is no polling anywhere: a held event stream is a
suspended coroutine, and a tab which goes away is noticed the next time
something is pushed to it.

## Security

The server binds to `127.0.0.1` and demands a token which is generated per run
and lives only as long as the process. The token is in the url, and the url is
not for sharing: anything which can open a socket on your machine can reach the
loopback, and this is a service which edits files and runs commands.

The files the page is made of — the css, the js, the logo — are served without
the token, because an es module `import` cannot carry one. They are the same for
everybody and carry nothing.

The api keys are the one thing the settings page never reads back. It shows
whether a key is configured and lets you replace it; the key itself stays in
`~/.xmake/harness/config.json` and never crosses the wire.

## Several tabs, one conversation

Every tab sees the same conversation and the same events. A tab which joins
halfway through draws itself from the session, which is the same file the
terminal ui reads — so a conversation started in the browser can be continued
with `xmake ai --resume`, and the other way round.

## While it works

The bar under the box says what it is doing in words — thinking, reasoning,
writing, or the name of the tool which is running — with a stop beside it.

When the agent keeps a plan (its own todo list), the plan stays in view above
the box with a count of what is done, rather than scrolling away with the rest
of the conversation.

The status bar shows how full the context window is, measured the same way the
auto-compaction measures it, so what you see is what the harness acts on. It
turns amber past 70% and red past 85%; `/compact` is the answer to both.

## The small things

- **copy** appears on an answer when the pointer is over it, and on every code
  block inside it
- reading something further up while an answer streams stops the view following
  it, and a button appears to jump back to the newest
- a conversation can be removed from **History**, which takes two clicks: the
  second one says what it is about to do
- **esc** stops the turn, and answers an open question with a no
- the tab is named after the project, because two of these open at once is the
  normal way to use it
- if the harness goes away — restarted, stopped — the page says so instead of
  quietly showing nothing

## When something looks wrong

Open the browser console. The page reports what it could not draw there and
keeps running rather than blanking itself.

If the page never appears, check the url in the terminal: a port which was
already taken means the harness moved to the next free one, and the printed url
is the one which is right.
