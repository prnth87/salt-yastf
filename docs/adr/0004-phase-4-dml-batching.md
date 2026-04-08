# ADR 0004 — Phase 4 DML batching with provenance and conflict detection

## Status

Accepted.

## Context

When N handlers on the same SObject each issue inline DML, three
problems compound:

1. **DML count.** Each handler's `update someList` consumes a DML
   statement against the 150-statement governor. The 23-handler
   workload blows the limit at modest cascade depth.
2. **Cascade multiplication.** Each inline DML on a parent SObject
   fires the parent's trigger cascade *immediately* before the next
   handler in the chain runs. A second handler that updates the
   same parent fires a *second* cascade. The cascade chain
   amplifies linearly with the number of inline-DML handlers, even
   when the handlers are mutually consistent.
3. **Silent conflicts.** Two handlers on the same trigger context
   that both write the same field on the same record have no way to
   notice each other. Whoever runs second wins; the first
   handler's write is silently overwritten with no error and no
   audit trail.

The 3-run whiteroom measurement against O'Hara and TAF (which both
run inline DML) confirms problems 1 and 2 are real on the 23-handler
workload: O'Hara writes 4,800 DML rows vs SALT's 3,600, and the
cascade chain produces 12 Account BU/AU fires (vs 6 in SALT/fflib) —
each extra fire re-instantiates every handler in the chain.

## Decision

DML registered by `IDmlAware` handlers in **after-trigger contexts**
defers to a **Phase 4 commit** that runs once at the end of the
trigger pass:

1. Each handler's `onDmlReady(IDmlRegistrar)` callback registers
   intent — `registerNew`, `registerDirty`, `registerDeleted` — into
   a write-only registrar that tags every operation with the
   declaring handler name.
2. **Cross-handler conflict detection** (`FieldConflict`) runs at
   register time. Two `registerDirty` calls on the same record-field
   combination:
   - **Same value** → WARN log (idempotent register; later handler
     becomes a no-op).
   - **Different values** → `FieldConflictException` with full
     provenance: "field X on record Y was set to A by handler P
     and to B by handler Q."
3. **Topological sort** (`DmlExecutor`) orders the deferred
   operations by FK dependency:
   - `Schema.describe(SObjectDescribeOptions.DEFERRED)` extracts the
     parent-child graph for the touched SObjectTypes.
   - Plus developer-declared dependencies via
     `registrar.declareDependency(source, target)`.
   - Cycle detection → `CyclicDependencyException`.
4. **Savepoint → ordered DML → rollback on any failure.** The
   commit is atomic with respect to the trigger pass.
5. **`UNABLE_TO_LOCK_ROW`** surfaces as a distinct
   `DmlCoordinationException` message — it's a transient platform
   failure, not a handler bug, and the distinct message lets retry
   middleware classify it correctly.
6. **Error provenance.** Any DML failure attaches the registering
   handler name to the error message for fast root-cause attribution.

**Before-trigger contexts** are different. `registerDirty` in a
before-trigger context applies *directly* to `Trigger.new` (no
buffering — the mutations must land before the platform writes the
records). Conflict detection runs there too, with the same
same-value/different-value semantics. The framework distinguishes
the two cases via `registrar.setBeforeTriggerContext(isBefore)`
called by the dispatcher before each handler's `onDmlReady`.

## Consequences

- **DML count batches by SObjectType, not by handler.** Five
  handlers updating Account in the same after-trigger context
  produce 1 DML statement, not 5.
- **Cascade chains shrink.** A single batched Account update fires
  the Account cascade once instead of 5 times. The 2026-04-08
  measurement shows SALT and fflib at ~6 cascade fires vs O'Hara/TAF
  at ~12 — half the cascade overhead, half the re-instantiated
  handler invocations.
- **Conflicts surface at runtime, not in production.** Tests catch
  the `FieldConflictException` immediately; the same-value WARN
  case is logged but doesn't fail the transaction (idempotent
  registration is a legitimate pattern).
- **DML ordering is correct by construction.** Parent-then-child FK
  ordering doesn't depend on handler `Order__c` discipline; the
  topological sort guarantees it regardless of registration order.
- **Atomic rollback.** A Phase 4 failure rolls back the entire
  Phase 4 commit. Earlier-phase Trigger.new mutations from
  before-trigger handlers are not rolled back (they're already
  applied to the platform-managed in-memory record); only the
  Phase 4 deferred DML rolls back.

## Trade-offs

- **`IDmlAware` handlers cannot read Phase 4 results.** The
  registrar is **write-only by design** — no `getPendingInserts()`,
  no `getPendingUpdates()`. This eliminates a class of handler-order
  bugs ("Handler B reads Handler A's pending insert and gets
  inconsistent state") but means handlers cannot chain DML
  observations within a single trigger pass. Use the cascade if
  you need to read what was written.
- **Before-trigger conflict detection is symmetrical but eager.**
  Two handlers writing the same field with different values in a
  before-trigger context throw immediately — even if a third
  handler later in `Order__c` would have overwritten both. This is
  a deliberate fail-fast: silent overwrites in before-trigger
  context are the kind of bug that takes weeks to track down.

## Validation

| Metric | SALT | fflib | O'Hara | TAF |
|---|---|---|---|---|
| DML statements | **21** | 25 | 24 | 24 |
| DML rows | **3,600** | **3,600** | 4,800 | 4,800 |
| Account BU + AU fires | **6 + 6** | **6 + 6** | 12 + 12 | 12 + 12 |

SALT and fflib (both batch DML by SObjectType) tie on row count.
O'Hara and TAF write 33 % more rows because each inline-DML cascade
re-touches records that the batched commit would have written once.
SALT issues 4 fewer DML statements than fflib because `DmlExecutor`
consolidates DML across SObjectTypes within a single Phase 4 commit
where fflib's UoW does one `commitWork()` per `onAfter*` Domain
method call.

## References

- `force-app/main/default/classes/DmlRegistrar.cls`
- `force-app/main/default/classes/DmlExecutor.cls`
- `force-app/main/default/classes/DmlOperation.cls`
- `force-app/main/default/classes/FieldConflict.cls`, `FieldConflictException.cls`
- `force-app/main/default/classes/CyclicDependencyException.cls`
- `force-app/main/default/classes/ForeignKeyBinding.cls`
- `benchmarks/comparative-frameworks-2026-04-07.md` § 3.2 DML — measured
