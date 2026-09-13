# Memory feature planning handoff

You are a planning subagent working on the Prose pane agent. Produce a concrete implementation plan for adding durable memory to the personal agent.

Read these sources before writing:

- `CLAUDE.md`
- `reference/agent-guide.md`
- `reference/agent-plan.md`
- `reference/product-spec.md`
- `agents/prose_agent/loop.py`
- `agents/prose_agent/prompt.py`
- `agents/prose_agent/tools.py`
- `agents/prose_agent/archetypes.py`
- `agents/prose_agent/skills.py`
- the tests that cover those modules

Write the completed handoff to `reference/memory-feature-plan.md`. Use Markdown prose, tables, and pseudocode where they make the design clearer. Do not return a JSON plan and do not modify any other file.

The plan must cover:

1. User-facing memory behaviors: what gets remembered, explicit remember/forget flows, review/correction, and what must never be silently retained.
2. A storage design appropriate for this local macOS app, including schemas, provenance, timestamps, deletion, compaction, and migrations.
3. Retrieval and prompt-injection points that preserve the existing token discipline.
4. The boundary between short structured parent/child results and longer `.md` handoffs, including how parents discover, validate, summarize, and clean up child handoff files.
5. Privacy, secrets, untrusted content, prompt-injection resistance, and per-workspace/global scoping.
6. Concrete module/file changes and tests, phased rollout, observability, failure modes, and acceptance criteria.
7. How memory interacts with the planned Slack, Google Workspace, GitHub, Linear, and Notion integrations without turning imported third-party content into trusted instructions.

Prefer a small, auditable first version. Clearly label decisions, alternatives, and open questions. This is a plan only; do not implement the feature.
