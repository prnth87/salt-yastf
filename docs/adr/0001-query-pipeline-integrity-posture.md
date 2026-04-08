# ADR 0001 — Query Pipeline Integrity Posture

- **Status:** Accepted
- **Scope:** SALT(YASTF) Query Pipeline (`QueryExecutor`, `QueryRequest`, `QueryBuilder`, `QueryResultCache`)

## Context

The SALT(YASTF) trigger framework runs handler logic inside Apex trigger
context. In trigger context, `Trigger.new` and `Trigger.old` are populated by
the platform regardless of the running user's Field-Level Security (FLS) — the
pipeline is therefore *already* operating against fully-populated SObjects
before any handler-issued query runs. Layering FLS enforcement on top of
follow-up SOQL would be inconsistent with the data the handlers already see.

At the same time, the framework's query primitives (`QueryBuilder`,
`QueryExecutor`) are reusable assets: handler authors may also use them from
Queueables, batch jobs, controllers, and REST endpoints where the running
user's FLS *does* matter and where bypassing it would be a defect.

This ADR records the decisions that govern how the Query Pipeline reconciles
those two contexts and what guarantees are (and explicitly are not) provided.

## Decision

### 1. System-mode default in trigger context

Every `Database.queryWithBinds(...)` call site in `QueryExecutor` passes
`AccessLevel.SYSTEM_MODE` explicitly. This matches the integrity posture
of `Trigger.new`: handlers see a coherent, fully-populated view of the
records they were dispatched on and any related data the framework
fetches on their behalf.

### 2. `AccessLevel.SYSTEM_MODE` is API-version stability, not a security choice

`Database.queryWithBinds` may default to `USER_MODE` on newer API versions.
Passing `SYSTEM_MODE` explicitly pins the executor's behavior across API
upgrades and prevents a silent, version-driven flip from trigger-shaped
"system" behavior to user-mode FLS enforcement that handler authors would
not have anticipated.

### 3. `enforceFLS=true` (`.withFLS()`) is opt-in

`QueryBuilder.withFLS()` sets `QueryRequest.enforceFLS = true`. When set,
`QueryExecutor.buildSOQLAndBinds` performs an explicit field-by-field
`isAccessible()` gate before issuing the SOQL. This is the supported escape
hatch for non-trigger callers (Queueable, batch, controllers, REST) where
the running user's FLS is the relevant authorization boundary.

`enforceFLS` defaults to `false` so trigger handlers do not have to think
about it. Non-trigger callers must opt in deliberately.

### 4. FLS gate scope = fields ∪ predicateFields ∪ childSubqueryFields

When `enforceFLS=true`, the FLS gate walks the union of:

- `req.fields` — top-level SELECT fields
- `req.relationshipField` — when filtering on a relationship
- every `FieldFilter.field` reached by recursing the `req.filters` predicate
  tree
- `req.childSubquery.childFields` and any `FieldFilter` reached by recursing
  `req.childSubquery.childFilter`

Gating only the SELECT fields would leak information about
inaccessible fields via the WHERE clause: a caller could observe row counts
under different filter shapes and infer the value of a field they have no
read access to. Including predicate-leaf fields in the FLS gate closes that
oracle inference channel.

### 5. No per-handler privilege boundary in trigger context

`QueryResultCache.getForHandler(handler, ...)` is **not** an authentication
or authorization gate. In trigger context all handlers run as the same
running user with the same FLS, CRUD, and sharing posture; the handler name
is a self-declared string with no platform-level identity backing.

The framework adds zero new privilege escalation surface compared to a
handler issuing direct Apex SOQL. What `getForHandler` *does* provide:

- per-(handler, tag) declared scope tracking, so a handler only sees rows
  it asked for — a *correctness* guarantee
- a deep-clone return path so one handler's mutations cannot bleed into
  another handler's view of the same merged result — a *correctness* and
  *integrity* guarantee
- a conditional in-memory matcher under OR-merge so a handler doesn't
  accidentally see rows that belong only to the other branch of an OR
  merge — a *correctness* guarantee

None of these are privilege boundaries. They are integrity guarantees.

### 6. "Security" findings reframed as correctness

Several adversarial-panel findings during query pipeline design review were
labeled "security". On closer inspection these are concerns about:

- handler-author surprise when shared cache slots leak rows
- correctness of OR-merge isolation under concurrent declarations
- integrity of bind-name allocation under nested predicate composition

These are genuine concerns and are addressed by the rules above. They are
**not** privilege escalation. The ADR records this distinction so future
reviewers do not re-litigate the trigger-context system-mode decision under
a misapplied threat model.

## Consequences

**Positive:**

- Trigger handlers continue to work in system mode without surprise.
- Non-trigger callers have a clear, explicit FLS opt-in.
- API version upgrades cannot silently flip access semantics.
- The FLS gate scope is closed against predicate-shape inference oracles.

**Negative / Accepted:**

- Handler authors who *want* user-mode in trigger context must build their
  own SOQL — the framework does not offer a per-call user-mode toggle.
- The deep-clone return path under OR-merge may carry top-level fields
  beyond the consumer's declared field set. This is a deliberate trade-off:
  preserving child collections from `withChildSubquery` takes precedence
  over strict top-level field isolation under OR-merge, because Apex's
  only feasible field-stripping path (`JSON.serialize` round-trip) loses
  child collections. Handler authors should treat the returned SObjects as
  read-only projections of the cached rows.
