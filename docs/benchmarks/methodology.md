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

The deploy order matters because each step exposes different failure
modes:

1. `sf project deploy start --source-dir test-harness/<fw>/vendor …`
   — validates the upstream framework compiles in isolation against
   the org's existing SALT classes. Catches missing labels, missing
   CMDT objects, identifier collisions.
2. `sf project deploy start --source-dir test-harness/<fw>/handlers …`
   (and `--source-dir test-harness/<fw>/customMetadata` for TAF) —
   validates the ports compile against the vendor classes.
3. **Edit + deploy SALT trigger bodies** — the activation step.
   After this, the framework is live.
4. `sf apex run --target-org <alias> --file <driver>.apex > <log>.log 2>&1`
5. **Restore SALT trigger bodies** — back to baseline.

### Why `.forceignore` excludes the framework triggers

Each framework port generates three framework-specific triggers
(`FflibAccountTrigger.trigger`, `OharaAccountTrigger.trigger`, etc.).
**These must never be deployed alongside the SALT triggers** — they
would fire on the same SObject/context combinations and double-
execute every handler. The fix is to add them to `.forceignore`:

```
# Comparative-framework triggers — never deploy alongside SALT triggers
# (would double-fire). The active framework is selected by editing the
# SALT trigger bodies in test-harness/main/default/triggers/ to call the
# framework's dispatcher.
test-harness/fflib/triggers/**
test-harness/taf/triggers/**
test-harness/ohara/triggers/**
```

The framework-specific triggers exist on disk only as a record of
"what the trigger body looks like in this framework's idiom" —
they're copied into the SALT trigger files at swap time but never
deployed directly.

### Why deploys are *additive*

Each framework's vendor classes (`fflib_*`, `OharaTriggerHandler`,
`MetadataTriggerHandler`, etc.) and ported handlers (`Accounts.cls`,
`Ohara*Handler.cls`, `TAF*Handler.cls`) are simply *added* to the
org's class table alongside the existing SALT classes. No
namespace collisions because:

- fflib uses the `fflib_` prefix
- O'Hara's `TriggerHandler` is renamed locally to `OharaTriggerHandler`
  to avoid colliding with the SALT-test-harness `TriggerHandler`
  class
- TAF uses unprefixed but distinct names
  (`MetadataTriggerHandler`, `TriggerActionFlow`, etc.)
- Ports use the `Ohara*` / `TAF*` / fflib Domain class prefixes

After all framework runs complete, the dev org has all 4 framework
runtimes installed simultaneously. Only the active framework's
dispatcher is referenced from the (single, swapped) SALT trigger
bodies; the others are inert.

## 6. Per-framework gotchas encountered

These are the failures that hit during real setup. None are
documented in the upstream READMEs. Reproducing the experiment will
hit each one.

### fflib: missing custom labels

**Symptom:** First deploy of fflib vendor classes fails with errors
like:
```
fflib_SecurityUtils: External string does not exist:
fflib_security_error_object_not_insertable (56:24)
```

**Cause:** `fflib_SecurityUtils.cls` references custom labels via
`System.Label.fflib_security_error_*`. The labels live in
`sfdx-source/apex-common/main/labels/fflib-Apex-Common-CustomLabels.labels-meta.xml`,
which an initial vendor copy will miss if only `classes/` was copied.

**Fix:** Also copy `apex-common/main/labels/` into
`test-harness/fflib/vendor/main/default/labels/`.

### O'Hara: vendored class name collides with SALT

**Symptom:** Both upstream `TriggerHandler` (the O'Hara base class)
and the SALT-test-harness `TriggerHandler` exist in the project,
causing a duplicate-class deploy error.

**Fix:** Rename the vendored class to `OharaTriggerHandler` at
vendor time, and patch four internal references in
`OharaTriggerHandler.cls`:
- The constructor (`public TriggerHandler()` → `public OharaTriggerHandler()`)
- Two static-member references
- The exception class `TriggerHandlerException` →
  `OharaTriggerHandlerException`

All ported handlers under `test-harness/ohara/handlers/` extend
`OharaTriggerHandler`. The SALT `TriggerHandler` remains untouched.

### O'Hara: Apex 40-char identifier limit

**Symptom:**
```
ApexClass OharaOpportunityCompetitorAnalysisHandler:
Identifier name is too long (1:14)
```

`OharaOpportunityCompetitorAnalysisHandler` is 41 characters; Apex
caps identifiers at 40.

**Fix:** Renamed file + class to `OharaOppCompetitorAnalysisHandler`
(33 chars) and updated the corresponding trigger body to match.

### TAF: `Trigger_Action__mdt` validation rules and 40-char fullName cap

**Symptom:** First deploy of the auto-generated CMDT records fails
with two distinct errors across most records:

1. `You must enter a description for this Trigger Action.`
2. `Value too long for field: fullName maximum length is: 40`

**Cause 1:** The vendored `Trigger_Action__mdt` ships with a
validation rule that requires the `Description__c` field to be
populated. Auto-generated CMDT records that omit it fail validation.

**Cause 2:** CMDT fullNames have a 40-char hard cap that includes
the DeveloperName. `TAF_OpportunityCompetitorAnalysis_After_Insert`
is 47 chars.

**Fix:** Bulk script that:
- Adds a `Description__c` value to every CMDT record before
  `</CustomMetadata>`.
- Abbreviates names: `Opportunity` → `Opp`, `Account` → `Acct`,
  `Contact` → `Cont`. Renames both the file and the
  `<Apex_Class_Name__c>` references where needed.

### TAF: v2 action caching is per-instance, not per-transaction

**The most consequential discovery during the comparison.**

The TAF v2 docs describe an "action caching" mode that supposedly
reduces CMDT routing to ~1 SOQL per transaction. The measured TAF
SOQL count is much higher — TAF issues an order-of-magnitude more
SOQL than fflib for the same workload.

Reading `MetadataTriggerHandler.cls` reveals why: the action cache
lives on the `MetadataTriggerHandler` *instance*, and the trigger
body instantiates a new `MetadataTriggerHandler()` per fire. So
every cascade fire pays a fresh CMDT lookup. The cache works within
a single trigger context, but cascading lead conversion compounds
the penalty linearly with cascade depth.

There is no fix for this — it's TAF's runtime behavior. It is the
strongest argument in this benchmark for measuring rather than
trusting documentation.

### SALT: undocumented CPU circuit breaker silently degrades SALT under profiling

**Symptom:** Profiled SALT runs (`ApexProfiling=FINEST`) show wildly
varying CPU totals across back-to-back runs. Per-context attribution
shows one or more handlers being skipped on different runs without
any apparent pattern.

**Cause:** SALT's `TriggerDispatcher` has a third circuit breaker
(in addition to the SOQL and Heap breakers documented in
`DESIGN.md`) that checks
`Limits.getCpuTime() > Limits.getLimitCpuTime() * 0.75` per handler
during Phase 3 and **skips non-critical handlers under CPU pressure**.
Default threshold: 7,500 ms. fflib / O'Hara / TAF have no
equivalent. `ApexProfiling=FINEST` adds enough CPU overhead to push
SALT past the 7,500 ms threshold during the profiled cascade,
tripping the breaker and silently skipping handlers — putting SALT
in degraded mode while the other frameworks run at full capacity.

**Fix:** The benchmark driver calls
`TriggerDispatcher.setCpuThresholdFraction(2.0)` at the top of the
script, raising the threshold above the governor limit and
effectively disabling the breaker for benchmark fairness. The
setter is a no-op when SALT's `TriggerDispatcher` isn't being
invoked (i.e. during fflib/O'Hara/TAF runs), so the change is
SALT-only and the comparison stays apples-to-apples. The breaker
has been added to `DESIGN.md` § Circuit Breakers since it was
omitted from the design docs.

### fflib `registerDirty(SObject)` replaces instead of merging fields

**Symptom:** State-snapshot verification showed fflib's
`Account.AnnualRevenue` and `Account.NumberOfEmployees` were `NULL`
where SALT wrote `$35M` and `200` respectively. fflib's `Rating`
column came out `Cold:200` where SALT had `Warm:200` — because
`AccountClassificationHandler` reads `AnnualRevenue` to compute the
rating, and `null < 100000 → Cold`. Row counts and fire counts
matched SALT exactly; only the **field values** were wrong. fflib
was visiting every Account but writing the wrong subset of fields.

**Cause:** `fflib_SObjectUnitOfWork.registerDirty(SObject)` (the
no-arg overload) **replaces** the entire SObject in
`m_dirtyMapByType` instead of merging fields. From
`fflib_SObjectUnitOfWork.cls`:

```apex
public void registerDirty(SObject record) {
    registerDirty(record, new List<SObjectField>());   // empty list
}

public void registerDirty(SObject record, List<SObjectField> dirtyFields) {
    if (record.Id == null) throw new UnitOfWorkException(...);
    String sObjectType = record.getSObjectType().getDescribe().getName();
    // If record isn't already in the map, OR no dirty fields to drive a merge:
    if (!m_dirtyMapByType.get(sObjectType).containsKey(record.Id)
        || dirtyFields.isEmpty()) {
        // REPLACE the record (drops any prior field updates)
        m_dirtyMapByType.get(sObjectType).put(record.Id, record);
    } else {
        // Merge: copy each dirtyField from the new record onto the registered one
        SObject registeredRecord = m_dirtyMapByType.get(sObjectType).get(record.Id);
        for (SObjectField dirtyField : dirtyFields) {
            registeredRecord.put(dirtyField, record.get(dirtyField));
        }
        m_dirtyMapByType.get(sObjectType).put(record.Id, registeredRecord);
    }
}
```

So when handlers register Account dirty in sequence:
- `pipelineRollup_AfterInsert` → `registerDirty(new Account(Id=X, AnnualRevenue=175000))`
- `forecastReconcile_AfterInsert` → `registerDirty(new Account(Id=X, Description='Weighted forecast: $X'))`
- `accountType_AfterInsert` → `registerDirty(new Account(Id=X, Type='Customer'))`

…the map ends up holding only the LAST one — `new Account(Id=X,
Type='Customer')` — with `AnnualRevenue` and `Description` both
unset. `commitWork()` issues `update [{Id, Type=Customer}]`. Type
gets set, the other fields are silently lost.

**Fix:** every `uow.registerDirty(...)` call in the fflib port must
use the field-list overload that triggers the merge branch:

```apex
// Wrong — replaces previous register, drops fields:
uow.registerDirty(new Account(Id = accId, AnnualRevenue = 175000));

// Right — merges field by field with any prior register:
uow.registerDirty(
    new Account(Id = accId, AnnualRevenue = 175000),
    new List<SObjectField>{ Account.AnnualRevenue }
);
```

**Detection:** the bug was invisible to row-count, DML-count,
SOQL-count, and cascade-fire-count comparisons (all four metrics
matched SALT exactly). It only surfaced when the benchmark driver
captured an aggregated **state snapshot** of post-cascade field
values and the cross-framework diff showed `AnnualRevenue=NULL` in
fflib vs `$35M` in SALT. **Always verify field-level state
equivalence, not just row counts**, when porting handlers to a
framework with a UoW-style commit pattern.

### All 3 non-SALT ports: missing `contactAccountSync_AfterUpdate`

**Symptom:** An earlier whiteroom session showed SALT firing 6/6 Account
BU/AU contexts where fflib fired 5/5 — a difference that shouldn't
exist if both frameworks batch DML the same way. The cascade-fire
divergence pointed at a missing handler.

**Cause:** SALT registers `ContactAccountSyncHandler` on **both**
AfterInsert and AfterUpdate (CMDT `AfterInsert__c=true`,
`AfterUpdate__c=true`). The original sub-agent ports for fflib,
O'Hara, and TAF only wired up the AfterInsert path. As a result,
Scenario B's Account-territory-transfer cascade
(`Account.OwnerId` update → Contact owner cascade → Contact
AfterUpdate) silently terminated one cascade level shallow in all
three non-SALT ports. The missing 200-row `Account.Phone` resync,
the missing cascade fire, and ~940 ms of CPU were all hidden by
the same port bug.

**Fix:** Added `contactAccountSync_AfterUpdate` to fflib's
`Contacts.cls` Domain, `afterUpdate()` override to
`OharaContactAccountSyncHandler`, `TriggerAction.AfterUpdate`
interface to `TAFContactAccountSyncHandler`, and a new
`Trigger_Action.TAF_ContAccountSync_After_Update.md-meta.xml` CMDT
record.

**Side bug found while fixing this:** the original fflib
`Contacts.cls` had a static `Set<String> recursionGuard` keyed on
`Contact.Id|Phone|AccountId` to mimic SALT's `IRecursionAware`
behavior. The static set persists across the entire anonymous Apex
transaction, so Scenario A's Contact AfterInsert populated the
guard with all 200 Contact ids, then Scenario B's new Contact
AfterUpdate found the same `Id|Phone|AccountId` keys (Phone and
AccountId unchanged by the OwnerId cascade) and skipped every
contact. SALT's `RecursionGuard` prunes per cascade-depth so
Scenario B sees a clean state. The fflib port now omits the static
guard entirely — the actual benchmark scenarios have no in-cascade
re-entry that needs guarding because fflib's UoW commits only at
the outermost trigger fire.

### Audit protocol: how to find this class of bug

When porting a framework's handlers, the **authoritative source of
"what contexts does this handler run on"** is the framework's
registration mechanism (CMDT, action class interfaces, etc.), **not**
the handler class body. A SALT handler's `onDataReady` method may be
context-agnostic on the surface but be registered for both Insert
and Update contexts via separate CMDT flags. Sub-agents porting
handlers from method bodies alone will miss that.

The audit:

1. Extract every SALT CMDT handler registration with its full
   context flag set:

   ```bash
   python3 -c "
   import re, glob
   for f in sorted(glob.glob('test-harness/main/default/customMetadata/TriggerHandler.*.md-meta.xml')):
     c = open(f).read()
     cls = re.search(r'HandlerClass__c</field>\s*<value[^>]*>(\w+)</value>', c, re.S).group(1)
     ctxs = [k for k in ['BeforeInsert','BeforeUpdate','AfterInsert','AfterUpdate','BeforeDelete','AfterDelete','AfterUndelete']
             if re.search(rf'<field>{k}__c</field>\s*<value[^>]*>true</value>', c, re.S)]
     print(cls.ljust(50), ctxs)
   "
   ```

2. For each handler with **multiple active contexts**, grep each
   port for both contexts:
   - **fflib**: search the relevant Domain class (`Accounts.cls`,
     `Contacts.cls`, `Opportunities.cls`) for `<handler>_<context>`
     private-method names.
   - **O'Hara**: search the per-handler class for
     `protected override void <context>()`.
   - **TAF**: search the per-handler class for
     `TriggerAction.<context>` interface declarations AND search
     `customMetadata/Trigger_Action.TAF_<handler>_<context>.md-meta.xml`
     for the matching CMDT record.

3. Any handler that's in the SALT CMDT for context X but missing
   from a port's context-X entry is a port bug.

The audit run for the SALT 23-handler workload found exactly one
gap: `ContactAccountSyncHandler` missing AfterUpdate in all three
ports. The other 7 multi-context handlers
(`AccountClassification`, `OpportunityCompetitorAnalysis`,
`OpportunityForecastReconcile`, `OpportunityNextStep`,
`OpportunityNotification`, `OpportunityPipelineRollup`,
`OpportunityStage`) were all wired up correctly in all three ports.

## 7. The driver script

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
  § 7a below) — 29 deterministic metric keys covering every
  handler-touched field.
- Cleans up all seed data in a `finally` block.

The script-reported total is the apples-to-apples comparison number
across frameworks because every framework runs the exact same driver
through the exact same trigger contexts. The state snapshot is the
strongest possible equivalence proof: same field values on the same
records, created by the same handlers, every framework, every run.

## 7a. State snapshot — verifying functional equivalence

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
fire counts all match. This is exactly how the fflib `registerDirty`
field-list-overload bug (§ 6) was discovered: every other metric
matched SALT, but the state snapshot showed `AnnualRevenue=NULL`
where SALT had `$35M`.

## 7b. The 10-run cleanroom protocol

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

## 8. Profiled-run setup for per-context CPU attribution

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

## 9. Log capture

Use `sf apex run … > log.txt 2>&1` to capture the run log via stdout
redirection when no TraceFlag is active. **Do NOT rely on
`sf apex get log --log-id …` for unprofiled runs** — `get log` only
returns logs the org persisted via an active `TraceFlag`, and a
plain dev user has none. `apex run`'s stdout output includes the
full debug log inline regardless of TraceFlag state, so redirecting
stdout always works and is the only reliable capture path for
ad-hoc benchmark runs.

When a `TraceFlag` is active (per § 8), `sf apex get log` does work
and returns the freshly-persisted profiled log.

## 10. Reproducing the comparison

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

# 3. (Optional) Create profiling DebugLevel + TraceFlag (see § 8)

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

## 11. What this approach can't measure

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

## 12. Lessons learned

- **Cost models are useful priors but invalidate easily.** SOQL-count
  predictions tend to hold (they're architecture-deterministic);
  CPU predictions miss by 30–40 % when they depend on framework
  runtime behavior (TAF action caching, O'Hara cascade
  re-instantiation cost). Measure when feasible.
- **`--source-dir` beats package.xml** for vendored bundles. Listing
  source directories explicitly is more reliable than maintaining a
  manifest, especially when the same bundle gets re-deployed
  incrementally.
- **`.forceignore` is the cleanest swap mechanism.** Putting the
  framework triggers behind `.forceignore` and editing the SALT
  trigger bodies in place is simpler than juggling separate trigger
  files via destructive deploys.
- **Trigger-body swap is ~10× faster than uninstall/reinstall.** A
  few minutes per swap vs 30+ minutes per full uninstall cycle, with
  trivial round-trip-clean verification (`git diff --stat`).
- **Always cross-check log captures against cumulative limits.**
  Stale-log issues from `sf apex get log` can silently produce wrong
  numbers. The sanity check: cumulative end-of-tx limits in the log
  should match the script-reported `TOTAL :: …` line within the
  cleanup-phase delta.
- **Read the framework source before assuming runtime behavior.**
  The TAF v2-cache-per-instance discovery would not have surfaced
  from reading docs alone.
- **Audit handler ports against the framework's registration source
  of truth, not the handler class body.** Sub-agents that port
  handlers from the SALT class body alone will miss CMDT-level
  context registrations and produce silently degraded comparisons.
- **3 runs per framework is the minimum for statistical robustness**
  on a multi-tenant dev org. With 1 run you can't tell whether an
  outlier is a real bug or noisy-neighbor variance. With 3, you can
  distinguish "structurally identical results, CPU spread X %" from
  "inconsistent structural results = something is wrong."
