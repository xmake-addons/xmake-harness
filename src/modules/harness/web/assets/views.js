/* the screens
 *
 * one object per screen, each owning its own corner of the document and nothing
 * else. `app.js` decides which one is showing; none of them know about the
 * others.
 */
"use strict";

import {api} from "./api.js";
import {el, message, tool, pending, thinking, filecard, summary, permission,
        codediff, changerow, todos, chip, brief, when, list,
        iconbutton, notice} from "./render.js";

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
  const changed = new Map();
  const turnfiles = new Set();

  const SUGGESTIONS = [
    "What does this project build?",
    "Fix the build errors",
    "Add a unit test target",
    "Explain the xmake.lua"
  ];

  const atBottom = () => thread.scrollHeight - thread.scrollTop - thread.clientHeight < 140;

  /* reading something further up while the answer keeps coming is a normal
   * thing to want, so the view stops following and offers a way back down */
  const tobottom = byId("tobottom");
  const bottom = () => { thread.scrollTop = thread.scrollHeight; };
  thread.addEventListener("scroll", () => tobottom.classList.toggle("hidden", atBottom()));
  tobottom.addEventListener("click", () => { bottom(); tobottom.classList.add("hidden"); });

  const add = (node) => {
    const stick = atBottom();
    messages.appendChild(node);
    if (stick) thread.scrollTop = thread.scrollHeight;
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
      streaming = {text: "", node: add(el("div", "msg assistant"))};
      streaming.body = el("div", "text streaming");
      streaming.node.appendChild(streaming.body);
      streaming.node.appendChild(el("span", "caret"));
    }
    streaming.text += delta;
    streaming.body.textContent = streaming.text;
    if (atBottom()) thread.scrollTop = thread.scrollHeight;
  };

  /* the streamed text is replaced by the rendered answer, in place: the node
   * which was growing token by token is swapped for the finished message, so
   * the page never shows the same answer twice or jumps as it settles */
  const settle = (payload) => {
    thought = null;
    if (!streaming) return;
    const stick = atBottom();
    streaming.node.replaceWith(message("assistant", payload || {text: streaming.text}));
    streaming = null;
    if (stick) thread.scrollTop = thread.scrollHeight;
  };

  /* the reasoning arrives token by token like the answer does, but it is not
   * the answer: it goes into its own folded block above it */
  const think = (delta) => {
    if (!thought) {
      thought = {text: "", node: add(thinking())};
    }
    thought.text += delta;
    thought.node.body.textContent = thought.text;
    if (atBottom()) thread.scrollTop = thread.scrollHeight;
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
    empty, suggest, stream, settle, add, think, started, ask, asked, changeset,
    user: (text, iscommand) => {
      empty(false);
      add(message(iscommand ? "command" : "user", {text, reuse: onreuse}));
    },
    onreuse(handler) { onreuse = handler; },
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
      changed.clear();
      turnfiles.clear();
      empty(true);
    },
    draw(state) {
      this.clear();
      for (const item of list(state.messages)) {
        if (item.role === "tool") {
          const change = record(item);
          add(change ? filecard(change, {limit: 60}) : tool(item));
        } else {
          add(message(item.role, item.role === "user" ? {...item, reuse: onreuse} : item));
        }
      }
      empty(list(state.messages).length === 0);
      thread.scrollTop = thread.scrollHeight;
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
  const listbox = byId("gitlist");
  const pane = byId("gitdiff");
  const count = byId("gitcount");
  const badge = byId("changecount");
  let current = null;

  const empty = (node, title, note) => {
    node.textContent = "";
    const box = el("div", "empty");
    box.appendChild(el("h3", null, title));
    if (note) box.appendChild(el("p", null, note));
    node.appendChild(box);
  };

  const show = async (file) => {
    current = file.path;
    [...listbox.children].forEach((row) =>
      row.classList.toggle("is-current", row.dataset && row.dataset.path === file.path));

    pane.textContent = "";
    const head = el("header", "diff-head");
    const names = el("span", "names");
    names.appendChild(el("span", "name", file.name || file.path));
    if (file.dir) names.appendChild(el("span", "dir", file.dir));
    head.appendChild(names);

    if (file.nodiff && !file.reverted) {
      head.appendChild(el("span", "diff-state", file.gone ? "removed by a command"
        : "changed by a command"));
      pane.appendChild(head);
      const body = el("div", "diff-body");
      pane.appendChild(body);
      empty(body, "No before to compare against",
            "A command wrote this file. Nobody knew which files it was about to write, "
            + "so no copy of what it held was kept — and without one there is neither a "
            + "diff to show nor a way to put it back.");
      return;
    }

    if (file.reverted) {
      head.appendChild(el("span", "diff-state", "put back"));
      pane.appendChild(head);
      const body = el("div", "diff-body");
      pane.appendChild(body);
      empty(body, "This change was put back",
            "The file holds what it held before this conversation touched it.");
      return;
    }

    const actions = el("span", "diff-actions");
    actions.appendChild(iconbutton("check", "act big keep" + (file.kept ? " is-on" : ""),
      file.kept ? "kept — click to undecide" : "keep this change",
      async () => { await api.keep(file.path, !file.kept); await draw(); }));
    actions.appendChild(iconbutton("cross", "act big revert",
      file.created
        ? "the agent created this file, so putting it back means removing it"
        : "put this file back the way it was before this conversation",
      async () => {
        const answer = await api.revert(file.path);
        if (answer && answer.errors) {
          head.appendChild(el("span", "diff-error", answer.errors));
          return;
        }
        current = null;
        await draw();
      }));
    head.appendChild(actions);
    pane.appendChild(head);

    const body = el("div", "diff-body");
    pane.appendChild(body);

    const answer = await api.filediff(file.path);
    if (answer && answer.errors) {
      empty(body, "That diff could not be read", answer.errors);
    } else if (!list(answer.lines).length) {
      empty(body, "Nothing is different", "The file holds what it held before.");
    } else {
      body.appendChild(codediff(answer));
    }
  };

  /* one decision for all of them, because a list of twelve decisions which are
   * all the same decision is a chore. reverting is armed first: it throws work
   * away, and a stray click on the wrong button should not be able to */
  const bulk = (files) => {
    const box = byId("gitbulk");
    box.textContent = "";
    const undecided = files.filter((file) => file.undecided).length;
    const revertable = files.filter((file) => !file.reverted && !file.nodiff).length;
    box.classList.toggle("hidden", undecided === 0 && revertable === 0);
    if (undecided === 0 && revertable === 0) return;

    if (undecided > 0) {
      box.appendChild(iconbutton("checkall", "act keepall",
        `keep all ${undecided} undecided changes`,
        async () => { await api.decideall("keep"); await draw(); }));
    }
    if (revertable > 0) {
      let armed = false;
      const all = iconbutton("cross", "act revertall",
        `put all ${revertable} files back`, async () => {
          if (!armed) {
            armed = true;
            all.classList.add("armed");
            all.title = `click again to put all ${revertable} files back`;
            setTimeout(() => { armed = false; all.classList.remove("armed"); }, 4000);
            return;
          }
          await api.decideall("revert");
          current = null;
          await draw();
        });
      box.appendChild(all);
    }
  };

  const draw = async (pick) => {
    const answer = await api.changes();
    const files = list(answer.files);
    const undecided = files.filter((file) => file.undecided).length;
    bulk(files);
    badge.textContent = String(undecided);
    badge.classList.toggle("hidden", undecided === 0);
    count.textContent = files.length === 1 ? "1 file changed" : `${files.length} files changed`;

    listbox.textContent = "";
    if (!files.length) {
      empty(listbox, "Nothing has been changed",
            "The files this conversation edits appear here, with their diffs. "
            + "Files a command writes appear too, as long as it ran inside this project — "
            + "one which writes somewhere else entirely is not something a project can see.");
      empty(pane, "Nothing to show", "");
      return;
    }
    for (const file of files) {
      listbox.appendChild(changerow(file, {
        pick: (picked) => show(picked),
        keep: async (picked, kept) => { await api.keep(picked.path, kept); await draw(); },
        revert: async (picked) => {
          await api.revert(picked.path);
          if (current === picked.path) current = null;
          await draw();
        }
      }));
    }

    /* keep looking at the same file across a refresh, or open the one which
     * was asked for: a view which jumped back to the top every time the agent
     * saved a file would be unusable while it works */
    const keep = files.find((file) => file.path === (pick || current)) || files[0];
    await show(keep);
  };

  /* the badge is on the rail and has to be right before anybody opens the
   * view, so the count can be refreshed on its own */
  const refresh = async () => {
    const answer = await api.changes();
    const undecided = list(answer.files).filter((file) => file.undecided).length;
    badge.textContent = String(undecided);
    badge.classList.toggle("hidden", undecided === 0);
  };

  return {
    draw, refresh,
    /* the agent saved a file while somebody is looking at this: the list is
     * redrawn where it is, and the file being read stays the one on screen */
    live: () => { if (byId("gitlist").offsetParent !== null || document.querySelector(
      ".view[data-view=\"changes\"].is-active")) draw(); else refresh(); }
  };
})();

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
  let pending = 0;

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
      const ticket = ++pending;
      const answer = await api.files(found.text);
      if (ticket !== pending || !token || token.kind !== "file") return;
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
  const body = byId("sessions");

  const draw = async (current) => {
    body.textContent = "";
    const answer = await api.sessions();
    const items = list(answer.sessions);
    if (!items.length) {
      body.appendChild(el("p", "empty", "No conversation has been saved for this project yet."));
      return;
    }
    for (const item of items) {
      const card = el("div", "card" + (item.id === current ? " is-current" : ""));

      const open = el("button", "card-open");
      open.type = "button";
      open.appendChild(el("span", "card-title", item.title || "(untitled)"));
      const meta = el("span", "card-meta");
      meta.appendChild(el("span", null, when(item.updatetime)));
      meta.appendChild(el("span", null, `${item.events || 0} messages`));
      meta.appendChild(el("span", "mono", item.id));
      open.appendChild(meta);
      open.addEventListener("click", () => api.resume(item.id));
      card.appendChild(open);

      /* two clicks to remove one, and the second one says what it will do:
       * a conversation is work, and a single stray click should not end it */
      const remove = el("button", "card-remove", "remove");
      remove.type = "button";
      let armed = false;
      remove.addEventListener("click", async () => {
        if (!armed) {
          armed = true;
          remove.textContent = "remove for good?";
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
      card.appendChild(remove);
      body.appendChild(card);
    }
  };

  return {draw};
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
            await api.save(key, value);
          }));
        }
        body.appendChild(section);
      }
    }
  };
})();
