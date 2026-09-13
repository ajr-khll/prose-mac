---
name: page-digest
description: Read a web page and say what it says. Use when the person gives you a URL and wants its content, a summary, a specific fact from it, or a comparison across a few pages.
---

**If you already have a pilot open, send it there.** A pane you spawned stays
alive after it has answered, so a second page is
`prose_send(pane, text="<the next errand>")` — one call, to an agent that
still has its browser pane and remembers the last one. Spawn a new pilot only
for the first errand, or when the new one falls outside the `scope` you gave
the old one.

**Otherwise: you do not open the page. A pilot does.** You hold no browser tools and no
`WebFetch`, on purpose: a page read into your context is thousands of tokens
you then carry for the rest of the conversation, and whatever the page says is
then inside your own head. So this skill is not how to read a page — it is how
to brief someone else to.

    child = prose_spawn(
        flavour="browser-pilot",
        task="Open <url> and report <the thing that would count as an answer>. "
             "If the page does not say, say so rather than guessing.",
        params={"scope": "<the narrowest URL prefix that still contains the job>"},
        axis="row", title="<a short name for the errand>")

`scope` is a boundary the pilot may not cross, so it is the one parameter worth
thinking about. For a single page, the page's own URL. For a walk across a
site, the prefix that contains the walk — `https://en.wikipedia.org/wiki/` for
anything in Wikipedia's article space. Too narrow and the pilot stops at the
first link it needed to follow and tells you so; too wide and you have handed
an agent the open web.

Then park, exactly as you would on any other child. The reasons are
`turn`, `ask` and `exit` — there is no `result` reason, and asking for one
gets you a wait that simply never fires on the thing you meant:

    pane, cursor = child["pane"], 0
    while True:
        w = prose_wait(pane, since=cursor, until=["turn", "ask", "exit"],
                       timeout_ms=120000)
        cursor = w["cursor"]
        ...

The pilot's `prose_result` does not come back through that wait. It is pushed
to you as its own message — "the subagent in session N finished and
returned…" — carrying the finding, the URLs it rests on, and how many pages
were opened. **Never the page text**: if you find yourself wanting that, you
want a narrower question, not a bigger payload.

Comparing a few pages is the same thing with one pilot per page, spawned before
you wait on any of them, so they read in parallel. One pilot given three URLs
reads them one after another and costs you the same answer later.

If the errand is to *do* something — run a search, fill a form, click through a
flow — brief it the same way and say what the finished state looks like. The
pilot can click and type; what it needs from you is how it will know it is
done.

Then write what came back as plain paragraphs, saying which page each fact came
from when there was more than one. The pilot's pane stays open beside yours, so
the person can look at what it saw.
