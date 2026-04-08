# SALT(YASTF) Benchmark Methodology

How the SALT-vs-fflib-vs-O'Hara-vs-TAF comparison was set up and run.
This is the **how**; the **what** and **why** are in
[`benchmark-report.md`](benchmark-report.md).

This document is written so a reader on a fresh machine can
reproduce the experiment against their own dev org.

---

## 1. Goal

Produce a **measured** comparison of cross-handler trigger frameworks
on the same 23-handler enterprise workload, using the same driver
script, against the same set of seed data, on the same dev org —
varying only which framework's dispatcher the trigger bodies invoke.

The output is a small set of numbers per framework (SOQL, DML, DML
rows, CPU, per-context CPU, fire counts) that can be compared
directly. No tracing, no cost models, no estimation.

## 2. Constraints

- **One dev org** (Developer Edition or scratch). All four frameworks
  share the same org sequentially. No DevHub required.
- **SALT is already deployed and in active development.** The
  experiment must not destructively uninstall SALT to swap in another
  framework.
- **No second user.** All runs share the same running user, same
  TraceFlag, same defaults.
- **The driver script must not change between framework runs.** It is
  the apples-to-apples reference; modifying it per framework would
  invalidate the comparison.

## 3. The trigger-body-swap strategy

The key decision is **never to uninstall SALT**. Once you understand
that SALT's 23 handlers + CMDT + `QueryExecutor` family + `BindContext`
runtime all dispatch *through* a single entry point — the body of the
three SALT triggers calling `TriggerDispatcher.run()` — you can
render the entire SALT stack inert by rewriting just three trigger
bodies. The classes stay deployed but become unreferenced dead code
for the duration of the framework run.

For each framework, the loop is:

1. Edit the three SALT trigger files in
   `test-harness/main/default/triggers/` to call the framework's
   dispatcher instead of `TriggerDispatcher.run()`.
2. `sf project deploy start --source-dir test-harness/main/default/triggers …`
3. Run the benchmark, capture the log.
4. Restore the SALT trigger bodies and re-deploy.

Round-trip verification: after the final framework run,
`git diff --stat test-harness/main/default/triggers/` returns empty.
SALT is back to its baseline byte-for-byte.

**Time cost:** ~3–5 minutes per framework swap including deploy.
A full 4-framework comparative run takes well under an hour of
deploy + measurement time. Compare to ~30 min per framework for an
uninstall/reinstall cycle.

## 4. Vendor-then-port pipeline

For each framework:

1. **Clone upstream** to a working directory and capture the HEAD
   commit SHA (record the SHA — every measurement should be tied to
   pinned vendor sources).
2. **Copy only the runtime classes** (no `*Test.cls`, no sample
   apps, no docs/images) into `test-harness/<fw>/vendor/main/default/classes/`.
3. **Copy any required non-class metadata** (custom labels for
   fflib; custom metadata type definitions for TAF) into
   `test-harness/<fw>/vendor/main/default/{labels,objects}/`.
4. **Write `test-harness/<fw>/vendor/VENDOR_INFO.md`** recording the
   source URL, pinned SHA, copy date, license, and any rename notes.
5. **Port the 23 SALT handlers** to the framework's idiom in
   `test-harness/<fw>/handlers/` and the framework-specific triggers
   in `test-harness/<fw>/triggers/`.

For the comparison documented in `benchmark-report.md`, the three
non-SALT frameworks were vendored at the latest stable commit on
their default branch at the time of the measurement, with the
following vendor SHAs recorded in each `VENDOR_INFO.md`:

| Framework | Repo | Pinned SHA | License |
|---|---|---|---|
| fflib-apex-common | apex-enterprise-patterns/fflib-apex-common | `286d0d12b40f22b1cb41a5fb451d4a9dd690e11a` | Apache-2.0 |
| fflib-apex-mocks (compile dep) | apex-enterprise-patterns/fflib-apex-mocks | `24deeebccb9647a07921f89247f24cace764f7f0` | BSD-3 |
| TAF | mitchspano/apex-trigger-actions-framework | `5c3793d2b5baaa91b0b5b2b691ab1750ef37fa41` | Apache-2.0 |
| O'Hara | kevinohara80/sfdc-trigger-framework | `b7e36c76a3608674979e44fe3a823b55016fff7c` | MIT |

## 5. Deploy choreography per framework

Per framework, deploy in order:

1. `sf project deploy start --source-dir test-harness/<fw>/vendor …`
2. `sf project deploy start --source-dir test-harness/<fw>/handlers …`
   (and `--source-dir test-harness/<fw>/customMetadata` for TAF)
3. Edit + deploy SALT trigger bodies (activation step)
4. `sf apex run --target-org <alias> --file <driver>.apex > <log>.log 2>&1`
5. Restore SALT trigger bodies

Framework-specific triggers (`test-harness/{fflib,taf,ohara}/triggers/`)
are excluded via `.forceignore` — they exist on disk as reference for
the trigger-body swap but are never deployed directly. All vendor
classes and ported handlers are deployed additively alongside SALT
(distinct prefixes prevent collisions).

## 6. The driver script

A single anonymous-Apex driver script is reused unchanged across
all framework runs. It:

- Disables SALT's CPU circuit breaker by calling
  `TriggerDispatcher.setCpuThresholdFraction(2.0)` (no-op when
  TriggerDispatcher isn't on the active code path).
- Pre-cleans any leftover seed data from prior runs.
- Runs Scenarios A/B/C in a single anonymous Apex transaction.
- Snapshots `Limits.getQueries()`, `getDmlStatements()`,
  `getDmlRows()`, `getCpuTime()`, `getHeapSize()` before and after
  each scenario.
- Prints a per-scenario `USER_DEBUG` line in the format
  `<scenario> :: SOQL=<n> DML=<n> DMLrows=<n> CPU=<n>ms HeapDelta=<n>B`.
- Prints a `TOTAL :: …` line summing the per-scenario deltas.
- **Captures an aggregated state snapshot** before cleanup (see
  § 6a below) — 29 deterministic metric keys covering every
  handler-touched field.
- Cleans up all seed data in a `finally` block.

The script-reported total is the apples-to-apples comparison number
across frameworks because every framework runs the exact same driver
through the exact same trigger contexts. The state snapshot is the
strongest possible equivalence proof: same field values on the same
records, created by the same handlers, every framework, every run.

## 6a. State snapshot — verifying functional equivalence

The benchmark driver runs an aggregated SOQL pass after the three
scenarios complete and before cleanup:

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

These 29 metric keys are:

- **Account**: count + Type/Rating distributions, SUM(AnnualRevenue),
  SUM(NumberOfEmployees), Phone-set count, Description-prefix counts
  (Apex-side aggregation because Description is long-text and not
  SOQL-filterable), AccountSource distribution.
- **Contact**: count + MailingCity distribution + normalized-phone
  count.
- **Opportunity**: count + StageName distribution + SUM(Probability)
  + NextStep-set count.
- **Task**: total count + counts grouped by Subject prefix
  (each prefix maps to exactly one handler that creates that
  Subject).
- **OpportunityContactRole**: total count + Role distribution.

The snapshot is **deterministic across runs** (no record-ID
dependencies, no timestamps) and can be diff'd line-by-line across
framework runs to verify equivalence.

If a framework writes the wrong field values, the snapshot exposes
it immediately — even if row counts, DML counts, SOQL counts, and
fire counts all match. ## 6b. The 10-run cleanroom protocol

For the headline measurement, run each framework **10 times**
back-to-back with cooloffs:

- 5-second sleep between runs of the same framework — gives the org
  pod a chance to release CPU pressure before the next run starts.
- 10-second sleep between frameworks — gives the new dispatcher's
  classes a chance to warm in cache after the trigger swap.
- 3-run minimum is unreliable on a multi-tenant dev org because a
  single noisy-neighbor event can dominate the median. 10 runs gives
  enough samples to compute a stable median + spread (CV) and to
  detect outliers.

A single bash orchestration script handles the trigger swap +
10-run loop + cooloff + trigger restore for all 4 frameworks.
Total wall-clock time on a typical dev org: ~30 minutes for 40 runs
+ cooloffs + 3 trigger deploys.

## 7. Profiled-run setup for per-context CPU attribution

The script-reported total is sufficient for cross-framework total-CPU
comparison. To attribute CPU to specific trigger contexts, you also
need a profiled debug log.

The procedure:

1. Create a `DebugLevel` via the Tooling API:

   ```bash
   sf data create record --target-org <alias> --use-tooling-api \
     --sobject DebugLevel \
     --values "DeveloperName=BenchProf MasterLabel=BenchProf \
               ApexCode=DEBUG ApexProfiling=FINEST Workflow=INFO \
               Validation=INFO Callout=INFO Database=INFO System=INFO \
               Visualforce=INFO Wave=INFO Nba=INFO"
   ```

2. Create a `TraceFlag` for the running user pointing at that
   `DebugLevel` (`LogType=USER_DEBUG`,
   `StartDate`/`ExpirationDate` ISO-8601, expiration far enough out
   to cover the run window).

3. Run each framework's swap+benchmark loop. With the TraceFlag
   active, the org persists the debug log automatically.

4. Use `sf apex list log --json` to find the most recent log Id;
   `sf apex get log --log-id <id>` to download it.

5. Parse the persisted log: maintain a stack of `CODE_UNIT_STARTED`
   trigger events
   (`AccountTrigger on Account trigger event BeforeUpdate`), pop on
   `CODE_UNIT_FINISHED`, and attribute each
   `Maximum CPU time: N out of 10000` reading inside a
   `CUMULATIVE_LIMIT_USAGE` block to the innermost active stack
   frame. Exclude `Before/AfterDelete` contexts (cleanup phase, not
   benchmark). Strip ANSI color escape codes that the SF CLI's
   pretty-printing injects into log output.

6. Delete the `TraceFlag` and `DebugLevel` after the run.

**Profiling-overhead caveat.** `ApexProfiling=FINEST` adds runtime
overhead variable per framework (the heavier the trigger pass, the
more samples the profiler takes). The script-reported totals from
unprofiled runs sit consistently below the profiled totals by ~5–9 %.
Use unprofiled totals for the headline cross-framework comparison;
use profiled per-context attribution to understand where the time
goes within each framework.

## 8. Log capture

Use `sf apex run … > log.txt 2>&1` to capture the run log via stdout
redirection when no TraceFlag is active. **Do NOT rely on
`sf apex get log --log-id …` for unprofiled runs** — `get log` only
returns logs the org persisted via an active `TraceFlag`, and a
plain dev user has none. `apex run`'s stdout output includes the
full debug log inline regardless of TraceFlag state, so redirecting
stdout always works and is the only reliable capture path for
ad-hoc benchmark runs.

When a `TraceFlag` is active (per § 7), `sf apex get log` does work
and returns the freshly-persisted profiled log.

## 9. Reproducing the comparison

From the repo root with your dev org's alias set:

```bash
# 0. Vendor the frameworks (one-time)
git clone --depth 1 https://github.com/apex-enterprise-patterns/fflib-apex-common.git
git clone --depth 1 https://github.com/apex-enterprise-patterns/fflib-apex-mocks.git
git clone --depth 1 https://github.com/mitchspano/apex-trigger-actions-framework.git
git clone --depth 1 https://github.com/kevinohara80/sfdc-trigger-framework.git
# (then copy classes/labels/objects per § 4)

# 1. Confirm .forceignore excludes framework triggers (see § 5)

# 2. Back up SALT triggers
mkdir -p /tmp/salt-trigger-backup
cp test-harness/main/default/triggers/*.trigger /tmp/salt-trigger-backup/

# 3. (Optional) Create profiling DebugLevel + TraceFlag (see § 7)

# 4. Per framework: deploy + swap + run + capture + restore
for FW in fflib ohara taf; do
  sf project deploy start --target-org <alias> \
    --source-dir test-harness/$FW/vendor \
    --source-dir test-harness/$FW/handlers \
    --ignore-conflicts --wait 30
  # (also deploy test-harness/taf/customMetadata for TAF)

  # Edit AccountTrigger / ContactTrigger / OpportunityTrigger bodies
  # to call the framework's dispatcher (see § 3 and the per-framework
  # trigger files in test-harness/$FW/triggers/ for the exact body)

  sf project deploy start --target-org <alias> \
    --source-dir test-harness/main/default/triggers \
    --ignore-conflicts --wait 30

  for N in 1 2 3; do
    sf apex run --target-org <alias> \
      --file <driver>.apex \
      > logs/$FW-run$N.log 2>&1
  done
done

# 5. Restore SALT triggers
cp /tmp/salt-trigger-backup/*.trigger test-harness/main/default/triggers/
sf project deploy start --target-org <alias> \
  --source-dir test-harness/main/default/triggers \
  --ignore-conflicts --wait 30

# 6. Verify clean restore
git diff --stat test-harness/main/default/triggers/  # must be empty

# 7. (Optional) Delete profiling TraceFlag + DebugLevel
```

Run the SALT baseline measurement the same way without swapping the
trigger bodies (the SALT triggers already call
`TriggerDispatcher.run()` at baseline).

## 10. What this approach can't measure

- **Per-call-site CPU attribution** (a level deeper than per-context)
  — would require either inline `Limits.getCpuTime()` snapshots
  inside `QueryExecutor.execute` / `QueryAggregator.aggregate` /
  `BindContext.registerBind`, or a `METHOD_ENTRY`/`METHOD_EXIT`-level
  log via the Tooling API's `executeAnonymous` endpoint with a
  custom debug header (the `sf apex run` CLI sends a hardcoded
  debug header that ignores the user's TraceFlag).
- **Heap accurately** — debug log instrumentation perturbs heap
  measurements; the heap deltas reported by the script are noisy
  and shouldn't be over-interpreted.
- **Cold-start vs warm-cache effects** — every run hits the same
  warm org. The first deploy of a framework includes JIT
  compilation cost that subsequent runs don't pay; this isn't
  isolated.
- **Concurrency / contention** — single user, single transaction.
  Frameworks that perform differently under high concurrency
  (e.g. static-flag-based recursion guards under interleaved
  invocations) aren't differentiated here.
- **Multi-tenant noisy-neighbor variance.** Dev orgs share physical
  resources with other tenants on the same Salesforce pod. Run-to-run
  CPU variance of 10–25 % is normal and reflects pod load, not
  framework behavior. Use the median across multiple runs (3 was
  the chosen sample size; 5–10 would smooth pod noise further).

