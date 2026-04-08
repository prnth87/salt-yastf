# SALT Framework Benchmarks

Cross-framework comparison of SALT against fflib Enterprise Patterns,
mitchspano's Trigger Actions Framework (TAF), and Kevin O'Hara's
sfdc-trigger-framework on a 23-handler enterprise trigger surface.
All four frameworks are measured directly against the same workload
on the same dev org, varying only which dispatcher the trigger
bodies invoke.

## Contents

- **[benchmark-report.md](benchmark-report.md)** — Setup, results,
  per-context CPU, winners table, and architectural analysis.
  Headline numbers are 10-run cleanroom medians from a profiled
  apples-to-apples session with state-equivalence verification.
- **[methodology.md](methodology.md)** — Procedure, vendor SHAs,
  trigger-body-swap strategy, profiled-run instrumentation, and the
  full reproduction recipe.
- **[handlers.yaml](handlers.yaml)** — Registry of all 23 handler
  classes used in the benchmark with each handler's trigger
  context, interfaces, merge key, DML target, and business
  justification.

## Headline result

| Metric | SALT | fflib | O'Hara | TAF |
|---|---:|---:|---:|---:|
| **SOQL** | **11** | 20 | 20 | 29 |
| **DML statements** | **21** | 25 | 24 | 24 |
| **DML rows** | **3,600** | **3,600** | 4,800 | 4,800 |
| **CPU (10-run median, profiled, ms)** | **7,298** | **6,604** | 8,702 | 8,840 |
| **CPU (10-run p95, profiled, ms)** | 8,042 | **7,241** | 10,048 | 9,314 |
| **Δ vs SALT median CPU** | — | −10 % | +19 % | +21 % |
| **Δ vs SALT p95 CPU** | — | −10 % | +25 % | +16 % |
| **Total trigger fires** | **26** | **26** | 38 | 38 |
| **State equivalence** | ✓ canonical | ✓ identical | ✓ identical | ✓ identical |

SALT issues 45 % fewer SOQL than fflib/O'Hara and 62 % fewer than
TAF on the same 23-handler workload. fflib is 10 % cheaper than SALT
on CPU at the median (and 10 % cheaper at the p95) because it pays
no per-trigger framework overhead floor — the cost SALT pays for
cross-handler aggregation, conflict detection, and recursion
robustness. SALT and fflib tie on DML rows (both batch by
SObjectType) and on cascade fire counts (both 26 fires). O'Hara and
TAF inline-DML cascade-multiply to 38 fires and 4,800 DML rows.
O'Hara's CPU p95 pushes to within 1 % of the 10,000 ms governor;
TAF's p95 (9,314 ms) sits 7 % below the governor.

**State equivalence is verified**: 29 aggregated post-cascade
state-snapshot keys (Account/Contact/Opportunity field
distributions, Task counts grouped by Subject prefix, OCR counts)
are **identical across all 4 frameworks** and across all 10 runs of
each framework. Every framework produces the same field-level
mutations on the same record cohort.

See [`benchmark-report.md`](benchmark-report.md) for the full
analysis.
