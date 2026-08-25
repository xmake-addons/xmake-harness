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
  const show = (name) => {
    document.querySelectorAll(".view").forEach((view) =>
      view.classList.toggle("is-active", view.dataset.view === name));
    document.querySelectorAll(".rail-item").forEach((item) =>
      item.classList.toggle("is-active", item.dataset.view === name));
    if (name === "changes") changes.draw();
    if (name === "sessions") sessions.draw(app.sessionid);
    if (name === "settings") settings.draw(theme);
  };
  document.querySelectorAll(".rail-item").forEach((item) =>
    item.addEventListener("click", () => show(item.dataset.view)));
  return {show};
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
        chat.user(payload.prompt, payload.command);
        this.busy(true);
        this.say(payload.command ? `${payload.prompt}…` : "thinking…");
        break;
      case "step":
        byId("model").textContent = payload.model || "";
        this.say(payload.step > 1 ? `thinking… (step ${payload.step})` : "thinking…");
        break;
      case "text":        this.say("writing…"); chat.stream(payload.delta || ""); break;
      case "reasoning":   this.say("reasoning…"); chat.think(payload.delta || ""); break;
      case "tool.start":
        chat.settle();
        this.say(`${payload.name || "working"}…`);
        chat.started(payload);
        break;
      case "assistant":   chat.settle(payload); break;
      case "tool.result":
        chat.settle();
        chat.tool(payload);
        if (payload.kind === "diff") changes.refresh();
        if (payload.kind === "todos") plan.show(payload.todos);
        break;
      case "notice":      chat.settle(); chat.note("notice", payload.text || ""); break;
      case "error":       chat.settle(); chat.note("error", payload.text || ""); break;
      case "usage":       this.counts(payload.total); break;
      case "context":     this.meter(payload); break;
      case "mode":        byId("mode").textContent = payload.mode || ""; break;
      case "ask":
        chat.settle();
        this.say("waiting for you…");
        chat.ask(payload, (value) => api.answer(payload.id, value));
        break;
      case "ask.done":    chat.asked(payload.id); break;
      case "turn.end":
        chat.settle();
        chat.changeset();
        changes.refresh();
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
    chat.draw(state);
    plan.show(state.todos);
    byId("cwd").textContent = state.cwd || "";
    byId("mode").textContent = state.mode || "";
    this.meter(state.context);
    this.counts(state.usage);
    this.busy(!!state.working);

    /* the tab says which project it is: two of these open at once is the
     * normal way to use it, and "xmake ai" twice tells you nothing */
    document.title = state.project ? `${state.project} · xmake ai` : "xmake ai";
  },

  async submit() {
    const prompt = byId("prompt");
    const text = prompt.value.trim();
    if (!text || this.working) return;
    prompt.value = "";
    prompt.style.height = "";
    palette.hide();
    const answer = await api.send(text);
    if (answer && answer.errors) chat.note("error", answer.errors);
  }
};

/* ------------------------------------------------------------------ boot */

const boot = async () => {
  const prompt = byId("prompt");

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
  byId("newsession").addEventListener("click", async () => {
    await api.fresh();
    stage.show("chat");
  });

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
  });
  prompt.addEventListener("blur", () => palette.hide());

  /* escape stops the turn, as it does in the terminal — the same key for the
   * same thing, so there is one thing to remember and not two */
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && app.working) { event.preventDefault(); api.abort(); }
  });
  prompt.addEventListener("input", () => {
    prompt.style.height = "";
    prompt.style.height = Math.min(prompt.scrollHeight, window.innerHeight * 0.4) + "px";
    palette.update(prompt.value, prompt.selectionStart, complete);
  });

  byId("gitrefresh").addEventListener("click", () => changes.draw());
  byId("reload").addEventListener("click", () => window.location.reload());

  chat.suggest((text) => { prompt.value = text; prompt.focus(); app.submit(); });

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
  changes.refresh();
  palette.load();
  prompt.focus();
};

boot().catch((error) => {
  console.error("xmake ai:", error);
  document.body.classList.add("is-broken");
  chat.note("error", "the page could not start: " + (error && error.message || error));
});
