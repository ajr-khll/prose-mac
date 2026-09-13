# prose's bundled skills

A skill is a directory with a `SKILL.md` in it. This directory is a **plugin**,
loaded by path, so everything under `skills/` is namespaced `prose:` — which is
what stops a skill here ever colliding with one of yours.

There are four places a skill can live, and they do not compete:

| | Where | Namespaced | On by default |
|---|---|---|---|
| prose's own | `agents/skills/skills/<name>/SKILL.md` — here | `prose:<name>` | yes |
| this workspace's | `<cwd>/.claude/skills/<name>/SKILL.md` | no | yes |
| another plugin | any directory named in `$PROSE_PLUGINS`, colon-separated | by its own name | yes |
| yours, everywhere | `~/.claude/skills/<name>/SKILL.md` | no | **no** |

The per-workspace directory is the same one your terminal Claude Code reads, so
a skill a project already has works in a pane with nothing to configure.

Your *personal* skills are deliberately left out. A working machine has dozens
of them — 85, when this was measured — mostly written for a coding terminal,
and every one costs its description in context on every turn of every pane. To
use one here, put it in `skills/` beside these, or point `$PROSE_PLUGINS` at the
directory holding it. To have all of them, add `"user"` back to
`setting_sources` in `agents/pane_agent.py`; it is one word.

## Adding one

Make `skills/<name>/SKILL.md`:

```markdown
---
name: <name>
description: <when to reach for this — see below>
---

<the instructions, as plain prose>
```

Then reopen the pane. The pane header's `skills` count comes from what actually
loaded, and the names go to stderr — `PROSE_LOG_DIR` captures them. If your
skill is not in that count, it did not load.

## The `description` is the whole thing

It is the only part the model reads before deciding whether to use the skill,
and it is read against a request, not against your file. So write it about
**when to reach for this**, in the words someone would actually use, and say
what it is *not* for when a near-miss is likely. `page-digest`'s description
names URLs, summaries and comparisons, and rules out questions about code you
can already see; that last clause is doing as much work as the rest.

Anything under about a thousand characters is fine. Vague descriptions are the
single reason a working skill never fires.

## Two things worth knowing

**Anyone can invoke one directly.** Typing `/prose:page-digest https://…` into a
pane's composer runs it. prose sends whatever you type as an ordinary message
and the SDK dispatches the slash itself, so this works without prose knowing
skills exist.

**A skill can pre-approve its own tools.** Add `allowed-tools` to the
frontmatter and those calls skip the permission card while the skill is
running. Use it sparingly — a card is how the person stays in the loop.
