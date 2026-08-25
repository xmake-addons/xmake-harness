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
  ones fold open, and the diffs are shown line by line. What a reasoning model
  thought on the way there goes into its own folded block.
- **Changes** — every file the conversation edited, one entry per file with its
  latest diff.
- **History** — the conversations of this project. Opening one resumes it, and
  every open tab moves with it.
- **Settings** — the project directory, the theme, the provider, the models and
  the api keys, in that order.

The theme follows your system by default and can be pinned to light or dark. It
is the page's own business and is never sent to the harness.

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

The permission modes work exactly as they do in the terminal. When a tool call
has to be confirmed, the page shows the same question — with the diff, if it is
an edit — and the same answers, including *do not ask again*.

The turn waits on the answer without costing anything while it waits, and the
question is pushed to every open tab: answering it in one closes it in all of
them. Pressing stop while a question is open answers it with a no.

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

## When something looks wrong

Open the browser console. The page reports what it could not draw there and
keeps running rather than blanking itself.

If the page never appears, check the url in the terminal: a port which was
already taken means the harness moved to the next free one, and the printed url
is the one which is right.
