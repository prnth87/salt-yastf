# SALT(YASTF) Query Pipeline — Knowledge Documentation

> Comprehensive technical reference covering the query subsystem's architecture,
> algorithms, data flow, handler authoring patterns, architectural trade-offs,
> and framework comparison. Intended for developers working on or with the
> framework internals.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Class Reference](#2-class-reference)
3. [Data Flow — End to End](#3-data-flow--end-to-end)
4. [The Merge Key](#4-the-merge-key)
5. [QueryBuilder — The Handler's Entry Point](#5-querybuilder--the-handlers-entry-point)
6. [QueryRequest — The Immutable Contract](#6-queryrequest--the-immutable-contract)
7. [Predicate System](#7-predicate-system)
8. [QueryAggregator — The Merge Gate](#8-queryaggregator--the-merge-gate)
9. [Hashing — Where and Why](#9-hashing--where-and-why)
10. [QueryExecutor — SOQL Rendering and Execution](#10-queryexecutor--soql-rendering-and-execution)
11. [QueryResultCache — Storage, Retrieval, and Eviction](#11-queryresultcache--storage-retrieval-and-eviction)
12. [Tags — The Provenance Dimension](#12-tags--the-provenance-dimension)
13. [Multi-Object Queries From a Single Handler](#13-multi-object-queries-from-a-single-handler)
14. [Handler-Specific Result Isolation](#14-handler-specific-result-isolation)
15. [Kahn's Algorithm — DML Topological Sort](#15-kahns-algorithm--dml-topological-sort)
16. [Circuit Breakers and Governor Limit Management](#16-circuit-breakers-and-governor-limit-management)
17. [Architectural Analysis — Is This an Anti-Pattern?](#17-architectural-analysis--is-this-an-anti-pattern)
18. [Predicate Scenario Benchmark](#18-predicate-scenario-benchmark)
19. [Trade-Offs and Accepted Costs](#19-trade-offs-and-accepted-costs)

---

## 1. Architecture Overview

The query pipeline is Phase 2 of the `TriggerDispatcher`'s 4-phase execution model:

```
Phase 1: Record Filtering       (IRecordFilter — which records apply?)
Phase 2: Query Pipeline          (IQueryAware — declare, aggregate, execute, cache)
Phase 3: Handler Execution       (onDataReady / context methods + IDmlAware)
Phase 4: DML Commit              (DmlExecutor — topologically sorted, atomic)
```

Phase 2 follows a **declare → aggregate → execute → cache** pipeline:

```
Handler.declareQueryNeeds()          ← each handler declares independently
    └─ QueryBuilder.build() → QueryRequest(s)
         └─ QueryAggregator.addRequests()
              └─ QueryAggregator.getMergedRequests()
                   └─ QueryExecutor.execute()
                        └─ QueryResultCache.populate()
                             └─ Handler.onDataReady(cache)  [Phase 3]
                                  └─ cache.getForHandler() / cache.getRelated()
```

The core value proposition: **N handlers declaring queries against the same object get merged into fewer SOQL statements**, transparently, with per-handler result isolation preserved through provenance tracking.

---

## 2. Class Reference

### Core Pipeline Classes

| Class | File | Purpose |
|-------|------|---------|
| `QueryBuilder` | `QueryBuilder.cls` | Fluent builder — handler's API for constructing `QueryRequest` objects |
| `QueryRequest` | `QueryRequest.cls` | Immutable data contract carrying query intent + 4-level provenance maps |
| `QueryAggregator` | `QueryAggregator.cls` | Merge gate — groups, classifies, and merges compatible requests |
| `QueryExecutor` | `QueryExecutor.cls` | Renders SOQL, manages chunking, enforces FLS, executes queries |
| `QueryResultCache` | `QueryResultCache.cls` | Stores results, builds lazy indexes, isolates per-handler retrieval, manages eviction |
| `BindContext` | `BindContext.cls` | Per-query bind variable allocator (`__salt_p0`, `__salt_c0`, ...) |

### Predicate System

| Class | File | Purpose |
|-------|------|---------|
| `Predicate` | `Predicate.cls` | Interface: `matches()`, `render()`, `equalsPredicate()`, `getStructuralHash()` |
| `FieldFilter` | `FieldFilter.cls` | Leaf predicate — single field + operator + value |
| `CompositePredicate` | `CompositePredicate.cls` | AND/OR/NOT combinator with max depth 16 |

### Supporting Types

| Class | File | Purpose |
|-------|------|---------|
| `ChildSubqueryDescriptor` | `ChildSubqueryDescriptor.cls` | Value type for child subqueries in parent SELECT |
| `IQueryAware` | `IQueryAware.cls` | Handler contract: `declareQueryNeeds()` + `onDataReady()` |

### Exceptions

| Class | Thrown When |
|-------|------------|
| `TriggerFrameworkException` | Validation failures, cache errors, tag collisions |
| `SoqlBudgetException` | SOQL circuit breaker trips (executor or dispatcher) |
| `FlsException` | Field-level security check failure |

### Dependency Graph

```
QueryBuilder
    └─▶ QueryRequest
         ├─▶ Predicate (interface)
         │    ├─▶ FieldFilter (leaf)
         │    └─▶ CompositePredicate (AND/OR/NOT)
         └─▶ ChildSubqueryDescriptor

QueryAggregator
    ├── Input: List<QueryRequest>
    ├── Uses: CompositePredicate.orOf() for n-way OR
    ├── Uses: Predicate.getStructuralHash() for fast equality
    └── Output: List<QueryRequest> (merged)

QueryExecutor
    ├── Input: List<QueryRequest>
    ├── Creates: BindContext per request
    ├── Uses: Predicate.render(ctx), ChildSubqueryDescriptor.render(ctx)
    ├── Uses: Database.queryWithBinds(soql, bindMap, SYSTEM_MODE)
    └── Output: Map<mergeKey, List<SObject>>

QueryResultCache
    ├── Input: Map<mergeKey, List<SObject>> + List<QueryRequest>
    ├── Lazy indexes: by record ID, by relationship field
    ├── Uses: Predicate.matches() for in-memory re-filtering
    └── Provides: getById(), getRelated(), getForHandler()
```

---

## 3. Data Flow — End to End

### Phase 2: Declare → Aggregate → Execute → Cache

**Step 1 — Declaration** (`TriggerDispatcher` lines 401–429):

For each `IQueryAware` handler, the dispatcher calls `declareQueryNeeds()` with the handler's filtered record set. The handler returns `List<QueryRequest>` — one or more requests built via `QueryBuilder`. The dispatcher feeds them all into a single `QueryAggregator`:

```apex
List<QueryRequest> requests = queryAware.declareQueryNeeds(applicable, oldMap);
aggregator.addRequests(requests);
```

**Step 2 — Aggregation** (`QueryAggregator.getMergedRequests()`):

The aggregator groups requests by merge key, clusters them by compatibility signature, and merges compatible clusters. Output is a reduced list of `QueryRequest` objects, each potentially representing multiple handlers' needs.

**Step 3 — Circuit Breakers** (`TriggerDispatcher` lines 437–567):

Before execution, the dispatcher checks:
- SOQL budget: `currentQueries + mergedRequests.size() > soqlThreshold`
- Heap usage: `Limits.getHeapSize() > heapThreshold`

If tripped, non-critical handlers are shed in a two-pass algorithm (see [Circuit Breakers](#16-circuit-breakers-and-governor-limit-management)).

**Step 4 — Execution** (`QueryExecutor.execute()`):

Each merged request becomes one SOQL query (or multiple if >900 IDs require chunking). Results are returned as `Map<String, List<SObject>>` keyed by merge key.

**Step 5 — Cache Population** (`TriggerDispatcher` line 574):

```apex
cache.populate(results, mergedRequests);
```

The cache stores the raw result superset and builds metadata for per-handler isolation and eviction tracking.

### Phase 3: Handler Retrieval

Each handler's `onDataReady()` receives the cache and retrieves its specific data:

```apex
// Simple path — no per-handler isolation needed
List<SObject> contacts = cache.getRelated(Contact.SObjectType, Contact.AccountId, accountIds);

// Isolated path — provenance-aware, OR-merge safe
List<SObject> contacts = cache.getForHandler('MyHandler', Contact.SObjectType, Contact.AccountId, 'myTag');
```

After `onDataReady()` completes, the dispatcher calls `cache.markHandlerServed(handlerName)` to decrement eviction counters.

---

## 4. The Merge Key

The merge key is the grouping identity for query aggregation. Format:

```
"SObjectTypeName|relationshipFieldName"    (e.g., "Contact|AccountId")
"SObjectTypeName|Id"                       (when no relationship field)
```

Built by `QueryRequest.buildMergeKey()` (line 308–314). Two requests with the same merge key are candidates for merging. Different merge keys are never merged — they produce separate SOQL queries and separate cache slots.

**Examples:**

| Handler Query | Merge Key |
|---------------|-----------|
| Contacts related through `AccountId` | `Contact\|AccountId` |
| Accounts by their own ID | `Account\|Id` |
| Opportunities related through `AccountId` | `Opportunity\|AccountId` |

---

## 5. QueryBuilder — The Handler's Entry Point

**File:** `QueryBuilder.cls`

A fluent builder that constructs `QueryRequest` objects. Returns `this` for chaining.

### Method Reference

| Method | Purpose | Required? |
|--------|---------|-----------|
| `QueryBuilder(String handlerName)` | Constructor — ties query to declaring handler | Yes |
| `onObject(SObjectType)` | Target SObject type | Yes |
| `fields(List<SObjectField>)` / `fields(Set<SObjectField>)` | Fields to SELECT (accumulates across calls) | Yes (≥1 field) |
| `forIds(Set<Id>)` | Record ID scope — **prevents unbounded SOQL** | Yes |
| `relatedThrough(SObjectField)` | FK field for related queries | No (null = query by own Id) |
| `withFLS()` | Enable field-level security enforcement | No (default: off) |
| `tag(String)` | Tag for per-(handler, tag) provenance | No (see [Tags](#12-tags--the-provenance-dimension)) |
| `whereFilter(Predicate)` | WHERE clause predicate (accumulates via AND) | No |
| `withChildSubquery(...)` | Child subquery (mutually exclusive with `whereFilter`) | No |
| `build()` | Validates and returns frozen `QueryRequest` | Yes (terminal) |

### Validation Rules (Enforced at `build()`)

- `forIds()` is mandatory — unbounded SOQL in trigger context is never correct
- `onObject()` is mandatory
- At least one field must be specified
- `withChildSubquery()` and `whereFilter()` are mutually exclusive on a single request
- Handler name must match `^[A-Za-z0-9_.]+$`
- Handler name must not start with `__salt_` (reserved for bind variables)
- Tag follows the same validation rules as handler name

### Usage Example

```apex
new QueryBuilder('OpportunityPipelineRollupHandler')
    .onObject(Opportunity.SObjectType)
    .fields(new List<SObjectField>{
        Opportunity.Amount, Opportunity.StageName, Opportunity.AccountId
    })
    .relatedThrough(Opportunity.AccountId)
    .forIds(accountIds)
    .build()
```

---

## 6. QueryRequest — The Immutable Contract

**File:** `QueryRequest.cls`

Once built, a `QueryRequest` is never mutated. Copies are created for chunking (`withChunkedIds`) and merging (`forOrMerged`).

### Key Fields

| Field | Type | Purpose |
|-------|------|---------|
| `targetObject` | `SObjectType` | What to query |
| `fields` | `Set<SObjectField>` | What to SELECT (becomes union after merge) |
| `recordIds` | `Set<Id>` | ID scope (becomes union after merge) |
| `relationshipField` | `SObjectField` | FK field for relationship queries (null = by own Id) |
| `enforceFLS` | `Boolean` | FLS enforcement flag |
| `tag` | `String` | Provenance tag (null for untagged) |
| `filters` | `List<Predicate>` | WHERE predicates (AND'd together) |
| `childSubquery` | `ChildSubqueryDescriptor` | Optional child subquery |
| `wasOrMerged` | `Boolean` | True if this request is the product of OR-merge |

### Provenance Maps (4-Level)

These maps track which handler declared which IDs, fields, and filters — critical for per-handler result isolation at cache retrieval time.

```
idsByHandler:      mergeKey → handler → tagKey → Set<Id>
fieldsByHandler:   mergeKey → handler → tagKey → Set<SObjectField>
filtersByHandler:  mergeKey → handler → tagKey → List<Predicate>
```

**Seeded** at construction time (lines 170–198) with the single declaring handler's data. **Unioned** during merge by `QueryAggregator.unionAllProvenance()`. **Read** by `QueryResultCache.getForHandler()` to isolate per-handler results.

### Factory Methods

| Method | Purpose |
|--------|---------|
| `forOrMerged(...)` | Creates a merged request with `wasOrMerged = true` and pre-built provenance maps |
| `withChunkedIds(Set<Id>)` | Copy with different ID set, all other state preserved (for >900 ID chunking) |

### Static Caches

`cachedTypeName(SObjectType)` and `cachedFieldName(SObjectField)` cache describe call results to avoid repeated governor limit consumption. Reset via `resetCaches()`.

---

## 7. Predicate System

### Predicate Interface (`Predicate.cls`)

```apex
public interface Predicate {
    Boolean matches(SObject row);              // in-memory evaluation
    String render(BindContext ctx);             // SOQL WHERE fragment
    Boolean equalsPredicate(Predicate other);   // structural equality
    Integer getStructuralHash();                // hash for merge optimization
}
```

### FieldFilter — Leaf Predicate (`FieldFilter.cls`)

Covers a single field with one of 8 operators:

| Operator | Factory Method | SOQL |
|----------|---------------|------|
| `EQUALS` | `FieldFilter.equals(field, value).build()` | `field = :bind` |
| `NOT_EQUALS` | `FieldFilter.notEquals(field, value).build()` | `field != :bind` |
| `IN_OP` | `FieldFilter.inSet(field, values).build()` | `field IN :bind` |
| `NOT_IN` | `FieldFilter.notInSet(field, values).build()` | `field NOT IN :bind` |
| `LT` | `FieldFilter.lt(field, value).build()` | `field < :bind` |
| `LE` | `FieldFilter.le(field, value).build()` | `field <= :bind` |
| `GT` | `FieldFilter.gt(field, value).build()` | `field > :bind` |
| `GE` | `FieldFilter.ge(field, value).build()` | `field >= :bind` |

**Factory-Time Rejections** (fields that can't be matched in-memory reliably):

- `EncryptedString` — cannot decrypt in-memory
- Location/geolocation — no in-memory distance calculation
- Cross-object formula fields — cannot resolve in-memory
- Currency on multi-currency orgs — no in-memory conversion
- Picklist with inequality operators — locale-dependent ordering
- String with inequality operators — locale collation hazard
- Date/Datetime cross-type inequalities — type mismatch
- Fields prefixed with `__salt_` — reserved for bind variables

**In-Memory Normalization** (in `matches()`):

- Id: 15-char → 18-char canonicalization
- String: case-insensitive equality
- Decimal: scale-tolerant `compareTo`
- Datetime: truncated to second

### CompositePredicate — Combinator (`CompositePredicate.cls`)

| Combinator | Factory | Behavior |
|------------|---------|----------|
| `AND_OP` | `CompositePredicate.andOf(List<Predicate>)` | All children must match |
| `OR_OP` | `CompositePredicate.orOf(List<Predicate>)` | Any child must match |
| `NOT_OP` | `CompositePredicate.notOf(Predicate)` | Unary negation |

- **Max depth:** 16 levels (prevents stack overflow)
- **Degenerate collapse:** Single-child AND/OR unwraps to the child directly
- **Varargs convenience:** `andOf(a, b)`, `andOf(a, b, c)`, `orOf(a, b)`, `orOf(a, b, c)`

---

## 8. QueryAggregator — The Merge Gate

**File:** `QueryAggregator.cls`

### Merge Modes

| Mode | Meaning | When |
|------|---------|------|
| `REFUSE` | Incompatible — cannot merge | FLS mismatch, different shapes, tier-3 fields |
| `MERGE_IDENTITY` | Structurally equal filter trees | Hash match + `equalsPredicate()` confirms equality |
| `MERGE_OR` | Different filter trees | Filters OR-composed; `wasOrMerged = true` |
| `MERGE_SUBSUME` | One side has no filters | Unfiltered wins; filtered side defers to in-memory matcher |

### Algorithm Overview

**1. Intake** (`addRequests`, lines 38–49):

Requests are grouped by merge key into `requestsByMergeKey`. Tag validation runs immediately.

**2. Per-Group Merge** (`mergeGroup`, lines 67–105):

For each merge key group with >1 request:

```
for each request in group:
    sig = computeClusterSignature(req)     // O(1) hash
    clusterIdx = sigToCluster.get(sig)     // O(1) map lookup
    if found AND canMergeOrUnion passes:
        add to cluster, escalate mode
    else:
        create new cluster
```

**3. Cluster Merge** (`mergeAll`, lines 215–292):

Per cluster:
- Union fields, IDs, handlers (fresh collections — never mutate inputs)
- Compose filters based on mode (IDENTITY → pick one; OR → `CompositePredicate.orOf(allTrees)`; SUBSUME → empty)
- Union all 4-level provenance maps via `unionAllProvenance()`
- Emit single merged `QueryRequest` via `forOrMerged()`

### Compatibility Preconditions (`canMergeOrUnion`, lines 160–211)

Checked in order — first failure returns `REFUSE`:

1. **FLS posture mismatch** → REFUSE
2. **Different SObjectType** → REFUSE
3. **Different relationshipField** → REFUSE
4. **Mixed shape** (one has child subquery, other has flat filters) → REFUSE
5. **Different child subquery descriptors** → REFUSE
6. **Tier-3 sensitive fields in filters** (MULTIPICKLIST, ENCRYPTEDSTRING, LOCATION) → REFUSE
7. **Filter comparison** — uses structural hash short-circuit, then full equality check

### Mode Escalation

Within a cluster, modes escalate monotonically: `IDENTITY → SUBSUME → OR`. Any single `MERGE_OR` pair escalates the entire cluster to OR mode.

---

## 9. Hashing — Where and Why

Hashing is used at **two levels** to reduce algorithmic complexity from O(N² × k) to O(N):

### Level 1: Cluster Signature Hash — O(1) Candidate Lookup

**File:** `QueryAggregator.cls`, `computeClusterSignature()` (lines 121–147)

**Problem:** Given N requests sharing a merge key, grouping by compatibility via pairwise comparison is O(N²).

**Solution:** Hash each request's merge-compatibility dimensions into a single integer, use `Map<Integer, Integer>` for O(1) cluster lookup.

**Signature components:**

```apex
Integer h = (req.enforceFLS ? 1 : 0);              // FLS posture (1 bit)
h = 31 * h + System.hashCode(req.targetObject);    // SObject type
h = 31 * h + System.hashCode(req.relationshipField); // relationship field
h = 31 * h + (hasChildSubquery ? 1 : 0);           // child subquery presence
if (hasChildSubquery):
    h = 31 * h + System.hashCode(childRelationshipName);
```

**Critical design choice:** Filter content is **deliberately excluded**. Requests with different filters should cluster together (they merge via OR-mode), not form separate clusters.

**Complexity:** O(N) single pass instead of O(N²) pairwise scan.

### Level 2: Predicate Structural Hash — Tree Equality Short-Circuit

**Files:** `FieldFilter.cls` (constructor, lines 50–62), `CompositePredicate.cls` (constructor, lines 25–34)

**Problem:** Once clustered, the aggregator compares filter trees via `equalsPredicate()` which walks every node — O(k) per comparison. Doing this for all pairs in a cluster is O(N² × k).

**Solution:** Precompute a structural hash at construction time. Different hashes guarantee different trees — skip the O(k) walk.

**FieldFilter hash (computed once in constructor):**

```apex
h = System.hashCode(field);           // field identity
h = 31 * h + operator.ordinal();      // operator enum (8 values)
h = 31 * h + System.hashCode(value);  // bind value (nullable)
```

**CompositePredicate hash (computed once in constructor):**

```apex
h = combinator.ordinal();             // AND_OP / OR_OP / NOT_OP
for (Predicate child : children):
    h = 31 * h + child.getStructuralHash();  // recursive
```

**Usage in aggregator** (`canMergeOrUnion`, lines 202–210):

```apex
if (treeA.getStructuralHash() != treeB.getStructuralHash()) {
    return MergeMode.MERGE_OR;      // hashes differ → definitely not equal
}
if (treeA.equalsPredicate(treeB)) {
    return MergeMode.MERGE_IDENTITY; // hashes match → verify with full walk
}
return MergeMode.MERGE_OR;
```

### Combined Complexity Impact

| Operation | Without Hashing | With Hashing |
|-----------|-----------------|--------------|
| Cluster formation (N requests) | O(N²) pairwise | **O(N)** hash map |
| Predicate equality per pair | O(k) tree walk always | **O(1)** hash compare; O(k) only on collision |
| Total for N requests, k-deep trees | O(N² × k) | **O(N)** typical case |

Hash collisions on structurally different predicate trees are rare — the 31-prime polynomial produces good distribution. Nearly all non-identical pairs are rejected in O(1).

---

## 10. QueryExecutor — SOQL Rendering and Execution

**File:** `QueryExecutor.cls`

### SOQL Construction (`buildSOQLAndBinds`, lines 106–192)

For each merged request, the executor builds:

```sql
SELECT Id, field1, field2, ..., (SELECT ... FROM ChildRel WHERE ...)
FROM ObjectName
WHERE relField IN :saltIds AND (predicate-tree)
```

**Bind isolation:** A fresh `BindContext` is created per request (line 107). Bind variables use `__salt_p0`, `__salt_p1`, ... for predicates and `__salt_c0`, `__salt_c1`, ... for child subqueries. The `__salt_` prefix is reserved — handler/tag names cannot use it.

### Chunking (>900 IDs)

Salesforce limits IN clause to ~900 values. When `recordIds.size() > 900`, the executor splits into chunks via `withChunkedIds()` — each chunk produces a separate SOQL query, and results are accumulated into the same merge key bucket.

### FLS Gate

When `enforceFLS == true`, the gate scope is the **union** of:
- Declared fields (`req.fields`)
- Relationship field (`req.relationshipField`)
- Predicate leaf fields (recursively collected from filter tree)
- Child subquery fields and child filter fields

If any field is not accessible to the current user, `FlsException` is thrown.

**Important under merge:** If Handler A (FLS on) and Handler B (FLS on) merge, the gate scope includes both handlers' field unions. If a field from Handler B is inaccessible, the merged query fails — even though Handler A never requested that field. This is why FLS mismatch (`enforceFLS` differs) causes `REFUSE` — mixing FLS-on and FLS-off is never allowed.

### SOQL Budget Guard

Before each query: `Limits.getQueries() + 1 > Limits.getLimitQueries() - soqlReserve`. Default `soqlReserve = 10`.

---

## 11. QueryResultCache — Storage, Retrieval, and Eviction

**File:** `QueryResultCache.cls`

### Storage Model

The cache stores **merged result supersets** — not per-handler slices:

```
cache: Map<mergeKey, List<SObject>>
```

Per-handler isolation happens at **retrieval time**, not storage time.

### Lazy Indexes

Built on first access, not at populate time:

- `indexById`: `mergeKey → recordId → List<SObject>` — built on first `getById()` call
- `indexByRelField`: `mergeKey → parentId → List<SObject>` — built on first `getRelated()` call

Both are O(n) to build (single pass), then O(1) per lookup.

### Three Retrieval Paths

#### Path 1: `getById(SObjectType, Set<Id>)` — Simple ID Lookup

Returns all rows matching the given record IDs. No per-handler isolation, no cloning. Suitable when the handler is the sole consumer of this merge key.

#### Path 2: `getRelated(SObjectType, SObjectField, Set<Id>)` — Relationship Lookup

Returns all rows whose relationship field value matches one of the parent IDs. No per-handler isolation, no cloning.

#### Path 3: `getForHandler(handler, SObjectType, SObjectField, tag)` — Provenance-Aware Retrieval

The full isolation path. Five steps:

**1. Explicit-failure checks** (lines 252–285):
- Cache slot evicted → throw `TriggerFrameworkException('cache-evicted')`
- Unknown (handler, mergeKey, tag) → throw `TriggerFrameworkException('unknown-declaration')`
- Known but empty → return empty list (not throw)

**2. Provenance lookup** (lines 295–302):
```apex
Set<Id> declaredIds = mergedReq.idsByHandler.get(key).get(handler).get(tk);
Set<SObjectField> declaredFields = mergedReq.fieldsByHandler.get(key).get(handler).get(tk);
List<Predicate> declaredFilters = mergedReq.filtersByHandler.get(key).get(handler).get(tk);
```

**3. In-memory matcher construction** (lines 307–316):
Only activated when `wasOrMerged == true` AND handler declared filters:
```apex
matcher = declaredFilters.size() == 1
    ? declaredFilters[0]
    : CompositePredicate.andOf(declaredFilters);
```

**4. Row-by-row filtering and cloning** (lines 330–351):
```
for each row in superset:
    if row's ID not in handler's declared IDs → skip
    if matcher exists AND row doesn't match handler's filters → skip
    deep clone row (preserving child collections)
    add to result
```

**5. Return** — handler gets only its rows, deep-cloned for mutation safety.

### Eviction

Two mechanisms (both converge on the same outcome):

**Handler-level** (`markHandlerServed`, lines 184–228): Tracks which handlers have been served per merge key. Evicts when all declared handlers are served.

**Per-(handler, tag) level** (`markHandlerTagServed`, lines 360–417): Counts total (handler, tag) consumers per merge key. Decrements on each serve. Evicts at 0.

On eviction, all data structures for the merge key are cleaned up: cache slot, both indexes, relationship field reference, provenance maps, served tracking.

**Circuit-breaker-shed handlers** must be explicitly evicted (`TriggerDispatcher` line 922–923) or their cache slots leak for the transaction.

---

## 12. Tags — The Provenance Dimension

Tags provide per-handler sub-grouping within a merge key, enabling a single handler to declare multiple requests against the same SObject/relationship and retrieve them independently.

### When Tags Are Required

| Scenario | Tags Needed? |
|----------|-------------|
| Handler needs 1 query | No |
| Handler needs 2 queries, different merge keys | Good practice, not required |
| Handler needs 2 queries, **same merge key**, different filters | **Yes — mandatory** |

### Why Same-Merge-Key Needs Tags

Without tags, both requests from the same handler occupy provenance slot `(mergeKey, handler, __null)`. The second overwrites the first. Tags create separate slots:

```apex
// Two requests, SAME merge key, different business purposes
new QueryBuilder('HandlerC')
    .onObject(Contact.SObjectType)
    .fields(...)
    .relatedThrough(Contact.AccountId)
    .forIds(accountIds)
    .tag('billing')                                          // ← tagged
    .whereFilter(FieldFilter.equals(Contact.Department, 'Billing').build())
    .build(),
new QueryBuilder('HandlerC')
    .onObject(Contact.SObjectType)
    .fields(...)
    .relatedThrough(Contact.AccountId)
    .forIds(accountIds)
    .tag('shipping')                                         // ← tagged
    .whereFilter(FieldFilter.equals(Contact.Department, 'Shipping').build())
    .build()
```

Provenance slots:
- `(Contact|AccountId, HandlerC, billing)` → IDs/fields/filters for billing contacts
- `(Contact|AccountId, HandlerC, shipping)` → IDs/fields/filters for shipping contacts

### Tag Validation Rules

- Must match `^[A-Za-z0-9_.]+$`
- Must not start with `__salt_` (reserved)
- Within a single `(handler, mergeKey)` pair, you **cannot mix null and non-null tags** — the aggregator throws `TriggerFrameworkException('provenance ambiguity')` at intake time (lines 491–516)
- Tags from different handlers don't interact — Handler A's tag `'foo'` and Handler B's tag `'foo'` are independent

### Tag and Eviction

Tags create separate consumers for eviction counting. A cache slot with 3 (handler, tag) pairs requires all 3 to call `markHandlerTagServed` before the slot is evicted.

### The Null Tag Key

Internally, null tags are stored as the sentinel string `'__null'` (line 40) to avoid Apex map key issues with literal null.

---

## 13. Multi-Object Queries From a Single Handler

A handler can return multiple `QueryRequest` objects from `declareQueryNeeds()`. The return type is `List<QueryRequest>` — not limited to one.

### Different Merge Keys (Different Objects)

```apex
public List<QueryRequest> declareQueryNeeds(List<SObject> applicable, Map<Id, SObject> oldMap) {
    Set<Id> accountIds = collectAccountIds(applicable);
    return new List<QueryRequest>{
        new QueryBuilder('MyHandler')
            .onObject(Contact.SObjectType)
            .fields(new List<SObjectField>{ Contact.Title, Contact.AccountId })
            .relatedThrough(Contact.AccountId)
            .forIds(accountIds)
            .tag('contacts')
            .build(),
        new QueryBuilder('MyHandler')
            .onObject(Opportunity.SObjectType)
            .fields(new List<SObjectField>{ Opportunity.Amount, Opportunity.AccountId })
            .relatedThrough(Opportunity.AccountId)
            .forIds(accountIds)
            .tag('opps')
            .build()
    };
}
```

These land in **different merge key groups** (`Contact|AccountId` vs `Opportunity|AccountId`). Each merges independently with other handlers' requests on the same key. SOQL cost: 0 extra if both merge groups already exist from other handlers.

Retrieval in `onDataReady()`:
```apex
List<SObject> contacts = cache.getForHandler('MyHandler', Contact.SObjectType, Contact.AccountId, 'contacts');
List<SObject> opps = cache.getForHandler('MyHandler', Opportunity.SObjectType, Opportunity.AccountId, 'opps');
```

### Same Merge Key (Same Object, Different Filters)

```apex
return new List<QueryRequest>{
    new QueryBuilder('MyHandler')
        .onObject(Contact.SObjectType)
        .fields(...)
        .relatedThrough(Contact.AccountId)
        .forIds(accountIds)
        .tag('billing')
        .whereFilter(FieldFilter.equals(Contact.Department, 'Billing').build())
        .build(),
    new QueryBuilder('MyHandler')
        .onObject(Contact.SObjectType)
        .fields(...)
        .relatedThrough(Contact.AccountId)
        .forIds(accountIds)
        .tag('shipping')
        .whereFilter(FieldFilter.equals(Contact.Department, 'Shipping').build())
        .build()
};
```

Both land in the same merge group (`Contact|AccountId`). The aggregator OR-merges the filters. At retrieval, each tag's in-memory matcher re-applies its specific filter. Tags are mandatory here — without them, provenance is ambiguous.

---

## 14. Handler-Specific Result Isolation

The cache stores **merged supersets**. Isolation happens at retrieval time through three filters:

### Filter 1: ID Membership

`getForHandler()` (line 335): Rows whose relationship field value (or record ID) is not in the handler's `declaredIds` are skipped.

### Filter 2: In-Memory Predicate Matcher

`getForHandler()` (lines 308–316, 339): Only activated when `wasOrMerged == true` AND the handler declared filters. Rows that matched another handler's OR branch but not this handler's predicates are dropped.

### Filter 3: Deep Clone

`getForHandler()` (line 349): `row.clone(true, true, true, false)` — deep clone with child collection preservation. Prevents handlers from mutating each other's data.

### Visual Example

```
SOQL Result (superset):
  [Contact{Id=1, AccountId=A, Status='Active'},
   Contact{Id=2, AccountId=A, Status='Inactive'},
   Contact{Id=3, AccountId=B, Stage='Proposal'},
   Contact{Id=4, AccountId=B, Status='Active'}]

Handler A (declared: ids={A}, filter=[Status='Active']):
  → ID filter:  keep rows 1, 2 (AccountId=A)
  → Matcher:    keep row 1 (Status='Active'), drop row 2
  → Clone:      return [clone of row 1]

Handler B (declared: ids={B}, filter=[Stage='Proposal']):
  → ID filter:  keep rows 3, 4 (AccountId=B)
  → Matcher:    keep row 3 (Stage='Proposal'), drop row 4
  → Clone:      return [clone of row 3]
```

### Field Leakage (Documented Trade-Off)

Under OR-merge, the field set is the union of all handlers' fields. Handler A may receive fields it didn't declare (e.g., Handler B's `Phone` field). This is documented in ADR 0001 as an accepted trade-off: child subquery preservation via deep clone requires keeping all fields, because the only alternative (`JSON.serialize`/`deserialize` round-trip) loses child collections.

---

## 15. Kahn's Algorithm — DML Topological Sort

**File:** `DmlExecutor.cls`, `getTopologicalOrder()` (lines 293–407)

When multiple handlers queue DML across different SObject types via `IDmlAware`, FK constraints require a specific execution order.

### Algorithm (Kahn's Topological Sort)

**1. Build dependency graph** (lines 295–313):
- Explicit declarations: `registrar.declareDependency(Child, Parent)`
- Schema-derived FK edges: field describe metadata

**2. Build reverse adjacency map** (lines 341–351):
`parent → Set<children>` for O(1) dependent lookup.

**3. Compute in-degrees** (lines 354–358):
Count of unresolved dependencies per SObject type.

**4. Seed queue** (lines 360–366):
All types with in-degree 0 (no dependencies).

**5. Main loop** (lines 370–385):
Uses index pointer (`queueIdx++`) instead of `List.remove(0)` to avoid O(n) shifts. For each processed node: add to sorted list, decrement dependents' in-degrees, enqueue at 0.

**6. Cycle detection** (lines 387–404):
If `sorted.size() < allTypes.size()` → cycle exists → throw `CyclicDependencyException`.

### Complexity

O(V + E) where V = SObject types, E = FK edges.

### Usage in `commitWork()`

- **Inserts** (lines 80–126): Forward topological order (parents first)
- **Updates** (lines 128–138): Forward topological order
- **Deletes** (lines 140–151): **Reverse** topological order (children first)

### Performance Optimization

FK edges are cached in a static `fkEdgeCache` to avoid redundant describe calls across multiple commits in the same transaction.

---

## 16. Circuit Breakers and Governor Limit Management

### The Platform Constraints

| Resource | Limit | Key Insight |
|----------|-------|-------------|
| SOQL Queries | 100 per transaction | Shared across ALL triggers, Flows, Process Builders in the same transaction |
| DML Statements | 150 per transaction | Multiple handlers updating different objects exhaust budget without batching |
| CPU Time | 10,000 ms | Framework overhead must be negligible |
| Heap Size | 6 MB sync / 12 MB async | Query caches and DML buffers must coexist within this ceiling |
| Query Rows | 50,000 per transaction | Redundant queries waste shared row budget |

**Critical insight:** Governor limits do not reset between cascading triggers. Account trigger → Contact trigger → Task trigger all share the same budget.

### SOQL Circuit Breaker (`TriggerDispatcher` lines 437–515)

**Threshold formula:**
```
soqlThreshold = max(0, limitQueries - soqlReserve - (cascadeDepth × soqlPerCascadeLevel))
```

Default: `soqlReserve = 10`, `soqlPerCascadeLevel = 10`. Cascade-adaptive — deeper cascades get tighter thresholds.

**Two-pass shedding:**
1. **Pass 1:** Shed all non-critical `IQueryAware` handlers. Re-aggregate remaining.
2. **Pass 2:** If critical handlers alone exceed threshold → throw `SoqlBudgetException`.

### Heap Circuit Breaker (`TriggerDispatcher` lines 517–567)

**Threshold:** `Limits.getLimitHeapSize() × 0.75` (configurable).

**Two-pass shedding:**
1. Shed non-critical `IQueryAware` handlers.
2. If critical `IQueryAware` handlers remain → throw (cannot shed critical).

### CPU Circuit Breaker (`TriggerDispatcher` lines 767–798)

**Per-handler, reactive.** Checked before each handler in Phase 3:
- Non-critical after-trigger handler + CPU exceeded → skip
- Critical or before-trigger → log warning, execute anyway

### Handler Criticality

Configured via `TriggerHandler__mdt.IsCritical__c`:
- `true`: Never shed by circuit breakers (transaction fails if they can't run)
- `false`: Eligible for shedding (graceful degradation)
- All before-trigger handlers are implicitly critical regardless of setting

### Configuration API

```apex
TriggerDispatcher.setSoqlReserve(Integer reserve);
TriggerDispatcher.setSoqlReservePerCascadeLevel(Integer reserve);
TriggerDispatcher.setHeapThresholdFraction(Decimal fraction);
TriggerDispatcher.setCpuThresholdFraction(Decimal fraction);
QueryExecutor.setSoqlReserve(Integer r);
DmlExecutor.setDmlReserve(Integer r);
```

---

## 17. Architectural Analysis — Is This an Anti-Pattern?

### In General Software Architecture: Yes

Cross-handler query merging violates several established principles:

- **Handler autonomy:** A handler declares one query, the framework silently rewrites it. The handler's contract and execution diverge (Leaky Abstraction).
- **The "God Query":** OR-merging structurally different queries creates a single statement serving multiple intents — analogous to the God Object anti-pattern.
- **Shared mutable state:** The `QueryResultCache` is shared state whose lifecycle depends on collective handler behavior (temporal coupling).
- **Beyond standard batching:** DataLoader (Facebook/GraphQL) merges identical queries by key. SALT merges structurally different queries — different fields, different filters.

No general-purpose framework (Spring, Django, Rails) does this.

### In Salesforce: No — Correct Response to a Unique Constraint

The 100-query hard limit with no reset across cascade triggers, no ability to add infrastructure, and no connection pool creates a problem that doesn't exist elsewhere.

**Why standard alternatives fail:**

| Alternative | Why It Fails on Salesforce |
|-------------|---------------------------|
| Each handler runs its own SOQL | Exhausts the 100-query budget |
| Manual handler coordination | Tighter coupling than transparent merging |
| Shared query service per object | God Class; one handler's change breaks the service |
| Cache-aside / lazy-load | Cache miss still pays SOQL; doesn't solve budget problem |
| Move to async | Async has its own 100-query limit, loses transaction context |

**Why the conditions are met:**
1. Budget is genuinely shared and hard-limited ✓
2. Consumers have equivalent privilege levels (same transaction, same user, same FLS) ✓
3. Mediator maintains per-consumer correctness (provenance maps + in-memory matcher) ✓
4. Complexity is borne by framework, not consumers (handlers use `QueryBuilder` / `cache.getForHandler()`) ✓

Remove any condition and the pattern becomes an anti-pattern again.

---

## 18. Predicate Scenario Benchmark

10-run cleanroom profiled benchmark of the 4 predicate handlers (200 Accounts, 600 Contacts, Account.Rating update). Full report at `docs/benchmarks/predicate-benchmark-report.md`. Logs at `scripts/benchmarks/logs/profiled/predicate-cleanroom-10/`.

### Results (10-Run Median)

| Metric | SALT | fflib | O'Hara | TAF |
|--------|-----:|------:|-------:|----:|
| **SOQL** | **1** | 5 | 5 | 5 |
| **DML statements** | **4** | 5 | 5 | 5 |
| **DML rows** | 1,200 | 1,200 | 1,200 | 1,200 |
| **CPU (median, ms)** | 2,290 | 1,809 | 1,799 | 1,747 |
| **CPU (p95, ms)** | 2,564 | 2,021 | 2,080 | 2,070 |
| **CPU (range, ms)** | 2,051 – 2,564 | 1,616 – 2,021 | 1,612 – 2,080 | 1,567 – 2,070 |
| **CPU CV** | 8.1% | 8.7% | 7.9% | 8.8% |
| **Heap delta (median, B)** | 824 | 3,152 | 302 | 302 |
| **Heap delta (range, B)** | 651 – 838 | 3,152 – 3,156 | 302 – 310 | 302 – 302 |

### State Equivalence

All 4 frameworks produce identical output across all 40 runs:

```
TaskTotal=800  BillingReview=200  ShippingAlert=200  TaggedBilling=200  TaggedEng=200  DescriptionSet=200
```

### SOQL Merge Analysis

SALT merges 5 handler queries (including TaggedDept's 2 tagged requests) into 1 via MERGE_SUBSUME — `AccountAllContactNotifyHandler` has no `whereFilter`, which subsumes all other handlers' predicates into an empty WHERE clause. In-memory matcher re-applies each handler's predicate at `getForHandler()` retrieval time.

The inline frameworks issue 5 separate queries (1 per handler invocation). No cross-handler merging.

### CPU Overhead Analysis

SALT's 24% CPU premium on this scenario comes from:
- `IRecordFilter` Phase 1 per-record `isApplicable()` evaluation
- `QueryAggregator` merge-gate (signature hashing + `canMergeOrUnion`)
- `BindContext` allocation per query render
- `QueryResultCache.getForHandler()` deep-clone per row per handler
- Phase 4 cross-handler `FieldConflict` detection on `registerDirty`

All frameworks sit well below the 10,000 ms CPU governor (SALT at 77% headroom, others at 82%).

### Heap Analysis

SALT's 824 B heap delta reflects `getForHandler()` deep-clone cost. The inline frameworks avoid cloning (each handler queries independently). All values are ~3 orders of magnitude below the 6 MB governor.

---

## 19. Trade-Offs and Accepted Costs

| Trade-Off | Cost | Benefit | Severity |
|-----------|------|---------|----------|
| **Field set leakage** | Handlers get fields they didn't declare | 1 query instead of N; child subquery preservation | Low — no privilege boundary between handlers |
| **OR-merge overfetch** | Larger result sets (heap + query rows) | Fewer SOQL statements | Medium — heap circuit breaker provides safety net |
| **Deep clone per handler** | N handlers x M rows = NxM clones | Prevents mutation leakage; preserves child collections | Medium — comparable to N independent queries |
| **Cache eviction complexity** | Two-level tracking with 4-level maps | Correct multi-consumer OR-merge support | High complexity, encapsulated from handler authors |
| **FLS scope expansion** | Merged query checks union of all handlers' fields | Prevents oracle inference via filter shape | Medium — FLS mismatch causes REFUSE, preventing cross-posture merge |
| **Debugging opacity** | Unexpected results may trace to merge logic, not handler query | Transparent optimization for handler authors | Medium — mitigated by `wasOrMerged`, provenance maps, explicit-failure semantics |

---

## Appendix: Key File Paths

| File | Path |
|------|------|
| QueryBuilder | `force-app/main/default/classes/QueryBuilder.cls` |
| QueryRequest | `force-app/main/default/classes/QueryRequest.cls` |
| QueryAggregator | `force-app/main/default/classes/QueryAggregator.cls` |
| QueryExecutor | `force-app/main/default/classes/QueryExecutor.cls` |
| QueryResultCache | `force-app/main/default/classes/QueryResultCache.cls` |
| BindContext | `force-app/main/default/classes/BindContext.cls` |
| Predicate | `force-app/main/default/classes/Predicate.cls` |
| FieldFilter | `force-app/main/default/classes/FieldFilter.cls` |
| CompositePredicate | `force-app/main/default/classes/CompositePredicate.cls` |
| ChildSubqueryDescriptor | `force-app/main/default/classes/ChildSubqueryDescriptor.cls` |
| TriggerDispatcher | `force-app/main/default/classes/TriggerDispatcher.cls` |
| DmlExecutor | `force-app/main/default/classes/DmlExecutor.cls` |
| IQueryAware | `force-app/main/default/classes/IQueryAware.cls` |
| ADR 0001 (Query Pipeline Integrity) | `docs/adr/0001-query-pipeline-integrity-posture.md` |
| ADR 0002 (Net-New Framework) | `docs/adr/0002-net-new-framework.md` |
| ADR 0005 (Query Aggregation) | `docs/adr/0005-query-aggregation-and-batch-execution.md` |
| ADR 0006 (Predicate Trees / OR-Merge) | `docs/adr/0006-predicate-trees-and-or-merge.md` |
| Benchmark Report (23-handler) | `docs/benchmarks/benchmark-report.md` |
| Benchmark Report (predicate) | `docs/benchmarks/predicate-benchmark-report.md` |
| Predicate Driver Script | `docs/benchmarks/predicate-driver.apex` |
| Handler Registry | `docs/benchmarks/handlers.yaml` |
| Predicate Benchmark Logs | `scripts/benchmarks/logs/profiled/predicate-cleanroom-10/` |
