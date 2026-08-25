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

/* the two icons this page needs, drawn rather than typed
 *
 * `✓` and `✗` are text: they are a different weight in every font, they sit off
 * the baseline, and on a system without the glyph they are a box. two paths of
 * svg are the same everywhere and take their colour from the button they are in
 */
const PATHS = {
  check: "M3.5 8.5 6.5 11.5 12.5 4.5",
  cross: "M4 4 12 12 M12 4 4 12",
  checkall: "M2 8.5 4.5 11 9 5.5 M8 11 10.5 13.5 15 7"
};

export const icon = (name) => {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("class", "icon icon-" + name);
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", PATHS[name] || PATHS.check);
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.8");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  svg.appendChild(path);
  return svg;
};

/* a button which is an icon and nothing else */
export const iconbutton = (name, cls, title, onclick) => {
  const button = el("button", cls);
  button.type = "button";
  button.title = title;
  button.setAttribute("aria-label", title);
  button.appendChild(icon(name));
  button.addEventListener("click", (event) => { event.stopPropagation(); onclick(event); });
  return button;
};

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

/* copy something, and say so on the button which did it
 *
 * `navigator.clipboard` needs a secure context, and `http://127.0.0.1` counts
 * as one in every browser which implements the rule — but not every browser
 * does, so there is the old way behind it */
export const copy = (text, button) => {
  const done = () => {
    const was = button.textContent;
    button.textContent = "copied";
    button.classList.add("done");
    setTimeout(() => { button.textContent = was; button.classList.remove("done"); }, 1200);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, () => fallback(text, done));
  } else {
    fallback(text, done);
  }
};

const fallback = (text, done) => {
  const area = el("textarea");
  area.value = text;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();
  try { document.execCommand("copy"); done(); } catch (_) { /* nothing else to try */ }
  area.remove();
};

const copybutton = (text, cls) => {
  const button = el("button", cls || "copy", "copy");
  button.type = "button";
  button.title = "copy";
  button.addEventListener("click", (event) => { event.preventDefault(); copy(text, button); });
  return button;
};

/* a message with something to do about it, e.g. an error which can be retried */
export const notice = (role, text, action) => {
  const node = el("div", "msg " + role);
  node.appendChild(el("div", "text", text || ""));
  if (action) {
    const button = el("button", "pill tiny", action.text);
    button.type = "button";
    button.addEventListener("click", () => action.run(button));
    node.appendChild(button);
  }
  return node;
};

export const message = (role, payload) => {
  const node = el("div", "msg " + role);
  if (role === "assistant" && payload.html !== undefined) {
    const body = markdown(payload.html);
    node.appendChild(body);
    node.appendChild(copybutton(payload.text || body.textContent, "copy msg-copy"));
    /* every code block gets its own, because copying one is what people
     * actually want from an answer which contains three */
    for (const block of body.querySelectorAll("pre")) {
      const holder = el("div", "codeblock");
      block.replaceWith(holder);
      holder.appendChild(block);
      holder.appendChild(copybutton(block.textContent, "copy code-copy"));
    }
  } else {
    node.appendChild(el("div", "text", payload.text || ""));
    /* asking almost the same thing again is the commonest next move after
     * reading an answer, so a message can be put back in the box to be edited
     * rather than typed out again */
    if (role === "user" && payload.reuse) {
      const again = el("button", "reuse", "edit");
      again.type = "button";
      again.title = "put this back in the box";
      again.addEventListener("click", () => payload.reuse(payload.text || ""));
      node.appendChild(again);
    }
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
  /* how long it has been going, ticking: a build which takes two minutes and
   * one which has hung look identical without it */
  const since = el("span", "since", "0s");
  since.dataset.since = String(Date.now());
  head.appendChild(since);
  box.appendChild(head);
  return box;
};

/* one timer for every running card, rather than one each */
export const ticking = (root) => {
  const tick = () => {
    for (const node of root.querySelectorAll(".tool.running .since")) {
      const started = Number(node.dataset.since) || Date.now();
      const seconds = Math.max(0, Math.round((Date.now() - started) / 1000));
      node.textContent = seconds < 60 ? `${seconds}s`
        : `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`;
    }
  };
  setInterval(tick, 1000);
  return tick;
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

/* how much a diff changes, as the two numbers everybody reads first */
export const counts = (payload) => {
  let added = 0, removed = 0;
  for (const line of list(payload && payload.lines)) {
    if (line.kind === "add") added++;
    else if (line.kind === "del") removed++;
  }
  return {added, removed};
};

/* the +12 −3 pair, as one node */
export const tally = (payload) => {
  const {added, removed} = counts(payload);
  const box = el("span", "tally");
  if (added) box.appendChild(el("span", "add", "+" + added));
  if (removed) box.appendChild(el("span", "del", "−" + removed));
  return box;
};

/* one file, folded, with its diff inside
 *
 * this is the card the conversation shows for an edit and the row the summary
 * shows at the end of a turn — the same thing in both places, because they are
 * the same thing */
export const filecard = (change, opt) => {
  const box = el("details", "filecard" + (change.iserror ? " failed" : ""));
  const head = el("summary");
  head.appendChild(el("span", "glyph", change.created ? "✦" : "✎"));
  head.appendChild(el("span", "name", change.name || change.filepath || "?"));
  head.appendChild(el("span", "path", change.dir || ""));
  head.appendChild(tally(change.diff));
  box.appendChild(head);
  const body = el("div", "body");
  body.appendChild(diff(change.diff, {limit: (opt && opt.limit) || 400}));
  box.appendChild(body);
  if (opt && opt.open) box.open = true;
  return box;
};

/* what a turn changed, all of it, at the end of it
 *
 * cursor and copilot both end a turn with the list of files rather than making
 * you scroll back through the conversation for them, and they are right: the
 * question after "done" is always "what did it touch" */
export const summary = (changes, onopen) => {
  const box = el("div", "changeset");
  const head = el("div", "changeset-head");
  head.appendChild(el("span", "what", changes.length === 1 ? "1 file changed"
    : `${changes.length} files changed`));
  const total = {added: 0, removed: 0};
  for (const change of changes) {
    const one = counts(change.diff);
    total.added += one.added;
    total.removed += one.removed;
  }
  const tallies = el("span", "tally");
  if (total.added) tallies.appendChild(el("span", "add", "+" + total.added));
  if (total.removed) tallies.appendChild(el("span", "del", "−" + total.removed));
  head.appendChild(tallies);
  box.appendChild(head);

  /* a row and not a folded diff: the diff, and the decision to keep it or put
   * it back, live in the changes view, and one of them is enough */
  for (const change of changes) {
    const row = el("button", "changeset-row");
    row.type = "button";
    row.appendChild(el("span", "glyph", change.created ? "✦" : "✎"));
    row.appendChild(el("span", "name", change.name || change.filepath));
    if (change.dir) row.appendChild(el("span", "path", change.dir));
    row.appendChild(tally(change.diff));
    row.addEventListener("click", () => onopen && onopen(change));
    box.appendChild(row);
  }
  return box;
};

/* a confirmation, in the conversation and not over it
 *
 * a modal sheet stops everything to ask about one command, which is the wrong
 * weight for a question the answer to which is usually "yes". it belongs where
 * the rest of the turn is, in order, so the flow reads as one thing.
 */
export const permission = (payload, onanswer) => {
  const box = el("div", "permission");
  const head = el("div", "permission-head");
  head.appendChild(el("span", "glyph", "!"));
  head.appendChild(el("span", "what", payload.question || "Do you want to continue?"));
  box.appendChild(head);

  if (payload.title) box.appendChild(el("pre", "permission-subject", payload.title));
  if (payload.subtitle) box.appendChild(el("p", "permission-note", payload.subtitle));
  if (payload.diff) {
    const holder = el("div", "permission-diff");
    holder.appendChild(diff(payload.diff, {limit: 60}));
    box.appendChild(holder);
  }
  if (payload.reason) box.appendChild(el("p", "permission-note", payload.reason));

  const choices = el("div", "permission-choices");
  list(payload.options).forEach((option, index) => {
    const button = el("button", index === 0 ? "primary" : "ghost", option.text);
    button.type = "button";
    button.addEventListener("click", () => onanswer(option.value, option.text));
    choices.appendChild(button);
  });
  box.appendChild(choices);

  /* once answered the card stays where it is and says what was answered: a
   * decision which vanished is a decision nobody can check afterwards */
  box.settle = (text) => {
    choices.textContent = "";
    box.classList.add("answered");
    choices.appendChild(el("span", "answered-note", text));
  };
  return box;
};

/* a diff which git produced, line by line, with the code coloured
 *
 * the tokens come from the harness's own highlighter — the one the terminal
 * uses — so a lua file looks like a lua file here and there, and there is no
 * grammar engine in the page to keep in step with it */
/* how many rows go in before the page stops and asks
 *
 * a generated file of four thousand lines is a diff nobody reads and a page
 * which takes a second to lay out. the first screenful arrives at once and the
 * rest is one click away */
const DIFFROWS = 600;

export const codediff = (payload, opt) => {
  const box = el("div", "code");
  const rows = list(payload.lines);
  const limit = (opt && opt.limit) || DIFFROWS;
  const shown = rows.length > limit ? rows.slice(0, limit) : rows;

  for (const line of shown) {
    if (line.kind === "hunk") {
      box.appendChild(el("div", "row hunk", line.text || ""));
      continue;
    }
    const row = el("div", "row " + (line.kind || "ctx"));
    row.appendChild(el("span", "no old", line.oldline || ""));
    row.appendChild(el("span", "no new", line.newline || ""));
    row.appendChild(el("span", "sign", line.kind === "add" ? "+" : line.kind === "del" ? "-" : " "));
    const code = el("span", "txt");
    for (const token of list(line.tokens)) {
      code.appendChild(el("span", "t-" + (token.style || "text"), token.text || ""));
    }
    row.appendChild(code);
    box.appendChild(row);
  }

  if (rows.length > shown.length) {
    const more = el("button", "diff-more",
      `${rows.length - shown.length} more lines — show them`);
    more.type = "button";
    more.addEventListener("click", () => {
      more.replaceWith(codediff({...payload, lines: rows.slice(shown.length)},
        {limit: rows.length}));
    });
    box.appendChild(more);
  }
  return box;
};

/* the same diff, side by side
 *
 * a unified diff reads as a story: this line went, this line came. a split one
 * reads as a comparison: this is what it said, this is what it says. both are
 * worth having and neither is a rewrite of the other — the rows are the same
 * rows, paired here instead of stacked.
 */
export const splitdiff = (payload, opt) => {
  const box = el("div", "code split");
  const rows = list(payload.lines);
  const limit = (opt && opt.limit) || 600;

  const cell = (line, side) => {
    const node = el("div", "side " + side + (line ? " " + line.kind : " blank"));
    if (!line) return node;
    node.appendChild(el("span", "no", (side === "old" ? line.oldline : line.newline) || ""));
    const code = el("span", "txt");
    for (const token of list(line.tokens)) {
      code.appendChild(el("span", "t-" + (token.style || "text"), token.text || ""));
    }
    node.appendChild(code);
    return node;
  };

  const pair = (left, right) => {
    const row = el("div", "srow");
    row.appendChild(cell(left, "old"));
    row.appendChild(cell(right, "new"));
    box.appendChild(row);
  };

  let drawn = 0;
  let index = 0;
  while (index < rows.length && drawn < limit) {
    const line = rows[index];
    if (line.kind === "hunk") {
      box.appendChild(el("div", "srow hunk", line.text || ""));
      index++;
      drawn++;
      continue;
    }
    if (line.kind === "ctx") {
      pair(line, line);
      index++;
      drawn++;
      continue;
    }

    /* a run of removals and the run of additions which follows it are one
     * change seen from two sides, so they are lined up rather than listed */
    const dels = [];
    const adds = [];
    while (index < rows.length && rows[index].kind === "del") dels.push(rows[index++]);
    while (index < rows.length && rows[index].kind === "add") adds.push(rows[index++]);
    for (let at = 0; at < Math.max(dels.length, adds.length); at++) {
      pair(dels[at] || null, adds[at] || null);
      drawn++;
    }
  }

  if (index < rows.length) {
    const more = el("button", "diff-more", `${rows.length - index} more lines — show them`);
    more.type = "button";
    more.addEventListener("click", () => {
      more.replaceWith(splitdiff({...payload, lines: rows.slice(index)}, {limit: rows.length}));
    });
    box.appendChild(more);
  }
  return box;
};

/* one row of the change list
 *
 * what changed, where, by how much, and the two things there are to do about
 * it: keep it, or put it back. a tick and a cross rather than a menu, because
 * there are exactly two answers and both of them are one click
 */
export const changerow = (file, on) => {
  const row = el("div", "gitrow"
    + (file.kept ? " is-kept" : "") + (file.reverted ? " is-reverted" : "")
    + (file.created ? " status-added" : file.gone ? " status-deleted" : ""));
  row.dataset.path = file.path;

  const open = el("button", "gitrow-open");
  open.type = "button";
  open.appendChild(el("span", "mark", file.created ? "A" : file.gone ? "D" : "M"));
  const names = el("span", "names");
  names.appendChild(el("span", "name", file.name || file.path));
  if (file.dir) names.appendChild(el("span", "dir", file.dir));
  open.appendChild(names);
  if (file.reverted) {
    open.appendChild(el("span", "state", "put back"));
  } else if (file.kept) {
    const marks = el("span", "tally");
    if (file.added) marks.appendChild(el("span", "add", "+" + file.added));
    if (file.removed) marks.appendChild(el("span", "del", "−" + file.removed));
    open.appendChild(marks);
    open.appendChild(el("span", "state", "kept"));
  } else if (file.nodiff) {
    /* a command wrote it and nobody knew which files it was about to write,
     * so there is no before to compare against — saying so beats a blank */
    open.appendChild(el("span", "state", file.gone ? "removed" : "by a command"));
  } else {
    const marks = el("span", "tally");
    if (file.added) marks.appendChild(el("span", "add", "+" + file.added));
    if (file.removed) marks.appendChild(el("span", "del", "−" + file.removed));
    open.appendChild(marks);
  }
  open.addEventListener("click", () => on.pick(file));
  row.appendChild(open);

  /* a change which was put back has nothing left to decide, so it keeps its
   * row — that is the receipt — and loses its buttons */
  if (!file.reverted && !file.nodiff) {
    const actions = el("span", "gitrow-actions");
    actions.appendChild(iconbutton("check", "act keep" + (file.kept ? " is-on" : ""),
      file.kept ? "kept — click to undecide" : "keep this change",
      () => on.keep(file, !file.kept)));
    actions.appendChild(iconbutton("cross", "act revert",
      file.created ? "delete this file again" : "put this file back the way it was",
      () => on.revert(file)));
    row.appendChild(actions);
  }
  return row;
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
