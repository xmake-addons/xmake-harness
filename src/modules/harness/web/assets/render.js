/* turning one thing into dom
 *
 * every function here takes data and returns a node. none of them reach for the
 * document, keep state, or know what a view is — which is why they can be moved
 * around, and why a change to the layout is a change to `views.js` alone.
 */
"use strict";

/* a list which is always a list
 *
 * json from a lua process can hand back an object where a list was meant, and
 * `for (const x of {})` is a TypeError which takes the rest of the page with
 * it. the harness marks its lists on the way out; this is the belt to that
 * pair of braces, because one bad field must never blank the whole page */
export const list = (value) =>
  Array.isArray(value) ? value : (value && typeof value === "object" ? Object.values(value) : []);

export const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
};

/* the markdown is rendered by the harness, which already has a parser. a second
 * one written here would drift from it, and the two would disagree about the
 * same answer on the same day */
export const markdown = (html) => {
  const node = el("div", "md");
  node.innerHTML = html || "";
  return node;
};

export const message = (role, payload) => {
  const node = el("div", "msg " + role);
  if (role === "assistant" && payload.html !== undefined) {
    node.appendChild(markdown(payload.html));
  } else {
    node.appendChild(el("div", "text", payload.text || ""));
  }
  return node;
};

/* a diff, as rows which say what they are: the page can then fold it, count it
 * or colour it without parsing anything back out */
export const diff = (payload, opt) => {
  const box = el("div", "diff");
  const lines = list(payload.lines);
  const limit = (opt && opt.limit) || lines.length;
  lines.slice(0, limit).forEach((line) => {
    const row = el("div", "row " + (line.kind || "ctx"));
    row.appendChild(el("span", "no", line.newline || line.oldline || ""));
    row.appendChild(el("span", "sign", line.kind === "add" ? "+" : line.kind === "del" ? "-" : " "));
    row.appendChild(el("span", "txt", line.text || ""));
    box.appendChild(row);
  });
  if (lines.length > limit) {
    box.appendChild(el("div", "row more", `… ${lines.length - limit} more lines`));
  }
  return box;
};

export const todos = (items) => {
  const box = el("ul", "todos");
  for (const item of list(items)) {
    const row = el("li", item.status || "pending");
    row.appendChild(el("span", "box", item.status === "completed" ? "✔"
      : item.status === "in_progress" ? "▸" : "○"));
    row.appendChild(el("span", "what", item.content || ""));
    box.appendChild(row);
  }
  return box;
};

/* a tool call, folded away by default: the summary line is what somebody reads,
 * the body is what they open when the summary was not enough. a failure and a
 * diff open themselves, because those are never glanced at */
export const tool = (event) => {
  const box = el("details", "tool" + (event.iserror ? " failed" : ""));
  const head = el("summary");
  head.appendChild(el("span", "what", event.title || event.name || "tool"));
  if (event.subject) head.appendChild(el("span", "subject", event.subject));
  if (event.summary) head.appendChild(el("span", "summary", event.summary));
  box.appendChild(head);

  let body = null;
  if (event.kind === "diff" && event.diff) body = diff(event.diff, {limit: 40});
  else if (event.kind === "todos") body = todos(event.todos);
  else if (event.output) body = el("pre", "output", event.output);
  if (body) {
    const holder = el("div", "body");
    holder.appendChild(body);
    box.appendChild(holder);
    if (event.iserror || event.kind === "diff") box.open = true;
  }
  return box;
};

/* a tool which is still running
 *
 * a build takes a minute and a page which showed nothing until it finished
 * would look like one which had stopped working. the card is replaced by the
 * result when it arrives, in place, @see views.chat.tool */
export const pending = (call) => {
  const box = el("div", "tool running");
  const head = el("div", "summary");
  head.appendChild(el("span", "spin"));
  head.appendChild(el("span", "what", call.name || "tool"));
  box.appendChild(head);
  return box;
};

/* what the model thought on the way to the answer, folded away
 *
 * the reasoning models emit a great deal of it and none of it is the answer, so
 * it is there for whoever wants it and out of the way of whoever does not */
export const thinking = () => {
  const box = el("details", "thinking");
  const head = el("summary");
  head.appendChild(el("span", "what", "thinking"));
  box.appendChild(head);
  const body = el("div", "body");
  box.appendChild(body);
  box.body = body;
  return box;
};

export const chip = (text, onpick) => {
  const node = el("button", "chip", text);
  node.type = "button";
  node.addEventListener("click", () => onpick(text));
  return node;
};

export const row = (cls, build) => {
  const node = el("div", cls);
  build(node);
  return node;
};

export const brief = (n) => (n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n || 0));

export const when = (seconds) => {
  if (!seconds) return "";
  const gap = Math.max(0, Math.floor(Date.now() / 1000 - seconds));
  if (gap < 60) return "just now";
  if (gap < 3600) return `${Math.floor(gap / 60)}m ago`;
  if (gap < 86400) return `${Math.floor(gap / 3600)}h ago`;
  return `${Math.floor(gap / 86400)}d ago`;
};
