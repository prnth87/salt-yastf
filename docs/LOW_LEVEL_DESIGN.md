# SALT(YASTF) Low-Level Design

## Salesforce Apex Layered Triggers — Yet Another Salesforce Trigger Framework

**License:** MIT

---

## Table of Contents

1. [The Need](#1-the-need)
2. [Background](#2-background)
3. [The Layered Architecture](#3-the-layered-architecture)
4. [Class Diagram and Specifications](#4-class-diagram-and-specifications)
5. [Closure](#5-closure)
6. [Appendix A — Tradeoffs, Risks, and Assumptions](#appendix-a--tradeoffs-risks-and-assumptions)
7. [Appendix B — The Full Pipeline (Origin Story)](#appendix-b--the-full-pipeline-origin-story)

See also: [Design Document](DESIGN.md) for the high-level specification, [README](README.md) for quick start and configuration.

---

# 1. The Need

## 1.1 The State of Trigger Frameworks on the Force.com Platform

The Salesforce ecosystem has produced several well-regarded trigger frameworks, each solving a genuine subset of the problems inherent to Apex trigger development. These frameworks represent years of community learning and deserve recognition for establishing the patterns that the industry now considers baseline.

### [Kevin O'Hara's Trigger Handler](https://github.com/kevinohara80/sfdc-trigger-framework) (2013, MIT License)

The framework that established "one trigger per object" as consensus practice. A developer extends `TriggerHandler`, overrides context methods (`beforeInsert`, `afterUpdate`, etc.), and the framework routes execution by trigger context.

**What it solves well:**

- Eliminates multiple triggers per object (indeterminate execution order)
- Provides basic recursion control via `setMaxLoopCount()`
- Minimal learning curve — three concepts, productive in 30 minutes

**Where it stops:** Each handler owns its own SOQL and DML. No query deduplication across handlers. No DML batching. No metadata-driven configuration. The recursion guard uses a static Boolean/counter pattern that fails on 200+ record bulk operations, partial saves (`allOrNone=false`), and workflow field update re-entrancy.

### [Trigger Actions Framework — TAF](https://github.com/mitchspano/apex-trigger-actions-framework) (2020, Apache 2.0, by Mitch Spano)

The framework that brought metadata-driven dispatch to the Salesforce trigger ecosystem. Handlers are individual action classes registered via Custom Metadata Type records, enabling configuration-time control over which actions fire, in what order, and for which contexts.

**What it solves well:**

- Metadata-driven registration, ordering, and bypass — no code changes to add/reorder handlers
- Record-level recursion deduplication via `Set<Id>`
- Separation of each business rule into its own class (eliminates god-handler anti-pattern)
- Supports both Apex and Flow-based actions

**Where it stops:** Each action class independently queries the data it needs. Two actions on the same trigger that both need Account data issue two SOQL queries. No query aggregation, no DML coordination, no cross-action conflict detection. The `Set<Id>` recursion guard improves on Boolean flags but still fails on partial saves and does not detect field-level re-entry.

### [fflib — Apex Enterprise Patterns](https://github.com/apex-enterprise-patterns/fflib-apex-common) (2013, BSD-3-Clause, by Andrew Fawcett)

The framework that brought Martin Fowler's enterprise patterns to Salesforce. A four-layer architecture — Selector (data access), Domain (business logic), Service (orchestration), Unit of Work (DML batching) — providing the most architecturally rigorous approach available on the platform.

**What it solves well:**

- **Selector layer** centralizes SOQL per SObject — one `AccountsSelector` class owns all Account queries
- **Unit of Work** batches DML across operations, orders commits by schema dependencies
- **Domain layer** wraps SObjects with business behavior
- **Separated Interfaces** enable testability via dependency injection and mocking (ApexMocks)

**Where it stops:** The Selector layer centralizes query _definitions_ but does not aggregate query _executions_ across consumers in a single trigger context. If `DomainA` calls `AccountsSelector.selectById(setA)` and `DomainB` calls `AccountsSelector.selectById(setB)`, fflib executes two SOQL queries — not one. fflib also lacks trigger dispatch/ordering, recursion guards, and metadata-driven configuration. The four-layer architecture imposes significant cognitive overhead (Domain, Selector, Service, Unit of Work classes per SObject), making it impractical for teams that cannot absorb that learning curve.

### SALT(YASTF) — Salesforce Apex Layered Triggers (2024, MIT License)

The framework that introduces cross-handler SOQL aggregation to the Salesforce trigger ecosystem. A concentric-layer architecture — dispatch (Layer 0), field-hash recursion (Layer 1), declarative query aggregation (Layer 2), coordinated DML (Layer 3) — delivered as opt-in capability interfaces on a single base class, with metadata-driven configuration.

**What it solves well:**

- **Cross-handler query aggregation** — handlers declare data needs; the framework merges compatible queries and executes the minimum SOQL statements across all handlers in a trigger context
- **Field-hash recursion guards** — detects whether watched fields actually changed between invocations, eliminating false skips from Boolean/Set<Id> patterns on partial saves, chunking, and workflow re-entry
- **Coordinated DML** — deferred registration with cross-handler conflict detection, dependency-aware commit ordering, savepoint-based atomicity, and error provenance
- **Concentric adoption** — teams adopt only the layers they need; different handlers on the same SObject can use different layers
- **Circuit breakers** — cascade-adaptive SOQL and heap thresholds that degrade non-critical handlers gracefully instead of failing the transaction

**Where it stops:** The batch-query-then-execute model means all queries run before any handler executes in Phase 3 — handlers see pre-modification data, so Handler B cannot query data that Handler A mutates in the same trigger pass. Field enforcement for query declarations is test-time only; production silently reads undeclared fields (a deliberate heap tradeoff). Platform Events and Change Data Capture triggers are excluded from v1.0. The framework adds ~2,500 lines of Apex and 14 metadata fields per handler registration — overhead that is unjustified for small orgs with simple trigger needs. The four-layer model, while individually opt-in, still represents a steeper learning curve than single-concept frameworks when teams eventually need Layers 2-3. No cross-transaction caching (platform limitation: static variables reset per transaction). The SOQL circuit breaker is heuristic — it cannot predict future cascade needs, so aggressive thresholds may skip handlers that would have had budget.

### [The Hari Architecture Framework](https://krishhari.wordpress.com/2013/07/22/an-architecture-framework-to-handle-triggers-in-the-force-com-platform/) (2013)

An early dispatcher pattern using `TriggerFactory` as the single entry point with `Type` API-based dynamic instantiation. Introduced the concept of separating first-time and re-entrant trigger logic at the dispatcher level.

**What it solves well:**

- Clean separation between first-time and re-entrant code paths
- Dynamic handler instantiation via the Type API

**Where it stops:** No query optimization, no DML batching, no metadata-driven configuration, no record partitioning.

## 1.2 The Evolution Opportunity

Each of these frameworks solves its intended use case well and is widely adopted at the scale it targets. Kevin O'Hara's simplicity makes it the right choice for teams that need structure without overhead. TAF's metadata-driven model is excellent for organizations that want admin-configurable trigger management. fflib's layered architecture is the gold standard for enterprises that can invest in its learning curve. Hari's dispatcher pattern remains a valuable educational foundation.

The following table illustrates how each framework's strengths align with different aspects of trigger management:

| Framework    | Dispatch        | Ordering                  | Recursion        | SOQL Dedup            | Record Filtering   | DML Batching |
| ------------ | --------------- | ------------------------- | ---------------- | --------------------- | ------------------ | ------------ |
| Kevin O'Hara | Handler class   | Code-order                | Max loop count   | —                     | —                  | —            |
| TAF          | Metadata-driven | Metadata-driven           | `Set<Id>`        | —                     | Partial (metadata) | Partial      |
| fflib        | Domain class    | N/A (no trigger dispatch) | —                | Per-object (Selector) | —                  | Yes (UoW)    |
| Hari         | Dynamic factory | Code-order                | Dispatcher flags | —                     | —                  | —            |
| SALT(YASTF)  | Metadata-driven | Metadata-driven           | Field-hash       | Cross-handler (agg.)  | Specification      | Yes (coord.) |

These frameworks were designed for — and excel at — the complexity profiles most Salesforce organizations encounter. For the majority of orgs, they are the right answer and will continue to be.

However, organizations operating at enterprise scale — large development teams, high transaction volumes, deep trigger cascades across many objects — encounter a challenge that falls outside the scope these frameworks were designed to address: **cross-handler SOQL aggregation before execution.**

When a trigger has five handler concerns, each needing two related objects, the independent-query approach consumes 10 SOQL queries per trigger invocation. In a cascading transaction spanning three objects, that becomes 30 SOQL queries against a budget of 100 — leaving little headroom for Flows, Process Builders, and integration logic sharing the same transaction. fflib's Selector layer centralizes query _definitions_ per object, which is valuable, but each caller still executes its query independently. TAF's strength is in dispatch and ordering, not in data access optimization.

This is not a shortcoming of these frameworks — it is a problem that emerges at a scale beyond their design targets. The optimization gap sits upstream in the pipeline: before queries execute, at the point where handler data needs could be collated and fulfilled collectively rather than independently.

## 1.3 What SALT(YASTF) Brings

SALT(YASTF) is designed for organizations where trigger complexity has outgrown the scope of existing frameworks — not as a replacement for them, but as an evolution that addresses the scale challenges larger teams face.

The core contribution is a **declare-then-aggregate-then-execute** query model:

1. Handlers declare what data they need (via `QueryRequest` value types), not how to fetch it.
2. The framework collates all declarations across all handlers, merges compatible queries, and executes the minimum number of SOQL statements.
3. Handlers receive query results via a shared cache — each handler accessing only the fields it declared.

This approach — effectively dependency injection for SOQL — builds on the ecosystem's proven patterns: metadata-driven dispatch (pioneered by TAF), Unit of Work (established by fflib), Specification-based filtering, and field-hash recursion guards. SALT(YASTF) combines these into a complete trigger pipeline, delivered as **concentric layers** rather than a monolithic architecture. Each team adopts only the layers it needs:

- A 3-person team uses Layer 0 (dispatch + recursion) and stops — comparable simplicity to Kevin O'Hara, with metadata-driven configuration.
- A 10-person team adds query aggregation for their most complex triggers.
- A 40-person enterprise team uses all layers, including DML coordination and circuit breakers.

The framework is intended to complement the existing ecosystem. Teams already succeeding with TAF, fflib, or O'Hara's pattern should continue doing so — those frameworks are well-suited to their design targets. SALT(YASTF) is for the organizations that have grown beyond those targets and need the additional governor limit efficiency, recursion sophistication, and operational safety that come with scale.

---

# 2. Background

## 2.1 The Platform Constraints That Shape This Design

Every design decision in SALT(YASTF) is a response to a specific Force.com platform constraint. These constraints are immovable — they are not configuration options or best practices but hard limits enforced by the Apex runtime.

### Governor Limits (Synchronous Apex)

| Resource       | Limit                       | Impact on Trigger Design                                                                                                      |
| -------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| SOQL Queries   | 100 per transaction         | Every handler query competes with every other handler, cascade triggers, Flows, and Process Builders — all in the same budget |
| DML Statements | 150 per transaction         | Multiple handlers updating different objects exhaust the budget quickly without batching                                      |
| CPU Time       | 10,000 ms                   | Framework overhead must be negligible; business logic owns the budget                                                         |
| Heap Size      | 6 MB (sync) / 12 MB (async) | Query result caches and DML buffers must coexist within this ceiling                                                          |
| Query Rows     | 50,000 per transaction      | Redundant queries for overlapping record sets waste rows nobody uses                                                          |
| DML Rows       | 10,000 per transaction      | Cross-object cascades accumulate rows against a shared cap                                                                    |

The critical insight: **governor limits do not reset between cascading triggers.** When an Account trigger updates 50 Contacts, the Contact trigger's handlers consume the _same_ SOQL/DML/CPU budget as the Account trigger's handlers. Optimization at the individual handler level is insufficient — the framework must optimize across handlers, across objects, across cascade levels.

### Recursion Re-Entrancy

The Salesforce platform re-fires triggers in several scenarios that naive recursion guards handle incorrectly:

- **Workflow field updates** re-fire before-update and after-update triggers one additional time
- **Record-triggered Flows** (after-save) can perform DML that re-fires triggers on the same or different objects
- **`Database.insert(records, false)`** (partial saves) retries successful records after removing failures, re-firing the trigger with a smaller record set
- **Bulk operations exceeding 200 records** are chunked by the platform, with each chunk firing the trigger independently but within the same transaction

Static Boolean guards fail on chunking and partial saves. Static `Set<Id>` guards fail on partial saves and when records legitimately need reprocessing after field changes. No existing framework provides field-level change detection to distinguish "already processed with these values" from "values changed, reprocessing needed."

### The Observability Deficit

Apex provides no APM integration, no structured logging framework, no distributed tracing. `System.debug()` output is subject to a 5 MB debug log limit and is only generated when a trace flag is active. Governor limit consumption by observability mechanisms (log record DML, Platform Event publishing) competes directly with business logic.

Any trigger framework that provides observability must do so within these constraints — or accept that production monitoring is limited to coarse-grained alerting rather than fine-grained tracing.

## 2.2 Design Principles

SALT(YASTF) is grounded in two complementary bodies of design thinking, adapted for the constraints of the Force.com platform.

### SOLID Principles

| Principle                 | Application                                                                                                                                                                                                                                                                 | Platform Adaptation                                                                                                                                                                                        |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Single Responsibility** | One handler class per business rule. One reason to change: the business rule evolves.                                                                                                                                                                                       | Apex class count impacts deployment time and metadata limits. Splitting a handler into three classes (filter, query, logic) triples the count without adding SRP value — the three always change together. |
| **Open/Closed**           | New handlers require zero modification to existing code — new class + new metadata record.                                                                                                                                                                                  | Metadata-driven configuration (Custom Metadata Types) is stronger OCP than code-driven registration because the extension point is declarative.                                                            |
| **Liskov Substitution**   | Any handler can be used wherever `TriggerHandler` is expected. Capability interfaces are discovered via `instanceof` (Extension Interface pattern), not type hierarchy.                                                                                                     | Composition eliminates false IS-A relationships that inheritance would impose. A query-aware handler is not "a kind of" recursion-aware handler — it optionally has that capability.                       |
| **Interface Segregation** | Four focused capability interfaces (`IRecordFilter`, `IRecursionAware`, `IQueryAware`, `IDmlAware`). Handlers implement only what they need.                                                                                                                                | The 7-method base class is a deliberate Layer Supertype. No-op defaults have zero runtime cost, zero cognitive cost, and zero coupling cost. The cure (7 separate interfaces) would be worse.              |
| **Dependency Inversion**  | Handlers depend on `QueryResultCache` (abstraction hiding query execution) and `IDmlRegistrar` (interface hiding DML mechanism). The dispatcher depends on `TriggerHandler` (abstraction) and loads concrete handlers via metadata configuration — Fowler's Plugin pattern. | `QueryResultCache` is a concrete class, not an interface. Justified per Fowler: extract an interface when a second implementation is needed, not before.                                                   |

### Fowler's Domain Layering

| Fowler Pattern          | SALT(YASTF) Component                                                                             | Why This Fits                                                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Service Layer**       | `TriggerDispatcher` — orchestrates handler execution, controls transaction flow                   | Triggers need a single orchestrator that owns phase sequencing and error handling — Service Layer formalizes what dispatchers do informally. |
| **Layer Supertype**     | `TriggerHandler` — broad base class for the trigger domain layer                                  | Seven context methods with no-op defaults give every handler a uniform protocol without forcing interface bloat on simple cases.             |
| **Transaction Script**  | Handler classes — one procedure per business rule per trigger event                               | SObjects are sealed — Rich Domain Model is impossible on this platform. Transaction Script is the honest pattern for Apex business logic.    |
| **Unit of Work**        | `DmlRegistrar` + `DmlExecutor` — deferred, ordered, atomic DML                                    | Multiple handlers mutating different objects need coordinated commits. UoW batches DML, orders by dependencies, and provides rollback.       |
| **Specification**       | `IRecordFilter` + built-in predicates — declarative record selection                              | Record filtering is a cross-cutting concern. Specification pattern makes predicates composable, testable, and reusable across handlers.      |
| **Table Data Gateway**  | `QueryAggregator` + `QueryExecutor` — centralized, optimized query execution                      | Centralizing query execution is the prerequisite for cross-handler aggregation — the core problem SALT(YASTF) exists to solve.               |
| **Plugin**              | `TriggerHandler__mdt` — runtime class loading via external configuration                          | Metadata-driven registration means adding a handler requires zero code changes to existing classes — true Open/Closed extension.             |
| **Separated Interface** | `IQueryAware`, `IDmlAware`, `IDmlRegistrar` — abstraction defined independently of implementation | Capability interfaces decouple handler contracts from framework internals, enabling independent evolution under the frozen-interface policy. |

**Patterns deliberately rejected:**

| Pattern                              | Why Rejected                                                                                                                                                                  |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Rich Domain Model**                | Apex SObjects are sealed platform classes. Every Salesforce architecture is anemic by Fowler's definition.                                                                    |
| **Repository**                       | Governor limits require visible query cost. Hiding queries behind an abstraction is dangerous.                                                                                |
| **Data Mapper**                      | SObjects serve as both data transfer objects and domain objects. No separate mapping layer is possible.                                                                       |
| **Identity Map** (cross-transaction) | Static variables reset per transaction. Platform Cache is non-durable.                                                                                                        |
| **Lazy Loading**                     | The framework's value is declaring data needs upfront for aggregation. Lazy loading inverts this.                                                                             |
| **Domain Events** (in-transaction)   | Metadata-driven ordering provides deterministic, auditable coordination. Events add non-deterministic ordering and governor risk in a constrained single-transaction context. |

---

# 3. The Layered Architecture

## 3.1 Design Rationale

A monolithic trigger pipeline — even a well-designed one — demands that every developer understand the full execution model before writing a single handler. The cognitive load of a 9-step pipeline with callback-based query collation, deferred DML, and field-hash recursion guards is roughly 10 concepts. For a 40-person team with mixed experience levels, this is an adoption barrier.

The solution is **concentric layers**. Each layer adds capability without modifying the layers beneath it. A developer chooses their layer by which interfaces they implement. Different handlers on the same SObject can use different layers. The team's complexity budget is spent precisely where the problem demands it.

## 3.2 Layer Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                      IDmlAware (Layer 3)                         │
│            Deferred DML, conflict detection, ordering            │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                   IQueryAware (Layer 2)                    │  │
│  │        Query declaration, aggregation, cache               │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │             IRecursionAware (Layer 1)                │  │  │
│  │  │     Field-hash guard, invocation counter, cascade    │  │  │
│  │  │  ┌────────────────────────────────────────────────┐  │  │  │
│  │  │  │           TriggerHandler (Layer 0)             │  │  │  │
│  │  │  │   Dispatch, ordering, Set<Id> guard, bypass    │  │  │  │
│  │  │  └────────────────────────────────────────────────┘  │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │            IRecordFilter (any layer, opt-in)               │  │
│  │         Specification-based record selection               │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

**Layers are not inherited — they are composed.** A handler extends `TriggerHandler` (the sole base class) and implements any combination of capability interfaces.

**Why composition over inheritance:** An inheritance chain (`TriggerHandler` → `RecursionAwareHandler` → `QueryAwareHandler` → `DmlAwareHandler`) creates three problems:

1. **Forced coupling.** A developer who wants only query aggregation (Layer 2) is forced to also accept field-hash recursion (Layer 1). The chain bundles capabilities that have no inherent dependency on each other.
2. **Sealed method over-constraint.** Using `final` on context methods to force the two-phase query model prevents handlers from mixing simple field logic (which needs no queries) with query-dependent logic in the same class.
3. **False IS-A relationships.** A query-aware handler is not "a kind of" recursion-aware handler — it optionally has that capability. Inheritance lies about the domain relationship to achieve code reuse.

Composition resolves all three. Each capability is an independent interface. A handler declares exactly what it needs — `implements IQueryAware` or `implements IRecursionAware, IDmlAware` or any other combination. The dispatcher discovers capabilities via `instanceof` (the Extension Interface pattern), preserving Liskov Substitution: any handler can be used wherever `TriggerHandler` is expected, regardless of which interfaces it implements.

### Layer 0 — Foundation (3 concepts, all adopters)

| Capability                   | Mechanism                                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------------------------- |
| Single trigger per SObject   | Logicless trigger calls `TriggerDispatcher.run()`                                              |
| Metadata-driven registration | `TriggerHandler__mdt` records: class name, order, context, active flag                         |
| Execution ordering           | `Order__c` field on metadata — deterministic, admin-configurable                               |
| Recursion guard              | `Set<Id>` per handler per context — prevents reprocessing same records                         |
| Bypass                       | Scoped: per-handler, per-SObject, per-context. Type-safe API. Admin seal via `AllowBypass__c`. |

**Why type-safe bypass and admin seal:** Most trigger frameworks provide bypass via a string-based API — `bypass('HandlerName')`. This creates a privilege escalation vector: any Apex code in the transaction, including installed managed packages, can silently disable security-critical handlers by passing the class name as a string. SALT(YASTF)'s bypass API requires a compile-time `Type` reference — `bypass(AuditHandler.class)` — which cross-namespace code cannot obtain for `public` (non-`global`) classes. For handlers that must never be bypassed regardless of API calls (compliance, audit), the `AllowBypass__c = false` metadata flag provides an admin-controlled seal that no code path can override.

**Developer experience:** Extend `TriggerHandler`, override one context method, create a metadata record. Time to productive: 30 minutes. Comparable to Kevin O'Hara with metadata-driven configuration from TAF.

### Layer 1 — Enhanced Recursion (opt-in via `IRecursionAware`)

| Capability                 | Mechanism                                                                                                                                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Field-hash recursion guard | Compares hash of declared fields across trigger invocations. Re-processes only when watched fields change. Zero collision risk (String concatenation, not 32-bit hashCode). |
| Invocation counter         | Per-handler, per-record. Configurable max (`MaxReentrancy__c`). Prevents ping-pong between handlers.                                                                        |
| Cascade depth limit        | Static counter, configurable (`CascadeDepthLimit__c`). Throws `CascadeDepthException` before hitting platform's hard limit of 16.                                           |
| Insert-context safety      | Field-hash disabled for `beforeInsert`/`afterInsert` (records have no stable IDs). Invocation counter only, max configurable via `MaxReentrancy__c` (CMDT default: 2).      |
| State pruning              | Recursion guard entries for a completing SObjectType are pruned when cascade depth decrements, releasing heap.                                                              |

**Developer experience:** Implement `IRecursionAware`, return the fields you care about from `getRecursionFields()`. The framework handles the rest.

### Layer 2 — Query Optimization (opt-in via `IQueryAware`)

| Capability                  | Mechanism                                                                                                                                                                   |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Declarative query needs     | Handler calls `declareQueryNeeds()` returning `List<QueryRequest>` — target SObject, fields, relationship, record IDs, optional `Predicate` filter tree, optional child subquery, optional tag. |
| Predicate trees             | `Predicate` interface with `FieldFilter` leaves (8 ops) and `CompositePredicate` AND/OR/NOT combinators. Real DNF/CNF business rules express at the framework boundary. ([ADR 0006](adr/0006-predicate-trees-and-or-merge.md)) |
| Child relationship subqueries | `withChildSubquery(childLookupField, childFields, childFilter, childLimit)` renders `(SELECT … FROM <relName> WHERE … LIMIT …)` for `EXISTS`-style parent-with-matching-child semantics. |
| Per-handler tags            | `tag(name)` disambiguates two distinct queries from the same handler against the same merge key (e.g. an Account handler that both notifies open-Case Contacts and propagates a rule to opted-in Contacts). |
| Query aggregation           | `QueryAggregator.canMergeOrUnion(a, b)` is the single merge-precondition gate. Returns `REFUSE` (FLS mismatch / SObject mismatch / shape mismatch / tag collision), `MERGE_IDENTITY` (structurally equal predicates), `MERGE_OR` (OR-merge with union field sets), or `MERGE_SUBSUME` (one side empty filters → matcher re-applies the other side at retrieval). ([ADR 0005](adr/0005-query-aggregation-and-batch-execution.md)) |
| Unified execution           | `QueryExecutor` renders dynamic SOQL with optional child subquery and flat-AND or OR'd predicate clause; runs `Database.queryWithBinds(soql, bindMap, AccessLevel.SYSTEM_MODE)`; chunks at 900 IDs via `QueryRequest.withChunkedIds()` preserving every dimension. |
| Provenance                  | 4-level maps: `Map<mergeKey, Map<handler, Map<tag, Set<Id>>>>` for ids, fields, and filters. CSV-joined handler-name substrate is gone — provenance is structured end-to-end. |
| Callback delivery           | Handler's `onDataReady()` receives `cache.getForHandler(handler, sObj, relField, tag)` — deep-cloned (`clone(true,true,true,false)` preserves child collections) and field-stripped to the handler's declared field set. |
| Matcher re-application      | When the source request was OR-merged (`wasOrMerged == true`), the cache walks the handler's `Predicate` list and re-applies it in-memory so each handler sees only the rows that satisfy *its* filter, not the OR'd union. Matcher is invoked **only** on OR-merged retrievals — bounds the correctness liability to that fire path. |
| Per-(handler, tag) eviction | `markHandlerTagServed(handler, tag)` releases the merge-key cache slot when **all** declared `(handler, tag)` consumers have read. This is the heap-safety mechanism that makes OR-merge viable at scale. |
| Circuit breakers            | **SOQL** (checked once before query execution): cascade-adaptive `limit - soqlReserve - cascadeDepth*soqlPerCascade`. **Heap** (checked once before query execution): `Limits.getLimitHeapSize() * 0.75`. **CPU** (checked **per handler** during Phase 3 execution): `Limits.getLimitCpuTime() * cpuThresholdFraction`, default 0.75 = 7,500 ms. All three configurable. Non-critical handlers skipped on breach; critical handlers logged with WARN. The CPU breaker is path-dependent — small CPU variations across runs can change which handler triggers the threshold and produce structurally different downstream cascades; benchmark / regression-test runs should set `cpuThresholdFraction = 2.0` to disable it. |
| QueryBuilder                | Fluent API producing `QueryRequest` value types. `forIds()` is mandatory — `build()` throws otherwise. Reserved bind prefix `__salt_*` rejected on filter field names too. |
| System mode by default      | Every `Database.queryWithBinds` call passes `AccessLevel.SYSTEM_MODE` explicitly — for API-version stability across Apex 60+, not for security. `withFLS()` is the opt-in for non-trigger callers (Queueable, batch, controllers). ([ADR 0001](adr/0001-query-pipeline-integrity-posture.md)) |

**Developer experience:** Implement `IQueryAware`. Declare what data you need in `declareQueryNeeds()`, receive it in `onDataReady()`. You cannot accidentally issue ad-hoc SOQL because the framework provides data via the cache — the path of least resistance is the correct path.

**This layer addresses the cross-handler query aggregation challenge that motivated SALT(YASTF)'s creation.**

### Layer 3 — DML Coordination (opt-in via `IDmlAware`)

| Capability                       | Mechanism                                                                                                                                                                  |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deferred DML                     | Write-only `IDmlRegistrar` — handlers call `registerNew()`, `registerDirty()`, `registerDeleted()`. No direct DML.                                                         |
| Context-aware registration       | Before-trigger: `registerDirty()` applies to `Trigger.new` directly (platform saves automatically). After-trigger: buffers for Phase 4 commit.                             |
| Cross-handler conflict detection | Symmetrical across trigger phases. Two handlers setting the same field on the same record: same value = WARN, different values = `FieldConflictException`.                 |
| Dependency-aware ordering        | Topological sort from schema relationships + developer-declared dependencies. Parent objects committed before children. Foreign key resolution for newly inserted parents. |
| Atomic commit                    | Savepoint before DML execution, rollback on any failure. Error provenance: exception enriched with "field X set by handler Y."                                             |
| Lock contention handling         | `UNABLE_TO_LOCK_ROW` caught and surfaced as a distinct transient error, not attributed to a handler.                                                                       |

**Why write-only registrar:** Exposing `getPendingInserts()` or `getPendingUpdates()` on the registrar would allow Handler B to inspect what Handler A registered — creating fragile implicit coupling where Handler B's behavior silently changes if Handler A's execution order changes or if Handler A is degraded by the circuit breaker. The registrar is write-only by design, enforcing Command-Query Separation. If cross-handler DML observation is needed in future, it will be introduced as a separate, explicit `IDmlObserver` interface that makes the dependency visible and contractual.

**Why context-aware registration:** In before-trigger context, the platform automatically saves mutations to `Trigger.new` — issuing an explicit `update` via DML would be redundant and would re-fire the trigger. The registrar detects the trigger phase and adapts: `registerDirty()` in before-trigger applies field values directly to the `Trigger.new` record (with conflict detection), while in after-trigger it buffers for the Phase 4 commit. This keeps the handler's code identical regardless of context — the framework handles the semantic difference.

**Developer experience:** Implement `IDmlAware`. Register mutations in `onDmlReady()`. The framework batches, orders, and commits.

## 3.3 Execution Flow

The dispatcher executes a 5-phase pipeline on every trigger invocation. Phases are sequential; handler execution within Phase 3 is a single pass in `Order__c` sequence.

```
┌─────────────────────────────────────────────────────┐
│                TriggerDispatcher.run()              │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  GUARD: Return early if PE/CDC                      │
│  LOAD: TriggerHandler__mdt (cached per SObject)     │
│  FILTER: active + SObject + context                 │
│  SORT: by Order__c                                  │
│  INSTANTIATE: Type.forName → throw/skip on null     │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  PHASE 1: Record Filtering                          │
│                                                     │
│  For each handler with IRecordFilter:               │
│    isApplicable() per record                        │
│    Zero match → mark handler SKIPPED                │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  PHASE 2: Query Declaration + Aggregation + Exec    │
│                                                     │
│  For each non-skipped IQueryAware handler:          │
│    declareQueryNeeds() → List<QueryRequest>         │
│      (with optional Predicate tree, child subquery, │
│       and per-handler tag)                          │
│  QueryAggregator.canMergeOrUnion(a, b) merge gate:  │
│    REFUSE / MERGE_IDENTITY / MERGE_OR / MERGE_SUBSUME│
│  Circuit breakers: SOQL (cascade-adaptive) + Heap   │
│  QueryExecutor: render dynamic SOQL with optional   │
│    child subquery + flat-AND or OR'd predicate;     │
│    Database.queryWithBinds(SYSTEM_MODE);            │
│    chunked via withChunkedIds()                     │
│  QueryResultCache populated; 4-level provenance     │
│    Map<mergeKey, Map<handler, Map<tag, …>>>         │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  PHASE 3: Handler Execution                         │
│  (ALL handlers, single pass, Order__c sequence)     │
│                                                     │
│  For each handler:                                  │
│    1. Bypass check (already done pre-instantiation) │
│    2. Recursion guard (Set<Id> manual API for L0,   │
│        invocation counter / field-hash for L1)      │
│    3. If SKIPPED or QUERY_SKIPPED → skip            │
│    4. IQueryAware → onDataReady(                    │
│         cache.getForHandler(handler, sObj,          │
│           relField, tag))                           │
│       — deep clone + field strip;                   │
│       — matcher re-applies handler's Predicate tree │
│         when source request was OR-merged           │
│       OR standard context method                    │
│    5. IDmlAware → onDmlReady(registrar)             │
│    6. markHandlerTagServed → per-(handler,tag)      │
│        eviction releases merge-key cache slot when  │
│        all consumers have read                      │
│    7. Exception: before=all-critical                │
│    Note: Telemetry instrumentation deferred         │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  PHASE 4: DML Commit (after-trigger only)           │
│                                                     │
│  Conflict detection (same-value=WARN, diff=FAIL)    │
│  Topological sort + FK resolution                   │
│  Savepoint → ordered DML → rollback on failure      │
│  Error provenance: "field X set by handler Y"       │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  CASCADE MANAGEMENT                                 │
│                                                     │
│  Decrement cascade depth                            │
│  Prune recursion state for completing SObjectType   │
│  Circuit breaker alert (Platform Event, try-catch)  │
│  Active bypass warning (gated by TriggerTelemetry)  │
└─────────────────────────────────────────────────────┘
```

**Why a single pass in Phase 3:** Splitting execution into two passes — all Layer 0/1 handlers first, then all Layer 2/3 handlers — would violate the `Order__c` contract: a Layer 2 handler at `Order__c = 10` would execute _after_ a Layer 0 handler at `Order__c = 30`, silently contradicting the metadata configuration. The admin sees Order 10 before Order 30 and expects that sequence. The single-pass design honors the `Order__c` contract across all handler types. Phase 2 (query aggregation) collects declarations from all IQueryAware handlers before Phase 3, but execution itself is one ordered pass — Layer 0, Layer 1, Layer 2, and Layer 3 handlers interleaved by their configured order.

**Why before-trigger handlers are always critical:** In before-trigger context, handlers mutate `Trigger.new` records directly. These mutations are irrevocable within the transaction — there is no savepoint mechanism that can undo a field change on `Trigger.new`. If a non-critical handler fails mid-execution after partially mutating records, the transaction continues with inconsistent field state. The only safe behavior is fail-fast: if any before-trigger handler throws, the entire transaction fails. The `IsCritical__c` metadata flag is honored only in after-trigger context, where Phase 4's savepoint provides a rollback path.

## 3.4 Configuration: TriggerHandler\_\_mdt

| Field                                  | Type          | Default  | Purpose                                                               |
| -------------------------------------- | ------------- | -------- | --------------------------------------------------------------------- |
| `SObjectType__c`                       | Text(80)      | Required | SObject API name                                                      |
| `HandlerClass__c`                      | Text(255)     | Required | Fully qualified Apex class name                                       |
| `Namespace__c`                         | Text(15)      | Blank    | For managed package handlers                                          |
| `Order__c`                             | Number(3,0)   | Required | Execution sequence (10, 20, 30...)                                    |
| `IsActive__c`                          | Checkbox      | true     | Master on/off                                                         |
| `BeforeInsert__c` — `AfterUndelete__c` | Checkbox (x7) | false    | Context enablement                                                    |
| `BypassPermission__c`                  | Text(80)      | Blank    | Custom Permission API name for bypass                                 |
| `BypassUsers__c`                       | LongTextArea  | Blank    | User IDs for bypass                                                   |
| `BypassProfiles__c`                    | LongTextArea  | Blank    | Profile IDs for bypass                                                |
| `AllowBypass__c`                       | Checkbox      | true     | When false, handler cannot be bypassed by any mechanism               |
| `MaxReentrancy__c`                     | Number(2,0)   | 2        | Max invocations per record (IRecursionAware)                          |
| `CascadeDepthLimit__c`                 | Number(2,0)   | 3        | Max trigger nesting depth                                             |
| `IsCritical__c`                        | Checkbox      | true     | If false: skippable by circuit breaker, deployable without Apex class |

---

# 4. Class Diagram and Specifications

## 4.1 Class Diagram

```
════════════════════════════════════════════════════════════════
 CONFIGURATION
════════════════════════════════════════════════════════════════

 ┌─────────────────────────────┐
 │    «Custom Metadata»        │
 │   TriggerHandler__mdt       │
 ├─────────────────────────────┤
 │ SObjectType__c              │
 │ HandlerClass__c             │
 │ Namespace__c                │
 │ Order__c                    │
 │ IsActive__c                 │
 │ IsCritical__c               │
 │ AllowBypass__c              │
 │ MaxReentrancy__c            │
 │ CascadeDepthLimit__c        │
 │ [7 context checkboxes]      │
 │ [3 bypass fields]           │
 └──────────────┬──────────────┘
                │ reads
                ▼
════════════════════════════════════════════════════════════════
 ORCHESTRATION
════════════════════════════════════════════════════════════════

 ┌─────────────────────────────┐
 │    TriggerDispatcher        │
 ├─────────────────────────────┤
 │ +run()                      │
 │ +bypass(Type)               │
 │ +clearBypass(Type)          │
 │ +bypassForNextDmlEvent(Type)│
 │ +setSoqlReserve(Integer)    │
 └──────────────┬──────────────┘
                │ instantiates
                ▼
════════════════════════════════════════════════════════════════
 HANDLER BASE
════════════════════════════════════════════════════════════════

 ┌─────────────────────────────┐
 │ «abstract» TriggerHandler   │
 ├─────────────────────────────┤
 │ #beforeInsert(List<SObject>)│
 │ #afterInsert(List<SObject>) │
 │ #beforeUpdate(List, Map)    │
 │ #afterUpdate(List, Map)     │
 │ #beforeDelete(Map)          │
 │ #afterDelete(Map)           │
 │ #afterUndelete(List)        │
 │ #hasBeenProcessed(Id)       │
 │ #markProcessed(Id)          │
 │ #getHandlerName()           │
 └──────┬──────────┬───────────┘
        │          │ extends
        ▼          ▼
 ┌────────────┐ ┌────────────┐ ┌────────────┐
 │ Simple     │ │ Query      │ │ Full       │
 │ Handler    │ │ Handler    │ │ Handler    │
 │ (Layer 0)  │ │ implements │ │ implements │
 │            │ │ IRecord    │ │ all 4      │
 │            │ │ Filter,    │ │ interfaces │
 │            │ │ IQueryAware│ │            │
 └────────────┘ └────────────┘ └────────────┘

════════════════════════════════════════════════════════════════
 CAPABILITY INTERFACES (all @frozen v1.0)
════════════════════════════════════════════════════════════════

 ┌──────────────────┐   ┌──────────────────┐
 │ «interface»      │   │ «interface»      │
 │ IRecordFilter    │   │ IRecursionAware  │
 ├──────────────────┤   ├──────────────────┤
 │ +isApplicable(   │   │ +getRecursion    │
 │   SObject new,   │   │   Fields()       │
 │   SObject old,   │   │                  │
 │   TriggerContext)│   └──────────────────┘
 └────────┬─────────┘
          │ built-in implementations
          ▼
 ┌──────────────────┐
 │ FieldChanged     │
 │ FieldNotNull     │
 │ RecordTypeIs     │
 │ And / Or / Not   │
 └──────────────────┘

 ┌──────────────────┐   ┌──────────────────┐
 │ «interface»      │   │ «interface»      │
 │ IQueryAware      │   │ IDmlAware        │
 ├──────────────────┤   ├──────────────────┤
 │ +declareQuery    │   │ +onDmlReady(     │
 │   Needs(List,Map)│   │   IDmlRegistrar) │
 │ +onDataReady(    │   │                  │
 │   List, Map,     │   └──────────────────┘
 │   QueryResult    │
 │   Cache)         │
 └──────────────────┘

════════════════════════════════════════════════════════════════
 QUERY SUBSYSTEM (Layer 2)
════════════════════════════════════════════════════════════════

 ┌──────────────────────┐  produces   ┌──────────────────────┐
 │ QueryBuilder         ├────────────►│ QueryRequest         │
 ├──────────────────────┤             │ (value object)       │
 │ +onObject(SObjType)  │             ├──────────────────────┤
 │ +forIds(Set<Id>)     │             │ targetObject         │
 │ +where(Predicate)    │             │ recordIds            │
 │ +withChildSubquery(  │             │ fields               │
 │   childLookupField,  │             │ relationshipField    │
 │   childFields,       │             │ enforceFLS           │
 │   childFilter,       │             │ filters: List<Pred>  │
 │   childLimit)        │             │ childSubquery        │
 │ +tag(String)         │             │ tag                  │
 │ +withFLS()           │             │ wasOrMerged          │
 │ +build()             │             │ idsByHandler  4-lvl  │
 │   forIds() mandatory │             │ fieldsByHandler 4-lvl│
 └──────────────────────┘             │ filtersByHandler 4-l │
                                       │ +withChunkedIds()    │
                                       └────────┬─────────────┘
                                                │ merges via
                                                ▼
                                       ┌──────────────────────┐
                                       │ QueryAggregator      │
                                       ├──────────────────────┤
                                       │ +addRequests()       │
                                       │ +canMergeOrUnion()   │
                                       │   → REFUSE /         │
                                       │     MERGE_IDENTITY / │
                                       │     MERGE_OR /       │
                                       │     MERGE_SUBSUME    │
                                       │ never mutates inputs │
                                       └────────┬─────────────┘
                                                │ executes via
                                                ▼
                                       ┌──────────────────────┐
                                       │ QueryExecutor        │
                                       ├──────────────────────┤
                                       │ +execute()           │
                                       │  dynamic SOQL        │
                                       │  child subquery      │
                                       │  flat-AND or OR'd    │
                                       │    predicate clause  │
                                       │  Database.queryWith  │
                                       │    Binds(SYSTEM_MODE)│
                                       │  withChunkedIds()    │
                                       │  FLS gate (opt-in)   │
                                       └────────┬─────────────┘
                                                │ populates
                                                ▼
                                       ┌──────────────────────┐
                                       │ QueryResultCache     │
                                       ├──────────────────────┤
                                       │ +getForHandler(      │
                                       │   handler, sObj,     │
                                       │   relField, tag)     │
                                       │ +markHandlerTagServed│
                                       │ deep clone           │
                                       │   (true,true,true,   │
                                       │    false) preserves  │
                                       │   child collections  │
                                       │ field strip          │
                                       │ matcher re-apply     │
                                       │   when wasOrMerged   │
                                       │ per-(handler,tag)    │
                                       │   eviction           │
                                       │ throws on evict /    │
                                       │   unknown handler /  │
                                       │   ambiguous tag      │
                                       └──────────────────────┘

 Predicate hierarchy:

 ┌──────────────────────┐
 │ «interface»          │
 │ Predicate            │
 ├──────────────────────┤
 │ +matches(SObject)    │
 │ +render(BindContext) │
 │ +equalsPredicate()   │
 └────────┬─────────────┘
          │ implements
          ▼
 ┌──────────────────────┐   ┌──────────────────────┐
 │ FieldFilter (leaf)   │   │ CompositePredicate   │
 ├──────────────────────┤   │ (combinator)         │
 │ enum Operator:       │   ├──────────────────────┤
 │  EQUALS, NOT_EQUALS, │   │ enum Combinator:     │
 │  IN, NOT_IN,         │   │  AND_OP, OR_OP,      │
 │  LT, LE, GT, GE      │   │  NOT_OP              │
 │ structural equals/   │   │ +andOf(Predicate...) │
 │   hashCode           │   │ +orOf(Predicate...)  │
 │ tier-1 in-memory     │   │ +notOf(Predicate)    │
 │   matcher fixes      │   │ tree renderer always │
 │ tier-2 factory       │   │   parenthesizes      │
 │   rejections         │   │   non-leaf nodes     │
 └──────────────────────┘   └──────────────────────┘

 ┌──────────────────────┐    ┌──────────────────────┐
 │ ChildSubqueryDescr.  │    │ BindContext          │
 ├──────────────────────┤    ├──────────────────────┤
 │ childLookupField     │    │ bind name allocator  │
 │ childFields          │    │ bindMap              │
 │ childFilter:Predicate│    │ reserved __salt_*    │
 │ childLimit           │    │   prefix             │
 └──────────────────────┘    └──────────────────────┘

════════════════════════════════════════════════════════════════
 DML SUBSYSTEM (Layer 3)
════════════════════════════════════════════════════════════════

 ┌──────────────────┐
 │ «interface»      │
 │ IDmlRegistrar    │
 │ (write-only)     │
 ├──────────────────┤
 │ +registerNew()   │
 │ +registerDirty() │
 │ +registerDeleted()│
 │ +declareDep()    │
 └────────┬─────────┘
          │ implements
          ▼
 ┌──────────────────┐  commits   ┌──────────────────┐
 │ DmlRegistrar     ├───────────►│ DmlExecutor      │
 ├──────────────────┤            ├──────────────────┤
 │ context-aware    │            │ +commitWork()    │
 │ field provenance │            │  topological sort│
 │ conflict detect. │            │  savepoint       │
 └──────────────────┘            │  FK resolution   │
                                 │  error provenance│
 ┌──────────────────┐            └──────────────────┘
 │ FieldConflict    │
 │ (value type)     │
 ├──────────────────┤
 │ recordId         │
 │ conflictField    │
 │ handlerA / B     │
 │ valueA / B       │
 └──────────────────┘

════════════════════════════════════════════════════════════════
 CROSS-CUTTING
════════════════════════════════════════════════════════════════

 ┌──────────────────┐   ┌──────────────────────┐
 │ RecursionGuard   │   │ TriggerTelemetry     │
 ├──────────────────┤   ├──────────────────────┤
 │ field-hash map   │   │ +captureSnapshot()   │
 │ invocation ctrs  │   │ +getReport()         │
 │ cascade depth    │   │ +getExecutionManifest│
 │ +prune(SObType)  │   └──────────────────────┘
 └──────────────────┘

 ┌──────────────────────────────┐
 │ «Platform Event»             │
 │ TriggerFrameworkAlert__e     │
 ├──────────────────────────────┤
 │ Published on circuit breaker │
 │ fire (try-catch wrapped)     │
 └──────────────────────────────┘
```

## 4.2 Interface Specifications

All interfaces are **frozen at v1.0**. New capabilities will only be added as new interfaces, never as methods on existing interfaces. This is enforced by CI.

**Why frozen interfaces:** Apex does not support default methods on interfaces (unlike Java 8+). Adding a method to `IQueryAware` — even one with an obvious default behavior — would break every existing handler class that implements it (compiler error: missing method implementation). In a public open-source framework, this means every adopter's code breaks on upgrade. The only non-breaking evolution path in Apex is to introduce new capabilities as new interfaces (e.g., `IQueryErrorAware`) that handlers opt into independently. The dispatcher discovers capabilities via `instanceof`, so new interfaces require no modification to existing framework code. This policy is enforced mechanically: a CI check flags any modification to a `@frozen` interface as a build failure.

### IRecordFilter

```apex
public interface IRecordFilter {
  Boolean isApplicable(
    SObject newRecord,
    SObject oldRecord,
    TriggerContext ctx
  );
}
```

- `newRecord` is null in delete contexts. `oldRecord` is null in insert/undelete.
- Built-in implementations handle null inputs with defined behavior per context.
- Must be O(1) per record — pure predicate, no SOQL, no side effects.

### IRecursionAware

```apex
public interface IRecursionAware {
  List<SObjectField> getRecursionFields();
}
```

- INSERT contexts: field-hash disabled (no stable IDs). Invocation counter only. Max configurable via `MaxReentrancy__c` (CMDT default: 2).
- UPDATE/DELETE contexts: field-hash via length-prefixed concatenation (`strVal.length() + ':' + strVal` joined by `|`). Zero collision risk — length-prefix eliminates delimiter collision.

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

- `applicableRecords` is a defensive copy — handler cannot mutate the framework's list.
- All queries execute before any handler runs in Phase 3. If Handler B's query depends on Handler A's Phase 3 mutations, use a Layer 0 handler for A.
- Query primitives available on `QueryBuilder`:
  - `.where(Predicate)` — flat AND across multiple `.where()` calls; pass a `CompositePredicate` tree (`andOf` / `orOf` / `notOf`) for OR/NOT inside a single filter. Real DNF/CNF business rules express at the framework boundary.
  - `.withChildSubquery(childLookupField, childFields, childFilter, childLimit)` — `EXISTS`-style parent-with-matching-child semantics; the child relationship name is resolved from the parent's child relationships.
  - `.tag(name)` — disambiguates two distinct queries from the same handler against the same merge key.
- `onDataReady` retrieves data via `cache.getForHandler(handlerName, sObjectType, relationshipField, tag)` — returns deep-cloned, field-stripped rows specific to this handler. When the source request was OR-merged, the matcher re-applies the handler's `Predicate` list so each handler sees only the rows that satisfy its own filter, not the OR'd union.

### IDmlAware

```apex
public interface IDmlAware {
  void onDmlReady(IDmlRegistrar registrar);
}
```

### IDmlRegistrar (write-only)

```apex
public interface IDmlRegistrar {
  void registerNew(SObject record);
  void registerNew(SObject record, SObjectField fkField, SObject relatedTo);
  void registerDirty(SObject record, List<SObjectField> dirtyFields);
  void registerDeleted(SObject record);
  void declareDependency(SObjectType source, SObjectType target);
}
```

- No read methods. Write-only by design — prevents implicit cross-handler coupling.
- Context-aware: before-trigger `registerDirty()` applies to `Trigger.new` directly with conflict detection.

## 4.3 Exception Hierarchy

```
TriggerFrameworkException (base — includes handlerName, context, step)
  ├── RecursionLimitException      — handler exceeded MaxReentrancy__c
  ├── CascadeDepthException        — trigger nesting exceeded CascadeDepthLimit__c
  ├── FlsException                 — field inaccessible to running user
  ├── FieldConflictException       — two handlers set same field to different values
  ├── DmlCoordinationException     — DML error enriched with field provenance
  ├── SoqlBudgetException          — SOQL circuit breaker: all critical handlers exceed budget
  └── CyclicDependencyException    — circular dependency in DML ordering graph
```

---

# 5. Closure

SALT(YASTF) exists because the Salesforce trigger ecosystem has a specific, validated gap: no framework aggregates SOQL across handlers before execution. Every existing framework — however well-designed — leaves each handler to independently consume the most constrained resource on the platform.

The framework addresses this gap without requiring teams to abandon what works. Layer 0 is deliberately familiar — a developer who knows Kevin O'Hara or TAF will be productive in minutes. Layers 1-3 are available when the problems they solve become real, not before.

The architecture is grounded in SOLID principles and Fowler's domain layering, adapted — not compromised — for the constraints of the Force.com platform. The accepted tradeoffs are documented, justified, and bounded in Appendix A.

The framework is ready to build.

**Acknowledgments:** SALT(YASTF) stands on the work of Kevin O'Hara (sfdc-trigger-framework), Mitch Spano (Trigger Actions Framework), Andrew Fawcett (fflib/Apex Enterprise Patterns), and Hari Krishnan (Hari Architecture Framework). Their open-source contributions established the patterns this framework extends.

---

# Appendix A — Tradeoffs, Risks, and Assumptions

## A.1 Accepted Tradeoffs

| #   | Tradeoff                                                                         | Why Accepted                                                                                | Mitigation                                                                                                         |
| --- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| T1  | Batch-query-then-execute: handlers see pre-modification data for queries         | Core value proposition — aggregation requires collecting all declarations before execution. | Documented escape hatches: use Layer 0 for field-modifying logic, or split across trigger contexts.                |
| T2  | Field enforcement is test-time only; production reads undeclared fields silently | Zero heap overhead vs. 2-5MB heap duplication for per-handler projections.                  | `TriggerHandlerTestBase` provides hook point for future field-access tracking (placeholder — not yet implemented). |
| T3  | Cache eviction is entry-level (SObjectType\|relationship), not field-level       | Apex SObject API has no `removeField()`.                                                    | Use separate QueryRequests for disjoint field sets on the same relationship.                                       |
| T4  | IRecordFilter skip bypasses entire handler including IDmlAware                   | If zero records are applicable, no DML should target them.                                  | Documented: unconditional DML handlers should not implement IRecordFilter.                                         |
| T5  | SOQL circuit breaker is heuristic; cannot predict future cascade needs           | Unsolvable without look-ahead.                                                              | Safe failure mode: skip non-critical handlers, continue context-method handlers. Platform Event alerting.          |
| T6  | String field-hash uses more memory than 32-bit hashCode                          | Zero collision risk eliminates ~3% silent skip rate at scale.                               | ~300KB in 3-level cascade. Pruned on cascade depth decrement.                                                      |
| T7  | Non-critical before-trigger handlers that throw block the SObject                | Irrevocable `Trigger.new` mutations make partial failure unsafe.                            | The handler must be fixed. IsCritical\_\_c is ignored in before-trigger — documented with INFO log.                |
| T8  | Default IsCritical\_\_c = true creates deployment ordering sensitivity           | Safe default is more important than deployment convenience.                                 | Deploy Apex before CMDT, or set IsCritical=false during development.                                               |
| T9  | Type-safe `bypass(Type)` is a breaking change from string-based API              | Eliminates privilege escalation vector (cross-namespace bypass).                            | Migration is mechanical: `bypass("X")` → `bypass(X.class)`.                                                        |
| T10 | IDmlObserver deferred to post-v1.0                                               | YAGNI — cross-handler DML visibility is acknowledged as rare.                               | Can be added as a new interface under the frozen-interface policy.                                                 |
| T11 | Interface evolution requires new interfaces, never new methods                   | Apex lacks default methods. Only non-breaking evolution path.                               | Bounded by finite capability set. CI enforces `@frozen` marker.                                                    |
| T12 | Defensive copy of applicableRecords adds ~0.02ms per handler                     | Negligible.                                                                                 | Eliminates inter-handler list mutation bugs that are extremely difficult to diagnose.                              |
| T13 | forIds() mandatory on QueryBuilder removes unscoped query flexibility            | Unbounded SOQL in a trigger context is never correct.                                       | If needed, add `QueryBuilder.unscoped()` in a future version with explicit opt-in.                                 |

## A.2 Accepted Risks

| Risk                                                                                 | Probability                                             | Impact                                                                     | Mitigation                                                                                                                                     |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Heap overflow in complex cascade scenarios with 5+ Layer 2/3 handlers                | Medium (specific to large orgs with deep object graphs) | Transaction failure (`LimitException`)                                     | Heap circuit breaker at 75% of limit. Cache eviction after each handler. Recursion state pruning on cascade exit.                              |
| Platform behavior change (e.g., Flow-trigger ordering, governor limit adjustments)   | Low (Salesforce changes major behavior ~1x/year)        | Framework may need adaptation                                              | Circuit breakers use dynamic `Limits.getLimitQueries()` — auto-adapts if limits increase. Flow ordering changes affect all frameworks equally. |
| Developer writes SOQL in IQueryAware handler (bypasses aggregation)                  | Medium (human error)                                    | Governor limit waste                                                       | `TriggerHandlerTestBase` asserts `Limits.getQueries()` matches expected. Code review.                                                          |
| Managed package installs SALT(YASTF) and subscriber has conflicting trigger patterns | Low-Medium (ISV scenario)                               | Potential double-processing if subscriber has independent recursion guards | Migration guide. SALT(YASTF)'s recursion guards are handler-keyed — they do not interfere with subscriber's static Booleans.                   |

## A.3 Assumptions

| #   | Assumption                                                                       | If Violated                                                                             |
| --- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| 1   | Handlers correctly declare their query needs via IQueryAware                     | Ad-hoc SOQL erodes governor savings. Detectable via test assertions.                    |
| 2   | IRecordFilter predicates are O(1) per record with no side effects                | Expensive predicates negate the filtering benefit. Documented.                          |
| 3   | Handlers do not perform direct DML in callbacks                                  | Bypasses the registrar and conflict detection. Detectable via test assertions.          |
| 4   | SObject dependency graph is acyclic or cycles are declared via declareDependency | Undeclared cycles cause CyclicDependencyException at commit time.                       |
| 5   | Re-entrant processing converges (no infinite ping-pong)                          | Invocation counter fires RecursionLimitException at configured max.                     |
| 6   | Framework adoption is consistent across the team                                 | One rogue trigger bypassing the pipeline undermines governor budgeting.                 |
| 7   | Platform Event and CDC triggers are excluded from SALT(YASTF) v1                 | PE/CDC triggers that call `TriggerDispatcher.run()` will exit early with no processing. |

---

# Appendix B — The Full Pipeline (Origin Story)

## The Problem That Won't Go Away

The story is familiar to anyone who has worked in a Salesforce org for more than a few years. It starts small — a handful of triggers, a few workflow rules, maybe a Process Builder or two. The org works fine. Then the business grows. New teams onboard. New integrations arrive. Features accumulate.

Five years in, the Account object has triggers from three different implementation waves, workflow field updates that re-fire those triggers, record-triggered Flows that perform DML on Contact and Opportunity, which fire their own triggers, which update Account fields, which re-fire the original triggers. Nobody planned the recursion — it emerged organically as independent teams solved independent problems on a shared platform. The governor limit errors start appearing in production. Not every time — just often enough to erode trust. A bulk data load hits `TOO_MANY_SOQL_QUERIES`. A nightly integration fails on `TOO_MANY_DML_STATEMENTS`. A user saves a record and sees an error they cannot understand because it originated three cascade levels deep in a trigger they have never heard of.

The response is predictable: add a static Boolean to stop the recursion. It works — until a partial save (`allOrNone=false`) retries the successful records and the Boolean blocks them from processing. Or until a bulk operation exceeds 200 records and the platform chunks it, resetting the Boolean between chunks. Or until a workflow field update re-fires the trigger and the Boolean blocks the legitimate second pass. Each fix introduces a new edge case. The org becomes a minefield of interacting recursion guards, none of which were designed to coexist.

This is not a story about bad developers or poor planning. It is the natural consequence of a multi-tenant platform where governor limits are shared across triggers, Flows, workflows, and integrations within a single transaction — and where the tools for managing that contention have historically operated at the individual handler level rather than the transaction level. Every long-running Salesforce org with sufficient scale arrives at some version of this problem.

## The Thought Experiment

The 9-step pipeline began as a thought experiment: what if a trigger framework could see all handler data needs before executing any of them? Not just dispatch and ordering — those problems were already solved — but the upstream problem of handlers independently consuming SOQL and DML budget without awareness of each other.

The idea was novel for the Salesforce platform: a declare-then-aggregate-then-execute model where handlers describe what data they need, the framework merges compatible queries, and the minimum number of SOQL statements are executed. Combined with coordinated DML and field-level recursion detection, the pipeline addressed the full scope of governor limit contention in cascading transactions.

```
1. Trigger Invocation
2. Event Handler (single entry point)
3. Record Segregation by Functionality
4. Callback Registration for Post-Referential Data Queries
5. Query Aggregation
6. Unified Query Execution
7. Callback Invocation
8. DML Aggregation by SObject
9. DML Execution Object-by-Object
```

## The Persistent Question

The pipeline was technically sound, but it raised a question that refused to go away: **is this level of complexity actually justified on the Salesforce platform?**

The Salesforce ecosystem already had capable frameworks. Kevin O'Hara's pattern handled dispatch elegantly. TAF brought metadata-driven configuration. fflib provided enterprise-grade patterns. These frameworks served the vast majority of organizations well. Introducing a 9-step pipeline with callback-based query collation, deferred DML coordination, and field-hash recursion guards meant asking developers to internalize roughly 10 new concepts before writing a single handler. For a 40-person team with mixed experience levels, that cognitive load was a real adoption barrier — not a theoretical one.

The question came back in different forms across months of consideration. Was this solving a real problem or inventing a need to justify something new? Were the governor limit pressures genuine enough at scale to warrant this much machinery? Would developers actually adopt it, or would they route around the complexity and write ad-hoc SOQL anyway? Was this framework serving the org's needs or the architect's ambitions?

There was no single moment of resolution. The answer emerged gradually from production evidence: orgs at scale were hitting the same governor limit walls regardless of which framework they used, because the frameworks optimized at the handler level while the problem existed at the transaction level. The need was real. The question was whether the solution had to be this complex.

## The Resolution: Composability as Compromise

The breakthrough was recognizing that the 9-step pipeline did not have to be an all-or-nothing proposition. The monolithic design demanded full commitment — every developer, every handler, every concept. But the problems it solved were not equally distributed. A simple field-defaulting handler does not need query aggregation. A handler that reads no related data does not need a callback model. Only the handlers operating at the intersection of scale and complexity — deep cascades, cross-object queries, coordinated DML — actually needed the full pipeline.

The layered architecture preserves all 9 steps but delivers them as opt-in capabilities:

| Original Step              | SALT(YASTF) Layer                               |
| -------------------------- | ----------------------------------------------- |
| 1. Trigger Invocation      | Layer 0: `TriggerDispatcher.run()`              |
| 2. Event Handler           | Layer 0: `TriggerHandler` base class            |
| 3. Record Segregation      | `IRecordFilter` (any layer, opt-in)             |
| 4. Callback Registration   | Layer 2: `IQueryAware.declareQueryNeeds()`      |
| 5. Query Aggregation       | Layer 2: `QueryAggregator` (framework-internal) |
| 6. Unified Query Execution | Layer 2: `QueryExecutor` (framework-internal)   |
| 7. Callback Invocation     | Layer 2: `IQueryAware.onDataReady()`            |
| 8. DML Aggregation         | Layer 3: `IDmlAware` + `DmlRegistrar`           |
| 9. DML Execution           | Layer 3: `DmlExecutor` (framework-internal)     |

The complexity is still there — it has to be, because the problems at scale are genuinely complex. But it is partitioned. A developer writing a simple handler encounters three concepts. A developer writing a query-optimized handler encounters six. Only the developers building handlers at the full intersection of scale challenges encounter all ten. The framework matches its cognitive cost to the problem being solved, rather than imposing the maximum cost on every participant.

The full pipeline exists as a capability. It is not a requirement. That distinction is the answer to the persistent question: the complexity is justified where the scale demands it, and invisible where it does not.
