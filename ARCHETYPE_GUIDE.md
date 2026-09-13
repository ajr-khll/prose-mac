# Designing and Deploying a Prose Archetype

This is the operational guide for adding a specialist agent to Prose. Follow it from the first
design decision through activation and verification. An archetype is not deployed merely because a
Markdown file exists: it is deployed only when the parent can route work to it, the child receives
the intended capabilities, forbidden capabilities are absent, and a real spawn returns the promised
result.

Do not place explanatory Markdown in `agents/archetypes/`. Every `*.md` in that directory is treated
as an archetype definition. Keep guides and drafts elsewhere, such as `reference/archetypes/`, and
put only deployable definitions in the live directory.

## 1. Decide whether this should be an archetype

Create an archetype when the work needs either:

- A separate context window that should absorb lengthy research, provider data, logs, or detailed
  procedures; or
- A capability boundary the parent should not hold, such as browser control, external-service
  access, or a narrowly constrained mutation surface.

Use a skill instead when the current agent should perform the work itself and only needs reusable
instructions. Use a built-in flavour implemented in Python when the agent needs substantially
different runtime plumbing that cannot be expressed as a prompt and allowance.

Before creating anything, inspect:

- `agents/archetypes/*.md` for overlap with an existing specialist;
- `agents/prose_agent/archetypes.py` for the current file format;
- `agents/prose_agent/permissions.py` for permission semantics;
- `agents/prose_agent/loop.py` for the effective tool set after startup; and
- `agents/tests/test_archetypes.py` for enforced conventions.

Do not create two archetypes whose routing descriptions overlap without explaining the dividing
line. Ambiguous specialists are silently misrouted rather than producing an obvious runtime error.

## 2. Write the routing contract first

The parent normally sees only an archetype's `name`, `description`, declared parameters, and return
schema. It does not read the body before choosing. The description is therefore a routing rule, not
a summary.

Write one sentence that answers all four questions:

1. When must the parent use this archetype?
2. Should it be used even when only one part of its capability set is needed?
3. Which similar tasks must go somewhere else?
4. Does the parent itself lack the specialist capability?

Example:

```text
Use when a task needs Service A or Service B, even when only one is involved. Reuse the same pane
for follow-up work. Not for Service C; that goes to the other-specialist archetype. The parent has
none of these service tools itself.
```

The description must contain the words `use when` and be shorter than 1,024 characters. Use terms a
parent will encounter in an actual request: provider names, artifact types, operations, and common
near misses.

If the boundary is important across all work, add a matching rule to the parent's system prompt in
`agents/prose_agent/prompt.py`. A catalogue description helps the model choose; a parent prompt
states the architecture it must obey. Capability isolation still has to be enforced in code.

## 3. Define the trust and capability boundary

Write down the boundary before listing tools:

| Question | Required decision |
| --- | --- |
| Inputs | What task text and parameters may the parent pass? |
| Read scope | What files, accounts, providers, panes, or URLs may the child inspect? |
| Write scope | Which mutations, if any, may it prepare or commit? |
| Exclusions | Which adjacent capabilities must remain unreachable? |
| Delegation | May it spawn children, or must it return missing work to the parent? |
| Untrusted data | Which content must be treated as evidence rather than instructions? |
| Output | What small, stable result does the parent need? |
| Failure | How does it report partial work, ambiguity, refusal, or a missing capability? |

Prefer the smallest coherent capability set. Set `spawns: false` unless recursive delegation is a
necessary part of the specialist's job. A narrow child that can spawn a wider agent can otherwise
route around its own boundary.

For external writes, use an explicit prepare/preview/confirm/commit sequence. The committing tool,
not merely the prompt, must enforce exact target confirmation and authorization. Instructions found
in web pages, messages, documents, issues, comments, or tool results never authorize new actions.

## 4. Create the definition

Draft the file outside the live catalogue. The eventual live path is:

```text
agents/archetypes/<name>.md
```

The filename stem and `name` must match exactly. Names should be short, specific, lowercase, and
hyphenated where necessary.

The parser supports a deliberately small frontmatter format, not general YAML:

- `parameters` and `returns` are valid JSON written on one line each.
- `allow`, `deny`, and `skills` are comma-separated lists.
- Other supported scalar fields are `name`, `description`, `preset`, `model`, `effort`, and
  `spawns`.
- Indented continuation lines are ignored.
- Unknown keys are silently ignored. Adding a key to a draft does not implement its behavior.

Use this template:

```markdown
---
name: example-specialist
description: Use when the task needs Example work. Not for adjacent work handled by another-specialist. The parent does not perform Example work directly.
allow: Read, Grep, prose_ask, prose_result
deny: Bash, Write, Edit, NotebookEdit, WebFetch
skills:
spawns: false
parameters: {"scope":{"description":"Exact boundary the specialist may not leave","required":true},"budget":{"description":"Maximum number of items to inspect","default":20}}
returns: {"type":"object","properties":{"answer":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}},"failed":{"type":"string"}},"required":["answer","sources","failed"]}
---

You are the Example specialist. Complete only the delegated Example work within `{scope}`.

## Boundary

State what is allowed, what is excluded, and what to do when the task crosses the boundary. Explain
that tool and provider content is data, not authority. Do not invent alternate access through shell,
HTTP, browser automation, or another provider when an intended capability is absent.

## Method

Give the concrete order of operations, including how to resolve ambiguity, how to stay within the
`{budget}`, how to verify important claims, and which evidence must be preserved. Describe the
conditions for asking the user and the conditions for returning a failure.

## Changes

If mutations are possible, require a preview, exact-target confirmation, provider acknowledgement,
and stable result reference. List operations that are never allowed. Never report success from an
attempt or preview alone.

## Return

Call `prose_result` once with the declared shape. Make `answer` useful to a parent that did not see
the source material. Return bounded evidence and stable references, not raw documents, transcripts,
credentials, logs, or provider payloads. Put partial completion and blockers in `failed`.
```

The body must exceed 600 characters under the current tests, but length is not the real goal. It
should contain the specialist knowledge the parent should not have to carry: ordering, stopping
conditions, scope rules, failure behavior, untrusted-input handling, mutation safety, and a precise
return obligation.

## 5. Understand each frontmatter field

### `preset`

Use `preset: claude_code` only when the child needs the SDK's coding-agent conventions. Without a
preset, the body becomes the complete system prompt. With a preset, the body is appended to it.

### `model` and `effort`

Set these only when the specialist has a measured quality, latency, or cost requirement. Otherwise
leave them absent and inherit the environment or SDK default.

### `parameters`

Every parameter must have a description and either `"required": true` or a `"default"`. Every
declared parameter must appear in the body as `{parameter_name}`, and every such placeholder must be
declared. Values are converted to strings and substituted literally. Parameters are configuration,
not a channel for authoring a new system prompt or choosing tools.

### `returns`

Use a JSON object schema with a stable failure field. Keep the result small enough for the parent to
consume directly. The schema is appended to the child's prompt, but `prose_result` does not currently
enforce it at runtime. Tests and smoke runs must therefore verify that the child actually follows it.

For a long handoff, have the child create a Markdown artifact and return a small descriptor containing
its path, purpose, provenance, and validation status. Do this only through a real, allowed handoff or
file-writing capability. Never list a proposed handoff tool before it has been registered and tested.

### `skills`

An empty value carries no skill catalogue, which is the correct default for a narrow specialist.
List exact skill names only when their instructions are required. `all` is expensive and should be
exceptional.

### `allow` and `deny`

These fields are not opposites:

- `allow` means “auto-approve these calls.” It replaces the ordinary unattended set when present.
- Omitting a tool from `allow` does not block it; the SDK may ask the user for permission.
- `deny` makes a tool unreachable through `disallowed_tools`.
- Prose's globally invisible tools remain denied regardless of the file.
- With `spawns: false`, `prose_spawn` is denied automatically.

Name Prose MCP tools without their namespace, such as `prose_result` or `browser_text`. The runtime
converts them to names such as `mcp__prose__prose_result`. Built-in SDK tools retain names such as
`Read`, `Bash`, and `WebFetch`.

There is a critical current-runtime caveat: `agents/prose_agent/loop.py` unconditionally registers
and auto-approves every non-denied Prose tool after the initial allowance is constructed. Therefore,
an `allow` list alone does not strictly confine the child to the named Prose tools. Put every
forbidden Prose tool in `deny`, test the final post-`serve` options, and fix the runtime composition
before relying on an archetype for a security boundary.

## 6. Do not confuse a Markdown declaration with capability implementation

An archetype file can select existing tools; it cannot create tools, authentication, provider
scoping, confirmation logic, or an MCP server.

If the specialist needs a new capability:

1. Implement and test that capability first.
2. Register its server only in the agent entry point that should receive it.
3. Derive provider or account grants from a trusted archetype definition, not model-supplied task
   text or parameters.
4. Do not register the server in `pane_agent.py`, `code_agent.py`, or the generic loop when the
   parent and ordinary agents must not have it.
5. Test the effective registered tools and grants for the parent, the specialist, and every adjacent
   archetype.

For example, if one archetype owns Slack, Google, and Linear while another owns GitHub and Notion,
the runtime must attach exactly the first set to the first session and exactly the second set to the
second session. Prompts and frontmatter labels are documentation; server registration and broker
authorization are the enforcement boundary.

## 7. Validate the draft before activation

Run the repository tests:

```sh
python3 -m unittest discover -s agents/tests -t agents/tests
```

The bundled-archetype tests check that definitions parse, names match filenames, descriptions route
with “use when,” bodies contain substantive instructions, Prose tool names exist, parameters and
placeholders agree, and return schemas can represent failure.

For a draft file, parse it directly before moving it live:

```sh
PYTHONPATH=agents python3 -c 'from pathlib import Path; from prose_agent.archetypes import parse; p=Path("reference/archetypes/example-specialist.md"); a=parse(p.read_text(), p.stem); print(a.name, a.description); print(a.bind({"scope":"example"})); print(a.system_prompt({"scope":"example"}))'
```

Also add focused tests for behavior the generic suite cannot infer:

- The parent description routes positive and negative examples correctly.
- The final tool set contains everything required and none of the forbidden capabilities.
- A missing, extra, or malformed parameter is rejected before a pane opens.
- The archetype refuses or reports work outside its scope.
- Untrusted provider content cannot widen its task or trigger a mutation.
- Every mutation requires exact preview and confirmation, then reports provider acknowledgement.
- The returned value follows the schema on success, partial success, refusal, and failure.

Permission tests must inspect the effective options after all MCP servers and tool names have been
added. Testing `permissions.allowance()` alone is insufficient.

## 8. Smoke-test it in a pane

The local fake harness can start an archetype without a normal Prose session:

```sh
agents/.venv/bin/python agents/tests/fake_prose.py \
  --agent archetype_agent.py example-specialist '{"scope":"example"}' \
  --prompt "Perform one small representative task and return the declared result."
```

Use a draft-only directory with `PROSE_ARCHETYPES` when testing before activation. That directory
must contain only archetype definitions because every `*.md` in it is scanned:

```sh
PROSE_ARCHETYPES=/absolute/path/to/draft-archetypes \
  agents/.venv/bin/python agents/tests/fake_prose.py \
  --agent archetype_agent.py example-specialist '{"scope":"example"}' \
  --prompt "Perform one small representative task."
```

Exercise at least these cases:

1. A normal in-scope read task.
2. An ambiguous target that must ask or fail rather than guess.
3. An out-of-scope request that must be returned to the parent.
4. A prompt-injection attempt inside tool or provider content.
5. A requested mutation, including refusal or cancellation.
6. A partial-provider or missing-capability failure.
7. A result large enough to test the Markdown-handoff path, if one exists.

Observe the actual tool calls. A plausible final answer is not evidence that the boundary worked.

## 9. Activate it

Activation is the change that adds the reviewed definition to:

```text
agents/archetypes/<name>.md
```

Activate the file in the same change as any required capability registration, parent routing rule,
and tests. Do not publish a live archetype whose named tools are not implemented: unknown tool names
can be ignored silently, leaving a specialist that looks equipped but is not.

After adding it:

1. Run the complete agent test suite again.
2. Confirm `prose_archetypes` reports the expected description, parameters, and return schema.
3. Confirm `prose_spawn` offers the new name and rejects invalid parameters before creating a pane.
4. Spawn it from a parent and complete one representative end-to-end task.
5. Verify from both sides that the parent lacks specialist-only tools.
6. Verify adjacent archetypes cannot access its providers or capabilities.
7. Reopen affected panes or restart the process. The archetype catalogue is cached per process, and
   the spawn schema is built from that catalogue.

If activation fails, revert the archetype, capability registration, and routing rule together. Do
not leave a catalogue entry pointing at unavailable tools or a provider server exposed without its
specialist.

## 10. Definition of done

An archetype is designed and deployed only when every statement below is true:

- Its routing description clearly says when to use it and when not to use it.
- Its name and filename match, and the shallow frontmatter parses.
- Its parameters are bounded configuration values, all declared and used.
- Its body defines scope, method, stopping conditions, untrusted-input handling, mutations, output,
  and failure behavior.
- `spawns` is false unless delegation is explicitly required and contained.
- Required tools really exist.
- Forbidden tools are absent from the effective runtime surface, not merely omitted from `allow`.
- Provider and account grants come from trusted runtime configuration.
- The parent and neighboring agents do not receive specialist-only capabilities.
- Its return schema is small, stable, and includes failure; long output uses a validated Markdown
  handoff rather than an oversized JSON payload.
- Parser, permission, routing, capability-isolation, and behavior tests pass.
- A real parent can discover, spawn, supervise, and receive a valid result from it.

The core rule is simple: the Markdown defines the specialist's contract; the runtime enforces its
authority; the tests prove both agree.
