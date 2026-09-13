# Prose agent application integrations

**Status:** implementation plan  
**Scope:** Slack, Google Workspace, GitHub, Linear, and Notion  
**Date:** 2026-09-13

## Outcome

Give the personal pane agent useful, least-privilege access to five external applications exclusively through two visible specialist panes: `workflow` for Slack, Google Workspace, and Linear, and `deployment` for GitHub and Notion. The parent itself receives no provider tools. OAuth tokens stay outside model context, provider schemas load only in the appropriate specialist, and third-party text never becomes instructions.

The first useful release should let the agent search and read connected resources, prepare a visible change, and commit that exact change after an approval. It should not attempt arbitrary provider API calls, background autonomy, bulk export, administration, destructive changes, or silent outbound communication.

## Decisions

1. **Build one Prose-owned integration layer, not five raw MCP attachments.** The Agent SDK already accepts multiple in-process MCP servers. Add one compact `apps` server whose handlers call a local broker; provider tokens and raw clients never enter model context.
2. **Put that server only in two specialist archetypes.** `workflow` exclusively owns Slack, Google Workspace, and Linear. `deployment` exclusively owns GitHub and Notion. The parent personal agent receives no `apps_*` tools, no provider MCP servers, and no provider schemas. It can only discover these archetypes, spawn one, supervise it, and receive its bounded result.
3. **Make routing explicit in both descriptions and the parent prompt.** Any request that requires reading or changing Slack, Google Workspace, or Linear goes to `workflow`. Any request that requires reading or changing GitHub or Notion goes to `deployment`. The parent must not substitute a browser pilot, shell command, direct HTTP call, or generic web fetch for either specialist.
4. **Keep the specialist tool surface small.** Expose connection discovery, capability discovery, search/get, prepare, and commit only inside the two integration archetypes. Provider-specific operation schemas are pulled with `apps_capabilities(provider)` only when needed.
5. **Separate preparation from effect.** Every external mutation first produces an immutable, expiring preview. A second, ask-gated call commits that preview. The approval card must show provider, account, target, operation, and a bounded human-readable diff.
6. **Treat all provider content as untrusted data.** Slack messages, email, documents, issues, comments, and page text may inform an answer, but they cannot grant permissions, widen scope, trigger tools, alter system instructions, or cause memory writes by themselves.
7. **Keep secrets outside agent processes.** Connection credentials belong in macOS Keychain. Archetypes receive opaque connection IDs and normalized results, never access tokens, refresh tokens, client secrets, app private keys, signing secrets, or webhook secrets.
8. **Ship local-first, but do not hide the production boundary.** A personal/development build can use bring-your-own provider app registrations and local polling. A broadly distributed build needs a small hosted OAuth/webhook relay for providers whose client secret or public webhook endpoint cannot safely live in a desktop binary.
9. **Use Markdown for long parent/child handoffs.** JSON remains right for small machine-shaped results. Long research, plans, and cross-provider synthesis should be written to a validated `.md` handoff and returned to the parent as a short descriptor, not embedded into `prose_result`.

## Architecture

```text
parent personal agent
  |-- prose_archetypes
  |-- prose_spawn(flavour="workflow")
  |-- prose_spawn(flavour="deployment")
  `-- no apps_* tools and no provider MCP servers

workflow archetype                 deployment archetype
  | apps_* MCP                       | apps_* MCP
  | provider allowlist:              | provider allowlist:
  | slack, google, linear            | github, notion
  +---------------+------------------+
                  |
                  | Prose wire / integration.call
                  v
IntegrationBroker (one per app instance; enforces archetype provider set)
  |-- ConnectionStore metadata
  |-- KeychainSecretStore
  |-- PermissionPolicy + PreviewStore + AuditLog
  |-- SlackProvider
  |-- GoogleProvider
  |-- GitHubProvider
  |-- LinearProvider
  `-- NotionProvider
       |
       v
  provider APIs / optional event relay
```

The broker should be app-owned and long-lived so that rate limits, refreshes, caches, pagination cursors, event cursors, and audit records are shared across panes. The preferred boundary is a new `integration.call` request on the authenticated Prose socket. `SessionRegistry` retains the existing pane/session containment rule and records an immutable provider set when an integration archetype session is reserved. Every broker request checks both the session and that provider set. Provider HTTP runs outside the main actor.

The parent must not receive a broadly scoped connection allowlist that descendants happen to inherit. Authority is granted to the exact `workflow` or `deployment` child session from the trusted archetype definition, not from a model-supplied task, parameter, environment variable, or provider argument. A nested child receives no connector authority unless a future archetype contract explicitly delegates a narrower set.

Do not pass credentials through `AgentProcess.environment` or extend `credentials.CARRIED`; every child inherits that environment. Do not shell out to `curl`, `gh`, or provider CLIs as the product interface. Those are acceptable developer probes, not the credential or authorization design.

## Archetype routing contract

These descriptions are part of the security and usability design: they are the only prose the parent reads before choosing a specialist. Put the same routing rule, more compactly, in `prompt.SYSTEM` so the parent does not need to infer it from names.

### `workflow`

Proposed catalogue description:

> Use when a task needs Slack, Google Workspace, or Linear: reading or sending workplace communication, working with email, calendars, Drive or Docs, or reading and updating Linear work. Use it even when only one of those services is involved, and reuse the same workflow pane for follow-up work. Not for GitHub repositories, pull requests, releases, deployments, or Notion; those go to the deployment archetype. The parent has none of these service tools itself.

The archetype receives exactly the provider set `slack`, `google`, and `linear`. Its body explains cross-service workflows—such as turning a Slack decision into a Linear update and scheduling the follow-up in Calendar—while keeping every source distinguishable. It returns conclusions, external refs/URLs, a list of prepared or completed actions, and `failed`. It never returns raw messages, email bodies, documents, or issue histories.

### `deployment`

Proposed catalogue description:

> Use when a task needs GitHub or Notion: repository, issue, pull-request, check, release, or deployment work in GitHub, and runbooks, engineering knowledge, launch notes, or deployment records in Notion. Use it even when only one of those services is involved, and reuse the same deployment pane for follow-up work. Not for Slack, Google Workspace, or Linear; those go to the workflow archetype. The parent has none of these service tools itself.

The archetype receives exactly the provider set `github` and `notion`. “Deployment” does not grant shell, repository mutation, cloud-console, or production-runtime access: code changes still go to the visible `code` flavour, and production execution needs a separately designed capability. This archetype coordinates delivery records and provider actions only. It returns conclusions, external refs/URLs, a list of prepared or completed actions, and `failed`; long release or runbook handoffs use the Markdown transport.

### Parent rule

The parent prompt should say this directly:

> You do not have Slack, Google Workspace, Linear, GitHub, or Notion tools. For any task that needs Slack, Google Workspace, or Linear, spawn or reuse `workflow`. For any task that needs GitHub or Notion, spawn or reuse `deployment`. Do not use browser-pilot, shell commands, direct HTTP, or web fetches to work around that boundary. If one request spans both groups, spawn both specialists, give each only its part, and synthesize their bounded results yourself.

The parent calls `prose_archetypes` before first use, then `prose_spawn`, `prose_wait`, and `prose_send` as today. It reads summaries first. Provider content stays in the specialist's context; only its typed result or validated Markdown handoff crosses upward.

### Compact archetype-only tools

| Tool | Purpose | Side effect policy |
|---|---|---|
| `apps_connections` | List connected accounts only for this archetype's fixed provider set | unattended; no secrets |
| `apps_capabilities` | Pull one allowed provider's supported resource kinds, filters, operations, and argument schemas | unattended; cacheable |
| `apps_search` | Search or list a bounded set of resources using provider-specific filters | unattended only within a connected account's read allowlist |
| `apps_get` | Fetch one canonical resource or thread by opaque ref, with bounded fields/size | unattended only within the read allowlist |
| `apps_prepare` | Validate a mutation and create an immutable preview; performs no remote write | unattended; returns risk and preview text |
| `apps_commit` | Execute the exact preview by ID, with idempotency key and stale-version checks | always permission-gated in v1 |
| `apps_cancel` | Discard a prepared operation | unattended |

These tools are not registered in `pane_agent.py` or `code_agent.py`. `archetype_agent.py` registers them only when the trusted archetype definition declares an integration provider set. `apps_capabilities` refuses a provider outside that fixed set before any network call. Avoid a generic `apps_execute(method, url, body)` tool; that is arbitrary network access with a friendlier name.

Normalized resource refs should be opaque strings such as `github:<connection>:pull_request:<node-id>` rather than URLs or user-supplied names. Results should include `provider`, `connection`, `kind`, `ref`, `title`, `url`, `updated_at`, `author`, and a bounded `summary`/`content` field. Provider IDs stay available for diagnostics but must not be accepted without the connection prefix.

### Prepare/commit contract

`apps_prepare` resolves names to stable IDs, checks current permissions, validates fields, fetches the current version, and stores this record locally:

```json
{
  "id": "preview_…",
  "session": 12,
  "connection": "linear_work",
  "operation": "issue.update",
  "target": "linear:linear_work:issue:…",
  "arguments_hash": "sha256:…",
  "base_version": "provider revision or updated_at",
  "preview": "Status: Todo → In Progress",
  "risk": "external-write",
  "expires_at": "…"
}
```

`apps_commit` accepts only the preview ID. The broker rechecks ownership, expiry, granted scopes, target version, and idempotency before calling the provider. If the target changed, it refuses and asks the model to prepare again; it never silently rebases a user-approved change.

## Connection and credential design

Add a Connections view to the macOS app. Each connection shows provider, account/workspace identity, scopes/capabilities, selected resources, last successful call, last sync, and Reconnect/Disconnect controls. OAuth must open in the system authentication session, use a random `state`, and use PKCE wherever the provider supports it. Google explicitly rejects embedded webviews for OAuth and documents a system-browser/local-redirect installed-app flow.

Store secret material in Keychain with an access group owned by Prose. Store only non-secret metadata under `~/Library/Application Support/Prose/Connections/`, using a versioned schema and atomic writes. Logs must redact authorization headers, cookies, query tokens, email/message bodies, and provider payloads by default.

Support two deployment modes:

- **Personal/developer mode:** bring your own provider app registration. Google can use an installed desktop client. Slack can use Socket Mode. Providers needing a client secret use credentials the user supplies to Keychain. Linear/Notion/GitHub/Google change events use incremental polling where possible.
- **Distributed mode:** a narrow hosted relay owns confidential OAuth client credentials, GitHub App signing material, and public HTTPS webhook endpoints. It exchanges authorization codes and forwards signed, encrypted event envelopes to the identified Prose installation. It does not run the model and should not retain provider content after delivery.

This deployment choice is the only blocking product decision before implementation. Embedding a shared Slack/Notion/Linear client secret or GitHub App private key in the `.app` is not an acceptable shortcut.

## Provider slices

### Slack — `workflow` only

Start with channels explicitly joined by the app, direct mentions, bounded message search, thread reads, and prepared message/reply/reaction writes. Prefer a bot identity so outbound content is visibly from the agent; request a user token only for a user-only capability such as broad user-scoped search, and make that a separate optional connection capability.

For local mode, Socket Mode avoids a public request URL and supports the Events API behind a firewall. For distributed mode, use signed HTTP Events API delivery through the relay. Dedupe by event/envelope ID, acknowledge before slow work, and never treat a message event as permission to act outside the mentioned thread or configured channel.

Do not support channel creation, invitations, admin APIs, retention changes, workspace-wide history import, message deletion, or posting to an unpreviewed channel in v1.

Official constraints: Slack uses OAuth v2 with granular bot/user scopes and optional scopes, and Socket Mode is available only to granular-permission apps and is not eligible for the public Marketplace. See [Slack OAuth](https://docs.slack.dev/authentication/installing-with-oauth/), [Slack scopes](https://docs.slack.dev/reference/scopes/), and [Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/).

### Google Workspace — `workflow` only

Treat Google Workspace as four capability packs under one Google account connection:

1. **Calendar:** list/get calendars and events; prepare create/update/RSVP operations.
2. **Drive/Docs:** search metadata, get user-selected files, export bounded document text; prepare creation or updates only for app-created/user-selected files.
3. **Gmail:** search/get threads and messages, prepare drafts, then explicitly send a prepared draft.
4. **People:** contact lookup for disambiguation; no contact mutation in v1.

Roll out Calendar and Drive before Gmail. Prefer `drive.file` and user file selection over all-Drive scopes. Gmail scopes that read bodies or modify mail are restricted and can trigger verification/security-assessment obligations, so Gmail needs a separate launch gate and policy review. Sending mail is always a commit with From/To/Cc/Bcc/Subject/body/attachments visible; replying must show the resolved thread and recipients. No delete, forwarding-rule, sharing-policy, or domain administration tools.

Use the installed-app OAuth flow with system browser, loopback callback, `state`, and PKCE. Note that Google's installed-app documentation says incremental authorization is not supported for installed apps, so use distinct OAuth clients or reconnect flows for optional capability packs rather than assuming scopes can be added invisibly.

Use Calendar sync tokens and provider cursors for incremental local refresh. Do not copy an entire mailbox or drive into Prose memory. See [OAuth for desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [Drive scopes](https://developers.google.com/identity/protocols/oauth2/scopes), and [Calendar incremental sync](https://developers.google.com/workspace/calendar/api/guides/sync).

### GitHub — `deployment` only

Use a GitHub App rather than a classic OAuth app. Installations can be limited to selected repositories and start with no permissions; request only metadata plus read access for issues, pull requests, checks, and contents needed for summaries. Use a user access token only when an action must be attributed to the human; otherwise use the bot installation identity so agency stays visible.

Initial reads: repository/issue/PR lookup, review and check status, changed-file metadata, and bounded file contents. Initial writes: prepare an issue, comment, label/status change, or PR review comment. Branch pushes and PR creation belong to the existing visible `code` subagent and can later be linked back through the integration.

Do not expose merge, release, workflow dispatch/edit, secret access, repository settings, collaborator changes, force-push, branch deletion, or arbitrary GraphQL/REST in v1. Installation tokens are minted on demand and cached only until their short expiry. Verify webhook signatures and dedupe delivery IDs when the relay lands.

See [choosing GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app), [GitHub App versus OAuth App](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/differences-between-github-apps-and-oauth-apps), and [GitHub webhooks](https://docs.github.com/en/webhooks/using-webhooks).

### Linear — `workflow` only

Initial reads: search/get issues, projects, cycles, teams, comments, and workflow states. Initial writes: prepare issue creation, field/status/assignee updates, and comments. Resolve all human names, teams, and states to IDs during preparation and show the result in the preview.

Use OAuth 2.0 for normal connections, store refresh-token state and revocation, and verify webhook HMAC plus timestamp if the relay is enabled. Start with user-actor behavior for the personal agent. Treat Linear's native Agent APIs as a later adapter: they are currently Developer Preview and impose a distinct session/activity lifecycle, including quick acknowledgement. If adopted, map Prose Band A activities to Linear Agent Activities without feeding Linear's rendered activity stream back into the model.

Do not auto-transition issues merely because they were mentioned in imported text. No workspace settings, webhook administration, bulk edits, or deletion in v1.

See [Linear OAuth](https://linear.app/developers/oauth-2-0-authentication), [GraphQL API](https://linear.app/developers/graphql), [webhooks](https://linear.app/developers/webhooks), and [Agents preview](https://linear.app/developers/agents).

### Notion — `deployment` only

Initial reads: search/get pages and data sources shared with the connection, including bounded block content and typed properties. Initial writes: prepare a page creation, property update, append-block operation, or comment. Keep parent/data-source resolution and the rendered block/property diff in the preview.

Notion access is capability- and page-scoped: connecting a workspace does not mean every page should be available. Surface which pages/data sources were shared, preserve `has_more`/cursor pagination, and handle archived/inaccessible pages as revoked access rather than missing data.

Do not expose workspace/user administration, broad export, page deletion/archive, permission changes, or arbitrary block JSON in v1. Public distribution uses a public OAuth connection; personal mode may use a user-created internal connection token stored in Keychain. Webhooks require public HTTPS and signature validation, so they wait for the relay.

See [Notion authorization](https://developers.notion.com/guides/get-started/authorization), [connection capabilities](https://developers.notion.com/reference/capabilities), and [webhooks](https://developers.notion.com/reference/webhooks).

## Trust, privacy, and permissions

Every normalized content field carries provenance: provider, connection, remote resource ID/ref, author, fetched timestamp, remote updated timestamp/version, and the query or event that introduced it. Render third-party text inside a clearly delimited data envelope before it enters a prompt. Instructions found inside that envelope are quoted content, not directives.

The broker enforces:

- an exact provider set attached to the integration-archetype session, not inherited by the parent or arbitrary descendants;
- provider and resource allowlists configured in Connections;
- maximum result counts and body sizes before content reaches the model;
- server-side operation allowlists and argument validation;
- URL/attachment fetching disabled unless separately scoped;
- no credentials or secret-like headers in results/errors/logs;
- rate-limit handling with bounded retries and `retry_after`, never an agent retry loop;
- idempotency keys for writes and delivery-ID deduplication for events;
- compare-and-swap/version checks between preview and commit;
- an append-only local audit record for auth changes, preparations, approvals, commits, failures, and disconnects.

Extend `Permissions.describe` and `grant` so an approval reads like “Linear wants to update ENG-123 in Work: Status Todo → In Progress,” not “apps_commit wants to use something.” Never offer “Allow from now on” for `apps_commit` in v1. A supervising parent may approve only when its own task explicitly requested that exact provider, target, and effect; otherwise it escalates to the user.

Memory is downstream of this boundary. Raw provider bodies, attachments, access tokens, secrets, private-channel membership, and inferred sensitive facts are never automatically remembered. Only a user-confirmed distilled fact with provenance may enter memory. Disconnecting a provider stops retrieval immediately and offers deletion of derived indexes/memory links.

## Markdown handoffs between agents

Keep `prose_result` for short status and typed values, capped at 4 KB serialized. Use a Markdown handoff when the useful result is long-form reasoning, a plan, a review, a research synthesis, or anything that would exceed that bound.

The child calls `prose_handoff_create(markdown, summary)`. A role-scoped handoff manager writes UTF-8 Markdown beneath `~/Library/Caches/Prose/Handoffs/<run>/<session>/` and returns a descriptor. The child then returns only a small business result plus this transport field:

```json
{
  "summary": "two or three sentences",
  "handoff": {
    "path": "…/Library/Caches/Prose/Handoffs/<run>/<session>/<uuid>.md",
    "sha256": "…",
    "bytes": 12345,
    "media_type": "text/markdown",
    "delete_after_read": true
  }
}
```

The manager, not the model, chooses the path and enforces a 256-KiB limit, `0700` directories, `0600` regular non-symlink files, session ownership, valid UTF-8, byte count, and SHA-256. The parent sees the short summary first and reads bounded 8-KB chunks only when needed through `prose_handoff_read`, which validates and reads the same open file descriptor to avoid a path-swap race. It calls the exact-target, idempotent `prose_handoff_finish` after summarizing. Crash leftovers expire after 24 hours, and a deliverable is explicitly copied to a user-chosen path rather than retained in this cache.

Do not replace archetypes' current business result schemas. `handoff` is an optional transport field alongside them. Spawned personal/code agents receive the create role; an archetype receives it only when its frontmatter explicitly allows `prose_handoff_create`. Supervising personal agents receive read/finish. Memory tools never ship to child roles.

The companion design in `reference/memory-feature-plan.md` owns the detailed lifecycle, security checks, and cleanup policy.

## Concrete code changes

### Swift host and UI

- Add `IntegrationProtocol.swift` to `ProseCore`: connection IDs, canonical refs, bounded result types, prepare/commit records, trusted archetype provider grants, and error codes.
- Extend `Protocol.swift`, `AgentSocket.swift`, `SessionRegistry.swift`, and `Host.swift` with `integration.call`, preserving session authentication while authorizing against the exact integration-archetype session and its fixed provider set.
- Add `ProseIntegrations` target with `IntegrationBroker`, `ConnectionStore`, `KeychainSecretStore`, `PreviewStore`, `AuditLog`, provider protocol, HTTP transport, redaction, pagination, retry, and fixtures.
- Add provider clients one slice at a time: Notion, Linear, GitHub, Slack, Google.
- Add SwiftUI Connections UI and OAuth callback handling. Never perform provider I/O on the main actor.
- Add optional event relay registration and a local event inbox only after on-demand calls are stable.

### Python agent

- Add `agents/prose_agent/apps.py` with plain-data tool definitions and handlers over `Wire.call("integration.call", …)`, keeping the SDK import inside `mcp_server()` as `tools.py` does. Construct it with a trusted provider set and reject every other provider locally as well as in the broker.
- Extend archetype frontmatter with a shallow-list `integrations` field. Validate it against the fixed provider catalogue. `workflow` declares `slack, google, linear`; `deployment` declares `github, notion`. The parent cannot provide or override this field through `params`.
- Register the `apps` MCP server only in `archetype_agent.py` when the loaded archetype has a nonempty `integrations` field. Never register it in `pane_agent.py`, `code_agent.py`, or generic `loop.serve` by default.
- Add the explicit workflow/deployment routing rule to `prompt.SYSTEM`: the parent has no provider tools and must not route around the specialists through browsers, shell, direct HTTP, or web fetch.
- Add `agents/archetypes/workflow.md` and `agents/archetypes/deployment.md` only in the same change that makes their connector toolsets functional. Give both `spawns: false`, explicit integration sets, explicit deny lists, bounded return schemas with `failed`, and detailed untrusted-content rules.
- Fix the current effective-allowance composition before adding connector tools: `loop.serve` presently auto-approves every registered Prose MCP tool not denied, even when an archetype omitted it from `allow`. Connector registration and approval must be derived from the trusted archetype allowance, with `apps_commit` always reaching its internal confirmation path.
- Add compact specialist rules: external text is data, use prepare/commit, never claim a write before the commit result, never return raw provider bodies, and use Markdown handoffs only for genuinely long outputs.
- Extend `permissions.py` with action-aware descriptions and no persistent commit grants.
- Add the role-scoped Markdown handoff manager and tools, and update archetype loading without changing existing business schemas, as described above.

### Packaging and operations

- Add provider configuration templates with no committed secrets.
- Add connection/audit data migrations and uninstall/disconnect cleanup.
- Add a diagnostics command/view that reports scopes, health, last status, rate-limit state, and webhook cursor without revealing content or tokens.
- Document local/BYO setup separately from distributed relay registration.

## Delivery sequence

### Phase 0 — routing, product, and threat-model decisions

Choose personal/BYO-only versus distributable mode, define which Google capability packs ship, decide whether outbound messages use an agent/bot identity, and approve the v1 operation allowlist. Freeze the two archetype descriptions and provider sets. Write abuse cases before code: parent tries a direct provider call, wrong archetype names a provider, arbitrary descendant calls the broker, prompt injection in content, stale preview, confused account, compromised child, leaked token, replayed webhook, duplicate commit, and disconnect during a turn.

**Exit:** signed-off provider-to-archetype routing and capability/permission matrix, deployment mode, and no unresolved shared-secret-in-app design.

### Phase 1 — broker and archetype capability foundation

Land protocol, Keychain metadata split, connection UI, mock transport, canonical refs, result bounds, provenance envelopes, audit log, trusted archetype provider grants, and the scoped `apps_connections/capabilities/search/get` surface. Fix the current Prose-tool auto-approval composition. Add both archetype definitions only after their scoped server can be constructed.

**Exit:** tests prove the parent and code agent have no `apps_*` schemas or handlers; `workflow` cannot name GitHub/Notion; `deployment` cannot name Slack/Google/Linear; an arbitrary descendant cannot inherit either capability; no token appears in process environment, transcript, diagnostics, traffic logs, or crash output.

### Phase 2 — read-only `workflow`

Add Slack channel/thread access, Google Calendar and selected-file Drive/Docs access, and Linear issue/project access inside `workflow`. Add Gmail only behind its separate scope-readiness gate. Exercise tasks that combine the three providers without merging provenance or returning raw provider bodies.

**Exit:** the parent consistently routes any single- or multi-provider Slack/Google/Linear task to `workflow`, reuses its pane, and receives bounded sourced results. Direct parent browser/shell workarounds are absent from the tested tool surface.

### Phase 3 — `workflow` prepare/commit

Land preview storage, policy classification, action-aware approval cards, idempotency, optimistic concurrency, and the allowed Slack, Google, and Linear mutations. Gmail send remains a separately enabled capability with the complete message envelope in its preview.

**Exit:** all workflow writes require a matching current preview and one explicit approval; stale/double commits are harmless and visible; the parent can approve only the exact action it delegated or escalate it.

### Phase 4 — `deployment`

Add GitHub App installations and repository selection plus Notion page/data-source sharing. Land read operations first, then the same prepare/commit contract for allowed GitHub and Notion writes. Keep code changes in the `code` flavour and keep actual production-runtime deployment outside this archetype.

**Exit:** the parent routes GitHub/Notion tasks to `deployment`; repository/page scope changes take effect without restart; bot/app identity is visible; `deployment` cannot reach workflow providers, shell deployment, or forbidden admin/destructive calls.

### Phase 5 — events, memory links, and long handoffs

Add incremental polling first, then the hosted webhook relay where needed. Feed events into a bounded local inbox; do not automatically start model turns for every event. Land Markdown handoff support and connect user-confirmed memory records to provider refs/provenance.

**Exit:** events are verified, deduplicated, inspectable, and opt-in; disconnect erases cursors/indexes and invalidates memory links as configured; long subagent work reaches parents via validated Markdown descriptors.

## Verification

Unit tests should cover canonical ref parsing, connection containment, Keychain abstraction, redaction, scope denial, capability discovery, pagination, size caps, malformed provider data, OAuth state/PKCE, token refresh/revocation, rate limits, preview expiry/version drift, idempotency, audit records, webhook signatures/timestamps/replay, and Markdown handoff path/digest/size validation.

Provider contract tests run against recorded redacted fixtures and a fake clock/transport. Each provider gets negative fixtures for 401, 403, 404/revoked resource, 409/version conflict, 429, 5xx, truncated pagination, malformed JSON, and a payload containing prompt-injection text and fake credentials.

Python tests keep the SDK-free import property. Extend `FakeWire` assertions for apps tools; prove `pane_agent` and `code_agent` register none; prove each integration archetype registers the compact surface with only its fixed provider set; prove the `apps_commit` handler always performs its own exact-preview confirmation and offers no persistent grant; and test permission-card wording. Add description-routing tests requiring the exact positive and negative provider groups, plus effective-option tests that inspect the post-`serve` allow/deny/tool composition rather than only `allowance()` in isolation. Extend `fake_prose.py` with a fake integration response so a real specialist turn can search, prepare, ask, and commit without network access.

One gated live test per provider verifies identity, read, preview, approved write to a dedicated sandbox resource, and cleanup. Live tests never run by default. Manual QA verifies system-browser OAuth, Keychain behavior, reconnect/disconnect, multi-account disambiguation, approval readability, and app termination during refresh/commit.

## Definition of done

- A user can connect multiple named accounts and see exactly what each grants.
- `workflow` can search/get bounded Slack, Google Workspace, and Linear data; `deployment` can search/get bounded GitHub and Notion data.
- The parent personal agent and `code` flavour have no provider tools, schemas, MCP servers, tokens, or direct broker route. Their only route is spawning/supervising the correct archetype.
- The archetype descriptions and parent prompt state the routing in both directions: workflow for Slack/Google/Linear, deployment for GitHub/Notion, with no browser/shell/direct-HTTP workaround.
- Provider sets come from trusted archetype definitions and cannot be widened by task text, parameters, environment, nested children, or imported provider content.
- Every external write is an allowlisted operation, prepared first, previewed clearly, approved once, idempotent, audited, and reported from the provider response.
- No raw API escape hatch, destructive/admin action, shared secret in the app bundle, credential in an agent environment, or silent “allow forever” external-write grant exists.
- Third-party text cannot widen scope, approve an action, invoke a tool, or enter memory without an explicit user-confirmed transformation.
- Disconnect and revocation fail closed and clean up tokens, cursors, previews, and configured derived data.
- Large child results use validated Markdown handoffs; short typed results remain JSON.
- The existing Python and Swift suites remain green, provider contract tests are deterministic, and each enabled provider has a gated live test and a written rollback switch.

## Open questions

1. Is this initially a personal/BYO build, or must the first release be installable by unrelated users? This decides whether the OAuth/webhook relay is phase 0 work.
2. Which Google surfaces are meant by “Google Workspace”: Calendar/Drive/Docs/Gmail/People, or a narrower set?
3. Should Slack and GitHub writes appear as a Prose bot/app, as the connected user, or be selectable per connection?
4. Are external events allowed to wake the agent, or should they only populate an inbox until a user asks?
5. Should one long-lived `workflow`/`deployment` pane be reused across every account, or should account isolation require separate specialist panes?
6. How long should audit records, cached snippets, event cursors, and Markdown handoffs be retained?
