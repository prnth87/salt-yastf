# SALT(YASTF) Design

## Salesforce Apex Layered Triggers — Yet Another Salesforce Trigger Framework

> Composition-based Salesforce trigger framework. Zero external
> dependencies. Metadata-driven configuration. Handlers opt into
> capabilities via small, stable interfaces. Cross-handler SOQL
> aggregation and coordinated DML are the differentiators.

The architectural validation for the cross-handler aggregation and
Phase 4 batching choices lives in
[`benchmarks/comparative-frameworks-2026-04-07.md`](benchmarks/comparative-frameworks-2026-04-07.md)
and the head-to-head measured section of
[`benchmarks/benchmark-report.md`](benchmarks/benchmark-report.md):
SALT issues 42 % fewer SOQL than fflib/O'Hara and 65 % fewer than TAF
on the same 23-handler workload, with comparable CPU and ~26 % fewer
DML rows. See [`adr/`](adr/) for the decisions that produced those
numbers.

---

## Class Model

```
TriggerDispatcher              (single entry point — TriggerDispatcher.run())
TriggerHandler                 (sole abstract base for all handlers)
    - 7 no-op context methods (beforeInsert/beforeUpdate/.../afterUndelete)
    - getHandlerName() — namespace-normalized
    - manual recursion convenience: hasBeenProcessed/markProcessed

Capability interfaces (handlers opt in by `implements`):
    IRecordFilter      → Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx)
    IRecursionAware    → List<SObjectField> getRecursionFields()
    IQueryAware        → declareQueryNeeds(records, oldMap) + onDataReady(records, oldMap, cache)
    IDmlAware          → onDmlReady(IDmlRegistrar)

Query pipeline primitives:
    QueryBuilder            → fluent .forIds().where().withChildSubquery().tag().build()
    QueryRequest            → value object carried through aggregator + executor
    Predicate               → interface { matches(row); render(BindContext); equalsPredicate(other) }
        FieldFilter             → leaf Predicate, 8 operators
        CompositePredicate      → AND / OR / NOT combinator over Predicate trees
    ChildSubqueryDescriptor → child relationship subquery shape
    BindContext             → bind-name allocator + bindMap during SOQL render
    QueryAggregator         → canMergeOrUnion() gate; merges compatible requests
    QueryExecutor           → renders SOQL, runs Database.queryWithBinds(SYSTEM_MODE)
    QueryResultCache        → 4-level provenance maps; getForHandler(handler, sObj, relField, tag)

DML pipeline primitives:
    IDmlRegistrar / DmlRegistrar  → write-only registration API
    DmlOperation                  → unit of work item
    DmlExecutor                   → topological sort + savepoint commit
    FieldConflict                 → same-value WARN / different-value FAIL detector
    ForeignKeyBinding             → defer-then-resolve FK sequencing
```

---

## Execution Flow

```
TriggerDispatcher.run()
  │
  ├── GUARD: early-return on Platform Event or CDC contexts (excluded from v1)
  ├── LOAD: TriggerHandler__mdt records for the SObject (cached statically per-SObject)
  ├── FILTER: active rows for the current trigger context
  ├── SORT: by Order__c
  ├── INSTANTIATE: Type.forName(normalizedNamespace, className)
  │     - null result + IsCritical=true  → throw TriggerFrameworkException
  │     - null result + IsCritical=false → WARN log + skip
  │     - before-context + IsCritical=false → INFO log: IsCritical is ignored in
  │       before-context (all before-trigger handlers are implicitly critical)
  │     - Bypass check (scoped + AllowBypass__c seal) runs HERE during pre-instantiation;
  │       bypassed handlers never enter any phase.
  │
  ├── PHASE 1 — Record Filtering
  │     For each handler implementing IRecordFilter:
  │       try { isApplicable(newRec, oldRec, ctx) per record }
  │       catch (NPE) { rethrow as TriggerFrameworkException with handler+record context }
  │       Store applicable record IDs per handler.
  │       Zero applicable → mark handler SKIPPED for Phases 2 + 3.
  │
  ├── PHASE 2 — Query Declaration + Aggregation + Execution
  │     For each non-skipped IQueryAware handler in Order__c:
  │       declareQueryNeeds(defensiveCopy(applicableRecords), oldMap)
  │         - applicableRecords = filtered subset if IRecordFilter, else Trigger.new
  │         - delete contexts: applicableRecords = oldMap.values()
  │       Each request goes through QueryAggregator.canMergeOrUnion(a, b).
  │     QueryAggregator merge modes:
  │       REFUSE         — incompatible (FLS mismatch, different SObject/relField,
  │                         child-subquery vs flat WHERE mix, tag collision, mixed null tags)
  │       MERGE_IDENTITY — structurally equal predicate trees → merge by union of ids/fields,
  │                         no OR rendering
  │       MERGE_OR       — different predicate trees → merge by union of ids/fields, render
  │                         predicate as `((handlerA-AND-chain) OR (handlerB-AND-chain))`,
  │                         set wasOrMerged = true
  │       MERGE_SUBSUME  — one side empty filters, other has filters → take empty side as
  │                         base; filtered side's predicates re-applied in-memory by the matcher
  │                         matcher in getForHandler()
  │     Circuit breakers (cascade-adaptive):
  │       SOQL: threshold = limit - soqlReserve - cascadeDepth*soqlPerCascadeLevel
  │       Heap: threshold = limit * 0.75
  │       Over → skip non-critical IQueryAware; if all critical and over → throw
  │              SoqlBudgetException / heap counterpart.
  │     QueryExecutor renders SOQL (with optional child subquery + flat or OR'd predicate
  │       clause), calls Database.queryWithBinds(soql, bindMap, AccessLevel.SYSTEM_MODE),
  │       chunks at 900 ids via QueryRequest.withChunkedIds(chunk) preserving every dimension.
  │     QueryResultCache populated; 4-level provenance maps indexed by
  │       (mergeKey → handler → tag → ids/fields/filters).
  │
  ├── PHASE 3 — Handler Execution (Order__c, single pass)
  │     For each handler:
  │       - SKIPPED / QUERY_SKIPPED → continue
  │       - Recursion guard:
  │           MaxReentrancy__c → invocation counter (applies to ALL handlers)
  │           IRecursionAware + INSERT → invocation counter only (no stable IDs to hash)
  │           IRecursionAware + UPDATE/DELETE → field-hash via length-prefixed concat
  │           No IRecursionAware + no MaxReentrancy → no automatic guard; manual API available
  │       - IQueryAware:
  │           cache.getForHandler(handlerName, sObjectType, relField, tag) — returns SObject
  │           clones limited to the handler's declared field set, with child relationship
  │           collections preserved via deep clone (clone(true,true,true,false)).
  │           If wasOrMerged, the in-memory matcher re-applies the handler's predicates
  │           against the OR-merged row set so each handler sees only the rows that satisfy
  │           ITS filter — not the OR'd union.
  │           Mark (handler, tag) served; per-(handler, tag) eviction releases the merge-key
  │           cache slot when all consumers have read.
  │       - IDmlAware:
  │           registrar.setCurrentHandler(handlerName)
  │           registrar.setBeforeTriggerContext(isBefore)
  │           onDmlReady(registrar) — handler calls registerNew/registerDirty/registerDeleted
  │       - Standard context method (beforeInsert / afterUpdate / etc.) for non-IQueryAware
  │       - Exception handling:
  │           Before-trigger:                  ALL exceptions propagate (mutations to
  │                                            Trigger.new are irrevocable)
  │           After + IsCritical=true:         exception propagates
  │           After + IsCritical=false:        catch, log, continue with remaining handlers
  │
  ├── PHASE 4 — DML Commit (after-trigger contexts only, if any IDmlAware handler ran)
  │     Conflict detection (cross-handler):
  │       same record + same field + same value     → WARN (idempotent register)
  │       same record + same field + different value → FieldConflictException with provenance
  │     Topological sort:
  │       Schema.describe() (DEFERRED option) for FK dependency graph
  │       Plus developer-declared dependencies via registrar.declareDependency(src, tgt)
  │       Cycle detection → CyclicDependencyException
  │     Savepoint → ordered DML → rollback on any failure
  │     UNABLE_TO_LOCK_ROW surfaces as a distinct transient-error message
  │     Error provenance: "field X on record Y set by handler Z"
  │
  ├── ALERTING
  │     Any circuit-breaker firing publishes a TriggerFrameworkAlert__e Platform Event
  │     via Type.forName resolution (no compile-time PE dependency); telemetry failures
  │     are swallowed so they cannot cause secondary failure.
  │
  └── CASCADE MANAGEMENT
        decrementCascadeDepth()
        Prune recursion guard entries for the completing SObjectType
        Active-bypass warning (gated by TriggerTelemetry.isEnabled())
```

---

## Capability Interfaces

### IRecordFilter

```apex
public interface IRecordFilter {
  Boolean isApplicable(SObject newRecord, SObject oldRecord, TriggerContext ctx);
}
```

`newRecord` is null in delete contexts. `oldRecord` is null in
insert/undelete contexts. Built-in implementations:
`FieldChanged`, `FieldNotNull`, `RecordTypeIs`, `CompositeFilter`
(And/Or/Not). All built-ins handle the null cases per this table:

| Built-in            | Insert (old=null)        | Delete (new=null)        | Update                             |
| ------------------- | ------------------------ | ------------------------ | ---------------------------------- |
| FieldChanged(field) | `new.get(field) != null` | `old.get(field) != null` | `new.get(field) != old.get(field)` |
| FieldNotNull(field) | checks new               | checks old               | checks new                         |
| RecordTypeIs(rt)    | checks new               | checks old               | checks new                         |

### IRecursionAware

```apex
public interface IRecursionAware {
  List<SObjectField> getRecursionFields();
}
```

- **INSERT**: field-hash disabled (no stable IDs). Invocation counter
  only, capped by `MaxReentrancy__c` (CMDT default 2).
- **UPDATE / DELETE**: field-hash via length-prefixed concatenation —
  `strVal.length() + ':' + strVal` joined by `|`. Length-prefix
  eliminates delimiter collision risk; zero false-skip rate at scale.
- State pruned on cascade depth decrement.

### IQueryAware

```apex
public interface IQueryAware {
  List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap
  );
  void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  );
}
```

- `applicableRecords` is a defensive copy — handlers cannot mutate
  the framework's list.
- All queries execute in Phase 2 before any handler runs in Phase 3.
  Handler B cannot query data that Handler A mutates in the same
  trigger pass — see [ADR 0005](adr/0005-query-aggregation-and-batch-execution.md).

### IDmlAware

```apex
public interface IDmlAware { void onDmlReady(IDmlRegistrar registrar); }

public interface IDmlRegistrar {
  void registerNew(SObject record);
  void registerNew(SObject record, SObjectField fkField, SObject relatedTo);
  void registerDirty(SObject record, List<SObjectField> dirtyFields);
  void registerDeleted(SObject record);
  void declareDependency(SObjectType source, SObjectType target);
}
```

- **Write-only.** No `getPendingInserts()` / `getPendingUpdates()`.
- **Context-aware.** `registerDirty` in a before-trigger context
  applies directly to `Trigger.new` with conflict detection;
  in an after-trigger context it buffers for Phase 4.
- Conflict detection is symmetrical across phases.

### Interface Evolution Policy

These four interfaces are stable. New capabilities ship as **new
interfaces** (e.g. `IQueryErrorAware`, `ICacheEvictionAware`)
discovered via `instanceof` — never as new methods on existing
interfaces. Apex lacks default methods, so adding methods is the only
breaking move and is therefore prohibited.

---

## Query Pipeline

The query pipeline is the framework's primary differentiator. It
collapses N independent handler queries on the same merge key into
one SOQL execution while preserving per-handler provenance so each
handler sees only the rows it declared interest in.

### Predicate trees

Filters are expressed as `Predicate` trees, not flat AND chains, so
real-world DNF/CNF business rules can be pushed all the way through to
SOQL:

```apex
// "Status IN ('Active','Pending') AND NOT Type='Internal'"
new QueryBuilder('MyHandler')
    .onObject(Account.SObjectType)
    .forIds(parentIds)
    .where(CompositePredicate.andOf(
        CompositePredicate.orOf(
            FieldFilter.equals(Account.Status, 'Active'),
            FieldFilter.equals(Account.Status, 'Pending')
        ),
        CompositePredicate.notOf(FieldFilter.equals(Account.Type, 'Internal'))
    ))
    .build();
```

`Predicate` is the contract:

```apex
public interface Predicate {
  Boolean matches(SObject row);                  // in-memory evaluator
  String render(BindContext ctx);                 // emits SOQL fragment, registers binds
  Boolean equalsPredicate(Predicate other);       // structural equality
}
```

`FieldFilter` is the leaf — 8 operators (`EQUALS, NOT_EQUALS, IN,
NOT_IN, LT, LE, GT, GE`), namespace-qualified field names, JSON-safe
bind values. `CompositePredicate` is the combinator — `andOf(...)`,
`orOf(...)`, `notOf(...)`. Trees are compared by structural equality
for merge eligibility; the renderer always parenthesizes non-leaf
nodes (no precedence guessing).

The in-memory matcher is invoked **only** when the source request was
OR-merged (`wasOrMerged == true`), bounding the matcher's correctness
liability to that fire path. Tier-1 SOQL-parity fixes (Id 15/18-char
normalization, Decimal scale tolerance, case-insensitive String
compare, second-truncated Datetime equality) are built in. Tier-2
combinations that cannot be evaluated reliably in Apex (multi-currency
fields, encrypted fields, cross-object formula references,
geolocation with non-DISTANCE operators) are rejected at factory
time. Tier-3 documented divergences (single-currency conversion,
locale collation, picklist label/API normalization) are loud in
javadoc and accepted as opt-in costs of OR-merge participation.

### Child relationship subqueries

```apex
.withChildSubquery(
    Contact.AccountId,                  // child lookup field
    new Set<SObjectField>{ Contact.Id, Contact.Email },
    /* childFilter   */ FieldFilter.equals(Contact.Status, 'Active'),
    /* childLimit    */ 1
)
```

Renders as `(SELECT Id, Email FROM Contacts WHERE Status =
:__salt_c0 LIMIT 1)`. The framework resolves the child relationship
name from `parentSObjectType.getDescribe().getChildRelationships()`.
Cross-clone preservation in `getForHandler()` uses
`clone(true, true, true, false)` so child collections survive cache
projection — naive `newSObject(id) + put` loops cannot copy child
collections and silently break this path.

### Tags — multiple requests per handler per merge key

When one handler issues two distinct queries against the same merge
key (e.g. an Account handler that both notifies open-Case Contacts and
propagates a rule to opted-in Contacts), each request is disambiguated
by `.tag(name)`:

```apex
new QueryBuilder('AccountHandler').onObject(Contact.SObjectType)
    .forIds(accountIds).tag('open-cases').withChildSubquery(...).build();

new QueryBuilder('AccountHandler').onObject(Contact.SObjectType)
    .forIds(accountIds).tag('rule-targets').where(FieldFilter.equals(Contact.DoNotContact__c, false)).build();
```

`getForHandler(handler, sObj, relField, tag)` returns the right
subset; the cache evicts the merge-key slot only when **every**
`(handler, tag)` consumer has been served.

### 4-level provenance

```
Map<mergeKey, Map<handler, Map<tag, Set<Id>>>>           idsByHandler
Map<mergeKey, Map<handler, Map<tag, Set<SObjectField>>>> fieldsByHandler
Map<mergeKey, Map<handler, Map<tag, List<Predicate>>>>   filtersByHandler
Map<mergeKey, Boolean>                                   wasOrMergedByMergeKey
```

The CSV-based handler-name substrate that earlier versions relied on
is gone — handler names with `,` corrupted the index and there was no
structured per-handler retrieval path. Provenance is now structured
end-to-end, set into the cache at populate time, and consulted by
`getForHandler` to project rows down to each handler's declared field
set via deep clone + field strip.

### Per-(handler, tag) eviction

`QueryResultCache.markHandlerTagServed(handler, tag)` marks one
consumer done; when **all** declared `(handler, tag)` consumers for a
merge key have been served, the row list and per-handler structures
are released. This is the heap-safety mechanism that makes OR-merge
viable at scale (otherwise OR-merged rows accumulate across cascade
depth and consume the heap).

### System mode by default; FLS opt-in

Every `Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE)`
call passes `SYSTEM_MODE` explicitly — not for security, but for API
version stability. API 60+ may default to `USER_MODE` which would
silently enforce FLS+sharing and break trigger handlers that today
rely on system-mode SOQL semantics. Trigger context already has no
privilege boundary between handlers (all handlers run as the same
running user with the same FLS/CRUD/sharing); the framework introduces
zero new privilege escalation surface that direct Apex SOQL doesn't
already have. See [ADR 0001](adr/0001-query-pipeline-integrity-posture.md).

`withFLS()` is the opt-in for non-trigger callers (Queueable, batch,
controller `@AuraEnabled`, integration callouts) that invoke the
query pipeline directly outside the trigger pipeline.

---

## Bypass API (Scoped + Sealed)

```apex
public class TriggerDispatcher {
  static void bypass(Type handlerType);
  static void bypass(Type handlerType, SObjectType sObjectType);
  static void bypass(Type handlerType, SObjectType sObjectType, TriggerContext ctx);

  static void bypassForNextDmlEvent(Type handlerType);   // auto-clears after one DML event

  static void clearBypass(Type handlerType);
  static void clearAllBypasses();
}
```

- `AllowBypass__c` on the CMDT row: when `false`, the handler **cannot**
  be bypassed by any mechanism. The seal is enforced in the
  pre-instantiation bypass check.
- All `bypass()` calls log at WARN with caller stack trace.
- Active-bypass warnings are emitted at end-of-dispatcher when
  `TriggerTelemetry.isEnabled()`.
- Type-safe only. String-based bypass (`bypass("X")`) is not
  supported — eliminates the cross-namespace privilege-escalation
  vector.

---

## Custom Metadata: TriggerHandler__mdt

| Field                  | Type         | Default  | Purpose                                                                          |
| ---------------------- | ------------ | -------- | -------------------------------------------------------------------------------- |
| SObjectType__c         | Text(80)     | required | SObject API name                                                                 |
| HandlerClass__c        | Text(255)    | required | Fully qualified class name                                                       |
| Namespace__c           | Text(15)     | blank    | Managed-package namespace (blank → null)                                         |
| Order__c               | Number(3,0)  | required | Execution sequence (10, 20, 30 …)                                                |
| IsActive__c            | Checkbox     | true     | Master on/off                                                                    |
| BeforeInsert__c        | Checkbox     | false    | Per-context enablement                                                           |
| BeforeUpdate__c        | Checkbox     | false    |                                                                                  |
| BeforeDelete__c        | Checkbox     | false    |                                                                                  |
| AfterInsert__c         | Checkbox     | false    |                                                                                  |
| AfterUpdate__c         | Checkbox     | false    |                                                                                  |
| AfterDelete__c         | Checkbox     | false    |                                                                                  |
| AfterUndelete__c       | Checkbox     | false    |                                                                                  |
| BypassPermission__c    | Text(80)     | blank    | Custom Permission API name granting bypass authority                             |
| BypassUsers__c         | LongTextArea | blank    | Comma-separated User IDs                                                         |
| BypassProfiles__c      | LongTextArea | blank    | Comma-separated Profile IDs                                                      |
| AllowBypass__c         | Checkbox     | true     | When false, handler cannot be bypassed                                           |
| MaxReentrancy__c       | Number(2,0)  | 2        | Invocation counter cap (applies to ALL handlers)                                 |
| CascadeDepthLimit__c   | Number(2,0)  | 3        | Maximum trigger nesting depth                                                    |
| IsCritical__c          | Checkbox     | true     | If false, skippable by circuit breaker; ignored in before-trigger contexts       |

---

## Circuit Breakers

### SOQL — cascade-adaptive, configurable

```
soqlReserve            : TriggerDispatcher.setSoqlReserve(n),               default 10
soqlPerCascadeLevel    : TriggerDispatcher.setSoqlReservePerCascadeLevel(n), default 10

threshold = Limits.getLimitQueries() - soqlReserve - (cascadeDepth * soqlPerCascadeLevel)

Over threshold → skip non-critical IQueryAware handlers
              → if still over and all remaining are critical → SoqlBudgetException
```

### Heap — auto-adapts sync/async

```
threshold = Limits.getLimitHeapSize() * 0.75
// sync = 4.5 MB, async = 9 MB — auto-detected from Limits
Over threshold → same skip / throw behavior
```

### CPU — per-handler check during Phase 3 execution

```
cpuThresholdFraction : TriggerDispatcher.setCpuThresholdFraction(f), default 0.75
threshold = Limits.getLimitCpuTime() * cpuThresholdFraction
// default = 7,500 ms (75 % of the 10,000 ms synchronous limit)

Checked PER HANDLER as Phase 3 progresses (not once-per-phase like SOQL/heap).
Over threshold:
  non-critical handler in after-trigger context → skip + WARN log
  critical handler OR before-trigger context    → WARN log only ("approaching limit")
```

The CPU breaker is the only breaker that checks **incrementally** as
handlers execute, because CPU consumption is path-dependent in a way
that SOQL count and heap size are not. The trade-off is that it makes
the dispatcher's behavior **path-dependent**: small CPU variations
across runs (e.g. profiling overhead, JIT warmup, concurrent org
load) can change which handler is executing when the threshold is
crossed, producing structurally different downstream cascades.

For benchmark / regression-test runs where deterministic output is
required, raise the threshold above the governor limit:

```apex
TriggerDispatcher.setCpuThresholdFraction(2.0);  // disables the CPU breaker
```

The benchmark driver `scripts/benchmarks/run-benchmarks.apex` does
this automatically.

### Alerting

`Type.forName('TriggerFrameworkAlert__e')` is used so the dispatcher
has no compile-time dependency on the Platform Event. If the PE is
not deployed, the breaker degrades to a `System.debug(WARN, …)` log.
`EventBus.publish` failures are swallowed — telemetry must never
cause secondary failure.

---

## Exception Handling Contract

| Context            | IsCritical__c = true                     | IsCritical__c = false                                                                                                               |
| ------------------ | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **Before-trigger** | Exception propagates (transaction fails) | Same — `IsCritical` ignored. All before-trigger handlers are implicitly critical (mutations to `Trigger.new` are irrevocable). INFO log emitted if `IsCritical=false` is set. |
| **After-trigger**  | Exception propagates (transaction fails) | Exception caught, logged, handler skipped. Remaining handlers continue. Phase 4 savepoint protects any pending DML.                 |

Before-trigger mutations cannot be rolled back inside the trigger pass,
so partial execution with a failed handler leaves inconsistent field
state with no recovery path. Fail-fast is the only safe behavior.

---

## Architecture Decisions

The decisions that shape the framework live as numbered ADRs in
[`adr/`](adr/):

| ADR  | Title | What it locks |
|------|-------|---------------|
| [0001](adr/0001-query-pipeline-integrity-posture.md) | Query pipeline integrity posture | System mode by default; FLS opt-in only via `withFLS()`; no privilege boundary between handlers in trigger context |
| [0002](adr/0002-net-new-framework.md) | Net-new framework rather than fork | Why SALT isn't a fork of fflib / TAF / O'Hara; what each framework solves; what SALT adds |
| [0003](adr/0003-composition-and-specification.md) | Composition over inheritance + Specification pattern | Single base class with opt-in interfaces (not deep hierarchy); `IRecordFilter` as Specification |
| [0004](adr/0004-phase-4-dml-batching.md) | Phase 4 DML batching with cross-handler conflict detection | Why DML defers to a Phase 4 commit; how field-conflict provenance and topological FK ordering work |
| [0005](adr/0005-query-aggregation-and-batch-execution.md) | Query aggregation with structured provenance and per-tag eviction | The batch-query-then-execute model, the 4-level provenance maps, the per-`(handler, tag)` eviction mechanism |
| [0006](adr/0006-predicate-trees-and-or-merge.md) | Predicate trees + cross-handler OR-merge with in-memory matcher | Why filter pushdown uses Predicate trees rather than flat AND chains; how OR-merge unions field sets and reapplies the matcher |
