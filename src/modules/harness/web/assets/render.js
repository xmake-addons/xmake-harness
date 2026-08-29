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
  checkall: "M2 8.5 4.5 11 9 5.5 M8 11 10.5 13.5 15 7",
  chevron: "M6 3.5 10.5 8 6 12.5",
  folder: "M2 4.5h4l1.4 1.6H14v7.4H2z",
  file: "M4 2h5l3 3v9H4z M9 2v3h3"
};

/* a circle is a circle and not a path: `○` and `●` are the same story as `✓`,
   two more glyphs which change weight with the font and land as coloured emoji
   on the systems which have one */
const CIRCLES = {
  ring: {r: 4.5, fill: false},
  dot: {r: 3.2, fill: true}
};

const SVGNS = "http://www.w3.org/2000/svg";

export const icon = (name) => {
  const svg = document.createElementNS(SVGNS, "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("class", "icon icon-" + name);
  svg.setAttribute("aria-hidden", "true");

  const round = CIRCLES[name];
  if (round) {
    const circle = document.createElementNS(SVGNS, "circle");
    circle.setAttribute("cx", "8");
    circle.setAttribute("cy", "8");
    circle.setAttribute("r", String(round.r));
    circle.setAttribute("fill", round.fill ? "currentColor" : "none");
    circle.setAttribute("stroke", "currentColor");
    circle.setAttribute("stroke-width", round.fill ? "0" : "1.5");
    svg.appendChild(circle);
    return svg;
  }

  const path = document.createElementNS(SVGNS, "path");
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

/* the task on the left and its mark on the right
 *
 * a checklist is read for what is left to do, so what it says comes first and
 * the marks line up in a column of their own down the right edge. leading with
 * the marks pushes every task the same distance in from the margin and makes
 * the column of text start nowhere in particular */
export const todos = (items) => {
  const box = el("ul", "todos");
  for (const item of list(items)) {
    const row = el("li", item.status || "pending");
    row.appendChild(el("span", "what", item.content || ""));
    /* not `box`: that is the composer's class, and a span which borrowed it
       came with a rounded border, a shadow and `max-width: 820px` — which is
       what pushed the mark half a screen away from the task it belongs to */
    const mark = el("span", "mark");
    mark.appendChild(icon(item.status === "completed" ? "check"
      : item.status === "in_progress" ? "dot" : "ring"));
    row.appendChild(mark);
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

/* one row of the project tree
 *
 * a directory or a file, indented by where it is, and marked when this
 * conversation has changed it — so the tree is also the list of changes,
 * without being a second list to keep in step with the first
 */
export const treerow = (entry, depth, opt) => {
  const isdir = entry.kind === "dir";
  const row = el("button", "treerow"
    + (isdir ? " isdir" : " isfile")
    + (entry.changed ? " changed" : "")
    + (entry.undecided ? " undecided" : "")
    + (entry.kept ? " kept" : "")
    + (entry.reverted ? " reverted" : "")
    + ((opt && opt.open) ? " open" : "")
    + ((opt && opt.current) ? " is-current" : ""));
  row.type = "button";
  row.dataset.path = entry.path;
  row.dataset.depth = String(depth);
  row.style.paddingLeft = (8 + depth * 15) + "px";
  row.style.setProperty("--depth", String(depth));
  row.title = entry.path;

  /* the twist and the icon are drawn, not typed: a triangle from a font is a
   * different shape and a different weight in every one of them */
  const twist = el("span", "twist");
  if (isdir) twist.appendChild(icon("chevron"));
  row.appendChild(twist);

  const glyph = el("span", "glyph");
  glyph.appendChild(icon(isdir ? "folder" : "file"));
  row.appendChild(glyph);

  row.appendChild(el("span", "name", entry.name));

  /* what this conversation did to it, and what was decided about that: the
   * same fact the file's own header shows, so the two never disagree */
  if (entry.changed) {
    const marks = el("span", "tally");
    if (entry.kept) {
      const tick = el("span", "decided");
      tick.appendChild(icon("check"));
      tick.title = "kept";
      marks.appendChild(tick);
    } else if (entry.reverted) {
      marks.appendChild(el("span", "decided", "↩"));
    }
    if (entry.added) marks.appendChild(el("span", "add", "+" + entry.added));
    if (entry.removed) marks.appendChild(el("span", "del", "−" + entry.removed));
    if (!entry.added && !entry.removed && !entry.kept && !entry.reverted) {
      marks.appendChild(el("span", "add", "•"));
    }
    row.appendChild(marks);
  }
  return row;
};

/* a file, all of it, coloured, with what changed marked in the margin
 *
 * this is the middle of the workspace: a diff answers "what moved", a file
 * answers "what does it say now", and after deciding about a change the second
 * question is the one left standing. the marks are the diff, kept in the margin
 * where they inform without taking the file over.
 */
export const codeview = (source, opt) => {
  const box = el("div", "code source");

  /* a change which has been decided about is not a change any more
   *
   * once somebody has kept it, the question "what did it do to this file" is
   * answered and put away, and what is left is the file. so the colours go and
   * the code stays — which is what "show me the final code" means */
  const marks = (opt && opt.clean) ? {} : (source.marks || {});

  /* the marks arrive as lists — the line numbers which are new, and the lines
   * which were taken out with the text of them — because a table keyed by line
   * number is a sparse array to json, @see harness.web.source.marks */
  const added = new Set(list(marks.added));
  const removed = new Map(list(marks.removed).map((gap) => [gap.after, list(gap.lines)]));

  /* one row of code, however it got here */
  const row = (kind, number, tokens) => {
    const node = el("div", "row" + (kind ? " " + kind : ""));
    node.appendChild(el("span", "no", number || ""));
    node.appendChild(el("span", "sign", kind === "add" ? "+" : kind === "del" ? "−" : " "));
    const code = el("span", "txt");
    for (const token of list(tokens)) {
      code.appendChild(el("span", "t-" + (token.style || "text"), token.text || ""));
    }
    node.appendChild(code);
    return node;
  };

  /* the lines which are gone are shown where they were, in red, above the ones
   * which replaced them — as the terminal shows them, @see harness.ui.diff
   *
   * `opt.plain` leaves them out: that is the editing layer, and it must have
   * exactly one row per line of the file or the caret drifts away from the
   * letters, @see views.editor */
  const gap = (after) => {
    if (opt && opt.plain) return;
    for (const line of removed.get(after) || []) {
      box.appendChild(row("del", "", line.tokens));
    }
  };

  gap(0);
  for (const line of list(source.lines)) {
    box.appendChild(row(added.has(line.number) ? "add" : "", line.number, line.tokens));
    gap(line.number);
  }
  return box;
};

/* a suggestion on the empty page, which asks itself when clicked */
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
