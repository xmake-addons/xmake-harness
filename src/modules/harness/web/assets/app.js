/* xmake ai — the wiring
 *
 * no framework and no build step: what is on disk is what the browser runs, so
 * editing a file and reloading is the whole development loop.
 *
 *   api.js      talking to the harness
 *   render.js   turning one thing into dom
 *   views.js    the screens
 *   app.js      which screen is showing, and what an event does
 */
"use strict";

import {api} from "./api.js";
import {brief} from "./render.js";
import {chat, changes, palette, plan, sessions, settings} from "./views.js";

const byId = (id) => document.getElementById(id);

/* ---------------------------------------------------------------- theme */

const theme = (() => {
  const root = document.documentElement;
  const dark = window.matchMedia("(prefers-color-scheme: dark)");
  const apply = (choice) => {
    root.dataset.theme = choice;
    root.classList.toggle("prefers-dark", choice === "auto" && dark.matches);
  };
  apply(localStorage.getItem("xmake-ai-theme") || "auto");
  dark.addEventListener("change", () => apply(root.dataset.theme));
  return {
    current: () => root.dataset.theme,
    set: (choice) => { localStorage.setItem("xmake-ai-theme", choice); apply(choice); }
  };
})();

/* --------------------------------------------------------------- screens */

const stage = (() => {
  const work = document.querySelector('.view[data-view="work"]');

  const show = (name, argument) => {
    document.querySelectorAll(".view").forEach((view) =>
      view.classList.toggle("is-active", view.dataset.view === name));
    document.querySelectorAll(".rail-item").forEach((item) =>
      item.classList.toggle("is-active", item.dataset.view === name));
    if (name === "settings") settings.draw(theme, () => show("work"));
  };

  /* the rail is what changes the screen, and it had better be wired to it */
  document.querySelectorAll(".rail-item").forEach((item) =>
    item.addEventListener("click", () => show(item.dataset.view)));

  /* the work screen has two shapes, and it is the reader who picks
   *
   * a conversation which has just changed a file has not necessarily been
   * asked "show me": the badge says there is something to look at, and the
   * screen changes when somebody goes to look — by opening a file from the
   * list at the end of a turn, or with the button in the corner. a layout
   * which rearranged itself under somebody mid-sentence would be answering a
   * question they had not asked.
   */
  const layout = (next) => {
    work.dataset.layout = next;
    byId("widen").textContent = next === "split" ? "full width" : "show changes";
  };

  return {
    show,
    /* @param pick  the file to open, if this is somebody going to look at one */
    async choose(next, pick) {
      layout(next);
      if (next === "split") await changes.draw(pick);
    },
    get layout() { return work.dataset.layout; }
  };
})();

/* ------------------------------------------------------------------- app */

const app = {
  working: false,
  sessionid: null,

  busy(state) {
    this.working = state;
    byId("status").classList.toggle("hidden", !state);
    byId("send").classList.toggle("busy", state);
    byId("dot").className = "dot " + (state ? "busy" : "live");
    if (!state) this.say("");
  },

  /* show one file, from wherever it was clicked: the workspace opens if it
   * was not open, and the file which was clicked is the one being read */
  open(filepath) {
    stage.choose("split", filepath);
  },

  /* the tools which are running right now */
  running: new Map(),

  saytools() {
    const names = [...this.running.values()];
    if (names.length === 0) {
      this.say("thinking…");
    } else if (names.length === 1) {
      this.say(`${names[0]}…`);
    } else {
      this.say(`${names.length} tools running · ${[...new Set(names)].join(", ")}`);
    }
  },

  /* what it is doing, in words
   *
   * a spinner says "something is happening" and nothing else, and the thing
   * which is happening is the interesting part: a build which takes a minute
   * and a model which is thinking look identical until one of them is named */
  say(text) {
    byId("statustext").textContent = text || "";
  },

  /* how full the context window is, in the one place a status belongs */
  meter(context) {
    const meter = byId("meter");
    if (!context || !context.size) { meter.classList.add("hidden"); return; }
    const percent = Math.min(100, Math.round((context.ratio || 0) * 100));
    meter.classList.remove("hidden");
    meter.className = "meter" + (percent >= 85 ? " full" : percent >= 70 ? " filling" : "");
    byId("meterfill").style.width = percent + "%";
    byId("metertext").textContent = percent + "%";
    meter.title = `${brief(context.used || 0)} of ${brief(context.size)} tokens of context used`;
  },

  /* a `/loop` is armed or gone: it is the one thing which makes the page act on
   * its own, so it says so where the rest of the state is */
  loop(state) {
    const box = byId("loop");
    box.textContent = (state && state.text) || "";
    box.classList.toggle("hidden", !(state && state.text));
  },

  /* what is still running in the background, which a terminal only mentions at
   * the next step and a page can simply keep in view */
  jobs(running) {
    const box = byId("jobs");
    const list = Array.isArray(running) ? running : [];
    box.textContent = list.length === 1 ? "1 job running" : `${list.length} jobs running`;
    box.title = list.map((job) => job.label || job.id).join("\n");
    box.classList.toggle("hidden", list.length === 0);
  },

  counts(total) {
    if (!total || !total.input) { byId("usage").textContent = ""; return; }
    const seen = (total.cachehit || 0) + (total.cachemiss || 0);
    const rate = seen ? Math.round(100 * (total.cachehit || 0) / seen) : null;
    byId("usage").textContent = `${brief(total.input)}↑ ${brief(total.output)}↓`
      + (rate === null ? "" : ` · cache ${rate}%`);
  },

  /* one event from the harness, and what it does to the page */
  handle(name, payload) {
    switch (name) {
      case "ready":
        byId("dot").className = "dot live";
        byId("offline").classList.add("hidden");
        break;
      case "offline":
        byId("dot").className = "dot lost";
        byId("offline").classList.remove("hidden");
        break;
      case "turn.start":
        this.lastprompt = payload.command ? null : payload.prompt;
        chat.user(payload.prompt, payload.command);
        this.busy(true);
        this.say(payload.command ? `${payload.prompt}…` : "thinking…");
        break;
      case "step":
        byId("model").textContent = payload.model || "";
        this.say(payload.step > 1 ? `thinking… (step ${payload.step})` : "thinking…");
        break;
      case "text":        this.say("writing…"); chat.stream(payload.delta || ""); break;
      case "text.block":  chat.block(payload); break;
      case "reasoning":   this.say("reasoning…"); chat.think(payload.delta || ""); break;
      /* several tools run at once when none of them can get in the others' way
       * — reads, searches, subagents, @see harness.tools.runner. each gets its
       * own card at once, and the status line says how many are going rather
       * than naming whichever one started last */
      case "tool.start":
        chat.settle();
        this.running.set(payload.id || payload.name, payload.name || "tool");
        this.saytools();
        chat.started(payload);
        break;
      case "assistant":   chat.settle(payload); break;
      case "tool.result":
        chat.settle();
        this.running.delete(payload.id || payload.name);
        this.saytools();
        chat.tool(payload);
        if (payload.kind === "diff") changes.live();
        if (payload.kind === "todos") plan.show(payload.todos);
        break;
      case "notice":      chat.settle(); chat.note("notice", payload.text || ""); break;
      /* an error is usually the provider having a bad minute, and the useful
       * thing at that moment is the same message again rather than typing it
       * out a second time */
      case "error":
        chat.settle();
        chat.note("error", payload.text || "", this.lastprompt && {
          text: "retry",
          run: async (button) => {
            button.disabled = true;
            const again = this.lastprompt;
            this.lastprompt = null;
            const answer = await api.send(again);
            if (answer && answer.errors) chat.note("error", answer.errors);
          }
        });
        break;
      case "usage":       this.counts(payload.total); break;
      case "context":     this.meter(payload); break;
      case "mode":        byId("mode").textContent = payload.mode || ""; break;
      case "changed":     changes.live(); break;
      /* a `/loop` is armed or gone: it is the one thing which makes the page
       * act on its own, so it says so where the state is */
      case "loop":        this.loop(payload); break;
      case "jobs":        this.jobs(payload.jobs); break;
      case "ask":
        chat.settle();
        this.say("waiting for you…");
        chat.ask(payload, (value) => api.answer(payload.id, value));
        break;
      case "ask.done":    chat.asked(payload.id); break;
      case "turn.end":
        this.running.clear();
        chat.settle();
        if (this.finished) this.finished();
        chat.changeset((change) => this.open(change.filepath));
        changes.live();
        this.busy(false);
        this.counts(payload.usage);
        break;
      /* the conversation was swapped, here or in another tab: the page asks for
       * the state again rather than being sent it, so every tab redraws from
       * the one history the harness keeps */
      case "session":     api.state().then((state) => this.draw(state)); break;
    }
  },

  draw(state) {
    this.sessionid = state.id;
    sessions.title(state.title);
    chat.draw(state);
    plan.show(state.todos);
    byId("cwd").textContent = state.cwd || "";
    byId("mode").textContent = state.mode || "";
    this.meter(state.context);
    this.loop(state.loop);
    this.jobs(state.jobs);
    this.counts(state.usage);
    this.busy(!!state.working);

    /* the tab says which project it is: two of these open at once is the
     * normal way to use it, and "xmake ai" twice tells you nothing */
    document.title = state.project ? `${state.project} · xmake ai` : "xmake ai";

    changes.refresh();
  },

  async submit() {
    const prompt = byId("prompt");
    const text = prompt.value.trim();
    if (!text || this.working) return;
    history.remember(text);
    prompt.value = "";
    prompt.style.height = "";
    palette.hide();
    const answer = await api.send(text);
    if (answer && answer.errors) chat.note("error", answer.errors);
  }
};

/* --------------------------------------------------------------- history
 *
 * what was typed before, on the up arrow, as every shell and the terminal ui
 * do it. it lives in the browser and not in the harness: it is what *this
 * person at this keyboard* typed, and it should not follow the conversation
 * onto somebody else's screen.
 */
const history = (() => {
  const KEY = "xmake-ai-history";
  const MAX = 50;
  let lines = [];
  let at = -1;
  let draft = "";

  try { lines = JSON.parse(localStorage.getItem(KEY) || "[]"); } catch (_) { lines = []; }
  if (!Array.isArray(lines)) lines = [];

  const save = () => {
    try { localStorage.setItem(KEY, JSON.stringify(lines.slice(0, MAX))); } catch (_) {}
  };

  return {
    remember(text) {
      if (!text || lines[0] === text) { at = -1; return; }
      lines.unshift(text);
      lines = lines.slice(0, MAX);
      at = -1;
      save();
    },
    /* only from the ends of the box: in the middle of a line the arrows are
     * for moving the caret, which is what they are for everywhere else */
    move(step, box) {
      if (!lines.length) return false;
      if (at === -1) {
        if (step < 0) return false;
        draft = box.value;
      }
      const next = at + step;
      if (next < -1 || next >= lines.length) return false;
      at = next;
      box.value = at === -1 ? draft : lines[at];
      box.setSelectionRange(box.value.length, box.value.length);
      return true;
    },
    reset() { at = -1; }
  };
})();

/* ------------------------------------------------------------------ boot */

const boot = async () => {
  const prompt = byId("prompt");

  /* the token came in the url and the browser now has it in a cookie, so the
   * address bar can lose it: a live secret in the history, in the title bar and
   * in every screenshot of this page is a secret with a longer life than the
   * session it belongs to. the page keeps its own copy, @see api.js */
  const here = window.location;
  if (here && here.search && here.search.includes("token=")
      && window.history && window.history.replaceState) {
    window.history.replaceState({}, "", here.pathname);
  }

  /* the mode button cycles as shift+tab does in the terminal: default →
   * accept edits → plan. bypass is not in the cycle, because turning every
   * safeguard off is not something to reach by clicking one button twice */
  const MODES = ["default", "acceptedits", "plan"];
  byId("mode").addEventListener("click", async () => {
    const now = byId("mode").textContent.trim();
    const next = MODES[(MODES.indexOf(now) + 1) % MODES.length];
    const answer = await api.mode(next);
    if (answer && answer.errors) chat.note("error", answer.errors);
  });

  byId("send").addEventListener("click", () => app.submit());
  byId("stop").addEventListener("click", () => api.abort());

  /* the palette takes the keys it needs and leaves the rest alone: up and down
   * move through it, tab and enter take the command it is showing, escape puts
   * it away without touching the turn */
  const complete = (item) => {
    if (!item) return;
    const {text, caret} = palette.complete(prompt.value, prompt.selectionStart, item);
    prompt.value = text;
    prompt.setSelectionRange(caret, caret);
    palette.hide();
    prompt.focus();
  };

  prompt.addEventListener("keydown", (event) => {
    if (palette.open) {
      if (event.key === "ArrowDown") { event.preventDefault(); palette.move(1); return; }
      if (event.key === "ArrowUp") { event.preventDefault(); palette.move(-1); return; }
      if (event.key === "Tab") { event.preventDefault(); complete(palette.current()); return; }
      if (event.key === "Escape") { event.preventDefault(); palette.hide(); return; }
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        complete(palette.current());
        return;
      }
    }
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); app.submit(); }

    /* the box is a textarea, so the arrows belong to it while there is
     * anything to move through; at the ends they recall what was typed before */
    if (event.key === "ArrowUp" && prompt.selectionStart === 0 && prompt.selectionEnd === 0) {
      if (history.move(1, prompt)) event.preventDefault();
    } else if (event.key === "ArrowDown" && prompt.selectionStart === prompt.value.length) {
      if (history.move(-1, prompt)) event.preventDefault();
    }
  });
  prompt.addEventListener("blur", () => palette.hide());

  /* escape stops the turn, as it does in the terminal — the same key for the
   * same thing, so there is one thing to remember and not two */
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && app.working) { event.preventDefault(); api.abort(); }

    /* ctrl+f is the browser's, and it stays the browser's: the page only puts
     * the folded parts of the document back before the find box opens, because
     * the browser can only find what is in the document. nothing is prevented
     * here — the find happens exactly as it always does, over all of it */
    if ((event.ctrlKey || event.metaKey) && (event.key === "f" || event.key === "F")) {
      chat.expandall();
      document.querySelectorAll(".diff-more, .earlier").forEach((button) => button.click());
    }
  });
  prompt.addEventListener("input", () => {
    prompt.style.height = "";
    prompt.style.height = Math.min(prompt.scrollHeight, window.innerHeight * 0.4) + "px";
    palette.update(prompt.value, prompt.selectionStart, complete);
  });

  byId("sessionpicker").addEventListener("click", () => sessions.toggle(app.sessionid));
  byId("newsession").addEventListener("click", async () => {
    sessions.hide();
    await api.fresh();
    prompt.focus();
  });
  byId("widen").addEventListener("click", () =>
    stage.choose(stage.layout === "split" ? "welcome" : "split"));

  /* on a phone the workspace fills the screen and the conversation is not on
   * it, so the way back has to be *here* — the button which would do it lives
   * in the chat, which is exactly what is not showing */
  byId("tochat").addEventListener("click", () => stage.choose("welcome"));

  byId("reload").addEventListener("click", () => window.location.reload());

  chat.suggest((text) => { prompt.value = text; prompt.focus(); app.submit(); });
  chat.onreuse((text) => {
    prompt.value = text;
    prompt.focus();
    prompt.setSelectionRange(text.length, text.length);
    prompt.dispatchEvent(new Event("input"));
  });

  /* the stream is subscribed to before the first draw, and the draw is allowed
   * to fail on its own: a page which threw while laying out an old conversation
   * used to end up connected to nothing, which looks from the outside exactly
   * like a harness that answers nothing */
  api.events((name, payload) => {
    try { app.handle(name, payload); }
    catch (error) { console.error("xmake ai:", name, error); }
  });
  try {
    app.draw(await api.state());
  } catch (error) {
    console.error("xmake ai:", error);
    chat.note("error", "the page could not be drawn: " + (error && error.message || error));
  }
  /* a turn which finished while the tab was in the background says so in the
   * one place a background tab is visible: its title. it is cleared the moment
   * somebody looks at it again, and it asks for no permission to do any of it */
  const mark = () => {
    if (!document.hidden) return;
    if (!document.title.startsWith("● ")) document.title = "● " + document.title;
  };
  const unmark = () => {
    if (document.title.startsWith("● ")) document.title = document.title.slice(2);
  };
  document.addEventListener("visibilitychange", () => { if (!document.hidden) unmark(); });
  window.addEventListener("focus", unmark);
  app.finished = mark;

  changes.refresh();
  palette.load();
  prompt.focus();
};

boot().catch((error) => {
  console.error("xmake ai:", error);
  document.body.classList.add("is-broken");
  chat.note("error", "the page could not start: " + (error && error.message || error));
});
