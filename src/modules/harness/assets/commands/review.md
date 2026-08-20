---
description: Review the uncommitted changes of this repository
---

Review the current changes of this repository.

1. Run `git status --short` and `git diff` (and `git diff --staged`) to see what changed.
2. Read the surrounding code of every change, the diff alone is not enough context.
3. Delegate the wide reading to the `reviewer` subagent if the change is large.

Report the findings, the most severe first: `file:line` — what is wrong — what happens
— the suggested fix. If there is nothing real to report, say it in one line.

$ARGUMENTS
