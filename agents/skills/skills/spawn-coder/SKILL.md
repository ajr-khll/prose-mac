---
name: spawn-coder
description: Work on a codebase by opening a coding agent in its own pane and supervising it. Use when the person asks for code to be written, read, debugged, reviewed or changed in a repository, or asks you to "work on" a project directory. Not for answering a question about code you can already see.
---

You are a personal agent, not a coding agent. When the work is a repository,
open a pane that *is* one and supervise it, rather than doing it yourself with
your own file tools. The person gets a pane they can watch and interrupt, and
you keep your own context for the conversation.

Start it with the `code` flavour, and give it the directory:

    child = prose_spawn(task="<the whole task, in full>",
                        flavour="code",
                        cwd="<absolute path to the repository>",
                        axis="row",
                        title="<two or three words>")

Two things to get right when you write the task. Put the *whole* brief in it —
the child starts with no memory of your conversation, so anything you leave out
is gone. And say what "done" looks like, because the child decides for itself
when it has finished.

Then supervise it with the ordinary loop, threading the cursor:

    pane, cursor = child["pane"], 0
    while True:
        w = prose_wait(pane, since=cursor, until=["turn", "ask", "exit"],
                       timeout_ms=180000)
        cursor = w["cursor"]
        ...

Three things will happen and each has one right response. If it woke on `ask`,
the child is stopped on a question: answer it with `prose_answer` when you know
the answer, because you wrote the task and it did not. A question whose prompt
begins with a tool name and the words "wants to" is a permission request — it
commits you to a side effect you cannot see, so answer that one only when you
asked for exactly that thing, and `prose_answer(pane, escalate=True)` otherwise.
If it woke on `turn`, read what it said: the summary blocks carry `n`, and a
long final message is worth `prose_read(pane, block=i)`. If it woke on `exit`,
the process is gone; read the notice in its pane for why.

Timeouts are not failures. A build or a test run can outlast one, so wait again
with the same cursor rather than prodding it. Prod it with `prose_send` only
when it has genuinely stopped without finishing.

When it is done, tell the person what changed in your own words. Do not paste
the child's transcript back at them — they can see the pane.
