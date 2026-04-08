# ADR 0002 — Net-new framework rather than fork or extend

## Status

Accepted.

## Context

Three established Apex trigger frameworks already exist:

- **kevinohara80/sfdc-trigger-framework** (2013, MIT) — established
  the "one trigger per object" pattern. Provides handler dispatch
  and a `Set<Id>` recursion guard. No metadata, no query
  deduplication, no DML batching.
- **mitchspano/apex-trigger-actions-framework (TAF)** (2020, Apache)
  — brought metadata-driven action registration. Each handler is an
  Action class registered via `Trigger_Action__mdt`. No query
  deduplication, no DML coordination, no cross-action conflict
  detection.
- **apex-enterprise-patterns/fflib-apex-common** (2013, BSD) — Martin
  Fowler's enterprise patterns on Salesforce: Selector / Domain /
  Service / Unit of Work. Selectors centralize SOQL **definitions**
  per SObject but don't aggregate query **executions** across
  consumers in the same trigger context. Two domains calling the
  same Selector method issue two SOQLs.

The motivating workload is a 23-handler enterprise trigger surface
where multiple handlers on the same SObject need data from the same
related object using overlapping field sets and overlapping ID sets.
None of the existing frameworks merge these queries; the resulting
SOQL pressure is the dominant governor exhaustion vector at scale.

## Decision

Build SALT as a **net-new framework**, not a fork or wrapper of any
existing framework. The differentiator is **cross-handler query
aggregation** with structured per-handler provenance, plus
coordinated Phase 4 DML batching with conflict detection. Both
features required intrusive changes to the dispatch + query + DML
plumbing that no existing framework's extension points support.

## Consequences

- **Zero external dependencies.** SALT compiles standalone.
  Downstream consumers don't take a transitive dependency on fflib /
  TAF / O'Hara, eliminating version-skew and licensing entanglement.
- **Net new cognitive surface.** Teams that already know fflib must
  learn a new mental model. The "concentric layer" structure
  (dispatch → recursion → query → DML, each opt-in) keeps the
  gradient gentle: a handler that just needs the dispatcher extends
  `TriggerHandler` and is done; query aggregation and DML
  coordination are opt-in via interfaces.
- **Cannot reuse fflib's Selector pattern.** fflib Selectors hide
  the SOQL inside the Selector class; the trigger framework needs to
  see the query *intent* (target SObject, relationship field, ID
  set, field set, predicate tree) before execution to merge across
  handlers. This is fundamentally incompatible with the Selector
  abstraction.
- **Cannot reuse TAF's action model.** TAF actions are pure
  callbacks; they have no declarative data-needs phase. Adding one
  to TAF would require either rewriting the dispatcher or adding a
  parallel pre-pass that breaks TAF's "one action class = one
  responsibility" contract.
- **Acknowledgment.** SALT borrows established patterns from prior
  art: one-trigger-per-object (O'Hara), metadata-driven registration
  (TAF), Unit of Work-style DML batching (fflib). Where the
  borrowing is structural rather than just inspirational, the
  relevant section in `DESIGN.md` and the ADR linked above credits
  the source.

## Validation

A 3-run whiteroom head-to-head measurement (see
[`benchmarks/benchmark-report.md`](../benchmarks/benchmark-report.md))
confirms the net-new architecture pays off on the differentiating
metric:

| Framework | SOQL | Δ vs SALT |
|---|---|---|
| **SALT** | **11** | — |
| fflib | 20 | +82 % |
| O'Hara | 20 | +82 % |
| TAF | 29 | +164 % |

SALT issues 45 % fewer SOQL than fflib/O'Hara and 62 % fewer than
TAF on the same 23-handler workload. fflib achieves slightly lower
CPU on this workload because it pays no per-trigger overhead
(no recursion-guard hashing, no `BindContext` allocation), but pays
~82 % more SOQL — and CPU is the wrong currency to optimize when
SOQL is the production bottleneck.

## References

- `DESIGN.md` § Class Model
- `benchmarks/benchmark-report.md` § Comparative Frameworks (2026-04-08 measured)
- `benchmarks/methodology-2026-04-08.md` for how the comparison was performed
