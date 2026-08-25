# The web ui

English | [中文](web.zh.md)

```bash
$ xmake ai --web
```

It starts a small http server on the loopback, prints a url which carries a
token, and opens your default browser on it. The same harness is behind it as in
the terminal: the same tools, the same skills, the same permission modes, the
same session files. It is a second front end, not a second agent.

It opens on the **last conversation of this project**, not on an empty one — a
browser is a window somebody leaves open, and it is restarted by a reload, a
crash or a laptop waking up. The conversation, its changes and its decisions are
all still there. `--web --new` starts a fresh one instead, and so does the ＋ in
the corner.

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

One screen, in two shapes.

It **opens as a conversation** with the room to itself: the mark, a line to say
hello, a few suggestions and a box big enough to think in. That is what somebody
wants before there is anything else to look at.

When you go to **look** at what it changed, it opens out into a workspace: the
conversation on the left, the diff of the file being read in the middle, the
changed files on the right. It is the same conversation moved, not a second one
— nothing is lost in the change.

Going to look means clicking a file in the list at the end of a turn, or the
button in the corner of the chat. It does **not** happen by itself: a conversation
which has just changed a file has not necessarily been asked "show me", and a
layout which rearranged itself mid-sentence would be answering a question nobody
asked. The badge on the rail is what says there is something to look at.

The conversations of this project live **under the name of the one you are in**,
at the top of the chat: clicking it lists them, with when each was last touched
and how long it is; ＋ starts a new one; each row can be removed, which takes two
clicks. There is no separate screen to go to and come back from.

**Settings** is its own screen: the project directory, the theme, the provider,
the models and the api keys.

The theme follows your system by default and can be pinned to light or dark. It
is the page's own business and is never sent to the harness.

On a phone the rail moves to the bottom where a thumb is, and the workspace
shows one thing at a time.

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

`/loop` works here too. The terminal fires an armed loop from its idle loop,
between keystrokes; a browser has no idle loop of its own, so the conversation
waits for the next iteration to be due and runs it — and stopping it is noticed
at once rather than at the next tick. While one is armed the status bar says so:
the interval, when the next run is due, and how many have run.

## Attaching a file

`@` in the box completes the files of the project — `git ls-files` when there is
a repository, so what git ignores stays out of the way — and the file is
attached to what you send, exactly as it is in the terminal. Both front ends
call the same expansion, so `@src/main.c` means one thing and not two.

## The changes view

It lists the files **this conversation** changed, and nothing else.

Not `git status`: a working tree holds whatever was already in it — the
half-finished work of the morning, the build directory, the temporary file
somebody forgot — and none of that is what "what did it change" means.

The diff of a file is what it held before this conversation first touched it
against what it holds now, however many times it was written in between. That
before is the copy every write already keeps for `/rewind`, so there is one
mechanism and not two.

A file a **command** wrote counts too. `xmake create -t console hello` writes
eleven files and says nothing about any of them, so a command is bracketed: what
the project held before it ran, what it holds after, and the difference. What
that cannot give you is the *before* of a file the command overwrote — nobody
knew which files it was about to write — so such a row says `by a command` and
offers neither a diff nor a way back, rather than pretending to have one. A
command which writes outside the project is not something a project can see.

**It is a list of decisions, and it empties.** A file leaves the list the moment
it is decided about, so the screen reaches the state a working tree reaches
after a commit: nothing waiting. What was decided is folded away at the bottom —
a decision is worth being able to check — and a file comes straight back to the
top if the agent touches it again, because that is a new change.

The diff in the middle follows the list: deciding about the file you are reading
moves it on to the next one waiting, and to *nothing waiting for you* when there
is none. Opening one from the decided fold shows it again, marked with what was
decided and still undoable — but nothing decided is left sitting in the middle
with its buttons on, which would be the screen disagreeing with itself.

Each file has two answers, and both are one click — a tick and a cross, on the
row in the list and at the top right of the diff:

- **tick — keep** — the change is fine. Nothing is written; what changes is the
  list, which is a list of decisions still to make. The badge on the rail counts
  the undecided ones.
- **cross — revert** — put the file back the way it was before the conversation
  touched it. A file the agent created is removed again.

The header of the list carries the same two for all of them at once. *Keep all*
takes the undecided ones; *revert all* asks twice, because it throws work away
and a stray click should not be able to.

The decisions are written into the conversation, not held in the server, so
restarting the harness or opening another tab does not ask you about the same
change twice. If the agent edits a file **after** you decided about it, that is
a new change and the list asks again — which is the point of it.

The list follows the agent: leaving this screen open while it works shows each
file as it is written, and keeps the diff you were reading on screen.

The list of files at the end of a turn is the same list: clicking one opens it
here, with its diff and its two buttons.

The diff reads **unified** or **side by side** — the button at the top says
which, and remembers. A unified diff reads as a story (this line went, this line
came); a split one reads as a comparison (this is what it said, this is what it
says). Both are worth having.

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
and lives only as long as the process. The url printed in the terminal carries
it, and that url is not for sharing: anything which can open a socket on your
machine can reach the loopback, and this is a service which edits files and runs
commands.

The token is in the address bar for exactly one request. The page hands it to
the browser as a `SameSite=Strict` cookie and then takes it out of the url, so
it is not left in the history, in the title bar, or in a screenshot — and the
page still reloads.

A request which carries an `Origin` from anywhere else is refused before the
token is even looked at. `SameSite=Strict` already stops a browser attaching the
cookie to one, but a page can still make the request, and a check which costs
one string comparison is worth having behind one which relies on every browser
getting a rule right.

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

Several tools run at once whenever none of them can get in the others' way — the
reads, the searches, the subagents. Each gets its own card the moment it starts,
each counts its own seconds, and the line under the box says how many are going
rather than naming whichever one started last.

The conversation follows the newest by itself. It follows the *growing* and not
the appending, so text streaming into a paragraph, a block being replaced by its
rendered self and a fold being opened all keep the bottom in view. Scrolling
away stops it following and offers a button back down; opening a fold does the
same, because opening one is saying "I want to look at this".

The bar under the box says what it is doing in words — thinking, reasoning,
writing, or what is running — with a stop beside it.

When the agent keeps a plan (its own todo list), one line above the box says how
far along it is and what it is on now. The whole list is a click away, folded,
because a plan which pushed the conversation off the screen would be answering a
question nobody asked as often as the one they did.

The status bar shows how full the context window is, measured the same way the
auto-compaction measures it, so what you see is what the harness acts on. It
turns amber past 70% and red past 85%; `/compact` is the answer to both.

It also shows what is still running in the background — a build the agent
started and carried on past — and the armed `/loop`, if there is one. A terminal
mentions a background job at the next step; a page can simply keep the count in
view.

## The small things

- **copy** appears on an answer when the pointer is over it, and on every code
  block inside it
- reading something further up while an answer streams stops the view following
  it, and a button appears to jump back to the newest
- a conversation can be removed from **History**, which takes two clicks: the
  second one says what it is about to do
- **esc** stops the turn, and answers an open question with a no
- a turn which failed offers **retry**, because a provider having a bad minute
  is the usual reason and the useful thing then is the same message again
- **Settings** has a *run /doctor* button: the one question a settings page
  cannot answer by itself is whether any of it works
- a diff of thousands of lines draws the first six hundred and offers the rest,
  so opening one is never a pause, and a conversation of hundreds of messages is
  drawn from the end with the rest one click away — pressing **ctrl+f** puts the
  folded parts back first, so the browser's own find still searches all of it
- hovering a message you sent offers **edit**, which puts it back in the box:
  asking almost the same thing again is the commonest next move after reading an
  answer
- a turn which finishes while the tab is in the background marks the title with
  a dot, cleared the moment you look at it. it asks for no permission to do that
- everything which takes the keyboard shows a focus ring when it was reached by
  keyboard, and not when it was clicked
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
