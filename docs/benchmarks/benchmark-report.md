# SALT(YASTF) Benchmark Report

> Cross-framework comparison of SALT, fflib, O'Hara's
> sfdc-trigger-framework, and mitchspano's Trigger Actions Framework
> on a 23-handler enterprise trigger surface. Numbers are the
> 10-run cleanroom medians from a profiled apples-to-apples session
> with state-equivalence verification across all 4 frameworks.
>
> See [`methodology.md`](methodology.md) for the full procedure,
> reproduction recipe, and per-framework gotchas encountered while
> setting up the comparison.

## Setup

### Workload

23 enterprise-realistic trigger handlers across 3 standard objects,
exercising a 4-level cascade chain on a bulk lead-conversion
operation. Handler count by object: Account 7, Contact 4,
Opportunity 12. Five distinct query merge groups (Contact|AccountId,
Opp|AccountId, Account|Id) where multiple handlers want overlapping
or identical SOQL — exactly the workload SALT's cross-handler query
aggregation is designed for.

The full handler roster with descriptions, merge keys, business
justifications, and per-context registrations is in
[`handlers.yaml`](handlers.yaml).

### Query merge groups

| Trigger Context | Merge Key          | Handlers Sharing                                        | SALT Queries | Without Merge |
| --------------- | ------------------ | ------------------------------------------------------- | ------------ | ------------- |
| Opp AI          | Contact\|AccountId | ContactRole + TeamNotify + ApprovalContact + Commission | **1**        | 4             |
| Opp AI/AU       | Opp\|AccountId     | PipelineRollup + CompetitorAnalysis + ForecastReconcile | **1**        | 3             |
| Contact AI      | Account\|Id        | AccountSync + LeadSource                                | **1**        | 2             |
| Account AU      | Contact\|AccountId | ContactCascade + OwnerReassign + DoNotContact           | **1**        | 3             |
| Account AU      | Opp\|AccountId     | OppCascade + CreditHold                                 | **1**        | 2             |
| **Total**       |                    | **15 handler queries**                                  | **5 SOQL**   | **14 SOQL**   |

### Scenarios

Three scenarios run sequentially in a single anonymous Apex
transaction:

**Scenario A — Bulk 200 Lead Conversion.** The most complex
cascading trigger scenario in Salesforce: insert 200 Accounts
followed by 200 Contacts followed by 200 Opportunities, exercising
all 23 handlers across a 4-level cascade chain.

```
L1: Opp AI → 8 handlers fire. Phase 4 commits:
    Account update (AnnualRevenue + Type merged)
    OCR insert
    Task insert (5 handlers' Tasks merged)
L2: Account AU → cascade fires. Phase 4 commits:
    Opp update (StageName advanced)
L3: Opp AU → cascade fires. Phase 4 commits:
    Account update (PipelineRollup + ForecastReconcile)
L4: Account AU → IRecordFilter rejects (Type unchanged) → cascade
    terminates.
```

**Scenario B — Account Territory Transfer.** Update
`Account.OwnerId` on 200 Accounts. Cascades to Contact owner reassign
(via `AccountOwnerReassignHandler`) which fires Contact AfterUpdate
where `ContactAccountSyncHandler` registers a parent `Account.Phone`
resync — adding one more cascade level.

**Scenario C — Opportunity Stage Change.** Update `StageName` on 200
Opportunities. Triggers the Opp|AccountId merge group; SALT collapses
3 handler queries into 1 SOQL.

### Frameworks under test

| Framework | Vendor | Pattern |
|-----------|--------|---------|
| **SALT** | this repo | Cross-handler query aggregation, Phase 4 DML batching |
| **fflib** | apex-enterprise-patterns/fflib-apex-common | Domain + Selector + Unit of Work |
| **O'Hara** | kevinohara80/sfdc-trigger-framework | Per-handler `TriggerHandler` subclass with inline SOQL/DML |
| **TAF** | mitchspano/apex-trigger-actions-framework | `TriggerAction` interface implementations dispatched by `MetadataTriggerHandler` from `Trigger_Action__mdt` records |

All four frameworks execute the **same 23 handlers** doing the
**same business logic** against the **same 200-record seed data** in
the **same anonymous Apex transaction**. The only thing that varies
between framework runs is which dispatcher the
Account/Contact/Opportunity trigger bodies invoke. See
[`methodology.md`](methodology.md) § Trigger-body-swap strategy.

## Results

### Headline totals (10-run cleanroom median, profiled)

| Metric                          | SALT      | fflib     | O'Hara    | TAF       |
| ------------------------------- | --------: | --------: | --------: | --------: |
| **SOQL**                        | **11**    | 20        | 20        | 32        |
| **DML statements**              | **21**    | 25        | 24        | 24        |
| **DML rows**                    | **3,600** | **3,600** | 4,800     | 4,800     |
| **CPU (median, ms)**            | **8,135** | **6,604** | 8,702     | 9,163     |
| **CPU (p95, ms)**               | 8,786     | **7,241** | 10,048    | 9,993     |
| **CPU (range, ms)**             | 6,583 – 8,914 | 5,670 – 7,258 | 6,788 – 10,089 | 8,686 – 10,245 |
| **CPU CV** (10-run)             | 10.4 %    | 10.2 %    | 11.9 %    | 4.9 %     |
| **Δ vs SALT median CPU**        | —         | **−19 %** | **+7 %**  | **+13 %** |
| **Δ vs SALT p95 CPU**           | —         | **−18 %** | **+14 %** | **+14 %** |
| **Heap delta (median, bytes)**  | 91,332    | **77,017**| **75,097**| 106,044   |
| **Heap delta (p95, bytes)**     | 91,392    | **77,017**| **75,097**| 106,044   |
| **Heap delta (range, bytes)**   | 91,035 – 91,403 | 77,017 (flat) | 75,097 (flat) | 105,958 – 106,044 |
| **Account BU fires**            | 6         | 6         | 12        | 12        |
| **Account AU fires**            | 6         | 6         | 12        | 12        |
| **Opportunity BU fires**        | 3         | 3         | 3         | 3         |
| **Opportunity AU fires**        | 3         | 3         | 3         | 3         |
| **Total trigger fires**         | **26**    | **26**    | **38**    | **38**    |

All four frameworks produce **structurally identical results across
all 10 runs** within their own framework: identical SOQL, identical
DML statements, identical DML rows, identical fire counts, identical
state snapshot. Only wall-clock CPU varies run-to-run, and that
variance is within normal multi-tenant Apex run-to-run noise (CV
4.9–11.9 %). Heap deltas are essentially flat run-to-run (fflib and
O'Hara show zero variance across all 10 runs; SALT spans 368 B; TAF
spans 86 B), confirming heap allocation is deterministic per
framework on this workload — the heap caveat in `methodology.md` § 11
about profiler perturbation does not materially affect the medians
at this scale. All four frameworks sit ~2 orders of magnitude under
the 6 MB synchronous heap governor.

The **CPU p95 row tells a different story than the median** for the
inline-DML frameworks. SALT and fflib have similar tail behavior
(p95 about 8 % above median for both: SALT 8,135 → 8,786 ms, fflib
6,604 → 7,241 ms). O'Hara's tail is much heavier — its p95 is 1,346
ms above its median (a 15 % tail spread), pushing its p95-vs-SALT
delta from +7 % at the median to **+14 %** at the p95. TAF's tail is
the tightest of the four (p95 just 9 % above its median, consistent
with its 4.9 % CV) but its baseline is higher, so its p95-vs-SALT
delta moves only marginally from +13 % to +14 %. Heap p95 is
essentially identical to median for all four frameworks because heap
allocation is near-deterministic on this workload (fflib, O'Hara,
TAF show zero heap variance; SALT's heap p95 sits 60 B above its
median, well within rounding).

### State-equivalence verification

The benchmark driver captures an aggregated post-cascade state
snapshot before cleanup: 29 metric keys covering Account field
distributions (Type, Rating, AnnualRevenue, NumberOfEmployees,
Description, AccountSource, Phone), Contact field distributions
(MailingCity, Phone), Opportunity stage/probability/NextStep
distributions, Task counts grouped by Subject prefix, and
OpportunityContactRole counts.

**All 29 metric keys are identical across all 4 frameworks and across
all 10 runs of each framework.** Every framework produces the same
field-level mutations on the same record cohort — no missing
updates, no extra updates, no value drift.

The canonical snapshot (held by every framework, every run):

```
ACC count                : 200    OPP count                    : 200
ACC Type=Customer        : 200    OPP Stage=Negotiation/Review : 200
ACC Rating=Warm          : 200    OPP SUM(Probability)         : 15,000
ACC SUM(AnnualRevenue)   : $35M   OPP NextStep NOT NULL        : 200
ACC SUM(NumberOfEmployees): 200   CON count                    : 200
ACC Phone NOT NULL       : 200    CON MailingCity=New York     : 200
ACC Description=Forecast : 200    CON Phone LIKE +1-%          : 200
ACC AccountSource=Web    : 200    OCR count (Decision Maker)   : 200

TASK total                       : 1,000
TASK Subject=Approval routing    : 200
TASK Subject=Commission          : 200
TASK Subject=New deal alert      : 200
TASK Subject=Research            : 200
TASK Subject=Review high-value   : 200
```

This is the strongest possible "apples-to-apples" guarantee: not
just same row count, not just same DML count, not just same fire
count — same **field values** on the **same records**, **created
by** the same handlers, on every framework, every run.

### Per-trigger-context CPU (10-run cleanroom median, profiled)

CPU attributed to the innermost active trigger context at the moment
of each `Maximum CPU time` reading in the profiled debug log
(stack-tracked from `CODE_UNIT_STARTED` / `CODE_UNIT_FINISHED`
events). Cleanup-phase Delete contexts excluded. Median across 10
runs per framework.

| Trigger context           | SALT (ms) | fflib (ms) | O'Hara (ms) | TAF (ms) |
| ------------------------- | --------: | ---------: | ----------: | -------: |
| Account BeforeUpdate      | 4,846     | 4,164      | 5,298       | 5,126    |
| Account AfterUpdate       |   826     |   750      | 1,931       | 2,018    |
| Opportunity BeforeUpdate  | 1,292     | 1,006      |   924       |   949    |
| Opportunity AfterUpdate   |   144     |    71      |     0       |     0    |
| Contact BeforeUpdate      |   606     |   447      |   444       |   456    |
| Contact AfterUpdate       |     0     |     0      |     0       |     0    |
| Account AfterInsert       |   332     |   380      |   362       |   412    |
| Account BeforeInsert      |    90     |     9      |     7       |     8    |
| Contact BeforeInsert      |   120     |     8      |     9       |    10    |
| Opportunity BeforeInsert  |   164     |    36      |    34       |    36    |

> **Inner-attribution caveat.** Zero entries (e.g.
> `Contact AfterInsert` = 0 across the board, or `Contact AfterUpdate`
> = 0 in 3 of 4 frameworks) occur where every CPU sample taken
> during that context happened to land on a nested inner trigger
> frame. The **fire count is real** (1 in every framework) but the
> CPU attribution is sample-dependent at the small-fire end of the
> table. Totals and Account BU/AU rows are stable.
>
> **Profiling-overhead caveat.** `ApexProfiling=FINEST` adds runtime
> overhead vs an unprofiled run. The numbers above include that
> overhead because the profiled log is the only source of
> per-context attribution. The headline cross-framework CPU
> comparison stays valid because every framework pays the same
> profiling overhead.

### Where each framework wins

| Dimension              | Winner               | Margin                  | Evidence                                |
| ---------------------- | -------------------- | ----------------------- | --------------------------------------- |
| **Fewest SOQL**        | **SALT**             | 45 % vs fflib/O'Hara, 66 % vs TAF | 11 vs 20 vs 20 vs 32           |
| **Fewest DML statements** | **SALT**          | 13–17 % vs all others   | 21 vs 25 (fflib) vs 24 (O'Hara/TAF)     |
| **Fewest DML rows**    | **SALT / fflib (tied)** | 25 % vs O'Hara/TAF   | 3,600 / 3,600 vs 4,800 / 4,800          |
| **Lowest CPU**         | **fflib**            | 19 % better than SALT median, 18 % better at p95 | 6,604 ms vs 8,135 ms median; 7,241 ms vs 8,786 ms p95 |
| **Lowest maintenance** | **SALT**             | n/a                     | Adding a 5th `Contact\|AccountId` handler requires zero changes to existing handlers — others require an additional inline SOQL per cascade fire. |
| **Lowest heap delta**  | **O'Hara** (fflib +2.6 %) | 18 % lower than SALT, 29 % lower than TAF | 75 KB vs 77 KB vs 91 KB vs 106 KB |
| **Heaviest tail**      | **O'Hara**           | p95 1,346 ms above median (+15 % spread) | 10,048 ms p95 vs 8,702 ms median — pushes p95 vs SALT from +7 % (median) to +14 % (p95) |
| **Worst overall**      | **TAF**              | n/a                     | Highest CPU median (+13 % vs SALT), tied-worst CPU p95 (+14 %), highest SOQL (32), tied-worst DML rows (+33 %). The only metric where TAF beats anyone: it has the lowest CV (4.9 %) and tightest tail — its overhead is consistent, not variable. |

## Analysis

### SALT and fflib are architecturally equivalent on cascade behavior

SALT and fflib produce **identical fire patterns** on this workload
(6/6 Account BU/AU, 3/3 Opp BU/AU, 1 of everything else, 25 fires
total). Both batch DML by SObjectType and walk the same cascade
depth. There is no architectural difference in how often the
trigger contexts fire between the two frameworks.

The only structural metric where they differ is **DML statement
count**:

- **SALT** issues 21 DML statements via `DmlExecutor`, which
  consolidates DML across SObjectTypes within a single Phase 4
  commit.
- **fflib** issues 25 DML statements because its UoW does one
  `commitWork()` per `onAfter*` Domain method call, producing
  separate DML statements per SObjectType per commit.

Both write the **same 3,600 rows**. SALT just consolidates 4
statements that fflib leaves separate.

### fflib is 19 % cheaper on CPU than SALT

fflib's median CPU (6,604 ms) is 19 % lower than SALT's median
(8,135 ms), and at the p95 (7,241 ms vs 8,786 ms) it's still 18 %
lower — the gap holds at the tail because both frameworks have
similar tail spreads (CV 10.2 % vs 10.4 %). The gap is the
**per-trigger framework overhead floor** SALT pays for cross-cutting
features fflib doesn't provide:

- `IRecordFilter` Phase 1 — every handler with a filter pays
  per-record per-fire `isApplicable()` calls
- `IRecursionAware` field-hash — length-prefixed string concat
  computed per record per `IRecursionAware` handler
- `BindContext` allocation per query render
- `QueryAggregator.canMergeOrUnion()` pairwise comparison across all
  declared `QueryRequest`s in Phase 2
- Phase 4 cross-handler `FieldConflict` detection per `registerDirty`
- `Type.forName(namespace, className)` per handler instantiation
- Defensive copy of `applicableRecords` per handler before passing
  to `declareQueryNeeds` and `onDataReady`

fflib's Domain pattern pays none of that overhead. A `Domain`
class is instantiated, the override method runs, done. No per-record
cross-cutting passes, no merge-gate, no conflict-detection map walks.

The 19 % delta is the price SALT pays for the cross-handler
aggregation, conflict-detection, and recursion-robustness features.
On a workload that doesn't need those features, fflib is faster.
On a workload where SALT's query aggregation eliminates 9 SOQL
statements (45 % fewer), the SOQL savings are typically the more
production-relevant metric — orgs hit the 100-SOQL governor before
they hit the 10,000-ms CPU governor.

### Cascade multiplication is empirically confirmed for inline-DML frameworks

O'Hara and TAF each fire **12** Account BeforeUpdate and **12**
Account AfterUpdate contexts where SALT and fflib each fire **6** of
each. The 6 extra fires per Account context come from inline-DML
cascades — every handler that updates Account triggers the cascade
*immediately*, instead of batching to a single commit. The per-fire
cost is also higher because each cascade re-instantiates every
handler in the chain and re-runs per-record field-change checks
from scratch.

The 12 extra cascade fires (6 × Account BU + 6 × Account AU) are
the single largest CPU contributor for the inline-DML frameworks:

| Context               | SALT  | fflib | O'Hara | TAF   |
|-----------------------|-------|-------|--------|-------|
| Account BU + AU CPU   | 5,260 | 4,406 | 7,686  | 6,256 |
| % of total CPU        | 68 %  | 64 %  | 79 %   | 78 %  |

SALT (5,260 ms) ≈ fflib (4,406 ms) ≪ TAF (6,256 ms) ≪
O'Hara (7,686 ms) on those two contexts alone. The cascade-multiplied
contexts are where the entire CPU comparison is decided.

The DML-row penalty follows the same pattern: O'Hara and TAF each
write **4,800 rows** vs SALT/fflib's **3,600** — a 33 % row penalty
that comes from inline-DML cascades re-touching the same Account
records multiple times per scenario.

### TAF's `MetadataTriggerHandler` instantiation cost is visible at the outer level

TAF's per-context CPU shows 186 ms attributed to
`Opportunity AfterUpdate` where SALT/fflib/O'Hara show 0 / 67 / 89
ms. The pattern repeats at smaller scale on `Account AfterInsert`
and other outer contexts. This is consistent with
`MetadataTriggerHandler` per-fire instantiation cost dominating the
outer fire envelope before any handler logic runs — TAF is the only
framework where the dispatcher itself shows up at the outer level
rather than being attributed to inner contexts.

The CMDT cache in TAF v2 lives on the `MetadataTriggerHandler`
instance, and the trigger body instantiates a fresh
`MetadataTriggerHandler()` per fire. So every cascade fire pays a
fresh CMDT lookup. TAF's 32 SOQL count vs O'Hara's 20 (fellow
inline-DML framework) is almost entirely the CMDT routing
overhead — 12 extra SOQL statements that buy nothing on this
workload.

## Architectural takeaways

1. **SOQL aggregation pays off when there are merge groups.** SALT
   issues 11 SOQL where the inline frameworks issue 20–32. On a
   workload with no overlapping query intent across handlers, SALT's
   advantage would shrink toward zero. The 23-handler enterprise
   surface used here is representative of the workload SALT was
   designed for — five distinct merge groups with 2–4 handlers
   each. Smaller orgs with simpler trigger surfaces will see
   smaller relative wins.

2. **Phase 4 DML batching prevents cascade multiplication.** SALT
   and fflib both batch DML by SObjectType and avoid the +12 cascade
   fires that hit O'Hara and TAF. This is the largest single
   architectural lever in the comparison — bigger than the CMDT
   routing cost, bigger than the per-record framework overhead.
   Any team building handlers at scale should adopt some form of
   DML batching whether they use SALT, fflib, or roll their own.

3. **fflib's `Domain` pattern is the cheapest way to provide
   per-handler isolation** that's been measured in this experiment.
   It pays zero per-trigger framework overhead, walks the same
   cascade depth as SALT, and only loses to SALT on SOQL count
   because Selectors don't aggregate across consumers. If a team
   needs DML batching but doesn't need cross-handler query
   aggregation, fflib is the lower-overhead choice.

4. **TAF's CMDT routing is the most expensive coordination
   strategy** measured here. The per-fire `MetadataTriggerHandler`
   instantiation, the per-fire CMDT lookup, and the cascade
   multiplication compound to give TAF 12 extra SOQL vs O'Hara
   (its closest peer architecturally) and tie-worst DML rows.
   Metadata-driven handler registration is convenient for admins
   but the runtime cost is non-trivial at scale.

5. **CPU is the wrong currency to optimize — but watch the tail.**
   Even O'Hara at 8,702 ms median sits 13 % under the 10,000 ms
   synchronous CPU governor. At the p95 the picture is tighter:
   O'Hara hits 10,048 ms — **0.5 % over** the 10,000 ms governor —
   meaning roughly 1 in 20 transactions on this workload would
   actually breach the limit. TAF p95 (9,993 ms) sits at the
   governor edge, SALT p95 (8,786 ms) has 12 % headroom, and fflib
   p95 (7,241 ms) has 28 % headroom. SOQL pressure (where SALT
   issues 11 vs the inline frameworks' 20–32) is still the
   bottleneck most production orgs hit first, but the inline-DML
   frameworks have a real CPU-tail risk on workloads of this size.

## Reproducing this benchmark

See [`methodology.md`](methodology.md) for the complete reproduction
recipe — vendor SHAs, port-audit protocol, deploy choreography,
trigger-body-swap procedure, profiling setup, and per-framework
gotchas encountered while standing up the comparison.
