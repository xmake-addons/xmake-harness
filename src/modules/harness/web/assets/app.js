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
import {el, brief, list, diff} from "./render.js";
import {chat, changes, sessions, settings} from "./views.js";

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
    byId("working").classList.toggle("hidden", !state);
    byId("stop").classList.toggle("hidden", !state);
    byId("send").classList.toggle("hidden", state);
    byId("dot").className = "dot " + (state ? "busy" : "live");
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
      case "ready":       byId("dot").className = "dot live"; break;
      case "offline":     byId("dot").className = "dot lost"; break;
      case "turn.start":  chat.user(payload.prompt); this.busy(true); break;
      case "step":        byId("model").textContent = payload.model || ""; break;
      case "text":        chat.stream(payload.delta || ""); break;
      case "reasoning":   chat.think(payload.delta || ""); break;
      case "tool.start":  chat.settle(); chat.started(payload); break;
      case "assistant":   chat.settle(payload); break;
      case "tool.result": chat.settle(); chat.tool(payload); changes.record(payload); break;
      case "notice":      chat.settle(); chat.note("notice", payload.text || ""); break;
      case "error":       chat.settle(); chat.note("error", payload.text || ""); break;
      case "usage":       this.counts(payload.total); break;
      case "ask":         chat.settle(); ask.open(payload); break;
      case "ask.done":    ask.done(payload.id); break;
      case "turn.end":    chat.settle(); this.busy(false); this.counts(payload.usage); break;
      /* the conversation was swapped, here or in another tab: the page asks for
       * the state again rather than being sent it, so every tab redraws from
       * the one history the harness keeps */
      case "session":     changes.reset(); api.state().then((state) => this.draw(state)); break;
    }
  },

  draw(state) {
    this.sessionid = state.id;
    chat.draw(state);
    byId("cwd").textContent = state.cwd || "";
    byId("mode").textContent = state.mode || "";
    this.counts(state.usage);
    this.busy(!!state.working);
  },

  async submit() {
    const prompt = byId("prompt");
    const text = prompt.value.trim();
    if (!text || this.working) return;
    prompt.value = "";
    prompt.style.height = "";
    const answer = await api.send(text);
    if (answer && answer.errors) chat.note("error", answer.errors);
  }
};

/* ------------------------------------------------------------------- ask
 *
 * the agent stops and waits for an answer. the page is the only thing which can
 * give one, so the sheet is modal on purpose: an approval clicked by accident
 * because it was a small button in a corner is worse than a moment of
 * interruption.
 */
const ask = (() => {
  const modal = byId("modal");
  const sheet = byId("sheet");
  let showing = null;

  const close = () => { showing = null; modal.classList.add("hidden"); };

  return {
    open(payload) {
      showing = payload.id;
      sheet.textContent = "";
      sheet.appendChild(el("h3", null, payload.question || "Do you want to continue?"));
      if (payload.title) sheet.appendChild(el("pre", "ask-subject", payload.title));
      if (payload.subtitle) sheet.appendChild(el("p", "ask-reason", payload.subtitle));
      if (payload.diff) sheet.appendChild(diff(payload.diff, {limit: 60}));
      if (payload.reason) sheet.appendChild(el("p", "ask-reason", payload.reason));

      const choices = el("div", "ask-choices");
      list(payload.options).forEach((option, index) => {
        const button = el("button", index === 0 ? "primary" : "ghost", option.text);
        button.type = "button";
        button.addEventListener("click", async () => {
          close();
          await api.answer(payload.id, option.value);
        });
        choices.appendChild(button);
      });
      sheet.appendChild(choices);
      modal.classList.remove("hidden");
    },

    /* somebody else answered it — another tab, or a stop button. the sheet goes
     * without an answer being sent, because the answer has already been given */
    done(id) {
      if (showing === null || showing === id) close();
    }
  };
})();

/* ------------------------------------------------------------------ boot */

const boot = async () => {
  const prompt = byId("prompt");

  byId("send").addEventListener("click", () => app.submit());
  byId("stop").addEventListener("click", () => api.abort());
  byId("newsession").addEventListener("click", async () => {
    await api.fresh();
    stage.show("chat");
  });

  prompt.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); app.submit(); }
  });

  /* escape stops the turn, as it does in the terminal — the same key for the
   * same thing, so there is one thing to remember and not two */
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && app.working) { event.preventDefault(); api.abort(); }
  });
  prompt.addEventListener("input", () => {
    prompt.style.height = "";
    prompt.style.height = Math.min(prompt.scrollHeight, window.innerHeight * 0.4) + "px";
  });

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
  prompt.focus();
};

boot().catch((error) => {
  console.error("xmake ai:", error);
  document.body.classList.add("is-broken");
  chat.note("error", "the page could not start: " + (error && error.message || error));
});
