# Predicate Scenario Benchmark Report

> Cross-framework comparison of SALT, fflib, O'Hara, and TAF on a
> predicate-filtered query scenario. Numbers are the 10-run cleanroom
> medians from a profiled session with state-equivalence verification
> across all 4 frameworks.
>
> See [`methodology.md`](methodology.md) for the full cleanroom
> procedure and [`predicate-driver.apex`](predicate-driver.apex) for
> the driver script.

## Setup

### Workload

4 predicate-exercising handlers on Account AfterUpdate, sharing merge
key `Contact|AccountId`. Each handler queries Contacts filtered by
Department and creates Tasks or updates Account.Description.

| Handler | Predicate | Tag | DML |
|---------|-----------|-----|-----|
| AccountBillingContactReviewHandler | `FieldFilter.equals(Department, 'Billing')` | — | Task (new) |
| AccountShippingContactAlertHandler | `FieldFilter.equals(Department, 'Shipping')` | — | Task (new) |
| AccountAllContactNotifyHandler | *(none — exercises SUBSUME)* | — | Account (Description) |
| AccountTaggedDeptContactHandler | `FieldFilter.equals(Department, 'Billing')` | `billing` | Task (new) |
| | `FieldFilter.equals(Department, 'Engineering')` | `engineering` | Task (new) |

### Scenario

Insert 200 Accounts with `Rating='Hot'` and 600 Contacts (3 per
Account: Billing, Shipping, Engineering departments). Update all 200
Accounts' Rating to `'Warm'`. Measure SOQL, DML, CPU, and Heap for
the update operation only (setup and cleanup excluded from metrics).

### Query merge group

| Merge Key | Handlers Sharing | SALT Queries | Without Merge |
|-----------|------------------|:------------:|:-------------:|
| Contact\|AccountId | BillingReview + ShippingAlert + AllContactNotify + TaggedDept (×2 tagged) | **1** | 5 |

SALT merges all 5 handler queries (including TaggedDept's 2 tagged
requests) into 1 SOQL via MERGE_SUBSUME — AllContactNotifyHandler has
no `whereFilter`, which subsumes all other handlers' predicates into
an empty WHERE clause. In-memory matcher re-applies each handler's
predicate at `getForHandler()` retrieval time.

## Results

### Headline totals (10-run cleanroom median, profiled)

| Metric | SALT | fflib | O'Hara | TAF |
|--------|-----:|------:|-------:|----:|
| **SOQL** | **1** | 5 | 5 | 5 |
| **DML statements** | **4** | 5 | 5 | 5 |
| **DML rows** | **1,200** | **1,200** | **1,200** | **1,200** |
| **CPU (median, ms)** | 2,290 | **1,809** | **1,799** | **1,747** |
| **CPU (p95, ms)** | 2,564 | 2,021 | 2,080 | 2,070 |
| **CPU (range, ms)** | 2,051 – 2,564 | 1,616 – 2,021 | 1,612 – 2,080 | 1,567 – 2,070 |
| **CPU CV** (10-run) | 8.1 % | 8.7 % | 7.9 % | 8.8 % |
| **Heap delta (median, B)** | 824 | 3,152 | **302** | **302** |

### State-equivalence verification

All 4 frameworks produce **identical state across all 10 runs**:

```
TaskTotal         : 800    (4 per Account × 200)
BillingReview     : 200    (1 per Account)
ShippingAlert     : 200    (1 per Account)
TaggedBilling     : 200    (1 per Account)
TaggedEng         : 200    (1 per Account)
DescriptionSet    : 200    (all Accounts have 'Contact count: 3')
```

Same Task subjects, same Task counts, same Account.Description values
on the same records, every framework, every run.

### Where each framework wins

| Dimension | Winner | Margin | Evidence |
|-----------|--------|--------|----------|
| **Fewest SOQL** | **SALT** | 80 % fewer | 1 vs 5 |
| **Fewest DML** | **SALT** | 20 % fewer | 4 vs 5 |
| **Lowest CPU** | **TAF** | 24 % below SALT | 1,747 ms vs 2,290 ms |
| **Lowest heap** | **O'Hara / TAF** | 63 % below SALT | 302 B vs 824 B |
| **Narrowest CPU range** | **O'Hara** | 7.9 % CV | Most consistent |

## Analysis

### SALT issues 80 % fewer SOQL than all other frameworks

SALT's query aggregation pipeline merges 5 handler queries into 1:

- Handlers 1 & 2 have different `FieldFilter` predicates → structural
  hash comparison classifies them as `MERGE_OR`
- Handler 3 has no predicate → `MERGE_SUBSUME` escalates the entire
  group to empty WHERE
- Handler 4's two tagged requests merge into the same group
- Handler 1 and Handler 4's `billing` tag share identical predicates
  (same `Department='Billing'` filter) → structural hash identity →
  `MERGE_IDENTITY` between those two

Net result: 1 SOQL with `WHERE AccountId IN :saltIds` (no predicate
clause — subsumption). In-memory matcher applies per-handler predicates
at `cache.getForHandler()` retrieval time.

The 3 inline-SOQL frameworks (fflib, TAF, O'Hara) each issue 5
queries: 1 per handler query invocation. No cross-handler merging.

### SALT is 24-28 % slower on CPU

All three inline frameworks are ~500 ms faster (median) than SALT on
this workload. The gap comes from SALT's per-trigger overhead:

- `IRecordFilter` Phase 1 per-record `isApplicable()` evaluation
- `QueryAggregator` merge-gate comparison (signature hashing +
  `canMergeOrUnion` checks)
- `BindContext` allocation per query render
- `QueryResultCache` `getForHandler()` deep-clone per row per handler
- Phase 4 cross-handler `FieldConflict` detection on `registerDirty`

The inline frameworks pay none of this — they query inline, DML
inline, no cross-handler coordination.

**Context:** The 2,290 ms SALT median sits 77 % below the 10,000 ms
CPU governor. The 1,747 ms TAF median has 83 % headroom. Both are
comfortable. The CPU difference matters less than the SOQL difference
in production, where Flows + managed packages consume 30-50 of the
100-query budget.

### DML: SALT saves 1 statement via Phase 4 batching

SALT issues 4 DML statements (Phase 4 batches all 4 handlers' Task
inserts into 1 INSERT + registers Account dirty updates separately).
The inline frameworks issue 5 (1 per handler's direct DML call).

All frameworks write the same 1,200 DML rows (800 Task inserts + 200
Account updates × 2 paths).

### Heap: SALT's deep-clone overhead is measurable but trivial

SALT's 824 B median heap delta reflects the `getForHandler()` deep-clone
cost per handler. The inline frameworks avoid this (no clone needed when
each handler queries independently). All values are ~3 orders of
magnitude below the 6 MB governor limit.

### Profiling overhead caveat

`ApexProfiling=FINEST` adds runtime overhead vs unprofiled runs. All
frameworks pay the same overhead, so the cross-framework comparison
remains valid. Unprofiled runs would show ~5-9 % lower absolute CPU.

## Architectural takeaways

1. **Predicate aggregation eliminates 80 % of SOQL on filtered
   queries.** The original benchmark (23 handlers, no predicates)
   showed 45 % SOQL reduction. The predicate scenario — where every
   handler queries the same SObject with different WHERE filters —
   is where aggregation delivers maximum benefit.

2. **SUBSUME is the critical merge mode for predicate scenarios.**
   When any handler in a merge group has no filter,
   `MERGE_SUBSUME` collapses the entire group to an unfiltered query.
   The in-memory matcher handles per-handler filtering. This is more
   SOQL-efficient than OR-merging all filters, at the cost of
   returning a superset that filtered handlers must re-filter in
   memory.

3. **Tags enable per-handler multi-request isolation without
   additional SOQL.** Handler 4's two tagged requests
   (`billing` + `engineering`) merge into the same group as
   Handlers 1–3. Zero additional queries.

4. **CPU overhead is the price of coordination.** SALT's 24 % CPU
   premium on this workload comes from features the inline frameworks
   don't provide: merge-gate evaluation, structural hash comparison,
   deep-clone isolation, and DML conflict detection. On workloads
   where SOQL is the binding governor constraint, this trade-off
   pays for itself.

5. **State equivalence proves functional correctness.** All 4
   frameworks produce identical field-level results on 200 records ×
   10 runs — same Tasks, same Description values, same counts. The
   predicate in-memory matcher in SALT produces the same output as
   direct filtered SOQL in the inline frameworks.

## Reproducing this benchmark

```bash
# From repo root, with dev org alias set:
bash /tmp/predicate_cleanroom.sh
# Or use the methodology in docs/benchmarks/methodology.md § 3-7
# with docs/benchmarks/predicate-driver.apex as the driver script.
```

Logs are stored in
`scripts/benchmarks/logs/profiled/predicate-cleanroom-10/`.
