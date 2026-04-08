# ADR 0006 — Predicate trees and cross-handler OR-merge

## Status

Accepted.

## Context

ADR 0005 establishes that `QueryAggregator` merges compatible
requests across handlers. The first version of that mechanism
required predicate trees on each side to be **structurally equal** —
two handlers querying the same merge key with different filters
could not merge, and each handler issued its own SOQL.

That constraint hides a significant value-proposition gap. The real
workload that motivated this decision looks like this:

> An Account trigger has two operations on related Contacts:
>
> - **Op 1.** Notify Contacts that have ≥1 open Case when their
>   Account's Status changes. SOQL needs a child relationship
>   subquery: `(SELECT Id FROM Cases WHERE IsClosed = false LIMIT 1)`.
> - **Op 2.** Propagate `StaticRule__c` to Contacts where
>   `DoNotContact__c = false` when their Account's rule changes. SOQL
>   needs a flat target-object WHERE: `Contact.DoNotContact__c =
>   false`.

Both operations target the same merge key (`Contact|AccountId`),
but they're not structurally equal — one has a child subquery, the
other has a flat WHERE. Without OR-merge they cost 2 SOQL.

A second pressure point: real handlers express **DNF/CNF business
rules** like `(Status='Active' OR Status='Pending') AND NOT
Type='Internal'`. Earlier versions accepted only flat AND across
multiple `.where()` calls — anything with OR or NOT had to be
encoded as separate handlers, separate SOQL, separate provenance
slots, all defeating the aggregation goal.

## Decision

### Predicate trees, not flat AND chains

A small `Predicate` interface plus a `CompositePredicate` combinator
class:

```apex
public interface Predicate {
  Boolean matches(SObject row);                  // in-memory evaluator
  String render(BindContext ctx);                 // emits SOQL fragment, registers binds
  Boolean equalsPredicate(Predicate other);       // structural equality
}

public class CompositePredicate implements Predicate {
  public enum Combinator { AND_OP, OR_OP, NOT_OP }
  public static Predicate andOf(Predicate... children);   // rejects empty; degenerate single-child returns child
  public static Predicate orOf(Predicate... children);    // same
  public static Predicate notOf(Predicate child);
}

public class FieldFilter implements Predicate {
  // 8 ops: EQUALS, NOT_EQUALS, IN, NOT_IN, LT, LE, GT, GE
  public static FieldFilter equals(SObjectField field, Object value);
  // ...
}
```

`FieldFilter` is the leaf. `CompositePredicate` is the combinator.
Trees nest arbitrarily. The renderer **always parenthesizes
non-leaf nodes** — there's no precedence guessing. Trees compare by
structural equality (`equalsPredicate`) for merge eligibility — no
canonicalization, no hash.

`QueryBuilder.where(Predicate)` accepts either a leaf or a tree;
multiple `.where()` calls AND together at the top level (the
canonical `WHERE A AND B AND C` shape).

### OR-merge with union field sets

When `QueryAggregator.canMergeOrUnion(a, b)` returns `MERGE_OR`
(structurally different non-empty filters on both sides, otherwise
compatible), the aggregator produces a merged request that:

1. **Unions ids** → merged WHERE `relField IN :__salt_ids`
2. **Unions field sets** → merged SELECT projects every field any
   handler declared
3. **OR-renders predicate clauses**:
   `... AND ((handlerA-AND-chain) OR (handlerB-AND-chain))`
4. **Sets `wasOrMerged = true`** on the cache slot
5. **Preserves provenance** per `(mergeKey, handler, tag)` in
   `idsByHandler` / `fieldsByHandler` / `filtersByHandler`

**Union field sets, not intersection.** Earlier rounds of design
review proposed intersection on the rationale that intersection
prevents Handler Q from accidentally exposing Handler P to fields
P didn't ask for. That concern is **moot under trigger transactional
rollback semantics**: if the merged query throws at the FLS gate
because Q's added field is unreadable, the entire transaction rolls
back; if Q instead falls out of the merge and runs solo with the
same field, that solo query throws too and also rolls back.
Intersection costs an extra SOQL in the success case and ties in
the failure case. Union is strictly dominant inside trigger context.

### Matcher re-application — bounded to OR-merge fire path

When a handler retrieves its rows via `getForHandler`, the cache
checks `wasOrMergedByMergeKey[mergeKey]`:

- **`false`** → SOQL already returned the exact set this handler
  declared; just project fields and return.
- **`true`** → walk the handler's `Predicate` list and re-apply
  each one to each row. Filter the row set down to the rows that
  satisfy *this handler's* filter — not the OR'd union.

The matcher's correctness liability is therefore bounded to the
OR-merge fire path. Non-OR-merged retrievals never invoke it.

### Matcher SOQL-parity tiers

Apex in-memory evaluation can't perfectly match SOQL semantics on
every type. The tiers are:

- **Tier-1 fixes (built into the matcher).** Id 15/18-char
  normalization, Decimal scale tolerance via `compareTo() == 0`,
  case-insensitive String compare via `equalsIgnoreCase`,
  second-truncated Datetime equality. These are the divergences
  that would silently produce wrong results most often.
- **Tier-2 rejections at factory time.** `FieldFilter` factories
  reject combinations that cannot be evaluated reliably:
  multi-currency-org currency fields (no in-memory conversion path),
  encrypted fields (`isEncrypted() == true`), formula fields with
  cross-object dotted references, geolocation fields with
  non-`DISTANCE` operators, Date↔Datetime cross-type binds on
  range operators.
- **Tier-3 documented divergences.** Single-currency org currency
  comparisons (matches SOQL only when records are in corporate
  currency), locale-dependent String collation (Apex
  `String.compareTo` is locale-independent; SOQL respects org
  locale for sorts but uses byte-equality for `=`), picklist API
  name vs. label normalization (matcher compares API names only).
  Loud in javadoc, accepted as opt-in costs of OR-merge
  participation.

### `MERGE_SUBSUME` — the empty-filter side

If exactly one side has empty filters and the other has filters,
the aggregator takes the empty-filter side as the SOQL base (it
already fetches everything the filtered side could need) and stores
the filtered side's predicates in `filtersByHandler`. The matcher
re-applies them at retrieval time. `wasOrMerged` is set to `true`
because filter semantics divergence still applies even though no
OR rendering happened.

## Consequences

- **Real DNF/CNF business rules express in the framework boundary.**
  Flat AND no longer forces handlers to fragment into multiple
  classes or escape to ad-hoc SOQL.
- **The user's two-op handler scenario merges.** Op 1
  (`withChildSubquery` for open Cases) and Op 2 (flat WHERE for
  `DoNotContact__c`) end up as `MERGE_OR` once both have
  predicates of the right shape, or as `MERGE_SUBSUME` if one is
  shape-compatible. Either way, 1 SOQL instead of 2.
- **The matcher's correctness story is bounded.** Only OR-merged
  retrievals trigger it. Non-OR-merged retrievals get the exact
  SOQL result with zero matcher exposure.
- **Predicate tree equality is structural, not canonical.** Two
  semantically-equivalent trees written in different orders
  (`A AND B` vs `B AND A`) don't merge. This is accepted as the
  cost of avoiding canonical-form complexity; teams that need
  identity merging can normalize their predicate construction.

## Trade-offs

- **The matcher is the framework's only correctness contract that
  isn't 1:1 with SOQL.** The tier-1/2/3 split is the
  honest accounting of where it diverges. Handlers that participate
  in OR-merge accept the tier-3 documented divergences as opt-in
  costs.
- **No predicate-tree canonicalization, no hash.** Structural equals
  walks the tree on every merge attempt — O(tree size). In practice
  trees are small (≤ 10 nodes) and the merge attempt count is
  bounded by handler count, so the cost is negligible. If profiling
  ever shows it as a bottleneck, hashing is reachable as a future
  optimization.
- **Empty `andOf([])` and `orOf([])` are rejected.** Degenerate
  single-child `andOf(p)` and `orOf(p)` return `p` directly. These
  are factory-time validations, not runtime — programmer errors fail
  fast.

## Out of scope (deferred)

- `LIKE`, `INCLUDES`, `EXCLUDES` operators
- Cross-object dotted field references (`Parent.Owner.Profile.Name`)
- `GROUP BY` / aggregate support
- Tier-3 divergence fixes (multi-currency conversion, locale
  collation, picklist label/API name)
- `predicateHash` / canonical-form hashing

These are deferred from current scope; none of them block the current
value proposition.

## References

- `force-app/main/default/classes/Predicate.cls`
- `force-app/main/default/classes/CompositePredicate.cls`
- `force-app/main/default/classes/FieldFilter.cls`
- `force-app/main/default/classes/CompositeFilter.cls` (the
  `IRecordFilter` combinator — separate from `CompositePredicate`,
  used in Phase 1 record filtering not query rendering)
- `force-app/main/default/classes/BindContext.cls`
- ADR 0005 — query aggregation (the aggregation side of this story)
- `DESIGN.md` § Query Pipeline → Predicate trees
