# prose automation — scheduled and event-driven agent work

This is a plan for letting prose arrange work that happens later: once at a particular time,
repeatedly, after a local or remote event, or on demand. It is deliberately a host feature rather
than a clever prompt or an in-process timer. A pane process ends when prose ends today; a useful
automation has to survive both that pane and the app that created it.

The short version is:

1. An agent may **propose** an automation, but prose owns and persists it only after the user sees
   and approves the trigger, task, permissions, limits and destination.
2. A scheduler turns occurrences into durable runs. It does not execute model turns itself.
3. A run executor starts a fresh root agent with the same visible, containable delegation tree prose
   already uses. It records events before presenting them in a pane or notification.
4. One macOS launch agent owns the database and executor when the app is closed. The app is a client
   of that service, not a second scheduler.
5. Trigger adapters turn filesystem, connector and webhook activity into one durable event envelope.
   Matching and deduplication happen after the event has been recorded.

This adds prose's first durable product data. It does **not** imply restoring ordinary tabs, pane
layouts or conversations on launch; automation definitions and run history are a separate, explicit
store with their own retention controls.

---

## 1. Goals and boundaries

### Goals

- One-time work: “At 4 PM, research these three companies and summarize the result.”
- Calendar recurrence: “Every weekday at 8:30 AM,” expressed in a named time zone.
- Fixed intervals: “Check every 30 minutes,” with an anchor and an explicit missed-run policy.
- Event-driven work: “When this folder receives a PDF,” “when this build fails,” or “when a new
  matching message appears.”
- Dependencies: an automation can react to another automation's success or failure through the same
  event system, without adding a separate workflow engine in the first pass.
- Fresh delegation: every occurrence may spawn and supervise prose, code or archetype children under
  the existing descendant containment rule.
- Useful operation with the app closed, subject to the Mac being awake or to a stated catch-up rule.
- A complete answer to “what will run, what ran, what is running, and why did this run?”
- Safe unattended execution: bounded cost, runtime and concurrency, with no surprise permission
  prompts hanging for a day in a hidden process.

### Not goals for the first release

- Guaranteed execution while the Mac is powered off. That requires a cloud scheduler and cloud
  executor, not a different local timer.
- A general DAG or visual workflow language. Chaining by emitted events covers the first real uses;
  add a graph only after those uses show what it needs to mean.
- Arbitrary commands supplied by the model. An automation names a fixed `flavour`, just as
  `prose_spawn` does; prose resolves that name to an argv.
- Silent, permanent permission inheritance from an interactive pane. “Allow for this pane” currently
  dies with the process and must stay that way.
- Treating an SDK `CronCreate`, `ScheduleWakeup`, `Monitor` or `RemoteTrigger` call as prose state.
  Some of those calls are currently blocked because prose supplies no harness for them, and even a
  working SDK-owned timer would sit outside prose's containment, history and cancellation model.

---

## 2. The model: automation, occurrence and run

Keep three concepts separate.

An **automation** is the durable user-approved recipe. An **occurrence** is one reason that recipe
became due: a calendar instant, a manual request, or a particular event id. A **run** is an attempt to
execute that occurrence. This separation is what makes retries, deduplication and history honest.

```text
automation definition
    trigger + task + policy + limits
                 |
                 v
      durable occurrence key          normalized event inbox
                 |                              |
                 +--------------+---------------+
                                v
                        queued run record
                                |
                       lease / execute / retry
                                |
              succeeded | failed | needs approval | cancelled
```

### Automation definition

Use a versioned `Codable` value for the public shape, with indexed columns for the fields the
scheduler queries frequently.

```swift
struct AutomationDefinition: Codable, Sendable {
    var id: UUID
    var revision: Int
    var title: String
    var enabled: Bool
    var trigger: Trigger
    var action: AgentTask
    var policy: ExecutionPolicy
    var delivery: DeliveryPolicy
    var createdAt: Date
    var updatedAt: Date
}

struct AgentTask: Codable, Sendable {
    var prompt: String
    var flavour: String             // prose, code, or a known archetype
    var parameters: [String: JSONValue]
    var workingDirectory: WorkingDirectory?
}
```

Do not store `PaneID`, `SessionID`, a session token or an argv. All four are ephemeral or privileged.
At fire time, the executor validates the stored flavour against the current catalogue and creates a
new root session. Every run stores an immutable snapshot of the automation revision it used, so an
edit during a run cannot rewrite history.

### Trigger shapes

Start with a small, semantic union rather than exposing raw launchd or five-field cron syntax:

- `at(instant)` — fires once. If disabled and re-enabled after the instant, the misfire policy says
  whether it runs immediately or remains complete.
- `interval(duration, anchor)` — elapsed intervals anchored to a real instant.
- `calendar(rule, timeZone)` — daily, selected weekdays, monthly day, or a bounded calendar rule.
  Preserve the named time zone and original local components in addition to the computed UTC next
  fire.
- `event(source, type, predicates, debounce, throttle)` — matches a normalized event envelope.
- `manual` — only `run now`; useful while building and for reusable agent recipes.

Raw cron can be an import/export escape hatch later, but it should not be the agent-facing format.
It hides time-zone and daylight-saving choices precisely where an unattended system must expose
them.

Each timed trigger declares:

- a named time zone;
- what to do with a nonexistent local time during the spring transition (`skip` or `nextValid`);
- which occurrence to choose when a local time happens twice (`first` or `second`);
- a misfire policy: `skip`, `runOnce`, or `catchUp(maximum:)`.

The default should be `runOnce`: after sleep, downtime or a crash, execute one overdue occurrence
and advance to the next future one. Replaying 400 half-hour checks after a week offline is almost
never the user's intent.

### Event envelope

Every trigger adapter writes the same value before matching rules:

```swift
struct AutomationEvent: Codable, Sendable {
    var id: String                  // stable source id or a content-derived UUID
    var source: String              // filesystem, github, calendar, automation, ...
    var type: String                // created, changed, failed, succeeded, ...
    var occurredAt: Date
    var receivedAt: Date
    var subject: String?
    var payload: JSONValue
    var trust: EventTrust
}
```

The unique key is `(source, id)`. Delivery is at least once; inserting that key and creating the
matching occurrence happen in one database transaction. Payload text is untrusted input, not extra
system instructions. The runner should label and delimit it separately from the user-approved task
prompt.

### Execution policy

An automation also stores behavior that must not be improvised at fire time:

- concurrency: `queue`, `skipWhileRunning`, `replace`, or `coalesce`;
- maximum concurrent children and spawn depth;
- maximum runtime, model turns, tokens and estimated cost;
- retry count and backoff with jitter;
- misfire policy;
- run retention and artifact-size limits;
- an approved capability profile and credential references;
- whether browser panes are permitted when a headless browser executor exists.

The first-release defaults should be one run at a time, skip duplicate occurrences, a conservative
runtime/cost limit, and no retries after an agent reports an application-level failure. Retry only
failures marked transient by the host, such as an unavailable network or crashed worker.

---

## 3. Ownership and permission model

Scheduling is a durable side effect. An agent may formulate it, but should not be able to make it
quietly while all prose MCP tools are currently auto-approved.

### Proposal, approval, commit

Make creation and capability expansion a two-stage host operation:

1. `automation.propose` validates and normalizes a definition, computes the next few occurrences,
   and returns a proposal id.
2. Prose draws a dedicated approval card containing the human-readable task, trigger and time zone,
   working directory, data sources, delivery target, durable grants, limits and first three fire
   times.
3. Approval commits the exact normalized proposal. Editing any security-relevant field invalidates
   the approval and creates a new proposal.

Pause, resume, delete, “run now,” widening a filesystem scope and adding a credential are also
mutations. They should go through host authorization rather than rely only on the model SDK's tool
permission callback. Listing definitions and reading history are safe, contained reads.

### Durable grants are not pane grants

An unattended process cannot stop on today's ask card. Give automation runs a separate permission
callback with only two outcomes:

- the tool and arguments fall inside the automation's durable grant, so allow them; or
- deny immediately, append an `approvalRequired` event, mark the run `needsApproval`, notify the
  user, and do not retry automatically.

The user may widen the definition and explicitly rerun the occurrence. Never translate an old
interactive “Allow from now on” click into an automation grant.

Start with narrow profiles instead of trying to serialize every possible SDK question:

- `observe` — existing unattended read/search/skill tools only;
- `notify` — `observe` plus a specific notification destination;
- `workspace` — reads and writes inside one approved directory;
- `custom` — explicit tool, executable, path, domain and connector scopes.

Persist Keychain item identifiers or connector credential ids, never secret material. Revalidate a
working-directory path when a run starts; if distribution becomes sandboxed, replace plain paths
with security-scoped bookmarks.

### A run has a capability ceiling

The scheduled root may delegate, but no descendant may gain more authority than the automation.
Pass a signed or host-issued run-policy id in every spawned process environment. The Python
permission layer intersects an archetype's allowance with that policy, and host-side prose calls
are checked against it too. This closes the hole that ordinary descendant containment does not:
starting a legitimate child whose flavour is wider than its parent.

Cancellation walks the run's session tree and terminates every descendant. A scheduler helper owns
its automation processes the same way the app owns interactive processes, so kill-on-drop remains
true at the correct boundary.

---

## 4. Architecture

### Components

Add four layers with one-way dependencies:

| Component | Responsibility |
|---|---|
| `ProseAutomationCore` | Pure definitions, validation, recurrence calculation, event matching, state transitions and permission intersection |
| `AutomationStore` | SQLite migrations and transactions for definitions, occurrences, runs, attempts, leases, events, grants and artifacts |
| `AutomationScheduler` | Computes due work, reconciles missed work, claims leases, applies concurrency/retry policy and asks an executor to run |
| `AutomationRunHost` | Hosts a fresh root agent and virtual descendants, records protocol events and results, enforces the run policy, and reports terminal state |

Keep `ProseAutomationCore` free of AppKit, SwiftUI, ServiceManagement and SQLite for the same reason
`ProseCore` is pure today: schedules and state transitions should be exhaustively testable with a
fake clock.

### One database, one scheduler

Use SQLite in WAL mode under `Application Support/Prose/Automation/`. Give the background service
exclusive ownership of writes once it exists; the app talks to it over XPC. Do not let an in-app
actor and a helper both scan `next_fire_at` and hope a unique constraint is sufficient.

Important tables, not a final schema:

- `automations` — identity, current revision, enabled state, indexed next fire and JSON definition;
- `automation_revisions` — immutable approved snapshots;
- `events` — normalized inbox with `(source, external_id)` uniqueness and processing state;
- `occurrences` — deterministic occurrence key and the revision selected for it;
- `runs` — queued/running/terminal state, attempt count, lease owner/deadline and result summary;
- `run_events` — append-only transcript/status/audit events with a monotonic cursor;
- `artifacts` — metadata and bounded paths or blobs;
- `grants` — approved policy revisions and credential references;
- `source_cursors` — last durable position for polling or resumable trigger adapters.

Creating an occurrence and advancing `next_fire_at` is atomic. Claiming a run is a compare-and-swap
from `queued` to `running` with a lease. A worker heartbeats that lease; on restart, the scheduler
reclaims an expired one according to retry policy. Side effects still cannot be made exactly once,
so each run receives a stable idempotency key and connector tools should pass it through where the
remote API supports one.

### Background service on macOS

Package one per-user launch agent inside `Prose.app/Contents/Library/LaunchAgents` and register it
with `SMAppService.agent(plistName:)`. The service owns the store, trigger adapters and workers,
recomputes deadlines after wake, and publishes XPC updates to the app. Apple exposes this bundled,
user-visible registration path on macOS 13 and later, below prose's macOS 15 floor.

Use one service, not one launchd plist per automation. Definitions change too often for executable
installation metadata, and per-job plists would turn a product data operation into code-signing and
Login Items churn.

Registration should be an explicit setting: **Run automations when Prose is closed**. Show the
service's authorization state and a useful remedy if the user disables it under Login Items. In a
source build, phase 1 can run the same scheduler actor inside the app; the service becomes mandatory
before claiming that app-closed execution works.

A local scheduler cannot run while the Mac is powered off. It can reconcile overdue work at next
login or launch. Apple documents that calendar-based launchd work runs after wake from sleep but not
after a powered-off interval; prose's own occurrence reconciliation should make its policy explicit
rather than depending on undocumented timer behavior.

### Run host and presentation

The current `Workspace` is both host-event handler and UI owner. Extract the protocol-neutral pieces
needed by `AutomationRunHost` rather than starting a hidden `Workspace`:

- `AgentSocket`, `AgentProcess` and `SessionRegistry` remain the process/security primitives;
- transcripts are reduced with the existing `Transcript` type;
- agent descendants receive virtual pane ids and the same parent links;
- `pane.read`, wait cursors, child asks/results and interrupts behave as they do in the app;
- every incoming event is appended to `run_events` before being streamed to a client;
- browser panes are rejected with a precise capability error until a headless WebKit host exists.

When Prose is open, it subscribes to run cursors and renders a live automation transcript without
owning the worker. When it is closed, the same events accumulate in SQLite. Opening a historical run
reconstructs the transcript through the existing reducer. A running or completed automation should
never steal pane focus; the user opens it from Automation history or from a notification.

Do not keep a parent pane alive waiting for a scheduled child. The new run is a root owned by the
automation definition, and its result goes to history/delivery. If the authoring pane still exists,
the UI may link to the definition, but that link is presentation, not authority.

---

## 5. Trigger adapters

All adapters have the same contract: resume from a stored cursor if the source permits it, normalize
an event, write it durably, then acknowledge or advance the source cursor. They do not start agents
directly.

Build them in this order:

1. **Internal events.** Run succeeded, failed, cancelled or produced a named result. This exercises
   chaining and dedupe with no external dependency.
2. **Filesystem.** Watch approved directories while online, debounce noisy writes, and rescan from a
   durable directory snapshot after restart. A raw notification alone is not a durable cursor.
3. **Polling connectors.** Mail, calendar, issue trackers and feeds. Store a provider cursor and
   poll on a timed trigger with rate limiting and backoff.
4. **Local app intents.** A URL scheme, CLI or Shortcuts/App Intent inserts an authenticated local
   event or requests `run now`.
5. **Remote webhooks.** Use a small cloud relay that authenticates providers and forwards signed,
   expiring event envelopes. Do not expose an unauthenticated local HTTP listener through NAT and
   call it a webhook system.

Event rules need typed predicates rather than executable expressions: equality, membership, prefix,
numeric comparison and bounded text match over named fields. Version the predicate language. Bound
payload size and redact credential-shaped fields before storing or prompting.

Debounce and throttle mean different things and both should be visible:

- debounce waits for quiet and normally keeps the last event;
- throttle limits how often a rule may fire;
- coalesce combines several matched event ids into one occurrence whose input lists all of them.

---

## 6. Agent and wire surface

Add host calls rather than teaching the Python process to edit a database:

- `automation.propose`
- `automation.list`
- `automation.get`
- `automation.update` (proposal/approval for sensitive changes)
- `automation.enable`
- `automation.delete`
- `automation.run`
- `automation.cancelRun`
- `automation.history`

As with the rest of the protocol, unknown methods remain ignorable by older app builds. Every
mutation names the current session on the wire; the registry authorizes the request before handing
it to the automation service. The committed definition is user-owned, so no ephemeral session id is
stored with it as future authority. Keep creator session/pane only as optional audit metadata.

Expose a small model-facing surface in `agents/prose_agent/tools.py`:

- `prose_schedule` — propose a new automation and wait for its dedicated approval result;
- `prose_schedules` — list definitions or recent runs;
- `prose_change_schedule` — pause, resume, edit, delete or run now, with host approval where needed;
- `prose_cancel_run` — cancel a running occurrence.

Keep schedule fields structured in the tool schema. The agent may turn “tomorrow afternoon” into a
proposal, but the approval card must show the resolved absolute time, zone and next occurrences.
Ambiguous local time should be a validation error or a user question, never a guess hidden behind
“Created.”

Scheduled agents receive a short runtime paragraph containing the automation id/revision, run id,
occurrence, deadline, limits, noninteractive permission behavior and trusted task text. Event payload
is attached as labelled data. Add schedule notifications to the Python loop only for live status;
the service and database, not an asyncio task, remain the source of truth.

Remove SDK `Cron*` from the reachable built-in surface once the prose-owned tools land. Two durable
schedulers with different histories and security rules are worse than one.

---

## 7. User experience and delivery

Add an Automations view reachable from the sidebar/footer. The list should answer at a glance:

- enabled/paused and currently running;
- task title and trigger summary, including time zone;
- next run and last outcome;
- capability profile and destination;
- a warning when the helper is disabled, credentials expired, or approval is needed.

The detail view has four sections: definition, next occurrences, run history, and durable grants.
Actions are pause/resume, edit, run now, duplicate and delete. A run detail reconstructs the normal
transcript, shows attempts and host diagnostics, and can cancel a live run. Retention controls can
delete history without deleting the definition.

Delivery is independent of execution:

- always persist a result summary and transcript cursor;
- optionally post a macOS notification on success, failure or `needsApproval`;
- optionally send through an approved connector destination;
- if delivery fails, retry delivery without rerunning the agent task.

Notifications contain a run id and deep link, not the full potentially sensitive result by default.

---

## 8. Build order

### Phase 0 — settle semantics with pure code

- Add `ProseAutomationCore` types, validators, recurrence engine, event matcher and run-state reducer.
- Add an injectable wall clock and deterministic UUID/idempotency source.
- Write the SQLite schema and migration policy, but keep execution fake.
- Decide and document DST, misfire, retry and concurrency defaults.

**Exit:** given definitions, fake time and fake events, tests produce the exact occurrence and run
state sequence without sleeping or opening the app.

### Phase 1 — manual and in-app timed runs

- Add `AutomationStore`, scheduler actor and fake/real executor seam.
- Add manual, one-time, interval and basic calendar triggers.
- Add Automations list/detail UI and local notifications.
- Add wire methods and the four Python tools with proposal approval.
- While Prose is open, execute a run as a new root agent and persist its complete event stream.

**Exit:** an agent can propose “run this in two minutes,” the user approves a normalized card, one
run appears without stealing focus, and relaunching Prose shows its definition and history. The UI
must label app-closed execution as unavailable in this phase.

### Phase 2 — unattended helper and headless run host

- Add service and runner targets, bundled launch-agent plist, XPC protocol and ServiceManagement UI.
- Move single-writer store/scheduler ownership from the app to the helper.
- Build `AutomationRunHost` from existing host primitives and enforce policy ceilings in Swift and
  Python.
- Add lease heartbeat/recovery, retry/backoff, cancellation trees and wake/login reconciliation.
- Stream live/history events from the helper into the existing transcript reducer.

**Exit:** approve a one-time run, quit Prose, let it fire, reopen Prose and see the terminal result;
repeat across sleep/wake and helper restart. A run requiring an ungranted mutation becomes
`needsApproval` without doing it or spinning.

### Phase 3 — events

- Add durable event inbox and internal automation events.
- Add filesystem adapter with rescan, debounce, coalescing and scope checks.
- Add one polling connector end to end before generalizing connector registration.
- Add authenticated CLI/App Intent ingestion.

**Exit:** duplicate source events create one occurrence; an offline change is discovered on rescan;
event data is visibly separated from instructions; pause and throttle prevent new runs.

### Phase 4 — remote and richer execution

- Add a signed cloud relay only if inbound webhooks or powered-off scheduling justify it.
- Add headless browser execution or explicitly route browser-required runs to an open Prose app.
- Add richer calendar rules, named result schemas, shared templates and multi-device ownership only
  from demonstrated uses.

---

## 9. Tests that make the claim credible

### Pure and persistence tests

- next occurrences across spring-forward, fall-back, leap years, month ends and time-zone changes;
- all misfire and concurrency policies, including hundreds of missed intervals;
- event match, dedupe, debounce, throttle and coalesce with stable occurrence keys;
- state machine rejects illegal transitions and terminal runs stay terminal;
- automation revision snapshot remains unchanged after editing the definition;
- migrations from every shipped schema version and recovery from an interrupted transaction;
- expired leases recover once, while a live lease cannot be claimed twice.

### Permission and containment tests

- create/update cannot commit without the exact approved proposal hash;
- a schedule never stores argv, secret values, pane ids or session tokens;
- path/domain/executable arguments outside a durable grant are denied;
- a child and grandchild inherit the run ceiling; a wider archetype does not widen it;
- `needsApproval` does not retry, and approval plus explicit rerun uses a new policy revision;
- cancellation terminates the root and all descendants;
- event payload cannot become a system prompt or protocol event.

### Integration tests

- fake clock drives the scheduler; no test waits for wall time;
- a fake executor covers queue, lease, retry and delivery independently;
- the real echo agent covers host protocol, persisted transcript and cancellation at no token cost;
- guarded paid E2E covers one real delegated run;
- guarded macOS E2E registers the helper, fires with the app closed, survives sleep/wake and then
  unregisters it;
- crash the service between occurrence insertion, claim, agent result and delivery to verify each
  recovery boundary.

### Operational acceptance

- every run can explain its automation revision and occurrence key;
- every external mutation can explain the durable grant that allowed it;
- disabling an automation prevents future claims immediately;
- deleting an automation has an explicit choice to retain or remove history;
- logging never includes tokens, credential contents or unredacted sensitive event fields;
- database growth is bounded by tested retention and artifact caps.

---

## 10. Decisions to make before Phase 2

1. **Distribution and signing.** `SMAppService` wants a stable bundled helper and the current source
   bundle is assembled by a shell script, carries no Python runtime, and has no settled notarization
   story. The helper design is sound, but packaging cannot be called complete until that decision is.
2. **Background browser support.** Either build an offscreen WebKit host with the same containment
   and page-monitor rules, or declare browser automations “only while Prose is open” until then.
3. **Default durable profile.** `observe` is the safe default; decide whether common notifications
   deserve a separate one-click profile or always require an explicit destination grant.
4. **App launch behavior.** A background run should not activate or open the main window. If the
   helper cannot host a needed capability, decide whether to defer the run or launch Prose visibly;
   never surprise the user by choosing between them implicitly.
5. **History privacy and retention.** Pick default transcript/artifact retention before real mail,
   calendars or documents can enter the event inbox.
6. **Cloud boundary.** If “at this time even when my Mac is off” is a requirement, decide which
   definitions, credentials and outputs may leave the Mac before implementing remote triggers.

---

## 11. Why this shape fits prose

Prose is already a host that allocates processes and panes, carries a forgiving protocol, and gives
parents one level-triggered supervision primitive. Scheduling should preserve those properties:

- the model decides **what** work would help and proposes **when**;
- the user owns durable intent and authority;
- the scheduler decides **which occurrence is due exactly once in local state**;
- the executor creates a fresh, bounded supervision tree;
- events are stored before they wake work;
- presentation can disappear and return without becoming the source of truth.

The tempting shortcut is an asyncio timer that later calls `prose_spawn`. It works only while one
particular pane, socket and app process survive, which is exactly the lifetime mismatch this feature
exists to solve. The design above is more machinery, but each piece answers a failure mode the
current architecture already makes visible: ephemeral ids, kill-on-drop agents, one-session
containment, no persistence, and permission questions that require a person in front of a pane.

### Platform references

- Apple, [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
  and [registering a bundled launch agent](https://developer.apple.com/documentation/servicemanagement/smappservice/agent%28plistname%3A%29).
- Apple, [Updating your app package installer to use the new Service Management API](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api).
- Apple, [Scheduling Timed Jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html),
  especially the different sleep and power-off behavior.
