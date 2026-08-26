/* the screens
 *
 * one object per screen, each owning its own corner of the document and nothing
 * else. `app.js` decides which one is showing; none of them know about the
 * others.
 */
"use strict";

import {api} from "./api.js";
import {el, message, tool, pending, thinking, filecard, summary, permission,
        splitdiff, codeview, treerow, todos, chip, brief, when, list,
        iconbutton, notice, ticking} from "./render.js";

const byId = (id) => document.getElementById(id);

/* ------------------------------------------------------------------ chat */

export const chat = (() => {
  const thread = byId("thread");
  const messages = byId("messages");
  const hero = byId("hero");
  let streaming = null;
  let thought = null;
  const running = new Map();
  const asking = new Map();
  let onreuse = null;
  let showearlier = null;   /* draws the folded part of a long conversation */
  const changed = new Map();
  const turnfiles = new Set();

  const SUGGESTIONS = [
    "What does this project build?",
    "Fix the build errors",
    "Add a unit test target",
    "Explain the xmake.lua"
  ];

  /* following the newest, or not
   *
   * a view which only scrolled when something was *appended* misses most of
   * what makes it grow: text streaming into a paragraph, a plain block being
   * replaced by its rendered self, a fold being opened, a font arriving late.
   * so the growing is watched instead of the appending — the browser has an
   * observer for exactly that — and the one flag it consults is whether the
   * reader is at the bottom.
   *
   * reading something further up while the answer keeps coming is a normal
   * thing to want: the view stops following the moment they scroll away, and
   * says so with a button back down.
   */
  const tobottom = byId("tobottom");
  const atBottom = () => thread.scrollHeight - thread.scrollTop - thread.clientHeight < 60;
  let following = true;

  const bottom = () => {
    thread.scrollTop = thread.scrollHeight;
    following = true;
    tobottom.classList.add("hidden");
  };

  thread.addEventListener("scroll", () => {
    following = atBottom();
    tobottom.classList.toggle("hidden", following);
  });
  tobottom.addEventListener("click", bottom);

  /* anything which changes the height of the conversation, whatever caused it */
  if (window.ResizeObserver) {
    const watcher = new ResizeObserver(() => {
      if (following) thread.scrollTop = thread.scrollHeight;
    });
    watcher.observe(messages);
  }

  /* a fold being opened is somebody saying "I want to look at this", so the
   * view stops following and puts what they opened where they can see it —
   * being pinned to the bottom of a card is not reading it
   *
   * `toggle` does not bubble, so it is caught on the way down */
  messages.addEventListener("toggle", (event) => {
    const card = event.target;
    if (!card || !card.open) return;
    following = false;
    tobottom.classList.remove("hidden");
    if (card.scrollIntoView) card.scrollIntoView({block: "nearest"});
  }, true);

  ticking(messages);

  const add = (node) => {
    messages.appendChild(node);
    if (following) thread.scrollTop = thread.scrollHeight;
    return node;
  };

  /* the hero is the empty state: it goes the moment there is a conversation,
   * and comes back when the conversation is cleared */
  const empty = (isEmpty) => hero.classList.toggle("hidden", !isEmpty);

  const suggest = (onpick) => {
    const box = byId("chips");
    box.textContent = "";
    SUGGESTIONS.forEach((text) => box.appendChild(chip(text, onpick)));
  };

  /* while the answer streams it is plain text: re-rendering a document every
   * few tokens is work thrown away, and the harness sends the rendered markdown
   * once the message is whole */
  const stream = (delta) => {
    if (!streaming) {
      streaming = {text: "", rendered: 0, node: add(el("div", "msg assistant"))};
      streaming.done = el("div", "md");
      streaming.body = el("div", "text streaming");
      streaming.node.appendChild(streaming.done);
      streaming.node.appendChild(streaming.body);
      streaming.node.appendChild(el("span", "caret"));
    }
    streaming.text += delta;
    streaming.body.textContent = streaming.text.slice(streaming.rendered);
  };

  /* the harness finished a block of the answer and rendered it: the formatted
   * part grows, and what stays plain text is the tail being written */
  const block = (payload) => {
    if (!streaming || !payload || !payload.upto) return;
    streaming.done.innerHTML = payload.html || "";
    streaming.rendered = payload.upto;
    streaming.body.textContent = streaming.text.slice(streaming.rendered);
  };

  /* the streamed text is replaced by the rendered answer, in place: the node
   * which was growing token by token is swapped for the finished message, so
   * the page never shows the same answer twice or jumps as it settles */
  const settle = (payload) => {
    thought = null;
    if (!streaming) return;
    streaming.node.replaceWith(message("assistant", payload || {text: streaming.text}));
    streaming = null;
  };

  /* the reasoning arrives token by token like the answer does, but it is not
   * the answer: it goes into its own folded block above it */
  const think = (delta) => {
    if (!thought) {
      thought = {text: "", node: add(thinking())};
    }
    thought.text += delta;
    thought.node.body.textContent = thought.text;
  };

  /* a tool which started gets a card straight away; the result replaces it in
   * place, so the conversation keeps its order and does not jump */
  const started = (call) => {
    const node = add(pending(call));
    if (call.id) running.set(call.id, node);
    return node;
  };

  const replace = (event, card) => {
    const node = event.id && running.get(event.id);
    if (!node) {
      return add(card);
    }
    running.delete(event.id);
    node.replaceWith(card);
    return card;
  };

  const finished = (event) => replace(event, tool(event));

  /* one logged message, as it is drawn back */
  const draw1 = (item) => {
    if (item.role === "tool") {
      const change = record(item);
      return change ? filecard(change, {limit: 60}) : tool(item);
    }
    return message(item.role, item.role === "user" ? {...item, reuse: onreuse} : item);
  };

  /* what this conversation has changed, one entry per file and the newest diff
   * of it. an edit is shown twice on purpose: as it happens, in order, and once
   * more in the list at the end of the turn — the first answers "what is it
   * doing", the second answers "what did it do" */
  const record = (event) => {
    if (event.kind !== "diff" || !event.diff) return null;
    const filepath = event.diff.filepath || event.subject || "?";
    const change = {
      filepath,
      name: filepath.split(/[\\/]/).pop(),
      dir: filepath.split(/[\\/]/).slice(0, -1).join("/"),
      diff: event.diff,
      created: /create/i.test(event.title || ""),
      iserror: event.iserror
    };
    changed.set(filepath, change);
    return change;
  };

  /* the turn is over: say what it touched, unless it touched nothing
   *
   * @param onopen  what to do when somebody picks one of the files — the
   *                changes view, which is where the diff and the decision are
   */
  const changeset = (onopen) => {
    if (!changed.size || turnfiles.size === 0) return;
    const ofturn = [...turnfiles].map((filepath) => changed.get(filepath)).filter(Boolean);
    turnfiles.clear();
    if (ofturn.length) add(summary(ofturn, onopen));
  };

  /* a question, asked where the rest of the turn is */
  const ask = (payload, onanswer) => {
    const card = permission(payload, (value, text) => {
      card.settle(text);
      onanswer(value);
    });
    asking.set(String(payload.id), card);
    add(card);
    return card;
  };

  const asked = (id) => {
    const card = asking.get(String(id));
    if (card) {
      asking.delete(String(id));
      if (!card.classList.contains("answered")) card.settle("answered elsewhere");
    }
  };

  return {
    empty, suggest, stream, block, settle, add, think, started, ask, asked, changeset,
    user: (text, iscommand) => {
      empty(false);
      add(message(iscommand ? "command" : "user", {text, reuse: onreuse}));
    },
    onreuse(handler) { onreuse = handler; },

    /* draw everything which is folded away
     *
     * the browser's own find only searches what is in the document, and a
     * conversation drawn from the end has most of itself outside it. so before
     * the find box opens, the rest of the conversation is put back — which is
     * what somebody pressing ctrl+f is asking for, whether they know it or not
     */
    expandall() {
      if (!showearlier) return false;
      showearlier();
      return true;
    },
    tool(event) {
      const change = record(event);
      if (change) {
        turnfiles.add(change.filepath);
        return replace(event, filecard(change, {limit: 60}));
      }
      return finished(event);
    },
    note: (kind, text, action) => add(notice(kind, text, action)),
    files: () => [...changed.values()],
    clear() {
      messages.textContent = "";
      streaming = null;
      thought = null;
      running.clear();
      asking.clear();
      showearlier = null;
      changed.clear();
      turnfiles.clear();
      empty(true);
    },
    draw(state) {
      this.clear();
      const items = list(state.messages);

      /* a conversation of six hundred messages is drawn from the end: the last
       * ones are what somebody came back for, and the rest is one click away.
       * the changes are still read from all of them — a file edited an hour ago
       * is still a file this conversation changed */
      const RECENT = 60;
      const earlier = items.length > RECENT ? items.slice(0, items.length - RECENT) : [];
      const recent = earlier.length ? items.slice(earlier.length) : items;
      for (const item of earlier) {
        record(item);
      }
      if (earlier.length) {
        const more = el("button", "earlier", `${earlier.length} earlier messages — show them`);
        more.type = "button";
        const expand = () => {
          const was = thread.scrollHeight - thread.scrollTop;
          const box = el("div", "earlier-box");
          for (const item of earlier) {
            box.appendChild(draw1(item));
          }
          more.replaceWith(box);
          thread.scrollTop = thread.scrollHeight - was;
          showearlier = null;
        };
        more.addEventListener("click", expand);
        showearlier = expand;
        messages.appendChild(more);
      }
      for (const item of recent) {
        add(draw1(item));
      }
      empty(items.length === 0);
      bottom();
    }
  };
})();

/* --------------------------------------------------------------- changes
 *
 * a git view and not a record of what the agent did: it is `git status` and
 * `git diff` on one side and the file the user clicked on the other. an edit
 * made in an editor shows up here too, reverting one is `git checkout`, and
 * nothing in it survives a reload — because none of it was ever the page's.
 */

export const changes = (() => {
  const treebox = byId("tree");
  const pane = byId("gitdiff");
  const count = byId("gitcount");
  const badge = byId("changecount");

  let current = null;          /* the file being read */
  let open = new Set();        /* the directories which are open */
  let editing = null;          /* the editor, while one is up */

  /* unified or side by side, remembered: it is how somebody reads diffs, not
   * something about this conversation, so it belongs to the browser */
  let layout = localStorage.getItem("xmake-ai-diff") === "split" ? "split" : "unified";
  const setlayout = (next) => {
    layout = next;
    try { localStorage.setItem("xmake-ai-diff", next); } catch (_) {}
  };

  /* reading it, or typing in it
   *
   *   view   the whole file, with what changed coloured on it — the lines
   *          which came in green, the lines which went in red, where they
   *          were, as the terminal shows them
   *   edit   the same file, editable, without the lines which are gone: the
   *          typing layer must have one row per line of the file or the caret
   *          drifts away from the letters
   */
  let mode = localStorage.getItem("xmake-ai-view") === "edit" ? "edit" : "view";
  const setmode = (next) => {
    mode = next;
    try { localStorage.setItem("xmake-ai-view", next); } catch (_) {}
  };

  /* which two versions a diff is of, when a file has been written more than
   * once: the last write, or everything this conversation did to it */
  let base = localStorage.getItem("xmake-ai-base") === "session" ? "session" : "last";
  const setbase = (next) => {
    base = next;
    try { localStorage.setItem("xmake-ai-base", next); } catch (_) {}
  };

  const empty = (node, title, note) => {
    node.textContent = "";
    const box = el("div", "empty");
    box.appendChild(el("h3", null, title));
    if (note) box.appendChild(el("p", null, note));
    node.appendChild(box);
  };

  /* ------------------------------------------------------------- the tree */

  const drawtree = async () => {
    const answer = await api.changes();
    const files = list(answer.files);
    const waiting = typeof answer.waiting === "number"
      ? answer.waiting : files.filter((file) => file.undecided).length;
    badge.textContent = String(waiting);
    badge.classList.toggle("hidden", waiting === 0);
    count.textContent = waiting === 0
      ? (files.length ? `${files.length} changed` : "files")
      : `${waiting} waiting`;
    bulk(files.filter((file) => file.undecided), files);

    treebox.textContent = "";
    await branch("", 0, treebox);
  };

  /* one directory, and the ones inside it which are open */
  const branch = async (dir, depth, into) => {
    const answer = await api.tree(dir);
    for (const entry of list(answer.entries)) {
      const isopen = open.has(entry.path);
      const row = treerow(entry, depth, {open: isopen, current: entry.path === current});
      into.appendChild(row);

      if (entry.kind === "dir") {
        const kids = el("div", "twigs");
        into.appendChild(kids);
        row.addEventListener("click", async () => {
          if (open.has(entry.path)) {
            open.delete(entry.path);
            kids.textContent = "";
            row.classList.remove("open");
          } else {
            open.add(entry.path);
            row.classList.add("open");
            await branch(entry.path, depth + 1, kids);
          }
        });
        if (isopen) await branch(entry.path, depth + 1, kids);
      } else {
        row.addEventListener("click", () => show(entry.path));
      }
    }
  };

  /* everything above a file has to be open for the file to be visible */
  const reveal = (filepath) => {
    const parts = String(filepath || "").split("/");
    parts.pop();
    let at = "";
    for (const part of parts) {
      at = at ? at + "/" + part : part;
      open.add(at);
    }
  };

  /* ------------------------------------------------------------- the file */

  /* a pane which goes blank says nothing about why
   *
   * every path into it is asynchronous — a request for the file, one for the
   * changes, one for the colours — and a rejection anywhere in it used to leave
   * an empty box and no clue. whatever goes wrong now says so where the file
   * would have been */
  const show = async (filepath) => {
    try {
      await openfile(filepath);
    } catch (error) {
      console.error("xmake ai:", error);
      pane.textContent = "";
      empty(pane, "That file could not be shown",
            (error && error.message) || String(error));
    }
  };

  const openfile = async (filepath) => {
    if (!filepath) return;
    current = filepath;
    reveal(filepath);
    [...treebox.querySelectorAll(".treerow")].forEach((row) =>
      row.classList.toggle("is-current", row.dataset.path === filepath));

    const changes = list((await api.changes()).files);
    const file = changes.find((one) => one.path === filepath || one.fullpath === filepath)
      || {path: filepath, name: filepath.split("/").pop(), dir: ""};

    pane.textContent = "";
    pane.appendChild(head(file));
    const body = el("div", "diff-body");
    pane.appendChild(body);
    await draw(file, body);
  };

  const draw = async (file, body) => {
    body.textContent = "";
    if (mode === "split" && file.undecided !== undefined) {
      await drawsplit(file, body);
    } else {
      await drawfile(file, body);
    }
  };

  /* the file itself: coloured, marked, and editable when somebody says so */
  const drawfile = async (file, body) => {
    const answer = await api.source(file.path);
    if (answer && answer.errors) {
      empty(body, "That file could not be opened", answer.errors);
      return;
    }
    if (!list(answer.lines).length) {
      empty(body, "This file is empty", "There is nothing in it yet.");
      return;
    }
    if (mode === "edit") {
      body.appendChild(editor(answer, file));
      return;
    }
    body.appendChild(codeview(answer, {clean: file.kept || file.reverted}));
  };

  /* the two versions beside each other, for the changes of one file */
  const drawsplit = async (file, body) => {
    let answer = await api.filediff(file.path, (file.edits || 1) > 1 ? base : null);
    if (answer && !answer.errors && !list(answer.lines).length && (file.edits || 1) > 1) {
      answer = await api.filediff(file.path, "session");
    }
    if (answer && answer.errors) {
      empty(body, "That diff could not be read", answer.errors);
    } else if (!list(answer.lines).length) {
      empty(body, "Nothing is different", "The file holds what it held before.");
    } else {
      body.appendChild(splitdiff(answer));
    }
  };

  /* what is above the file: its name, what was decided about it, and what can
   * be done about that */
  const head = (file) => {
    const bar = el("header", "diff-head");
    const names = el("span", "names");
    names.appendChild(el("span", "name", file.name || file.path));
    if (file.dir) names.appendChild(el("span", "dir", file.dir));
    bar.appendChild(names);

    if (file.created) bar.appendChild(el("span", "diff-state is-new", "new file"));
    if (file.kept) bar.appendChild(el("span", "diff-state is-kept", "kept"));
    if (file.reverted) bar.appendChild(el("span", "diff-state", "put back"));

    const actions = el("span", "diff-actions");

    /* which two versions the colours are of, when a file has been written more
     * than once: the last write, or everything this conversation did to it */
    if ((file.edits || 1) > 1) {
      const which = el("button", "pill tiny",
        base === "last" ? "last change" : `all ${file.edits} edits`);
      which.type = "button";
      which.title = base === "last"
        ? "the colours show what the most recent write did — click for everything"
        : "the colours show everything this conversation did — click for the last write";
      which.addEventListener("click", async () => {
        setbase(base === "last" ? "session" : "last");
        await show(file.path);
      });
      actions.appendChild(which);
    }

    /* side by side, for a file with changes: the same two versions, in columns */
    if (file.undecided !== undefined) {
      const side = el("button", "pill tiny" + (mode === "split" ? " is-on" : ""), "split");
      side.type = "button";
      side.title = mode === "split"
        ? "showing the two versions in columns — click for the file"
        : "show the two versions in columns";
      side.addEventListener("click", async () => {
        setmode(mode === "split" ? "view" : "split");
        await show(file.path);
      });
      actions.appendChild(side);
    }

    /* and typing in it */
    const write = el("button", "pill tiny" + (mode === "edit" ? " is-on" : ""),
      mode === "edit" ? "done" : "edit");
    write.type = "button";
    write.title = mode === "edit" ? "stop editing and read it again" : "edit this file";
    write.addEventListener("click", async () => {
      setmode(mode === "edit" ? "view" : "edit");
      await show(file.path);
    });
    actions.appendChild(write);

    /* and the two decisions, for a file this conversation changed */
    if (file.undecided !== undefined && !file.reverted) {
      actions.appendChild(iconbutton("check", "act big keep" + (file.kept ? " is-on" : ""),
        file.kept ? "kept — click to put it back on the list" : "keep this change",
        async () => { await api.keep(file.path, !file.kept); await drawtree(); await show(file.path); }));
      actions.appendChild(iconbutton("cross", "act big revert",
        file.created
          ? "the agent created this file, so putting it back means removing it"
          : "put this file back the way it was before this conversation",
        async () => {
          const answer = await api.revert(file.path);
          if (answer && answer.errors) {
            bar.appendChild(el("span", "diff-error", answer.errors));
            return;
          }
          await drawtree();
          await show(file.path);
        }));
    }
    bar.appendChild(actions);
    return bar;
  };

  /* one decision for all of them at once */
  const bulk = (waiting, files) => {
    const box = byId("gitbulk");
    box.textContent = "";
    const revertable = waiting.filter((file) => !file.reverted && !file.nodiff).length;
    box.classList.toggle("hidden", waiting.length === 0 && revertable === 0);
    if (!waiting.length && !revertable) return;

    if (waiting.length > 0) {
      box.appendChild(iconbutton("checkall", "act keepall",
        `keep all ${waiting.length} undecided changes`,
        async () => { await api.decideall("keep"); await drawtree(); if (current) await show(current); }));
    }
    if (revertable > 0) {
      let armed = false;
      const all = iconbutton("cross", "act revertall",
        `put all ${revertable} files back`, async () => {
          if (!armed) {
            armed = true;
            all.classList.add("armed");
            setTimeout(() => { armed = false; all.classList.remove("armed"); }, 4000);
            return;
          }
          await api.decideall("revert");
          await drawtree();
          if (current) await show(current);
        });
      box.appendChild(all);
    }
  };

  return {
    /* @param pick  a file to open, e.g. one clicked in the conversation */
    async draw(pick) {
      await drawtree();
      if (pick) {
        await show(pick);
      } else if (current) {
        await show(current);
      } else {
        empty(pane, "Nothing open",
              "Pick a file from the tree, or one from the list at the end of a turn.");
      }
    },

    /* the badge has to be right whether or not anybody is looking at the tree
     *
     * @return  how many files this conversation has changed
     */
    async refresh() {
      const answer = await api.changes();
      const files = list(answer.files);
      const waiting = typeof answer.waiting === "number"
        ? answer.waiting : files.filter((file) => file.undecided).length;
      badge.textContent = String(waiting);
      badge.classList.toggle("hidden", waiting === 0);
      return files.length;
    },

    /* the agent saved a file: redraw if the workspace is on screen */
    async live() {
      const showing = document.querySelector('.view[data-view="work"][data-layout="split"]');
      if (showing && !editing) {
        await drawtree();
        if (current) await show(current);
      }
      return this.refresh();
    },

    /* the editor tells us when it is holding unsaved work, so a redraw does
     * not throw it away, @see editor() */
    hold(state) { editing = state; }
  };
})();

/* --------------------------------------------------------------- editor
 *
 * a code editor without a code editor
 *
 * the file is drawn as coloured spans, and a transparent textarea is laid over
 * it with the same font and the same metrics: the caret, the selection, the
 * keyboard and the undo stack are the browser's own, and the colours are the
 * harness's. it is the oldest trick for this and it needs nothing from anybody
 * — which is the whole point, because a code editor is otherwise a megabyte of
 * somebody else's javascript.
 *
 * what somebody types is coloured by asking the harness for it, debounced: the
 * page has no highlighter of its own to drift from the one the terminal uses.
 */
export const editor = (source, file) => {
  const box = el("div", "editor");
  const paint = codeview(source, {plain: true});
  const area = el("textarea", "editor-input");
  area.spellcheck = false;
  area.value = text(source);
  area.setAttribute("wrap", "off");

  box.appendChild(paint);
  box.appendChild(area);

  const bar = el("div", "editor-bar hidden");
  const note = el("span", "editor-note", "edited, not saved");
  const save = el("button", "pill tiny primary", "save");
  save.type = "button";
  const revert = el("button", "pill tiny", "discard");
  revert.type = "button";
  bar.appendChild(note);
  bar.appendChild(revert);
  bar.appendChild(save);
  box.appendChild(bar);

  /* the grid row is as tall as the painted code, and the textarea fills it —
   * but a textarea has a height of its own until it is told otherwise, and
   * `rows` is the only thing which sets it before it is in the document */
  area.rows = Math.max(4, list(source.lines).length);

  let saved = area.value;
  let timer = null;

  const dirty = () => {
    const changed = area.value !== saved;
    bar.classList.toggle("hidden", !changed);
    changes.hold(changed ? file.path : null);
    return changed;
  };

  /* the colours follow what is typed, a moment behind it */
  let painted = paint;
  const recolour = async () => {
    const answer = await api.colour(file.path, area.value);
    if (answer && answer.lines) {
      const next = codeview({lines: answer.lines, marks: {}}, {plain: true});
      painted.replaceWith(next);
      painted = next;
    }
  };

  area.addEventListener("input", () => {
    dirty();
    area.rows = Math.max(4, area.value.split("\n").length);
    if (timer) clearTimeout(timer);
    timer = setTimeout(recolour, 250);
  });

  /* the two things which are always the same keys */
  area.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "s") {
      event.preventDefault();
      save.click();
    }
    /* tab is indentation here and not the next control: a code box which
     * cannot indent is not one */
    if (event.key === "Tab") {
      event.preventDefault();
      const at = area.selectionStart;
      area.setRangeText("    ", at, area.selectionEnd, "end");
      dirty();
    }
  });

  save.addEventListener("click", async () => {
    save.disabled = true;
    const answer = await api.save(file.path, area.value);
    save.disabled = false;
    if (answer && answer.errors) {
      note.textContent = answer.errors;
      return;
    }
    saved = area.value;
    note.textContent = "edited, not saved";
    dirty();
  });

  revert.addEventListener("click", () => {
    area.value = saved;
    dirty();
    recolour();
  });
  return box;
};

/* the text of a file, out of the lines it was drawn from */
const text = (source) => list(source.lines).map((line) =>
  list(line.tokens).map((token) => token.text || "").join("")).join("\n");

/* ----------------------------------------------------------------- plan
 *
 * the todo list the agent keeps for itself. the terminal prints it when it
 * changes; a page can keep it in view, which is better — the question "what is
 * it doing and how much is left" is the one people ask most while it works.
 */

export const plan = (() => {
  const panel = byId("todospanel");

  const draw = (items) => {
    const all = items.filter((item) => item && item.content);
    panel.textContent = "";
    panel.classList.toggle("hidden", all.length === 0);
    if (!all.length) return;

    /* one line: what it is doing now and how far along it is. the whole list
     * is a click away and folded by default — a plan which pushed the
     * conversation off the screen would be answering a question nobody asked
     * as often as the one they did */
    const done = all.filter((item) => item.status === "completed").length;
    const doing = all.find((item) => item.status === "in_progress")
      || all.find((item) => item.status !== "completed");

    const box = el("details", "todos-fold");
    const head = el("summary");
    head.appendChild(el("span", "count", `${done}/${all.length}`));
    head.appendChild(el("span", "now", doing ? doing.content : "done"));
    box.appendChild(head);
    box.appendChild(todos(all));
    panel.appendChild(box);
  };

  return {
    show: (items) => draw(list(items)),
    clear: () => draw([])
  };
})();

/* --------------------------------------------------------------- palette
 *
 * the slash commands, as the terminal has them. the same registry answers both,
 * so a command a plugin adds shows up here without anybody adding it twice.
 */

export const palette = (() => {
  const box = byId("palette");
  let commands = [];
  let shown = [];
  let token = null;      /* what is being completed: {kind, start, text} */
  let index = 0;
  let onpick = () => {};
  let inflight = 0;

  const draw = () => {
    box.textContent = "";
    box.classList.toggle("hidden", shown.length === 0);
    shown.forEach((item, at) => {
      const row = el("button", "palette-row" + (at === index ? " is-current" : ""));
      row.type = "button";
      row.appendChild(el("span", "name", item.kind === "file" ? item.name : "/" + item.name));
      row.appendChild(el("span", "desc", item.kind === "file" ? item.dir : (item.description || "")));
      if (item.source) row.appendChild(el("span", "source", item.source));
      /* mousedown and not click: the textarea must not lose the focus first,
       * because losing it is what closes the palette */
      row.addEventListener("mousedown", (event) => { event.preventDefault(); onpick(item); });
      box.appendChild(row);
    });
  };

  /* what the caret is sitting in, if it is anything we complete
   *
   * a command only at the very beginning, because `/` is a path separator
   * everywhere else; a file mention after a space, because `@` is in every
   * email address ever pasted into a question */
  const at = (text, caret) => {
    const before = text.slice(0, caret);
    if (/^\/[^\s]*$/.test(before)) {
      return {kind: "command", start: 0, text: before.slice(1)};
    }
    const mention = before.match(/(^|\s)@([^\s]*)$/);
    if (mention) {
      return {kind: "file", start: caret - mention[2].length - 1, text: mention[2]};
    }
    return null;
  };

  const hide = () => { shown = []; token = null; index = 0; draw(); };

  return {
    async load() {
      const answer = await api.commands();
      commands = list(answer.commands).map((command) => ({...command, kind: "command"}));
    },

    /* the box changed: show what could come next, if anything */
    async update(text, caret, pick) {
      onpick = pick;
      const found = at(text, caret);
      if (!found) { hide(); return; }
      token = found;

      if (found.kind === "command") {
        const typed = found.text.toLowerCase();
        shown = commands.filter((command) => command.name.toLowerCase().startsWith(typed)).slice(0, 8);
        index = 0;
        draw();
        return;
      }

      /* the files come from the harness, so the answer of a query which was
       * overtaken by the next keystroke is dropped rather than drawn */
      const ticket = ++inflight;
      const answer = await api.files(found.text);
      if (ticket !== inflight || !token || token.kind !== "file") return;
      shown = list(answer.files).map((file) => ({...file, kind: "file"}));
      index = 0;
      draw();
    },

    hide,
    get open() { return shown.length > 0; },
    get token() { return token; },
    move(step) {
      if (!shown.length) return;
      index = (index + step + shown.length) % shown.length;
      draw();
    },
    current() { return shown[index]; },

    /* the line, with what was picked put where it was being typed */
    complete(text, caret, item) {
      if (!token) return {text, caret};
      const inserted = item.kind === "file" ? "@" + item.path + " " : "/" + item.name + " ";
      const head = text.slice(0, token.start) + inserted;
      return {text: head + text.slice(caret), caret: head.length};
    }
  };
})();

/* -------------------------------------------------------------- sessions */

export const sessions = (() => {
  const menu = byId("sessionmenu");
  const picker = byId("sessionpicker");
  const name = byId("sessionname");

  /* the conversations of this project, where the current one is named
   *
   * they used to be a screen of their own, which meant leaving the work to
   * change conversation and coming back to find out where you were. a list
   * under the name of the one you are in is the same thing without the trip.
   */
  const draw = async (current) => {
    menu.textContent = "";
    const answer = await api.sessions();
    const items = list(answer.sessions);
    if (!items.length) {
      menu.appendChild(el("p", "session-empty",
        "No conversation has been saved for this project yet."));
      return;
    }

    for (const item of items) {
      const row = el("div", "session-row" + (item.id === current ? " is-current" : ""));

      const open = el("button", "session-open");
      open.type = "button";
      open.appendChild(el("span", "title", item.title || "(untitled)"));
      const meta = el("span", "meta");
      meta.appendChild(el("span", null, when(item.updatetime)));
      meta.appendChild(el("span", null, `${item.events || 0} messages`));
      open.appendChild(meta);
      open.addEventListener("click", async () => {
        hide();
        await api.resume(item.id);
      });
      row.appendChild(open);

      /* two clicks to remove one, and the second says what it will do: a
       * conversation is work, and one stray click should not end it */
      const remove = el("button", "session-remove", "remove");
      remove.type = "button";
      let armed = false;
      remove.addEventListener("click", async (event) => {
        event.stopPropagation();
        if (!armed) {
          armed = true;
          remove.textContent = "sure?";
          remove.classList.add("armed");
          setTimeout(() => {
            armed = false;
            remove.textContent = "remove";
            remove.classList.remove("armed");
          }, 4000);
          return;
        }
        const answer = await api.forget(item.id);
        if (answer && answer.errors) {
          remove.textContent = answer.errors;
          return;
        }
        await draw(current);
      });
      row.appendChild(remove);
      menu.appendChild(row);
    }
  };

  const hide = () => menu.classList.add("hidden");

  /* clicking anywhere else puts it away, which is what a menu does */
  document.addEventListener("click", (event) => {
    if (menu.classList.contains("hidden")) return;
    if (menu.contains(event.target) || picker.contains(event.target)) return;
    hide();
  });

  return {
    draw,
    hide,
    async toggle(current) {
      if (!menu.classList.contains("hidden")) { hide(); return; }
      menu.classList.remove("hidden");
      await draw(current);
    },
    /* the name in the head is the conversation you are in */
    title(text) { name.textContent = text || "new conversation"; }
  };
})();

/* -------------------------------------------------------------- settings */

export const settings = (() => {
  const body = byId("settings");

  const field = (entry, onsave) => {
    const row = el("label", "field");
    row.appendChild(el("span", "field-name", entry.label));
    if (entry.hint) row.appendChild(el("span", "field-hint", entry.hint));

    let input;
    if (entry.choices) {
      input = el("select");
      for (const choice of list(entry.choices)) {
        const option = el("option", null, choice);
        option.value = choice;
        if (choice === entry.value) option.selected = true;
        input.appendChild(option);
      }
    } else {
      input = el("input");
      input.type = entry.secret ? "password" : "text";
      input.value = entry.value || "";
      input.placeholder = entry.placeholder || "";
    }
    input.addEventListener("change", () => onsave(entry.key, input.value));
    row.appendChild(input);
    return row;
  };

  return {
    async draw(theme, onchat) {
      body.textContent = "";
      const answer = await api.settings();

      /* where the agent is working, which is the one setting a page can change
       * that the harness has to be rebuilt for, @see harness.web.session.chdir */
      const state = await api.state();
      const project = el("section", "group");
      project.appendChild(el("h3", null, "Project"));
      project.appendChild(el("p", "group-hint",
        "The directory the agent reads, builds and edits. Changing it starts a new conversation."));
      const row = el("label", "field");
      row.appendChild(el("span", "field-name", "Directory"));
      const dir = el("input");
      dir.type = "text";
      dir.value = state.cwd || "";
      dir.spellcheck = false;
      dir.addEventListener("change", async () => {
        const answer = await api.chdir(dir.value);
        if (answer && answer.errors) {
          row.appendChild(el("span", "field-error", answer.errors));
        } else {
          this.draw(theme, onchat);
        }
      });
      row.appendChild(dir);
      project.appendChild(row);
      body.appendChild(project);

      /* the appearance is the page's own business and never leaves it: the
       * harness has no opinion about which theme a browser is showing */
      const look = el("section", "group");
      look.appendChild(el("h3", null, "Appearance"));
      const themes = el("div", "segmented");
      for (const name of ["auto", "light", "dark"]) {
        const button = el("button", "seg" + (theme.current() === name ? " is-on" : ""), name);
        button.type = "button";
        button.addEventListener("click", () => { theme.set(name); this.draw(theme, onchat); });
        themes.appendChild(button);
      }
      look.appendChild(themes);
      body.appendChild(look);

      /* the one question a settings page cannot answer by itself is "does any
       * of this work". the harness already has that answer — `/doctor` — so the
       * button asks it rather than growing a second opinion here */
      const check = el("section", "group");
      check.appendChild(el("h3", null, "Is it working?"));
      check.appendChild(el("p", "group-hint",
        "Runs `/doctor` in the conversation: the provider, the key, the tools and the sandbox."));
      const run = el("button", "pill", "run /doctor");
      run.type = "button";
      run.addEventListener("click", async () => {
        run.disabled = true;
        await api.send("/doctor");
        onchat();
      });
      check.appendChild(run);
      body.appendChild(check);

      for (const group of list(answer.groups)) {
        const section = el("section", "group");
        section.appendChild(el("h3", null, group.title));
        if (group.hint) section.appendChild(el("p", "group-hint", group.hint));
        for (const entry of list(group.fields)) {
          section.appendChild(field(entry, async (key, value) => {
            await api.setting(key, value);
          }));
        }
        body.appendChild(section);
      }
    }
  };
})();
