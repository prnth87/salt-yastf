# SALT(YASTF) Implementation Guide

## All 16 Interface Combinations — Deep Reference

---

## Table of Contents

1. [Quick Reference](#1-quick-reference)
2. [Prerequisites](#2-prerequisites)
3. [Combination Matrix](#3-combination-matrix)
4. [Tier 0 — Base Handler](#4-tier-0--base-handler-no-interfaces)
5. [Tier 1 — Single Interface](#5-tier-1--single-interface-4-combinations)
6. [Tier 2 — Two Interfaces](#6-tier-2--two-interfaces-6-combinations)
7. [Tier 3 — Three Interfaces](#7-tier-3--three-interfaces-4-combinations)
8. [Tier 4 — All Interfaces](#8-tier-4--all-interfaces-1-combination)
9. [Advanced Patterns](#9-advanced-patterns)
10. [Constraints and Anti-Patterns](#10-constraints-and-anti-patterns)

---

## 1. Quick Reference

### Pipeline Phases

```
TriggerDispatcher.run()
  │
  ├─ Phase 0: Load CMDT → instantiate handlers → bypass checks → cascade depth
  ├─ Phase 1: IRecordFilter.isApplicable() per record → skip handler if zero match
  ├─ Phase 2: IQueryAware.declareQueryNeeds() → aggregate → circuit break → execute SOQL
  ├─ Phase 3: Execute handlers in Order__c sequence:
  │           ├─ IRecursionAware field-hash guard (skip if already processed)
  │           ├─ IQueryAware? → onDataReady()   ← INSTEAD OF context methods
  │           │  else        → beforeInsert() / afterUpdate() / etc.
  │           └─ IDmlAware?  → onDmlReady()     ← IN ADDITION TO above
  ├─ Phase 4: DML commit (after-trigger only, if any IDmlAware registered work)
  └─ Phase 5: Cleanup (cascade depth decrement, bypass clear, alert publish)
```

### Critical Dispatch Rule

| Interface | Dispatch Behavior |
|-----------|-------------------|
| **IQueryAware** | **EXCLUSIVE** — `onDataReady()` replaces standard context methods. `beforeInsert()`, `afterUpdate()`, etc. are **never called**. |
| **IDmlAware** | **ADDITIVE** — `onDmlReady()` is called **in addition to** whichever method ran above (either `onDataReady` or a context method). |

Source: `TriggerDispatcher.executeHandler()` lines 971-998.

### Interface Signatures

```apex
// IRecordFilter — Phase 1: per-record gating
public interface IRecordFilter {
  Boolean isApplicable(SObject newRecord, SObject oldRecord, TriggerContext ctx);
}

// IRecursionAware — Phase 3: field-hash recursion guard
public interface IRecursionAware {
  List<SObjectField> getRecursionFields();
}

// IQueryAware — Phase 2 + Phase 3: declare needs, receive results
public interface IQueryAware {
  List<QueryRequest> declareQueryNeeds(List<SObject> applicableRecords, Map<Id, SObject> oldMap);
  void onDataReady(List<SObject> applicableRecords, Map<Id, SObject> oldMap, QueryResultCache cache);
}

// IDmlAware — Phase 3 + Phase 4: register deferred DML
public interface IDmlAware {
  void onDmlReady(IDmlRegistrar registrar);
}

// IDmlRegistrar — the API passed to onDmlReady()
public interface IDmlRegistrar {
  void registerNew(SObject record);
  void registerNew(SObject record, SObjectField fkField, SObject relatedTo);
  void registerDirty(SObject record, List<SObjectField> dirtyFields);
  void registerDeleted(SObject record);
  void declareDependency(SObjectType source, SObjectType target);
}
```

---

## 2. Prerequisites

### 2.1 Trigger File

Every SObject needs exactly one logicless trigger:

```apex
trigger AccountTrigger on Account (
  before insert, before update, before delete,
  after insert, after update, after delete, after undelete
) {
  TriggerDispatcher.run();
}
```

All logic lives in handler classes registered via Custom Metadata.

### 2.2 TriggerHandler__mdt Configuration

Each handler requires one `TriggerHandler__mdt` record:

| Field | Type | Purpose |
|-------|------|---------|
| `HandlerClass__c` | Text | Fully qualified Apex class name |
| `Namespace__c` | Text | Managed package namespace (null for unmanaged) |
| `Order__c` | Number | Execution sequence within SObject (10, 20, 30...) |
| `IsActive__c` | Checkbox | Master on/off |
| `IsCritical__c` | Checkbox | When false, handler can be shed by circuit breakers |
| `BeforeInsert__c` | Checkbox | Enable for before insert context |
| `BeforeUpdate__c` | Checkbox | Enable for before update context |
| `BeforeDelete__c` | Checkbox | Enable for before delete context |
| `AfterInsert__c` | Checkbox | Enable for after insert context |
| `AfterUpdate__c` | Checkbox | Enable for after update context |
| `AfterDelete__c` | Checkbox | Enable for after delete context |
| `AfterUndelete__c` | Checkbox | Enable for after undelete context |
| `AllowBypass__c` | Checkbox | When false, handler cannot be bypassed (admin seal) |
| `MaxReentrancy__c` | Number | Max invocations per handler key (null = unlimited) |
| `CascadeDepthLimit__c` | Number | Max trigger nesting depth (null = unlimited) |
| `BypassPermission__c` | Text | Custom Permission API name for bypass |
| `BypassUsers__c` | Text | Comma-separated 18-char User IDs |
| `BypassProfiles__c` | Text | Comma-separated 18-char Profile IDs |

### 2.3 Test Mock Pattern

In tests, bypass CMDT SOQL with `mockHandlers` and `runWithContext()`:

```apex
// Build mock CMDT record via JSON round-trip
private static TriggerHandler__mdt buildConfig(
  String handlerClass, Decimal order, Boolean isCritical,
  Boolean bi, Boolean bu, Boolean ai, Boolean au
) {
  Map<String, Object> fields = new Map<String, Object>{
    'DeveloperName'       => handlerClass.replace('.', '_'),
    'HandlerClass__c'     => handlerClass,
    'Namespace__c'        => null,
    'Order__c'            => order,
    'IsActive__c'         => true,
    'BeforeInsert__c'     => bi,
    'BeforeUpdate__c'     => bu,
    'BeforeDelete__c'     => false,
    'AfterInsert__c'      => ai,
    'AfterUpdate__c'      => au,
    'AfterDelete__c'      => false,
    'AfterUndelete__c'    => false,
    'AllowBypass__c'      => true,
    'MaxReentrancy__c'    => null,
    'CascadeDepthLimit__c'=> null,
    'IsCritical__c'       => isCritical,
    'BypassPermission__c' => null,
    'BypassUsers__c'      => null,
    'BypassProfiles__c'   => null
  };
  return (TriggerHandler__mdt) JSON.deserialize(
    JSON.serialize(fields), TriggerHandler__mdt.class
  );
}

// Wire handlers and execute
TriggerDispatcher.mockHandlers = new Map<String, List<TriggerHandler__mdt>>{
  'Account' => new List<TriggerHandler__mdt>{
    buildConfig('MyTest.MyHandler', 10, false, true, false, true, false)
  }
};
insert new Account(Name = 'Test'); // fires dispatcher with mock config
```

---

## 3. Combination Matrix

4 optional interfaces = 16 possible combinations. Each row shows which pipeline phases the handler participates in.

| # | F | R | Q | D | Class Signature Suffix | Ph1 | Ph2 | Ph3 Dispatch | Ph4 | Test Harness Example | Frequency |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **0** | — | — | — | — | *(none)* | — | — | Context method | — | `AccountDefaultsHandler` | Common |
| **1** | F | — | — | — | `IRecordFilter` | Yes | — | Context method | — | `OpportunityStageHandler` | Common |
| **2** | — | R | — | — | `IRecursionAware` | — | — | Context method | — | *(theoretical)* | Rare |
| **3** | — | — | Q | — | `IQueryAware` | — | Yes | `onDataReady` | — | `ContactDuplicateCheckHandler` | Moderate |
| **4** | — | — | — | D | `IDmlAware` | — | — | Context method + `onDmlReady` | Yes | `FullCascadeDmlHandler` | Moderate |
| **5** | F | R | — | — | `IRecordFilter, IRecursionAware` | Yes | — | Context method | — | *(theoretical)* | Rare |
| **6** | F | — | Q | — | `IRecordFilter, IQueryAware` | Yes | Yes | `onDataReady` | — | `CriticalQueryHandler` | Moderate |
| **7** | F | — | — | D | `IRecordFilter, IDmlAware` | Yes | — | Context method + `onDmlReady` | Yes | `OpportunityNotificationHandler` | Common |
| **8** | — | R | Q | — | `IRecursionAware, IQueryAware` | — | Yes | `onDataReady` | — | *(theoretical)* | Rare |
| **9** | — | R | — | D | `IRecursionAware, IDmlAware` | — | — | Context method + `onDmlReady` | Yes | *(theoretical)* | Rare |
| **10** | — | — | Q | D | `IQueryAware, IDmlAware` | — | Yes | `onDataReady` + `onDmlReady` | Yes | `ContactCountRollupHandler` | **Most common** |
| **11** | F | R | Q | — | `IRecordFilter, IRecursionAware, IQueryAware` | Yes | Yes | `onDataReady` | — | *(theoretical)* | Rare |
| **12** | F | R | — | D | `IRecordFilter, IRecursionAware, IDmlAware` | Yes | — | Context method + `onDmlReady` | Yes | *(theoretical)* | Rare |
| **13** | F | — | Q | D | `IRecordFilter, IQueryAware, IDmlAware` | Yes | Yes | `onDataReady` + `onDmlReady` | Yes | `FullHandler` | Common |
| **14** | — | R | Q | D | `IRecursionAware, IQueryAware, IDmlAware` | — | Yes | `onDataReady` + `onDmlReady` | Yes | `ContactAccountSyncHandler` | Moderate |
| **15** | F | R | Q | D | All four | Yes | Yes | `onDataReady` + `onDmlReady` | Yes | *(theoretical)* | Rare |

**Legend:** F = IRecordFilter, R = IRecursionAware, Q = IQueryAware, D = IDmlAware

**Key dependency insight:** `IQueryAware` and `IDmlAware` are independent layers — either can be used without the other. A handler can query data without writing DML (read-only enrichment/validation), or write DML without querying (using data from `Trigger.new` directly via context methods).

---

## 4. Tier 0 — Base Handler (No Interfaces)

### Combo 0: `TriggerHandler` only

**Phases active:** Phase 3 only (standard context method dispatch)

**When to use:** Simple field defaulting, validation, normalization. No need to query related data or register cross-object DML.

**Class skeleton:**

```apex
public class AccountDefaultsHandler extends TriggerHandler {

  public override void beforeInsert(List<SObject> newRecords) {
    for (SObject rec : newRecords) {
      Account acc = (Account) rec;
      if (acc.Type == null) {
        acc.Type = 'Prospect';
      }
    }
  }
}
```

**CMDT config:**

| Field | Value |
|-------|-------|
| `HandlerClass__c` | `AccountDefaultsHandler` |
| `Order__c` | `10` |
| `BeforeInsert__c` | `true` |
| All other contexts | `false` |

**Context method signatures available to override:**

```apex
public virtual void beforeInsert(List<SObject> newRecords) {}
public virtual void afterInsert(List<SObject> newRecords) {}
public virtual void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {}
public virtual void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {}
public virtual void beforeDelete(Map<Id, SObject> oldMap) {}
public virtual void afterDelete(Map<Id, SObject> oldMap) {}
public virtual void afterUndelete(List<SObject> newRecords) {}
```

Override only the contexts you need. The handler receives **all** records in `Trigger.new` (no filtering).

**Test harness example:** `LeadConversionIntegrationTest.AccountDefaultsHandler` — sets `Type`, `Industry`, `Description` defaults on Account before insert.

**Constraints:** None. This is the simplest form.

---

## 5. Tier 1 — Single Interface (4 Combinations)

### Combo 1: `IRecordFilter`

**Phases active:** Phase 1 (filtering) + Phase 3 (context method)

**When to use:** Handler logic applies only to a subset of records (e.g., specific RecordType, field changed, field non-null). Without this interface the handler processes **all** records in the trigger batch.

**Class skeleton:**

```apex
public class OpportunityStageHandler extends TriggerHandler
  implements IRecordFilter {

  // Phase 1: called once per record
  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    if (ctx == TriggerContext.BEFORE_INSERT) {
      return true; // all new records
    }
    // On update: only if StageName changed
    return new FieldChanged(Opportunity.StageName).isApplicable(newRec, oldRec, ctx);
  }

  // Phase 3: receives ALL records (not just filtered ones)
  // You must re-filter in your context method if needed
  public override void beforeInsert(List<SObject> newRecords) {
    for (SObject rec : newRecords) {
      Opportunity opp = (Opportunity) rec;
      if (opp.CloseDate == null) {
        opp.CloseDate = Date.today().addDays(30);
      }
    }
  }

  public override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
    for (SObject rec : newRecords) {
      Opportunity opp = (Opportunity) rec;
      Opportunity old = (Opportunity) oldMap.get(opp.Id);
      if (opp.StageName != old.StageName && opp.StageName == 'Closed Won') {
        opp.Probability = 100;
      }
    }
  }
}
```

**Important:** When `IRecordFilter` returns `false` for ALL records, the handler is **skipped entirely** — neither context methods nor any other interface methods execute. But when at least one record passes the filter, the context method still receives the **full** `Trigger.new` list (not the filtered subset). The filter gates handler execution, not record delivery.

**Exception:** When `IRecordFilter` is combined with `IQueryAware`, `declareQueryNeeds()` and `onDataReady()` receive only the **filtered subset** (applicable records).

**Built-in IRecordFilter implementations** (composable, usable from `isApplicable()`):

```apex
// Field changed between old and new
new FieldChanged(Account.Rating).isApplicable(newRec, oldRec, ctx)

// Field is not null
new FieldNotNull(Account.Phone).isApplicable(newRec, oldRec, ctx)

// RecordType matches developer name (cached)
new RecordTypeIs(Account.SObjectType, 'Enterprise').isApplicable(newRec, oldRec, ctx)

// Composite logic
CompositeFilter.andFilter(
  new FieldChanged(Account.Rating),
  new FieldNotNull(Account.Phone)
).isApplicable(newRec, oldRec, ctx)

CompositeFilter.orFilter(
  new FieldChanged(Account.Rating),
  new FieldChanged(Account.Industry)
).isApplicable(newRec, oldRec, ctx)

CompositeFilter.notFilter(
  new RecordTypeIs(Account.SObjectType, 'Internal')
).isApplicable(newRec, oldRec, ctx)
```

**Test harness example:** `LeadConversionIntegrationTest.OpportunityStageHandler`

---

### Combo 2: `IRecursionAware`

**Phases active:** Phase 3 (recursion guard before context method)

**When to use:** Handler modifies fields that cause the same trigger to re-fire (e.g., before-update sets a field, which triggers the same handler again). The framework computes a hash of the declared fields and skips the handler if the same record was already processed with the same field values.

**Class skeleton:**

```apex
public class AccountPhoneNormalizer extends TriggerHandler
  implements IRecursionAware {

  // Declare which fields determine "same state"
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.Phone };
  }

  public override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
    for (SObject rec : newRecords) {
      Account acc = (Account) rec;
      if (acc.Phone != null && !acc.Phone.startsWith('+')) {
        acc.Phone = '+1-' + acc.Phone;
        // This mutation re-triggers AccountTrigger, but the recursion guard
        // detects that Phone now has the same normalized value → skips re-entry
      }
    }
  }
}
```

**CMDT config:**

| Field | Value | Notes |
|-------|-------|-------|
| `MaxReentrancy__c` | `2` | Optional. Limits total invocation count per handler key. |
| `CascadeDepthLimit__c` | `3` | Optional. Limits trigger nesting depth. |

**Constraints:**
- **BEFORE_INSERT:** `IRecursionAware` is silently skipped (records have no stable IDs for hashing). Only the invocation counter (`MaxReentrancy__c`) applies.
- **Fields must belong to the trigger SObject** — cross-object or formula fields are rejected.
- **Do NOT mix** with the manual `hasBeenProcessed()`/`markProcessed()` API on the same handler. They use different tracking mechanisms.

**Field-hash mechanics:** The framework concatenates field values as `length1:val1|length2:val2|...` to produce a collision-resistant hash. On re-entry, if the hash matches the previous execution for that record, the handler is skipped.

**Test harness example:** None standalone — this interface appears in combination with `IQueryAware + IDmlAware` in Combo 14 (`ContactAccountSyncHandler`).

---

### Combo 3: `IQueryAware` (Read-Only Query)

**Phases active:** Phase 2 (query declaration + execution) + Phase 3 (`onDataReady` dispatch)

**When to use:** Handler needs related data (parent records, child records, sibling records) but does not need to write DML. Examples: duplicate detection, validation against related data, read-only enrichment logging.

**Class skeleton:**

```apex
public class ContactDuplicateCheckHandler extends TriggerHandler
  implements IQueryAware {

  // Phase 2: declare what data you need
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap
  ) {
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      if (accId != null) {
        accountIds.add(accId);
      }
    }
    if (accountIds.isEmpty()) {
      return new List<QueryRequest>();
    }
    return new List<QueryRequest>{
      new QueryRequest(
        Contact.SObjectType,
        new Set<SObjectField>{ Contact.LastName, Contact.Email, Contact.AccountId },
        accountIds,
        Contact.AccountId,  // relationship FK
        false,              // enforceFLS
        'ContactDuplicateCheckHandler'  // handler name for provenance
      )
    };
  }

  // Phase 3: called INSTEAD of beforeInsert/afterInsert/etc.
  public void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      if (accId != null) {
        accountIds.add(accId);
      }
    }
    // Retrieve queried data from cache
    List<SObject> existingContacts = cache.getRelated(
      Contact.SObjectType,
      Contact.AccountId,
      accountIds
    );
    // Business logic: check for duplicates
    Set<String> existingEmails = new Set<String>();
    for (SObject c : existingContacts) {
      String email = (String) c.get('Email');
      if (email != null) {
        existingEmails.add(email.toLowerCase());
      }
    }
    for (SObject s : applicableRecords) {
      String email = (String) s.get('Email');
      if (email != null && existingEmails.contains(email.toLowerCase())) {
        s.addError('Duplicate contact email detected: ' + email);
      }
    }
  }
}
```

**Critical:** Do NOT override `beforeInsert()`, `afterInsert()`, etc. — they are never called when `IQueryAware` is implemented. All logic goes in `onDataReady()`.

**QueryRequest constructor (direct):**

```apex
new QueryRequest(
  SObjectType targetObject,        // what to query
  Set<SObjectField> fields,        // which fields to select
  Set<Id> recordIds,               // ID scope (mandatory, prevents unbounded SOQL)
  SObjectField relationshipField,  // FK field for related queries (null for direct ID lookup)
  Boolean enforceFLS,              // opt-in FLS enforcement
  String declaringHandler          // handler name for provenance tracking
)
```

**QueryResultCache retrieval:**

```apex
// Direct ID lookup (when relationshipField is null)
List<SObject> results = cache.getById(Account.SObjectType, accountIds);

// Related record lookup (when relationshipField is set)
List<SObject> results = cache.getRelated(Contact.SObjectType, Contact.AccountId, parentIds);
```

**Test harness example:** `LeadConversionIntegrationTest.ContactDuplicateCheckHandler`

**Constraints:**
- `declareQueryNeeds()` receives the **filtered subset** if `IRecordFilter` is also implemented, otherwise all `Trigger.new` records.
- Returning an empty list from `declareQueryNeeds()` means no query is executed, but `onDataReady()` is still called (with an empty/unpopulated cache for this handler).

---

### Combo 4: `IDmlAware` (DML Without Query)

**Phases active:** Phase 3 (context method + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** Handler creates/updates/deletes related records using data available directly from `Trigger.new` — no need to query first. Examples: creating child records on parent insert, cascading deletes, creating Tasks/Events on record changes.

**Class skeleton:**

```apex
public class FullCascadeDmlHandler extends TriggerHandler
  implements IDmlAware {
  private List<SObject> triggeredRecords;

  // Phase 3: standard context method — capture data for DML
  public override void afterInsert(List<SObject> newRecords) {
    triggeredRecords = newRecords;
  }

  // Phase 3 (after context method): register DML operations
  public void onDmlReady(IDmlRegistrar registrar) {
    if (triggeredRecords == null) { return; }

    for (SObject acc : triggeredRecords) {
      // Create Contact linked to Account via FK binding
      Contact con = new Contact(LastName = 'Auto-' + acc.Id);
      registrar.registerNew(con, Contact.AccountId, acc);

      // Create Opportunity linked to Account
      Opportunity opp = new Opportunity(
        Name = 'Auto-Opp-' + acc.Id,
        StageName = 'Prospecting',
        CloseDate = Date.today().addDays(30)
      );
      registrar.registerNew(opp, Opportunity.AccountId, acc);

      // Create OCR with declared dependencies for topological ordering
      OpportunityContactRole ocr = new OpportunityContactRole(Role = 'Decision Maker');
      registrar.registerNew(ocr, OpportunityContactRole.OpportunityId, opp);
      registrar.declareDependency(OpportunityContactRole.SObjectType, Opportunity.SObjectType);
      registrar.declareDependency(OpportunityContactRole.SObjectType, Contact.SObjectType);
    }
  }
}
```

**IDmlRegistrar API:**

| Method | Before-Trigger | After-Trigger | Notes |
|--------|---------------|---------------|-------|
| `registerNew(record)` | **Throws** | Buffers for Phase 4 | Cannot create records in before-trigger |
| `registerNew(record, fkField, relatedTo)` | **Throws** | Buffers + FK binding | Parent must be inserted first; framework resolves FK |
| `registerDirty(record, dirtyFields)` | Mutates `Trigger.new` directly | Buffers for Phase 4 | Before-trigger applies changes inline with conflict detection |
| `registerDeleted(record)` | **Throws** | Buffers for Phase 4 | Cannot delete in before-trigger |
| `declareDependency(source, target)` | N/A | Adds edge to DML dependency graph | Ensures topological ordering of inserts |

**FK binding pattern:** When inserting a child that references a parent being inserted in the same transaction, the parent has no ID yet. Use `registerNew(child, fkField, parentRecord)` — the framework inserts the parent first, then copies `parentRecord.Id` into `child.fkField` before inserting the child.

**Test harness example:** `LeadConversionIntegrationTest.FullCascadeDmlHandler`

**Constraints:**
- `onDmlReady()` is called **after** the context method. Store data in instance variables during the context method, then use it in `onDmlReady()`.
- DML operations are **not executed immediately** — they are buffered and committed atomically in Phase 4 (after all handlers have run).
- Phase 4 only runs in **after-trigger** contexts. In before-trigger, only `registerDirty()` works (applied inline to `Trigger.new`).

---

## 6. Tier 2 — Two Interfaces (6 Combinations)

### Combo 5: `IRecordFilter + IRecursionAware`

**Phases active:** Phase 1 (filtering) + Phase 3 (recursion guard + context method)

**When to use:** Handler normalizes or derives field values in before-update, but only for records matching a condition (e.g., specific RecordType), and the normalization could re-trigger the same handler.

**Class skeleton:**

```apex
public class EnterpriseAccountNormalizer extends TriggerHandler
  implements IRecordFilter, IRecursionAware {

  // Phase 1: only Enterprise accounts
  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    return new RecordTypeIs(Account.SObjectType, 'Enterprise')
      .isApplicable(newRec, oldRec, ctx);
  }

  // Recursion guard on the fields we mutate
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.Phone, Account.Website };
  }

  public override void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
    for (SObject rec : newRecords) {
      Account acc = (Account) rec;
      if (acc.Phone != null && !acc.Phone.startsWith('+')) {
        acc.Phone = '+1-' + acc.Phone;
      }
      if (acc.Website != null && !acc.Website.startsWith('https://')) {
        acc.Website = 'https://' + acc.Website;
      }
    }
  }
}
```

**CMDT config:**

| Field | Value |
|-------|-------|
| `BeforeUpdate__c` | `true` |
| `MaxReentrancy__c` | `2` |

**Interaction:** The filter runs first (Phase 1). If zero records match, the handler is skipped entirely — the recursion guard never runs. If records match, the recursion guard runs in Phase 3 before the context method.

**Test harness example:** None (theoretical). Derived from Combo 1 + Combo 2 patterns.

---

### Combo 6: `IRecordFilter + IQueryAware`

**Phases active:** Phase 1 (filtering) + Phase 2 (query on filtered records) + Phase 3 (`onDataReady`)

**When to use:** Read-only query handler that should only fire for a subset of records. The filter narrows which records are passed to `declareQueryNeeds()` and `onDataReady()`, reducing unnecessary SOQL scope.

**Class skeleton:**

```apex
public class CriticalQueryHandler extends TriggerHandler
  implements IQueryAware, IRecordFilter {

  // Phase 1: filter
  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    return true; // or any filtering logic
  }

  // Phase 2: declare queries scoped to filtered records
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,  // ← FILTERED subset
    Map<Id, SObject> oldMap
  ) {
    Set<Id> ids = new Set<Id>();
    for (SObject s : applicableRecords) {
      ids.add(s.Id);
    }
    return new List<QueryRequest>{
      new QueryRequest(
        Contact.SObjectType,
        new Set<SObjectField>{ Contact.LastName },
        ids,
        Contact.AccountId,
        false,
        'CriticalQueryHandler'
      )
    };
  }

  // Phase 3: process filtered records with queried data
  public void onDataReady(
    List<SObject> applicableRecords,  // ← same FILTERED subset
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    // Read-only logic using cache
  }
}
```

**Key interaction:** When `IRecordFilter` and `IQueryAware` are combined, `declareQueryNeeds()` and `onDataReady()` both receive **only the filtered records** — not the full `Trigger.new`. This is the primary advantage of combining these two interfaces: query scope is automatically narrowed.

**Test harness example:** `CircuitBreakerIntegrationTest.CriticalQueryHandler` and `NonCriticalQueryHandler`

---

### Combo 7: `IRecordFilter + IDmlAware`

**Phases active:** Phase 1 (filtering) + Phase 3 (context method + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** Handler creates related records only for records matching a condition. Example: create notification Tasks only for high-value Opportunities.

**Class skeleton:**

```apex
public class OpportunityNotificationHandler extends TriggerHandler
  implements IRecordFilter, IDmlAware {
  private List<SObject> applicableOpps = new List<SObject>();

  // Phase 1: only high-value Opportunities
  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    if (newRec == null) { return false; }
    Decimal amount = (Decimal) newRec.get('Amount');
    return amount != null && amount >= 100000;
  }

  // Phase 3: context method — re-filter since context methods get ALL records
  public override void afterInsert(List<SObject> newRecords) {
    for (SObject opp : newRecords) {
      Decimal amount = (Decimal) opp.get('Amount');
      if (amount != null && amount >= 100000) {
        applicableOpps.add(opp);
      }
    }
  }

  // Phase 3 (after context method): register DML for filtered records
  public void onDmlReady(IDmlRegistrar registrar) {
    for (SObject opp : applicableOpps) {
      Task t = new Task(
        Subject = 'Review high-value opportunity: ' + (String) opp.get('Name'),
        WhatId = (Id) opp.get('AccountId'),
        Status = 'Not Started',
        Priority = 'High'
      );
      registrar.registerNew(t);
    }
  }
}
```

**Important nuance:** Context methods (`afterInsert`, etc.) receive **all** `Trigger.new` records, not the filtered subset. The filter determines whether the handler executes *at all* — it does not narrow the record list passed to context methods. You must re-filter inside the context method.

This differs from `IQueryAware`, where `onDataReady()` receives the filtered subset automatically.

**Test harness example:** `LeadConversionIntegrationTest.OpportunityNotificationHandler`

---

### Combo 8: `IRecursionAware + IQueryAware`

**Phases active:** Phase 2 (query) + Phase 3 (recursion guard + `onDataReady`)

**When to use:** Handler queries related data for validation/enrichment and may be re-triggered by cascading updates. The recursion guard prevents re-querying and re-processing records whose watched fields haven't changed.

**Class skeleton:**

```apex
public class AccountComplianceChecker extends TriggerHandler
  implements IRecursionAware, IQueryAware {

  // Recursion guard: skip if these fields haven't changed since last execution
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.Industry, Account.BillingCountry };
  }

  // Phase 2: query compliance rules (read-only)
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap
  ) {
    Set<Id> ids = new Set<Id>();
    for (SObject s : applicableRecords) {
      ids.add(s.Id);
    }
    return new List<QueryRequest>{
      new QueryBuilder('AccountComplianceChecker')
        .onObject(Contact.SObjectType)
        .fields(new List<SObjectField>{ Contact.LastName, Contact.AccountId })
        .forIds(ids)
        .relatedThrough(Contact.AccountId)
        .build()
    };
  }

  // Phase 3: validate compliance (read-only, no DML)
  public void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    // Validation logic using queried data
  }
}
```

**Interaction:** The recursion guard runs **before** `onDataReady()`. If a record was already processed with the same field hash, `onDataReady()` is not called for that record.

**Constraint:** `IRecursionAware` is skipped for `BEFORE_INSERT` context (no stable IDs).

**Test harness example:** None (theoretical). Derived from Combo 3 + Combo 2 patterns.

---

### Combo 9: `IRecursionAware + IDmlAware`

**Phases active:** Phase 3 (recursion guard + context method + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** Handler writes DML that cascades back to the same trigger, using data from `Trigger.new` directly (no related query needed). The recursion guard prevents infinite cascading.

**Class skeleton:**

```apex
public class ContactOwnerSyncHandler extends TriggerHandler
  implements IRecursionAware, IDmlAware {
  private Map<Id, Id> ownerUpdates = new Map<Id, Id>();

  // Recursion guard: skip if OwnerId hasn't changed
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Contact.OwnerId };
  }

  // Phase 3: standard context method
  public override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
    for (SObject rec : newRecords) {
      Contact con = (Contact) rec;
      Contact old = (Contact) oldMap.get(con.Id);
      if (con.OwnerId != old.OwnerId) {
        // Need to sync owner to related records
        ownerUpdates.put(con.Id, con.OwnerId);
      }
    }
  }

  // Phase 3 (after context method): register DML
  public void onDmlReady(IDmlRegistrar registrar) {
    for (Id conId : ownerUpdates.keySet()) {
      // Update related Case records (simplified)
      // In practice you'd need to query Cases first → use Combo 14 instead
    }
  }
}
```

**When to prefer Combo 14 instead:** If you need to query related data before writing DML, use `IRecursionAware + IQueryAware + IDmlAware` (Combo 14). Combo 9 is only appropriate when all data needed for DML is available directly from `Trigger.new`.

**Test harness example:** None (theoretical). Derived from Combo 2 + Combo 4 patterns.

---

### Combo 10: `IQueryAware + IDmlAware`

**Phases active:** Phase 2 (query) + Phase 3 (`onDataReady` + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** The **most common combination**. Handler queries related data, then writes DML based on both the trigger records and the queried data. Examples: rollup calculations, cross-object field sync, creating junction records.

**Class skeleton:**

```apex
public class ContactCountRollupHandler extends TriggerHandler
  implements IQueryAware, IDmlAware {
  private Map<Id, Integer> accountContactCounts = new Map<Id, Integer>();

  // Phase 2: declare query needs
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap
  ) {
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      if (accId != null) {
        accountIds.add(accId);
      }
    }
    if (accountIds.isEmpty()) {
      return new List<QueryRequest>();
    }
    return new List<QueryRequest>{
      new QueryRequest(
        Contact.SObjectType,
        new Set<SObjectField>{ Contact.LastName, Contact.AccountId },
        accountIds,
        Contact.AccountId,
        false,
        'ContactCountRollupHandler'
      )
    };
  }

  // Phase 3: process query results — store intermediate state
  public void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      if (accId != null) {
        accountIds.add(accId);
      }
    }
    List<SObject> contacts = cache.getRelated(
      Contact.SObjectType, Contact.AccountId, accountIds
    );
    for (SObject c : contacts) {
      Id accId = (Id) c.get('AccountId');
      Integer cnt = accountContactCounts.containsKey(accId)
        ? accountContactCounts.get(accId) : 0;
      accountContactCounts.put(accId, cnt + 1);
    }
  }

  // Phase 3 (after onDataReady): register DML based on query results
  public void onDmlReady(IDmlRegistrar registrar) {
    for (Id accId : accountContactCounts.keySet()) {
      registrar.registerDirty(
        new Account(Id = accId, NumberOfEmployees = accountContactCounts.get(accId)),
        new List<SObjectField>{ Account.NumberOfEmployees }
      );
    }
  }
}
```

**Execution order within Phase 3:** `onDataReady()` is called first (with cache), then `onDmlReady()` is called. Use instance variables to pass data between them.

**Query aggregation benefit:** When multiple handlers on the same SObject declare queries with the same merge key (`SObjectType|relationshipField`), the framework merges them into fewer SOQL statements. For example, `ContactCountRollupHandler` and `ContactDuplicateCheckHandler` both query `Contact` via `Contact.AccountId` — merged into a single SOQL.

**Test harness examples:**
- `LeadConversionIntegrationTest.ContactCountRollupHandler` — rollup pattern
- `LeadConversionIntegrationTest.AccountContactPushbackHandler` — cross-object field sync
- `LeadConversionIntegrationTest.OpportunityContactRoleHandler` — junction record creation

---

## 7. Tier 3 — Three Interfaces (4 Combinations)

### Combo 11: `IRecordFilter + IRecursionAware + IQueryAware`

**Phases active:** Phase 1 (filter) + Phase 2 (query on filtered records) + Phase 3 (recursion guard + `onDataReady`)

**When to use:** Read-only query handler that applies to a subset of records and may be re-triggered. Rare — most handlers that query also write DML (Combo 13 or 15).

**Class skeleton:**

```apex
public class EnterpriseComplianceValidator extends TriggerHandler
  implements IRecordFilter, IRecursionAware, IQueryAware {

  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    return new RecordTypeIs(Account.SObjectType, 'Enterprise')
      .isApplicable(newRec, oldRec, ctx);
  }

  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.Industry, Account.AnnualRevenue };
  }

  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,  // ← filtered Enterprise accounts only
    Map<Id, SObject> oldMap
  ) {
    Set<Id> ids = new Set<Id>();
    for (SObject s : applicableRecords) { ids.add(s.Id); }
    if (ids.isEmpty()) { return new List<QueryRequest>(); }
    return new List<QueryRequest>{
      new QueryBuilder('EnterpriseComplianceValidator')
        .onObject(Contact.SObjectType)
        .fields(new List<SObjectField>{ Contact.LastName, Contact.AccountId })
        .forIds(ids)
        .relatedThrough(Contact.AccountId)
        .build()
    };
  }

  public void onDataReady(
    List<SObject> applicableRecords,  // ← filtered subset
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    // Read-only validation logic
  }
}
```

**Phase interaction order:** Filter (Phase 1) → Query on filtered records (Phase 2) → Recursion guard (Phase 3) → `onDataReady` (Phase 3)

**Test harness example:** None (theoretical).

---

### Combo 12: `IRecordFilter + IRecursionAware + IDmlAware`

**Phases active:** Phase 1 (filter) + Phase 3 (recursion guard + context method + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** Handler writes DML for filtered records using data from `Trigger.new`, with recursion protection. No related query needed.

**Class skeleton:**

```apex
public class HighValueAccountAuditHandler extends TriggerHandler
  implements IRecordFilter, IRecursionAware, IDmlAware {
  private List<SObject> applicableAccounts = new List<SObject>();

  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    Decimal revenue = (Decimal) newRec.get('AnnualRevenue');
    return revenue != null && revenue >= 1000000;
  }

  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.AnnualRevenue, Account.Rating };
  }

  public override void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap) {
    // Re-filter (context methods get all records)
    for (SObject rec : newRecords) {
      Decimal revenue = (Decimal) rec.get('AnnualRevenue');
      if (revenue != null && revenue >= 1000000) {
        applicableAccounts.add(rec);
      }
    }
  }

  public void onDmlReady(IDmlRegistrar registrar) {
    for (SObject acc : applicableAccounts) {
      registrar.registerNew(new Task(
        Subject = 'Audit: high-value account updated',
        WhatId = acc.Id,
        Status = 'Not Started'
      ));
    }
  }
}
```

**Test harness example:** None (theoretical).

---

### Combo 13: `IRecordFilter + IQueryAware + IDmlAware`

**Phases active:** Phase 1 (filter) + Phase 2 (query on filtered records) + Phase 3 (`onDataReady` + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** The **most common enterprise pattern**. Handler processes a filtered subset of records, queries related data, and writes DML. Combines all three active layers (filtering, querying, writing) without recursion guard.

**Class skeleton:**

```apex
public class FullHandler extends TriggerHandler
  implements IRecordFilter, IQueryAware, IDmlAware {

  private List<SObject> lastApplicable;

  // Phase 1: filter by name prefix
  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    return newRec != null && ((String) newRec.get('Name')).startsWith('SALT');
  }

  // Phase 2: query Contacts for filtered Accounts
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,  // ← filtered subset
    Map<Id, SObject> oldMap
  ) {
    Set<Id> ids = new Set<Id>();
    for (SObject s : applicableRecords) { ids.add(s.Id); }
    return new List<QueryRequest>{
      new QueryRequest(
        Contact.SObjectType,
        new Set<SObjectField>{ Contact.LastName, Contact.AccountId },
        ids,
        Contact.AccountId,
        false,
        'FullHandler'
      )
    };
  }

  // Phase 3: process filtered records with queried data
  public void onDataReady(
    List<SObject> applicableRecords,  // ← filtered subset
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    lastApplicable = applicableRecords;
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) { accountIds.add(s.Id); }
    List<SObject> contacts = cache.getRelated(
      Contact.SObjectType, Contact.AccountId, accountIds
    );
    // Process query results
  }

  // Phase 3 (after onDataReady): register DML
  public void onDmlReady(IDmlRegistrar registrar) {
    for (SObject acc : lastApplicable) {
      registrar.registerNew(
        new Contact(LastName = 'Auto-' + (String) acc.get('Name'))
      );
    }
  }
}
```

**Key advantage over Combo 7 (IRecordFilter + IDmlAware):** The filter narrows query scope — `declareQueryNeeds()` receives only filtered records, so SOQL is scoped to relevant IDs only.

**Key advantage over Combo 10 (IQueryAware + IDmlAware):** The filter prevents unnecessary query declaration and execution for records that don't need processing.

**Test harness example:** `TriggerDispatcherIntegrationTest.FullHandler`

---

### Combo 14: `IRecursionAware + IQueryAware + IDmlAware`

**Phases active:** Phase 2 (query) + Phase 3 (recursion guard + `onDataReady` + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** Handler queries data and writes DML that cascades back to the same trigger. The recursion guard is essential to prevent infinite loops. Classic use case: bidirectional field sync between parent and child.

**Class skeleton:**

```apex
public class ContactAccountSyncHandler extends TriggerHandler
  implements IQueryAware, IDmlAware, IRecursionAware {
  private Map<Id, String> accountPhoneMap = new Map<Id, String>();

  // Recursion guard: stop re-entry if Phone or AccountId haven't changed
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Contact.Phone, Contact.AccountId };
  }

  // Phase 2: query Account records for each Contact's AccountId
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap
  ) {
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      if (accId != null) { accountIds.add(accId); }
    }
    if (accountIds.isEmpty()) { return new List<QueryRequest>(); }
    return new List<QueryRequest>{
      new QueryRequest(
        Account.SObjectType,
        new Set<SObjectField>{ Account.Phone, Account.Description },
        accountIds,
        null,   // direct ID lookup (no FK relationship)
        false,
        'ContactAccountSyncHandler'
      )
    };
  }

  // Phase 3: extract phone numbers to sync
  public void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      String phone = (String) s.get('Phone');
      if (accId != null && phone != null) {
        accountPhoneMap.put(accId, phone);
      }
    }
  }

  // Phase 3 (after onDataReady): sync Contact.Phone → Account.Phone
  public void onDmlReady(IDmlRegistrar registrar) {
    for (Id accId : accountPhoneMap.keySet()) {
      registrar.registerDirty(
        new Account(Id = accId, Phone = accountPhoneMap.get(accId)),
        new List<SObjectField>{ Account.Phone }
      );
    }
  }
}
```

**Cascade scenario (from test harness):**

```
1. Contact inserted with Phone='5551234'
2. ContactAccountSyncHandler fires:
   - Queries Account
   - Registers Account.Phone = '+1-5551234' (after ContactDefaultsHandler normalizes)
3. Account update triggers AccountTrigger
4. ContactAccountSyncHandler runs again for the Contact BUT:
   - Field hash for (Phone, AccountId) matches previous execution
   - IRecursionAware guard SKIPS → prevents infinite loop
5. Other Account handlers (AccountContactPushbackHandler) still fire normally
```

**Test harness example:** `LeadConversionIntegrationTest.ContactAccountSyncHandler`

---

## 8. Tier 4 — All Interfaces (1 Combination)

### Combo 15: `IRecordFilter + IRecursionAware + IQueryAware + IDmlAware`

**Phases active:** All phases — Phase 1 (filter) + Phase 2 (query on filtered records) + Phase 3 (recursion guard + `onDataReady` + `onDmlReady`) + Phase 4 (DML commit)

**When to use:** Maximum composition — handler filters records, queries related data, writes DML that could cascade back, and guards against recursion. Use this when all four concerns are genuinely present. Don't add interfaces preemptively.

**Class skeleton:**

```apex
public class EnterpriseContactSyncHandler extends TriggerHandler
  implements IRecordFilter, IRecursionAware, IQueryAware, IDmlAware {
  private Map<Id, String> accountPhoneMap = new Map<Id, String>();

  // Phase 1: only Enterprise record type
  public Boolean isApplicable(SObject newRec, SObject oldRec, TriggerContext ctx) {
    return CompositeFilter.andFilter(
      new RecordTypeIs(Contact.SObjectType, 'Enterprise'),
      new FieldChanged(Contact.Phone)
    ).isApplicable(newRec, oldRec, ctx);
  }

  // Recursion guard
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Contact.Phone, Contact.AccountId };
  }

  // Phase 2: scoped to filtered Enterprise contacts only
  public List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,  // ← filtered subset
    Map<Id, SObject> oldMap
  ) {
    Set<Id> accountIds = new Set<Id>();
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      if (accId != null) { accountIds.add(accId); }
    }
    if (accountIds.isEmpty()) { return new List<QueryRequest>(); }
    return new List<QueryRequest>{
      new QueryBuilder('EnterpriseContactSyncHandler')
        .onObject(Account.SObjectType)
        .fields(new List<SObjectField>{ Account.Phone })
        .forIds(accountIds)
        .build()
    };
  }

  // Phase 3: process
  public void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  ) {
    for (SObject s : applicableRecords) {
      Id accId = (Id) s.get('AccountId');
      String phone = (String) s.get('Phone');
      if (accId != null && phone != null) {
        accountPhoneMap.put(accId, phone);
      }
    }
  }

  // Phase 3: register DML
  public void onDmlReady(IDmlRegistrar registrar) {
    for (Id accId : accountPhoneMap.keySet()) {
      registrar.registerDirty(
        new Account(Id = accId, Phone = accountPhoneMap.get(accId)),
        new List<SObjectField>{ Account.Phone }
      );
    }
  }
}
```

**Full phase execution order for this handler:**

```
Phase 1: isApplicable() called per record
  → 0 records match? Handler SKIPPED entirely (no Phase 2/3/4)
  → N records match? Continue with filtered subset

Phase 2: declareQueryNeeds(filteredRecords, oldMap)
  → Framework aggregates, executes SOQL, populates cache

Phase 3:
  Step 1: IRecursionAware field-hash check
    → Record already processed with same hash? Skip that record
  Step 2: onDataReady(filteredRecords, oldMap, cache)
    → Business logic with query results
  Step 3: onDmlReady(registrar)
    → Register DML operations

Phase 4: DML commit (after-trigger only)
  → Framework topologically sorts and executes registered DML
```

**Test harness example:** None (theoretical). Composed from Combo 13 (`FullHandler`) + Combo 14 (`ContactAccountSyncHandler`).

---

## 9. Advanced Patterns

### 9.1 QueryBuilder Fluent API

The `QueryBuilder` provides a fluent alternative to the `QueryRequest` constructor:

```apex
new QueryBuilder('MyHandler')          // handler name (required, for provenance)
  .onObject(Account.SObjectType)       // target SObject (required)
  .fields(new List<SObjectField>{      // fields to select (required, at least one)
    Account.Name,
    Account.Industry
  })
  .forIds(accountIds)                  // ID scope (required — unbounded SOQL throws)
  .relatedThrough(Contact.AccountId)   // FK for related queries (optional)
  .withFLS()                           // enforce FLS (optional, default false)
  .whereFilter(predicate)              // Predicate filter (optional)
  .tag('rollup')                       // per-handler tag (optional, for cache eviction)
  .withChildSubquery(                  // child subquery (optional, mutually exclusive with whereFilter)
    'Contacts',
    new List<SObjectField>{ Contact.LastName },
    null,    // child filter predicate (optional)
    100      // child LIMIT (optional)
  )
  .build()                             // returns QueryRequest
```

**Validation at build time:**
- `forIds()` is mandatory — throws if missing (unbounded SOQL in trigger context is always wrong)
- `onObject()` is mandatory
- `fields()` must include at least one field
- `withChildSubquery()` and `whereFilter()` are mutually exclusive on the same builder

### 9.2 Predicate Trees (for `whereFilter()`)

Predicates add WHERE clauses to queries and enable in-memory re-filtering for OR-merged results.

**Leaf predicates — `FieldFilter`:**

```apex
// 8 operators
FieldFilter.equals(Account.Industry, 'Technology')
FieldFilter.notEquals(Account.Industry, 'Government')
FieldFilter.inOp(Account.Rating, new Set<String>{ 'Hot', 'Warm' })
FieldFilter.notIn(Account.Type, new Set<String>{ 'Prospect' })
FieldFilter.lt(Account.AnnualRevenue, 1000000)
FieldFilter.le(Account.NumberOfEmployees, 500)
FieldFilter.gt(Account.AnnualRevenue, 0)
FieldFilter.ge(Account.NumberOfEmployees, 10)
```

**Composite predicates — `CompositePredicate`:**

```apex
CompositePredicate.andOf(new List<Predicate>{
  FieldFilter.equals(Account.Industry, 'Technology'),
  FieldFilter.gt(Account.AnnualRevenue, 1000000)
})

CompositePredicate.orOf(new List<Predicate>{
  FieldFilter.equals(Account.Rating, 'Hot'),
  FieldFilter.gt(Account.AnnualRevenue, 5000000)
})

CompositePredicate.notOf(
  FieldFilter.equals(Account.Type, 'Prospect')
)
```

**Usage in QueryBuilder:**

```apex
new QueryBuilder('MyHandler')
  .onObject(Account.SObjectType)
  .fields(new List<SObjectField>{ Account.Name })
  .forIds(ids)
  .whereFilter(CompositePredicate.andOf(new List<Predicate>{
    FieldFilter.equals(Account.Industry, 'Technology'),
    FieldFilter.gt(Account.AnnualRevenue, 1000000)
  }))
  .build()
```

**FieldFilter factory rejections** (throws at construction time):

| Rejected Type/Combination | Reason |
|--------------------------|--------|
| Currency field on multi-currency org | No in-memory currency conversion |
| `EncryptedString` field | Cannot match in-memory |
| Location/Geolocation field | Matcher mismatch |
| Cross-object formula field | Cannot resolve in-memory |
| Picklist with `LT`/`LE`/`GT`/`GE` | Locale-dependent ordering |
| String with `LT`/`LE`/`GT`/`GE` | Locale collation hazard |
| Date/Datetime cross-type on inequality | Type mismatch |
| Field name starting with `__salt_` | Reserved prefix |

**Predicate tree depth cap:** 16 levels maximum (adversarial defense).

### 9.3 Built-in IRecordFilter Implementations

These are standalone classes you can use directly in `isApplicable()` or compose with `CompositeFilter`:

```apex
// FieldChanged — true if field value differs between old and new
new FieldChanged(Account.Rating).isApplicable(newRec, oldRec, ctx)
// On DELETE: true if oldRecord field is non-null
// On INSERT: always true

// FieldNotNull — true if field is not null on newRecord (or oldRecord on DELETE)
new FieldNotNull(Account.Phone).isApplicable(newRec, oldRec, ctx)

// RecordTypeIs — matches RecordTypeId by developer name (static cache)
new RecordTypeIs(Account.SObjectType, 'Enterprise').isApplicable(newRec, oldRec, ctx)

// CompositeFilter — logical combinators
CompositeFilter.andFilter(filterA, filterB)
CompositeFilter.orFilter(filterA, filterB)
CompositeFilter.notFilter(filterA)
```

### 9.4 QueryResultCache Retrieval

```apex
// Direct ID lookup (relationshipField = null in QueryRequest)
List<SObject> accounts = cache.getById(Account.SObjectType, accountIdSet);

// Related record lookup (relationshipField set in QueryRequest)
List<SObject> contacts = cache.getRelated(Contact.SObjectType, Contact.AccountId, parentIdSet);

// Per-handler scoped retrieval (for OR-merged results with tag dimension)
List<SObject> results = cache.getForHandler(
  'MyHandler',
  Account.SObjectType,
  null,    // relationshipField (null for direct)
  'myTag'  // tag (null if no tag)
);
```

**Cache behavior:**
- Returns **deep clones** (`clone(true, true, true, false)`) — mutations don't affect cached data
- **Explicit-failure semantics:** throws if cache slot was evicted or handler declaration is unknown
- Returns empty list (not throw) for known declarations with no matching data
- Cache slots evicted after **all** declared consumers have been served

### 9.5 Before-Trigger vs After-Trigger DML Behavior

| Operation | Before-Trigger | After-Trigger |
|-----------|---------------|---------------|
| `registerNew()` | **Throws** (cannot create records in before-trigger) | Buffers → Phase 4 commit |
| `registerNew(rec, fk, parent)` | **Throws** | Buffers + FK binding → Phase 4 |
| `registerDirty(rec, fields)` | **Applies directly to Trigger.new** with conflict detection | Buffers → Phase 4 commit |
| `registerDeleted()` | **Throws** (cannot delete in before-trigger) | Buffers → Phase 4 commit |
| `declareDependency()` | N/A | Adds edge to DML dependency graph |
| Phase 4 DML commit | **Never runs** | Runs if any handler registered DML |

**Before-trigger `registerDirty()` behavior:**
- Directly sets field values on `Trigger.newMap` records
- Cross-handler conflict detection:
  - Same record + same field + **same value** → WARN log (idempotent, allowed)
  - Same record + same field + **different value** → **throws `FieldConflictException`** with handler provenance

### 9.6 DML Topological Ordering

When multiple SObject types are inserted, the framework determines insert order automatically:

1. **Schema-based edges:** Extracted from `SObjectField.getDescribe()` FK relationships
2. **Developer-declared edges:** Via `registrar.declareDependency(source, target)` — target is inserted before source
3. **Topological sort:** Ensures parents are inserted before children
4. **Cycle detection:** Throws `CyclicDependencyException` if circular dependencies exist
5. **Mixed DML guard:** Detects Setup vs non-Setup object mixing (throws before sort)

### 9.7 Field Conflict Detection

When multiple handlers call `registerDirty()` on the same record:

```
Handler A: registrar.registerDirty(new Account(Id=accId, Phone='111'), [Account.Phone])
Handler B: registrar.registerDirty(new Account(Id=accId, Phone='222'), [Account.Phone])
→ Throws FieldConflictException: "Field Phone on record <accId> set to '111' by HandlerA
   conflicts with value '222' from HandlerB"

Handler A: registrar.registerDirty(new Account(Id=accId, Phone='111'), [Account.Phone])
Handler B: registrar.registerDirty(new Account(Id=accId, Phone='111'), [Account.Phone])
→ WARN log only (same value = idempotent, allowed)

Handler A: registrar.registerDirty(new Account(Id=accId, Phone='111'), [Account.Phone])
Handler B: registrar.registerDirty(new Account(Id=accId, Website='x.com'), [Account.Website])
→ No conflict (different fields)
```

---

## 10. Constraints and Anti-Patterns

### 10.1 IQueryAware Replaces Context Methods

**The most critical rule:** When a handler implements `IQueryAware`, the framework calls `onDataReady()` **instead of** `beforeInsert()`, `afterUpdate()`, etc. Overriding context methods on an `IQueryAware` handler is dead code.

```apex
// WRONG — beforeInsert() is NEVER called
public class BadHandler extends TriggerHandler implements IQueryAware {
  public List<QueryRequest> declareQueryNeeds(...) { ... }
  public void onDataReady(...) { /* this runs */ }
  public override void beforeInsert(List<SObject> recs) { /* DEAD CODE */ }
}

// CORRECT — all logic in onDataReady()
public class GoodHandler extends TriggerHandler implements IQueryAware {
  public List<QueryRequest> declareQueryNeeds(...) { ... }
  public void onDataReady(...) { /* all logic here */ }
}
```

### 10.2 Do Not Mix Manual and Automatic Recursion APIs

```apex
// WRONG — uses both IRecursionAware AND manual hasBeenProcessed
public class ConflictingHandler extends TriggerHandler implements IRecursionAware {
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.Phone };
  }
  public override void afterUpdate(List<SObject> recs, Map<Id, SObject> oldMap) {
    for (SObject rec : recs) {
      if (!hasBeenProcessed(rec.Id)) {  // ← WRONG: different tracking mechanism
        markProcessed(rec.Id);
        // ...
      }
    }
  }
}

// CORRECT — use IRecursionAware exclusively, let the framework handle it
public class CorrectHandler extends TriggerHandler implements IRecursionAware {
  public List<SObjectField> getRecursionFields() {
    return new List<SObjectField>{ Account.Phone };
  }
  public override void afterUpdate(List<SObject> recs, Map<Id, SObject> oldMap) {
    // Framework already skipped records with unchanged Phone hash
    for (SObject rec : recs) {
      // Process directly — no manual guard needed
    }
  }
}
```

### 10.3 registerNew() Throws in Before-Trigger

```apex
// WRONG — registerNew in before-trigger throws
public class BadDmlHandler extends TriggerHandler implements IDmlAware {
  public override void beforeInsert(List<SObject> recs) {
    // ...
  }
  public void onDmlReady(IDmlRegistrar registrar) {
    registrar.registerNew(new Contact(LastName = 'X'));  // THROWS in before-trigger
  }
}

// CORRECT — use registerNew only in after-trigger handlers
// CMDT: AfterInsert__c = true, BeforeInsert__c = false
```

### 10.4 IRecursionAware Silently Skipped on BEFORE_INSERT

`IRecursionAware` has no effect in `BEFORE_INSERT` context because records have no stable IDs for field-hash tracking. Only the invocation counter (`MaxReentrancy__c`) applies. This is by design, not a bug.

### 10.5 withChildSubquery() and whereFilter() Are Mutually Exclusive

```apex
// WRONG — throws at build() time
new QueryBuilder('MyHandler')
  .onObject(Account.SObjectType)
  .fields(new List<SObjectField>{ Account.Name })
  .forIds(ids)
  .whereFilter(FieldFilter.equals(Account.Industry, 'Tech'))
  .withChildSubquery('Contacts', new List<SObjectField>{ Contact.LastName }, null, 100)
  .build()  // THROWS

// CORRECT — use one or the other, not both
// Option A: WHERE filter only
new QueryBuilder('MyHandler')
  .onObject(Account.SObjectType)
  .fields(new List<SObjectField>{ Account.Name })
  .forIds(ids)
  .whereFilter(FieldFilter.equals(Account.Industry, 'Tech'))
  .build()

// Option B: child subquery only
new QueryBuilder('MyHandler')
  .onObject(Account.SObjectType)
  .fields(new List<SObjectField>{ Account.Name })
  .forIds(ids)
  .withChildSubquery('Contacts', new List<SObjectField>{ Contact.LastName }, null, 100)
  .build()
```

### 10.6 Reserved `__salt_` Prefix

Handler names, tags, and bind variable names starting with `__salt_` are rejected at construction time. This prefix is reserved for framework internals (bind parameter allocation).

### 10.7 Platform Event / CDC / Big Object / External Object

Triggers on SObjects whose API name ends with `__e`, `ChangeEvent`, `__b`, or `__x` are silently skipped by the dispatcher. The framework is designed for standard and custom SObjects only.

### 10.8 Circuit Breaker Shedding Order

When governor limits are approached:
1. **Non-critical `IQueryAware` handlers** are shed first (SOQL and Heap breakers)
2. **Non-critical non-`IQueryAware` handlers** are shed by CPU breaker only
3. **Critical handlers** are never shed — if they would exceed limits, the framework throws
4. **Before-trigger handlers** are never shed by CPU breaker (mutations to `Trigger.new` are irrevocable)

Set `IsCritical__c = false` on handlers that can be safely skipped under load.

### 10.9 Non-Critical After-Trigger Exception Handling

When a non-critical handler throws in an after-trigger context:
- The exception is **caught and logged**, not propagated
- DML registrations from that handler are **rolled back** (via journal replay)
- Remaining handlers continue execution
- If the handler is `IQueryAware`, its cache entries are properly cleaned up

When a critical handler throws, or any handler throws in before-trigger: the exception **propagates** and aborts the transaction.

### 10.10 Query Aggregation Across Handlers

Two handlers declaring queries with the same **merge key** (`SObjectType|relationshipField`) may be merged:

```apex
// Handler A: Contact via AccountId
new QueryRequest(Contact.SObjectType, {LastName, AccountId}, ids, Contact.AccountId, false, 'A')

// Handler B: Contact via AccountId (same merge key)
new QueryRequest(Contact.SObjectType, {LastName, Email, AccountId}, ids, Contact.AccountId, false, 'B')

// Framework merges: 1 SOQL instead of 2
// SELECT Id, LastName, Email, AccountId FROM Contact WHERE AccountId IN :ids
// Both handlers receive the merged result set from cache
```

Merge is **refused** when:
- Different SObjectType or relationshipField
- FLS mismatch (one with, one without)
- Mixed child-subquery vs no child-subquery
- Tag collision on same merge key

---

## Appendix: Decision Flowchart

```
Does the handler need to process only a subset of records?
  ├─ YES → add IRecordFilter
  └─ NO  → skip IRecordFilter

Does the handler modify fields that could re-trigger the same trigger?
  ├─ YES → add IRecursionAware (+ set MaxReentrancy__c / CascadeDepthLimit__c)
  └─ NO  → skip IRecursionAware

Does the handler need data from related/parent/child records?
  ├─ YES → add IQueryAware
  │        (ALL business logic goes in onDataReady(), NOT in context methods)
  └─ NO  → skip IQueryAware
           (business logic goes in beforeInsert/afterUpdate/etc.)

Does the handler need to create, update, or delete OTHER records?
  ├─ YES → add IDmlAware
  │        (register operations in onDmlReady(), framework commits in Phase 4)
  └─ NO  → skip IDmlAware
```

Each decision is independent. Answer all four, implement only the interfaces you said YES to.
