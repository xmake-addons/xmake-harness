/* talking to the harness
 *
 * the only module which knows there is a server. everything else asks it for
 * things and is handed plain objects, which is what makes the rest of the page
 * testable by opening it and what keeps the token in one place.
 */
"use strict";

const token = window.HARNESS_TOKEN || "";

/* the token rides on every call to /api. the files the page is made of do not
 * need it — they are the same for everybody and carry nothing */
const url = (path) => path + (path.includes("?") ? "&" : "?") + "token=" + encodeURIComponent(token);

const get = async (path) => (await fetch(url(path))).json();

const post = async (path, body) => {
  const answer = await fetch(url(path), {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify(body || {})
  });
  return answer.json();
};

/* every event the harness can push, named once so a typo is a missing feature
 * rather than a silence nobody notices */
const EVENTS = ["ready", "ping", "step", "text", "reasoning", "assistant",
                "tool.start", "tool.result", "usage", "notice", "error",
                "context", "turn.start", "turn.end", "ask", "ask.done", "session",
                "mode", "changed", "close"];

export const api = {
  state: () => get("/api/state"),
  sessions: () => get("/api/sessions"),
  settings: () => get("/api/settings"),
  commands: () => get("/api/commands"),
  files: (q) => get("/api/files?q=" + encodeURIComponent(q || "")),
  forget: (id) => post("/api/session/remove", {id}),
  send: (prompt) => post("/api/send", {prompt}),
  abort: () => post("/api/abort"),
  answer: (id, value) => post("/api/answer", {id, value}),
  resume: (id) => post("/api/session", {id}),
  fresh: () => post("/api/session", {fresh: true}),
  chdir: (dir) => post("/api/chdir", {dir}),
  mode: (mode) => post("/api/mode", {mode}),
  changes: () => get("/api/changes"),
  filediff: (path) => get("/api/changes/diff?path=" + encodeURIComponent(path)),
  revert: (path) => post("/api/changes/revert", {path}),
  keep: (path, kept) => post("/api/changes/keep", {path, kept}),
  decideall: (what) => post("/api/changes/all", {what}),
  save: (key, value) => post("/api/settings", {key, value}),

  /* EventSource reconnects by itself. nothing is replayed onto it: a page which
   * comes back asks for the state again, so there is one history and not a
   * second one kept for reconnections */
  events(on) {
    const source = new EventSource(url("/api/events"));
    for (const name of EVENTS) {
      source.addEventListener(name, (event) => {
        let payload = {};
        try { payload = JSON.parse(event.data || "{}"); } catch (_) {}
        on(name, payload);
      });
    }
    source.onerror = () => on("offline", {});
    return source;
  }
};
