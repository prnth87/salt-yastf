# ADR 0003 — Composition over inheritance, Specification pattern for filtering

## Status

Accepted.

## Context

A trigger framework needs to express several orthogonal capabilities:
record filtering, recursion control, declarative query needs, and
coordinated DML. Three structural choices were available:

1. **Deep inheritance.** Multiple base classes: `FilterableHandler
   extends TriggerHandler`, `QueryAwareHandler extends
   FilterableHandler`, `DmlAwareHandler extends QueryAwareHandler`.
   Composition by extension. Apex's single-inheritance constraint
   forces a linear hierarchy that doesn't match the orthogonal
   capability matrix — a handler that needs filtering + DML but not
   query aggregation has nowhere to extend.
2. **Single god base class.** All capabilities exposed as overridable
   methods on a fat `TriggerHandler` base. Handlers override what
   they need. The framework dispatches by checking which methods
   the subclass overrode (impossible in Apex without reflection
   that doesn't exist) or by always calling every method.
3. **Composition via opt-in capability interfaces.** Single
   `TriggerHandler` base with no-op context method defaults; each
   capability is a small interface (`IRecordFilter`,
   `IRecursionAware`, `IQueryAware`, `IDmlAware`) that handlers
   implement à la carte. The dispatcher checks `instanceof` per
   phase.

The filtering capability has its own design pressure: filter
predicates need to be **composable** (`FieldChanged(Status) AND NOT
RecordTypeIs(Internal)`), **null-safe** (Insert vs. Delete vs.
Update each null one of `newRecord` / `oldRecord`), and **reusable
across handlers**. Inline `if` blocks in `beforeUpdate` are none of
these.

## Decision

**Choice 3 — composition via opt-in capability interfaces** plus the
**Specification pattern** (Fowler / GoF) for record filtering:

```apex
public interface IRecordFilter {
  Boolean isApplicable(SObject newRecord, SObject oldRecord, TriggerContext ctx);
}
```

Built-in specifications: `FieldChanged`, `FieldNotNull`,
`RecordTypeIs`, `CompositeFilter` (And/Or/Not). All handle the
null-side cases (Insert / Delete / Update) per a documented table
in `DESIGN.md`.

`IRecordFilter` is checked **once per record per handler in Phase 1**
and the result drives whether the handler is included in the
subsequent query/execution phases. Handlers with zero applicable
records are marked SKIPPED and bypass Phases 2-4 entirely — this is
the mechanism that lets a 23-handler trigger surface stay cheap when
most handlers don't apply to most updates.

## Consequences

- **Adoption is gradual.** A handler that just needs to react
  extends `TriggerHandler`, overrides one context method, and ships.
  No interfaces, no extra plumbing.
- **Capabilities compose freely.** A handler that needs filtering +
  query aggregation + DML coordination implements all three
  interfaces; the dispatcher checks each via `instanceof` and runs
  the matching phase. There's no inheritance ordering to navigate.
- **The base class stays small.** `TriggerHandler` is 7 no-op
  context methods + a getHandlerName() helper + manual recursion
  convenience methods. New capabilities are added as new
  interfaces, never as new methods on the base class.
- **Specifications are reusable.** `new FieldChanged(Account.Status)`
  is shared across every handler that needs to react to status
  changes. The composite combinators let teams build a small
  vocabulary of business-meaningful filters (`StatusBecameClosed`,
  `OwnerChangedToQueue`, etc.) without subclass proliferation.
- **Filter cost is paid in Phase 1, not Phase 3.** A handler that
  filters down to zero records never runs its query and never
  executes its context method. This is the primary mechanism that
  prevents the 23-handler workload from blowing CPU and SOQL.

## Trade-offs

- **`instanceof` checks per phase per handler.** Negligible cost
  (Apex `instanceof` is O(1)) but architectural symmetry suffers
  slightly — the dispatcher knows about each capability interface
  by name. New capabilities require dispatcher edits. This is
  accepted as the cost of avoiding reflection that Apex doesn't
  support.
- **Interfaces are stable, not frozen by tooling.** There's no Apex
  equivalent of Java's `default` methods, so adding a method to an
  existing interface is a breaking change for every implementor.
  The policy is: **never add methods to existing interfaces; ship
  new capabilities as new interfaces.**

## References

- `force-app/main/default/classes/IRecordFilter.cls`
- `force-app/main/default/classes/CompositeFilter.cls` (And/Or/Not combinator)
- `force-app/main/default/classes/FieldChanged.cls`, `FieldNotNull.cls`, `RecordTypeIs.cls`
- `DESIGN.md` § Capability Interfaces
