# ADR 0005 — Query aggregation, structured provenance, per-(handler, tag) eviction

## Status

Accepted.

## Context

When N handlers on the same SObject each independently query the
same related object, the framework either:

1. **Lets each handler issue its own SOQL.** Simple, but a 23-handler
   workload with 4 handlers all needing `Contacts WHERE AccountId IN
   :ids` consumes 4 SOQL statements per cascade level. At cascade
   depth 3 with multiple merge groups, the 100-statement governor is
   the production bottleneck.
2. **Pushes query definitions into a Selector layer (fflib)** so all
   `AccountsSelector.selectByX(ids)` calls go through one method.
   This centralizes *definitions* but doesn't aggregate
   *executions* — two callers of the same Selector method still
   issue two SOQL statements.
3. **Batch-collects query intent across all handlers in Phase 2,
   merges compatible requests, executes the minimum set of SOQL
   statements, and dispatches the results back to each handler with
   a per-handler view of the data.** This is what the framework
   does, and it's the primary differentiator that justifies the
   existence of SALT vs. forking an existing framework.

The mechanism has four hard constraints:

- **Provenance must survive merging.** After two handlers' requests
  merge into one SOQL, each handler must still be able to ask for
  *only the rows it declared interest in*. Earlier versions used a
  CSV-joined string of handler names as the provenance substrate;
  handler names containing `,` corrupted the index, and there was no
  structured per-handler retrieval path.
- **Field projection must work without copying.** A handler that
  declared `{Account.Id, Account.Name}` should not see fields
  declared by other handlers in the same merge group, even if those
  fields were fetched by the merged SELECT. Cloning is required
  but `SObject.put` cannot copy child relationship collections —
  the naive `newSObject(id) + put` loop silently breaks any handler
  that uses `withChildSubquery`.
- **Heap must stay bounded.** OR-merged queries fetch the union of
  every participating handler's row set. If the cache holds those
  rows for the lifetime of the trigger pass — and the cascade adds
  more merge groups at each level — heap grows linearly with
  cascade depth and explodes the 6 MB sync limit.
- **Failure semantics must be explicit.** A handler asking for data
  that was evicted, or for a `(handler, mergeKey, tag)` it never
  declared, must get a typed exception — not silent empty data
  that produces a hard-to-diagnose downstream bug.

## Decision

A four-piece query pipeline rooted in **structured per-handler
provenance**:

### 1. The merge gate — `QueryAggregator.canMergeOrUnion(a, b)`

Single precondition gate consulted by every merge path. Returns:

- `REFUSE` — incompatible. First check is FLS-mismatch (must never
  merge a `withFLS()` request with a system-mode request); then
  different SObject / relationship field; then filter-shape
  incompatibility (`withChildSubquery` cannot mix with flat WHERE);
  then tag collision (same handler + same tag is a programmer error);
  then mixed null-tag and non-null-tag within the same `(handler,
  mergeKey)`.
- `MERGE_IDENTITY` — predicate trees are structurally equal. Merge
  by union of ids and fields, no OR rendering needed.
- `MERGE_OR` — predicate trees differ on both sides. Union ids and
  fields; render the predicate clause as `((handlerA-AND-chain) OR
  (handlerB-AND-chain))`; set `wasOrMerged = true`.
- `MERGE_SUBSUME` — exactly one side has empty filters and the other
  has filters. Take the empty-filter side as the base SOQL; the
  filtered side's predicates are stored in `filtersByHandler` and
  re-applied in-memory by the matcher when the filtered handler
  retrieves its rows.

The gate **never mutates inputs** and always returns a new
`QueryRequest` with new maps. Earlier versions had subtle bugs from
in-place merging (one bug-hunt round identified `idsByHandler`
keying ambiguity that traced back to mutated state).

### 2. Structured 4-level provenance

```
Map<mergeKey, Map<handler, Map<tag, Set<Id>>>>           idsByHandler
Map<mergeKey, Map<handler, Map<tag, Set<SObjectField>>>> fieldsByHandler
Map<mergeKey, Map<handler, Map<tag, List<Predicate>>>>   filtersByHandler
Map<mergeKey, Boolean>                                   wasOrMergedByMergeKey
```

The CSV substrate is **deleted entirely** — `QueryAggregator` no
longer joins handler names with `,`, and `QueryResultCache` no
longer calls `.split(',')`. Provenance is structured end-to-end.

The `tag` dimension exists because a single handler may declare two
distinct queries against the same merge key (e.g. an Account handler
that both notifies open-Case Contacts via `withChildSubquery` and
propagates a rule to opted-in Contacts via flat WHERE — same merge
key `Contact|AccountId`, different filter shapes, not OR-mergeable).
The disambiguation parameter is the tag.

### 3. `getForHandler(handler, sObj, relField, tag)` — projection + matcher

The retrieval path:

1. Throw `TriggerFrameworkException` if the merge key is evicted, if
   the handler never declared on this merge key, if the tag is
   ambiguous (multiple tags exist and caller passed `null`), or if
   the resolved tag is unknown.
2. Pull rows by id or by relationship field via lazy-built indices
   (`ensureIdIndex` / `ensureRelIndex`).
3. **If the source request was OR-merged**, run the matcher: walk
   the handler's `Predicate` list and re-apply each one to each row,
   filtering down to the rows that satisfy *this handler's*
   predicate (not the OR'd union the SOQL fetched).
4. **Deep-clone with field strip.** Use
   `row.clone(true, true, true, false)` (preserveId,
   deep, preserveReadonlyTimestamps, no autonumber) and then strip
   undeclared top-level fields. The deep clone preserves
   `childSubquery` collections; the field strip enforces
   per-handler field isolation.

### 4. Per-`(handler, tag)` eviction — `markHandlerTagServed(handler, tag)`

Each handler that consumes its data calls
`markHandlerTagServed(handler, tag)` (the framework calls this
automatically after `onDataReady` returns). When *all* declared
`(handler, tag)` consumers for a merge key have been served, the
row list and per-handler structures for that merge key are
released. This bounds heap growth even under deep cascades — the
cache is always sized to "active consumers", never to "everything
fetched in this pass".

## Consequences

- **One SOQL per merge group, not one SOQL per handler.** The
  primary win. The 2026-04-08 measurement shows SALT issuing 11
  SOQL where fflib/O'Hara issue 19 and TAF issues 31 on the same
  workload (42 % / 65 % reductions).
- **Handlers see exactly what they declared.** No accidental
  cross-handler field leakage. The clone-and-strip path enforces
  the field set even when the underlying SOQL fetched the union.
- **Heap stays bounded across cascade depth.** Per-tag eviction
  releases merge-key slots as consumers finish, so the cache never
  accumulates rows from levels the trigger has already exited.
- **Failure modes are typed.** Cache evicted, unknown handler,
  ambiguous tag — each throws a distinct exception with enough
  context to diagnose without re-running with debug logs.

## Trade-offs

- **Handlers see pre-modification data.** All queries execute in
  Phase 2 *before* any handler runs in Phase 3. Handler B cannot
  query data that Handler A mutates in the same trigger pass. This
  is the core tension of the batch-query-then-execute model and is
  the single largest semantic difference from inline-SOQL
  frameworks. The escape hatch is to do field-mutating logic in a
  Layer 0 handler (extends `TriggerHandler` only, no `IQueryAware`)
  or to split the operation across trigger contexts.
- **Field enforcement is test-time only.** Production handlers can
  read undeclared fields silently; the framework does not gate the
  SObject API at runtime to enforce the declared field set. This
  is an explicit heap trade-off (field-access tracking would
  require a wrapping SObject layer with non-trivial cost). The
  test base provides a hook for static analysis; production never
  pays for it.
- **Defensive copy of `applicableRecords` on every handler call.**
  ~0.02ms per handler. Negligible cost; eliminates a class of
  inter-handler list-mutation bugs that were extremely difficult to
  diagnose under the old shared-list model.
- **`QueryBuilder.forIds()` is mandatory.** `QueryBuilder.build()`
  throws if no IDs are set. Unbounded SOQL in trigger context is
  never correct. If a handler genuinely needs an unscoped query,
  the path is a separate `Database.queryWithBinds` call outside
  the framework's pipeline — not a framework feature.

## Validation

The 23-handler enterprise workload:

| Metric | SALT | fflib | O'Hara | TAF |
|---|---|---|---|---|
| **SOQL** | **11** | 20 | 20 | 32 |
| Merge groups collapsed | 5 → 5 SOQL | 5 → ~15 SOQL | 5 → ~15 SOQL | 5 → ~18 SOQL |
| DML rows | **3,600** | **3,600** | 4,800 | 4,800 |
| CPU (median, profiled) | 7,770 ms | 6,842 ms | 9,489 ms | 8,698 ms |

fflib achieves slightly lower CPU on this workload because it pays
no per-trigger framework overhead, but at the cost of 82 % more SOQL
— and SOQL is the production bottleneck most orgs hit first.

## References

- `force-app/main/default/classes/QueryRequest.cls`
- `force-app/main/default/classes/QueryBuilder.cls`
- `force-app/main/default/classes/QueryAggregator.cls`
- `force-app/main/default/classes/QueryExecutor.cls`
- `force-app/main/default/classes/QueryResultCache.cls`
- `DESIGN.md` § Query Pipeline
- ADR 0001 — query pipeline integrity posture (system mode default)
- ADR 0006 — Predicate trees + OR-merge (the predicate-tree side of this story)
