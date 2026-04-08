# SALT(YASTF)

**S**alesforce **A**pex **L**ayered **T**riggers (**Y**et **A**nother **S**alesforce **T**rigger **F**ramework)

**License:** MIT

A composition-based Salesforce trigger framework with metadata-driven configuration. Zero external dependencies.

## What It Solves

Existing trigger frameworks handle dispatch and ordering well, but each handler independently queries the data it needs. When a trigger has five handlers each needing two related objects, that's 10 SOQL queries per trigger invocation — and in a cascading transaction spanning three objects, 30 queries against a budget of 100.

SALT(YASTF) introduces a **declare-then-aggregate-then-execute** query model: handlers declare what data they need, the framework merges compatible queries, and executes the minimum number of SOQL statements.

## Architecture

The framework is organized as four **concentric layers**. Each team adopts only the layers it needs.

### Layer 0 — Foundation

Extend `TriggerHandler`, override context methods, create a `TriggerHandler__mdt` metadata record. Metadata-driven dispatch, execution ordering via `Order__c`, type-safe bypass API with admin seal (`AllowBypass__c`), `Set<Id>` recursion guard.

### Layer 1 — Enhanced Recursion (`IRecursionAware`)

Field-hash recursion guard that re-processes records only when watched fields change. Invocation counter for insert contexts. Configurable cascade depth limit.

### Layer 2 — Query Optimization (`IQueryAware`)

Declare query needs via `QueryBuilder`, receive aggregated results via `QueryResultCache`. Merge-decline heuristic for disjoint queries. SOQL and Heap circuit breakers with Platform Event alerting.

### Layer 3 — DML Coordination (`IDmlAware`)

Write-only `IDmlRegistrar` for deferred DML. Cross-handler conflict detection (same value = WARN, different value = FAIL). Topological sort for dependency-ordered commits. Savepoint/rollback with error provenance.

### Record Filtering (`IRecordFilter`)

Opt-in at any layer. Built-in predicates: `FieldChanged`, `FieldNotNull`, `RecordTypeIs`, plus `CompositeFilter` combinators (`andFilter`, `orFilter`, `notFilter`).

## Quick Start

1. Create a logicless trigger:

```apex
trigger AccountTrigger on Account(
  before insert,
  before update,
  after insert,
  after update
) {
  TriggerDispatcher.run();
}
```

2. Create a handler:

```apex
public class AccountDefaulter extends TriggerHandler {
  public override void beforeInsert(List<SObject> newRecords) {
    for (Account acc : (List<Account>) newRecords) {
      if (acc.Description == null) {
        acc.Description = 'Default description';
      }
    }
  }
}
```

3. Register via Custom Metadata (`TriggerHandler__mdt`):
   - **SObjectType\_\_c**: `Account`
   - **HandlerClass\_\_c**: `AccountDefaulter`
   - **Order\_\_c**: `10`
   - **BeforeInsert\_\_c**: `true`
   - **IsActive\_\_c**: `true`

## Configuration

All handler configuration is managed through `TriggerHandler__mdt` Custom Metadata Type records:

| Field                                    | Purpose                                                   |
| ---------------------------------------- | --------------------------------------------------------- |
| `SObjectType__c`                         | SObject API name                                          |
| `HandlerClass__c`                        | Fully qualified Apex class name                           |
| `Namespace__c`                           | For managed package handlers                              |
| `Order__c`                               | Execution sequence (10, 20, 30...)                        |
| `IsActive__c`                            | Master on/off                                             |
| `BeforeInsert__c` ... `AfterUndelete__c` | Context enablement (7 checkboxes)                         |
| `BypassPermission__c`                    | Custom Permission API name for bypass                     |
| `BypassUsers__c`                         | Comma-separated User IDs for bypass                       |
| `BypassProfiles__c`                      | Comma-separated Profile IDs for bypass                    |
| `AllowBypass__c`                         | When false, handler cannot be bypassed                    |
| `IsCritical__c`                          | When false, skippable by circuit breaker in after-trigger |
| `MaxReentrancy__c`                       | Max invocations per record for IRecursionAware handlers   |
| `CascadeDepthLimit__c`                   | Max trigger nesting depth                                 |

## Bypass API

```apex
// Type-safe bypass — prevents cross-namespace escalation
TriggerDispatcher.bypass(AccountDefaulter.class);
TriggerDispatcher.bypass(AccountDefaulter.class, Account.SObjectType);
TriggerDispatcher.bypass(AccountDefaulter.class, Account.SObjectType, TriggerContext.BEFORE_INSERT);

// Auto-clearing — one DML event (before + after trigger pair)
TriggerDispatcher.bypassForNextDmlEvent(AccountDefaulter.class);

// Cleanup
TriggerDispatcher.clearBypass(AccountDefaulter.class);
TriggerDispatcher.clearAllBypasses();
```

## Documentation

| Document                                                | Description                                                                                                                                                                                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Architecture](docs/DESIGN.md)                          | High-level design: 5-phase pipeline, layered composition model, interface contracts                                                                                                                                                                              |
| [Low-Level Design](docs/LOW_LEVEL_DESIGN.md)            | Implementation detail: query aggregation algorithm, DML topological sort, recursion guard mechanics, circuit breakers                                                                                                                                            |
| [Call Chain](docs/CALL_CHAIN.md)                        | End-to-end execution trace through the 5-phase pipeline for each trigger context                                                                                                                                                                                 |
| [Benchmark Report](docs/benchmarks/benchmark-report.md) | Comparative governor limit analysis: SALT vs fflib vs Trigger Actions Framework vs O'Hara pattern. Measured SALT data from 23 enterprise-realistic handlers across 3 scenarios (lead conversion, territory transfer, deal progression) at 200-record bulk volume |
| [Handler Registry](docs/benchmarks/handlers.yaml)       | Full registry of 23 test harness handlers with per-object/per-context breakdown, merge keys, DML targets, and business justifications                                                                                                                            |

## Known Limitations & Notes

1. **Platform Event & CDC Triggers**: The dispatcher returns early for Platform Event and Change Data Capture trigger contexts. SALT currently supports standard SObject triggers only.

2. **Before-Trigger DML**: If a handler implements `IDmlAware` and is registered for a before-trigger context, the Phase 4 DML commit is skipped (before-trigger DML is a Salesforce anti-pattern). Any DML registered via `IDmlRegistrar` during a before-trigger execution is silently discarded.

3. **Workflow / Flow Re-entry**: When a Workflow Field Update or Record-Triggered Flow modifies a record after the after-trigger, the trigger re-fires. `IRecursionAware` handlers use field-hash comparison on their declared `getRecursionFields()` fields. If the workflow/flow changes only _unwatched_ fields, the field-hash is identical and the handler is skipped on re-entry. Choose recursion fields carefully to include any fields that workflow/flow automation might modify if re-processing is desired.

4. **Partial Save (`Database.insert(records, false)`)**: When `allOrNone=false`, Salesforce retries successful records in a second trigger invocation. `IRecursionAware` handlers re-process only records whose watched field values have changed (via field-hash comparison), which naturally handles the retry correctly. Handlers using only the legacy `hasBeenProcessed()`/`markProcessed()` API will skip retried records — use `IRecursionAware` for correct partial-save behavior.

5. **Packaging as 2GP (Second-Generation Managed Package)**: If distributing SALT as a managed package, add `@namespaceAccessible` annotations to all public classes and interfaces that subscribers need to extend or implement (`TriggerHandler`, `ITriggerHandler`, `IRecordFilter`, `IRecursionAware`, `IQueryAware`, `IDmlAware`, `IDmlRegistrar`, `QueryBuilder`, `QueryRequest`, `CompositeFilter`, and the built-in filter classes). Without these annotations, subscriber orgs cannot extend `TriggerHandler` or implement framework interfaces from their own namespace.

6. **Bypass Permission Setup**: The `BypassPermission__c` field references a Custom Permission API name. To use permission-based bypass, create a Custom Permission in Setup, assign it to a Permission Set, and grant that Permission Set to the users/profiles that should be able to bypass the handler. The framework checks `FeatureManagement.checkPermission(bypassPermissionName)` at runtime.

## Project Setup

```bash
# Clone the repository
git clone https://github.com/prnth87/salt-yastf.git
cd salt-yastf

# Install dev dependencies (prettier, eslint)
npm install

# Create a scratch org
sf org create scratch -f config/project-scratch-def.json -a salt-yastf-dev

# Deploy to scratch org
sf project deploy start --target-org salt-yastf-dev

# Run tests
sf apex run test --target-org salt-yastf-dev --test-level RunLocalTests
```

## License

[MIT](LICENSE)
