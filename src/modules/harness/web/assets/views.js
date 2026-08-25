/* the screens
 *
 * one object per screen, each owning its own corner of the document and nothing
 * else. `app.js` decides which one is showing; none of them know about the
 * others.
 */
"use strict";

import {api} from "./api.js";
import {el, message, tool, pending, thinking, diff, chip, brief, when, list} from "./render.js";

const byId = (id) => document.getElementById(id);

/* ------------------------------------------------------------------ chat */

export const chat = (() => {
  const thread = byId("thread");
  const messages = byId("messages");
  const hero = byId("hero");
  let streaming = null;
  let thought = null;
  const running = new Map();

  const SUGGESTIONS = [
    "What does this project build?",
    "Fix the build errors",
    "Add a unit test target",
    "Explain the xmake.lua"
  ];

  const atBottom = () => thread.scrollHeight - thread.scrollTop - thread.clientHeight < 140;

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

  const finished = (event) => {
    const node = event.id && running.get(event.id);
    if (!node) {
      return add(tool(event));
    }
    running.delete(event.id);
    const card = tool(event);
    node.replaceWith(card);
    return card;
  };

  return {
    empty, suggest, stream, settle, add, think, started,
    user: (text) => { empty(false); add(message("user", {text})); },
    tool: (event) => finished(event),
    note: (kind, text) => add(message(kind, {text})),
    clear: () => { messages.textContent = ""; streaming = null; thought = null;
                   running.clear(); empty(true); },
    draw(state) {
      messages.textContent = "";
      streaming = null;
      thought = null;
      running.clear();
      for (const item of list(state.messages)) {
        if (item.role === "tool") {
          add(tool({name: item.name, title: item.name, iserror: item.iserror,
                    subject: item.path, output: item.output}));
        } else {
          add(message(item.role, item));
        }
      }
      empty(list(state.messages).length === 0);
      thread.scrollTop = thread.scrollHeight;
    }
  };
})();

/* --------------------------------------------------------------- changes */

export const changes = (() => {
  const body = byId("changes");
  const badge = byId("changecount");
  const seen = new Map();

  const draw = () => {
    body.textContent = "";
    badge.textContent = String(seen.size);
    badge.classList.toggle("hidden", seen.size === 0);
    if (!seen.size) {
      body.appendChild(el("p", "empty", "Nothing has been edited in this conversation yet."));
      return;
    }
    for (const [filepath, payload] of seen) {
      const card = el("details", "tool");
      card.open = seen.size <= 3;
      const head = el("summary");
      head.appendChild(el("span", "what", filepath.split(/[\\/]/).pop()));
      head.appendChild(el("span", "subject", filepath));
      head.appendChild(el("span", "summary", payload.summary || ""));
      card.appendChild(head);
      const holder = el("div", "body");
      holder.appendChild(diff(payload.diff, {limit: 400}));
      card.appendChild(holder);
      body.appendChild(card);
    }
  };

  return {
    /* one entry per file, holding the most recent diff of it: a list which
     * repeated the same file five times would answer "what changed" with a
     * history nobody asked for */
    record(event) {
      if (event.kind !== "diff" || !event.diff) return;
      seen.set(event.diff.filepath || event.subject || "?",
               {diff: event.diff, summary: event.summary});
      draw();
    },
    reset() { seen.clear(); draw(); }
  };
})();

/* -------------------------------------------------------------- sessions */

export const sessions = (() => {
  const body = byId("sessions");

  return {
    async draw(current) {
      body.textContent = "";
      const answer = await api.sessions();
      const items = list(answer.sessions);
      if (!items.length) {
        body.appendChild(el("p", "empty", "No conversation has been saved for this project yet."));
        return;
      }
      for (const item of items) {
        const card = el("button", "card" + (item.id === current ? " is-current" : ""));
        card.type = "button";
        card.appendChild(el("span", "card-title", item.title || "(untitled)"));
        const meta = el("span", "card-meta");
        meta.appendChild(el("span", null, when(item.updatetime)));
        meta.appendChild(el("span", null, `${item.events || 0} messages`));
        meta.appendChild(el("span", "mono", item.id));
        card.appendChild(meta);
        card.addEventListener("click", async () => {
          await api.resume(item.id);
        });
        body.appendChild(card);
      }
    }
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
    async draw(theme) {
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
          this.draw(theme);
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
        button.addEventListener("click", () => { theme.set(name); this.draw(theme); });
        themes.appendChild(button);
      }
      look.appendChild(themes);
      body.appendChild(look);

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
