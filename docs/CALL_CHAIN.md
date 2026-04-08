# SALT-YASTF: Consolidated Call Chain Analysis

## Complete Pipeline Flow

```mermaid
flowchart TD
    APEX_TRIGGER["Apex Trigger File\ntrigger XTrigger on X ..."]
    APEX_TRIGGER --> RUN["TriggerDispatcher.run\nstatic, no params"]

    RUN --> GET_SOBJ["getSObjectName\nfrom Trigger.new or Trigger.old"]
    GET_SOBJ --> SPECIAL{"Special SObject?\nPlatform Event / CDC /\nBig Object / External Object"}
    SPECIAL -- Yes --> EXIT_EARLY(["Return, no processing"])
    SPECIAL -- No --> RESOLVE_CTX["TriggerContextUtil\n.fromTriggerOperation\nTriggerOperation to TriggerContext"]
    RESOLVE_CTX --> INC_CASCADE["RecursionGuard\n.incrementCascadeDepth\nsObjectName"]
    INC_CASCADE --> TRY_PIPELINE["try: runPipeline\nsObjectName, ctx"]
    TRY_PIPELINE --> PHASE_0_START(["Phase 0 Start"])

    TRY_PIPELINE -. "finally always" .-> FINALLY_BLOCK
    subgraph FINALLY["Phase 5: Cleanup"]
        FINALLY_BLOCK["RecursionGuard.decrementCascadeDepth\nprunes fieldHashes + invocationCounters\nfor SObjectTypes at this cascade level"]
        FINALLY_BLOCK --> FINALLY_BYPASS["Clear nextDmlEventBypasses"]
        FINALLY_BYPASS --> FINALLY_ALERT{"Handlers skipped\nby circuit breakers?"}
        FINALLY_ALERT -- Yes --> PUB_ALERT["publishCircuitBreakerAlert\nTriggerFrameworkAlert__e\nplatform event if deployed"]
        FINALLY_ALERT -- No --> DONE(["Pipeline complete"])
        PUB_ALERT --> DONE
    end
```

## Phase 0: Handler Loading and Pre-Processing

```mermaid
flowchart TD
    PHASE_0_START(["Phase 0 Start"])
    PHASE_0_START --> LOAD_CMDT["getHandlersForSObject\nSELECT FROM TriggerHandler__mdt\nWHERE SObjectType__c = sObj\nAND IsActive__c = TRUE\nORDER BY Order__c ASC\ncached in static Map"]

    LOAD_CMDT --> P0_LOOP["FOR EACH CMDT config\nOrder__c ascending"]

    P0_LOOP --> CTX_CHECK{"isEnabledForContext?\nchecks BeforeInsert__c\nAfterUpdate__c etc"}
    CTX_CHECK -- "Not enabled" --> P0_SKIP_CTX(["Skip handler"])
    CTX_CHECK -- Enabled --> INSTANTIATE

    INSTANTIATE["instantiateHandler config\nType.forName ns className\n.newInstance"]
    INSTANTIATE --> INST_RESULT{"Handler\ninstantiated?"}
    INST_RESULT -- "null + IsCritical" --> THROW_INST["THROW\nTriggerFrameworkException\nCritical handler class not found"]
    INST_RESULT -- "null + not critical" --> P0_SKIP_WARN(["Log WARN skip"])
    INST_RESULT -- Success --> DUP_CHECK

    DUP_CHECK{"Duplicate\nhandler name?"}
    DUP_CHECK -- Yes --> P0_SKIP_DUP(["Skip duplicate"])
    DUP_CHECK -- No --> BYPASS_CHECK

    BYPASS_CHECK["isBypassed\nconfig handlerName\nsObjectName ctx"]
    BYPASS_CHECK --> BYPASS_EVAL

    subgraph BYPASS_EVAL["Bypass Evaluation: most-specific-first, first match wins"]
        direction TB
        BY1{"1 AllowBypass__c = false?\nseal"}
        BY1 -- "Sealed" --> BY_NOT_BYPASSED(["NOT bypassable"])
        BY1 -- "Not sealed" --> BY2{"2 BypassPermission__c\nCustom Permission check"}
        BY2 -- Match --> BY_IS_BYPASSED(["BYPASSED"])
        BY2 -- No match --> BY3{"3 BypassUsers__c\ncomma-separated\n18-char User IDs"}
        BY3 -- Match --> BY_IS_BYPASSED
        BY3 -- No match --> BY4{"4 BypassProfiles__c\ncomma-separated\n18-char Profile IDs"}
        BY4 -- Match --> BY_IS_BYPASSED
        BY4 -- No match --> BY5{"5 Context-scoped\nprogrammatic bypass"}
        BY5 -- Match --> BY_IS_BYPASSED
        BY5 -- No match --> BY6{"6 SObject-scoped\nprogrammatic bypass"}
        BY6 -- Match --> BY_IS_BYPASSED
        BY6 -- No match --> BY7{"7 Global\nprogrammatic bypass"}
        BY7 -- Match --> BY_IS_BYPASSED
        BY7 -- No match --> BY8{"8 Next-DML-event bypass\nauto-clears after\nthis execution"}
        BY8 -- Match --> BY_IS_BYPASSED
        BY8 -- No match --> BY_NOT_BYPASSED2(["NOT bypassed"])
    end

    BY_IS_BYPASSED --> P0_SKIP_BYPASS(["Log INFO skip"])
    BY_NOT_BYPASSED & BY_NOT_BYPASSED2 --> CASCADE_CHECK

    CASCADE_CHECK{"CascadeDepthLimit__c check\nRecursionGuard\n.getCascadeDepth\nexceeds limit?"}
    CASCADE_CHECK -- Exceeded --> THROW_CASCADE["THROW\nCascadeDepthException"]
    CASCADE_CHECK -- OK --> ADD_HANDLER["Add to handlers\nhandlerNames\nhandlerConfigs"]

    ADD_HANDLER --> P0_MORE{"More configs?"}
    P0_SKIP_CTX & P0_SKIP_WARN & P0_SKIP_DUP & P0_SKIP_BYPASS --> P0_MORE
    P0_MORE -- Yes --> P0_LOOP
    P0_MORE -- No --> P0_END(["Phase 0 Complete"])
```

## Phase 1: Record Filtering via IRecordFilter

```mermaid
flowchart TD
    P1_START(["Phase 1 Start"])

    P1_START --> RECS_TO_FILTER{"Trigger context?"}
    RECS_TO_FILTER -- "BEFORE/AFTER DELETE" --> USE_OLD["recordsToFilter = Trigger.old"]
    RECS_TO_FILTER -- "All others" --> USE_NEW["recordsToFilter = Trigger.new"]
    USE_OLD & USE_NEW --> P1_LOOP

    P1_LOOP["FOR EACH handler\nOrder__c"]
    P1_LOOP --> IS_FILTER{"handler instanceof\nIRecordFilter?"}

    IS_FILTER -- No --> ALL_RECS["Handler applies to\nALL records\nno filtering entry created"]
    ALL_RECS --> P1_NEXT

    IS_FILTER -- Yes --> CAST_FILTER["Cast to IRecordFilter"]
    CAST_FILTER --> REC_LOOP["FOR EACH record\nin recordsToFilter"]

    REC_LOOP --> DETERMINE_ARGS{"Trigger context\ndetermines\nnewRec / oldRec"}

    DETERMINE_ARGS -- "BEFORE/AFTER DELETE" --> ARGS_DEL["newRec = null\noldRec = record"]
    DETERMINE_ARGS -- "BEFORE/AFTER INSERT\nAFTER UNDELETE" --> ARGS_INS["newRec = record\noldRec = null"]
    DETERMINE_ARGS -- "BEFORE/AFTER UPDATE" --> ARGS_UPD["newRec = record\noldRec = oldMap.get record.Id"]

    ARGS_DEL & ARGS_INS & ARGS_UPD --> CALL_FILTER

    CALL_FILTER["CALL filter.isApplicable\nnewRec oldRec ctx"]

    CALL_FILTER --> FILTER_NPE{"NullPointerException?"}
    FILTER_NPE -- Yes --> THROW_NPE["THROW\nTriggerFrameworkException"]

    FILTER_NPE -- No --> FILTER_RESULT{"Returns true?"}
    FILTER_RESULT -- No --> SKIP_RECORD["Record excluded\nfor this handler"]
    FILTER_RESULT -- Yes --> IS_INSERT_CTX{"INSERT context?"}
    IS_INSERT_CTX -- Yes --> TRACK_IDX["Track by array INDEX\nno IDs in INSERT"]
    IS_INSERT_CTX -- No --> TRACK_ID["Track by record ID"]

    SKIP_RECORD & TRACK_IDX & TRACK_ID --> MORE_RECS{"More records?"}
    MORE_RECS -- Yes --> REC_LOOP
    MORE_RECS -- No --> COUNT_CHECK{"Any applicable\nrecords?"}

    COUNT_CHECK -- "0 applicable" --> MARK_SKIP["Mark handler as skipped\nwont execute in Phase 3"]
    COUNT_CHECK -- "1+ applicable" --> STORE_APPLICABLE["Store in\napplicableRecordIds by Id\nor applicableRecordIndices by index"]

    MARK_SKIP & STORE_APPLICABLE --> P1_NEXT{"More handlers?"}
    P1_NEXT -- Yes --> P1_LOOP
    P1_NEXT -- No --> P1_END(["Phase 1 Complete"])
```

### Built-in IRecordFilter Implementations

```mermaid
flowchart LR
    F_FNN["FieldNotNull field\nfield != null\non new or old record"]
    F_FC["FieldChanged field\nValue differs old to new\nAlways true on DELETE\nTrue if non-null on INSERT"]
    F_RT["RecordTypeIs devName\nRecordTypeId matches\ndeveloper name\nstatic cross-instance cache"]
    F_AND["CompositeFilter.andOf\nALL filters pass\nshort-circuits on first false"]
    F_OR["CompositeFilter.orOf\nANY filter passes\nshort-circuits on first true"]
    F_NOT["CompositeFilter.notOf\nInverts inner filter"]
```

## Phase 2: Query Declaration, Aggregation, Execution via IQueryAware

```mermaid
flowchart TD
    P2_START(["Phase 2 Start"])

    P2_START --> P2_LOOP["FOR EACH non-skipped handler"]
    P2_LOOP --> IS_QA{"handler instanceof\nIQueryAware?"}
    IS_QA -- No --> P2_STD["Standard handler\nno query needs"]
    IS_QA -- Yes --> QA_CAST["Cast to IQueryAware"]

    QA_CAST --> QA_GET_RECS["getApplicableRecords\nrespects Phase 1 filtering"]
    QA_GET_RECS --> QA_DECLARE["CALL queryAware.declareQueryNeeds\napplicableRecords oldMap"]
    QA_DECLARE --> QA_RETURNS["Returns List of QueryRequest\n(may carry Predicate filter tree,\nChildSubqueryDescriptor,\nper-handler tag)"]
    QA_RETURNS --> QA_AGG["QueryAggregator.addRequests"]
    QA_RETURNS --> QA_CACHE["Cache applicable records\nfor Phase 3 reuse F-QB10"]

    P2_STD & QA_AGG & QA_CACHE --> P2_MORE{"More handlers?"}
    P2_MORE -- Yes --> P2_LOOP
    P2_MORE -- No --> MERGE

    MERGE["QueryAggregator.getMergedRequests"]
    MERGE --> MERGE_GROUP["Group by merge key\nSObjectType + RelationshipField"]
    MERGE_GROUP --> MERGE_GATE{"canMergeOrUnion(a, b)\nsingle merge gate"}
    MERGE_GATE -- "REFUSE\n(FLS mismatch / shape mismatch /\ntag collision / mixed null tags)" --> MERGE_SEP
    MERGE_GATE -- "MERGE_IDENTITY\n(structurally equal\nPredicate trees)" --> MERGE_DO
    MERGE_GATE -- "MERGE_OR\n(different non-empty\npredicate trees,\notherwise compatible)" --> MERGE_OR_DO
    MERGE_GATE -- "MERGE_SUBSUME\n(one side empty filters,\nother has filters)" --> MERGE_SUB
    MERGE_DO["Union ids + fields\nNo OR rendering\nwasOrMerged = false"]
    MERGE_OR_DO["Union ids + fields\nUNION FIELD SETS\nRender predicate clause as\n((handlerA-AND-chain) OR\n (handlerB-AND-chain))\nwasOrMerged = true"]
    MERGE_SUB["Take empty-filter side as base\nFiltered side's predicates stored\nin filtersByHandler for matcher\nwasOrMerged = true"]
    MERGE_SEP["Separate QueryRequests"]
    MERGE_DO & MERGE_OR_DO & MERGE_SUB & MERGE_SEP --> CB_SOQL

    CB_SOQL{"SOQL Circuit Breaker\nBudget = getLimitQueries\n- soqlReserve\n- cascadeDepth x perLevel\nMerged count fits?"}
    CB_SOQL -- Yes --> CB_HEAP
    CB_SOQL -- No --> CB_SOQL_P1["Pass 1: Drop ALL\nnon-critical IQueryAware\nhandlers from merged set"]
    CB_SOQL_P1 --> CB_SOQL_P2{"Pass 2: Critical\nqueries fit now?"}
    CB_SOQL_P2 -- Yes --> CB_HEAP
    CB_SOQL_P2 -- No --> THROW_SOQL["THROW\nSoqlBudgetException"]

    CB_HEAP{"Heap Circuit Breaker\nThreshold = getLimitHeapSize\nx 0.75 default\nUnder threshold?"}
    CB_HEAP -- Yes --> QE_START
    CB_HEAP -- No --> CB_HEAP_P1["Pass 1: Drop ALL\nnon-critical IQueryAware\nhandlers"]
    CB_HEAP_P1 --> CB_HEAP_P2{"Pass 2: Critical\nqueries under\nheap threshold?"}
    CB_HEAP_P2 -- Yes --> QE_START
    CB_HEAP_P2 -- No --> THROW_HEAP["THROW\nTriggerFrameworkException"]
```

### Query Execution

```mermaid
flowchart TD
    QE_START["QueryExecutor.execute\nmergedRequests"]
    QE_START --> QE_LOOP["For each QueryRequest"]
    QE_LOOP --> QE_SIZE{"More than 900\nrecord IDs?"}
    QE_SIZE -- Yes --> QE_CHUNK["Chunk into 900-ID batches"]
    QE_CHUNK --> QE_CHUNK_GUARD{"Per-chunk SOQL\nbudget guard exceeded?"}
    QE_CHUNK_GUARD -- Exceeded --> THROW_SOQL2["THROW\nSoqlBudgetException"]
    QE_CHUNK_GUARD -- OK --> QE_BUILD
    QE_SIZE -- No --> QE_BUILD

    QE_BUILD["buildSOQL request\nSELECT projected fields\n+ optional child subquery\n  (SELECT cf FROM rel\n   WHERE childFilter\n   LIMIT n)\nFROM target\nWHERE relField IN :__salt_ids\n+ flat-AND or OR'd\n  predicate clause\n  via Predicate.render(BindContext)\ncachedFieldName per field\ngetDescribe only if enforceFLS"]
    QE_BUILD --> QE_FLS{"enforceFLS = true?\n(opt-in via withFLS)"}
    QE_FLS -- Yes --> QE_FLS_CHECK{"All req.fields\nisAccessible?"}
    QE_FLS_CHECK -- No --> THROW_FLS["THROW FlsException\nfield + objectName"]
    QE_FLS_CHECK -- Yes --> QE_RUN
    QE_FLS -- No --> QE_RUN

    QE_RUN["Database.queryWithBinds(\n  soql, bindMap,\n  AccessLevel.SYSTEM_MODE)\nSYSTEM_MODE explicit for\nAPI-version stability\nChunks at 900 IDs via\nQueryRequest.withChunkedIds()"]
    QE_RUN --> QE_POPULATE["Populate QueryResultCache\nby merge key with 4-level\nprovenance maps:\n  idsByHandler\n  fieldsByHandler\n  filtersByHandler\nset wasOrMergedByMergeKey"]

    QE_POPULATE --> QE_MORE{"More requests?"}
    QE_MORE -- Yes --> QE_LOOP
    QE_MORE -- No --> P2_END(["Phase 2 Complete"])

    subgraph QR_CACHE["QueryResultCache Internals"]
        direction TB
        QRC_STORE["rowsByMergeKey: mergeKey to List of SObject"]
        QRC_IDX_ID["indexById: lazy-built on first ID-keyed access"]
        QRC_IDX_REL["indexByRelField: lazy-built on first relField access"]
        QRC_PROV["4-level provenance maps:\nidsByHandler / fieldsByHandler / filtersByHandler\nMap<mergeKey, Map<handler, Map<tag, ...>>>\nwasOrMergedByMergeKey"]
        QRC_GET["getForHandler(handler, sObj, relField, tag):\n  throws on evict / unknown handler / ambiguous tag\n  pulls rows by id or relField\n  if wasOrMerged: in-memory matcher re-applies\n    handler's Predicate list\n  deep clone(true,true,true,false)\n    preserves child collections\n  strips undeclared top-level fields"]
        QRC_EVICT["markHandlerTagServed(handler, tag):\nper-(handler,tag) eviction releases\nmerge-key slot when ALL declared\n(handler, tag) consumers have read"]
    end

    QE_POPULATE -.-> QR_CACHE
```

## Phase 3: Handler Execution

```mermaid
flowchart TD
    P3_START(["Phase 3 Start"])

    P3_START --> CREATE_REG["Create DmlRegistrar\nnew instance per pipeline"]
    CREATE_REG --> SET_CTX["registrar.setBeforeTriggerContext\nisBefore"]
    SET_CTX --> SET_MAP{"isBefore AND\nTrigger.newMap != null?"}
    SET_MAP -- Yes --> SET_NEWMAP["registrar.setTriggerNewMap\nTrigger.newMap"]
    SET_MAP -- No --> P3_LOOP
    SET_NEWMAP --> P3_LOOP

    P3_LOOP["FOR EACH handler\nOrder__c"]

    P3_LOOP --> SKIP_P1{"In skippedHandlers?\nPhase 1: 0 applicable"}
    SKIP_P1 -- Yes --> P3_SKIP_LOG1(["Log INFO skip"])
    SKIP_P1 -- No --> SKIP_P2{"In querySkippedHandlers?\nPhase 2: circuit breaker"}
    SKIP_P2 -- Yes --> P3_SKIP_LOG2(["Log INFO skip"])
    SKIP_P2 -- No --> REENTRY_CHECK

    REENTRY_CHECK{"INSERT context AND\nMaxReentrancy__c > 0?"}
    REENTRY_CHECK -- No --> RECURSION_CHECK
    REENTRY_CHECK -- Yes --> REENTRY_EXCEEDED{"RecursionGuard\n.isInvocationLimitExceeded?"}
    REENTRY_EXCEEDED -- No --> RECURSION_CHECK
    REENTRY_EXCEEDED -- Yes --> REENTRY_CRIT{"IsCritical__c?"}
    REENTRY_CRIT -- Yes --> THROW_REENTRY["THROW\nRecursionLimitException"]
    REENTRY_CRIT -- No --> P3_SKIP_SILENT(["Silently skip"])

    RECURSION_CHECK{"handler instanceof\nIRecursionAware\nAND NOT BEFORE_INSERT?"}
    RECURSION_CHECK -- No --> CPU_CHECK
    RECURSION_CHECK -- Yes --> REC_CAST["Cast to IRecursionAware"]
    REC_CAST --> REC_FIELDS["CALL recursionAware\n.getRecursionFields\nreturns List of SObjectField"]
    REC_FIELDS --> REC_VALIDATE{"All fields belong\nto trigger SObject\nschema?"}
    REC_VALIDATE -- No --> THROW_FIELD_VAL["THROW\nTriggerFrameworkException\nfield does not belong to SObject"]
    REC_VALIDATE -- Yes --> REC_HASH_LOOP["FOR EACH record"]

    REC_HASH_LOOP --> REC_COMPUTE["RecursionGuard.computeFieldHash\nrecord recursionFields\nlength-prefixed field values"]
    REC_COMPUTE --> REC_CHECK{"hasBeenProcessed\nWithSameFields?"}
    REC_CHECK -- Yes --> REC_SKIP_REC["Record SKIPPED\nalready processed\nwith same field values"]
    REC_CHECK -- No --> REC_COLLECT["Collect as unprocessed\nStore pendingHash\nF48: deferred marking"]

    REC_SKIP_REC & REC_COLLECT --> REC_MORE{"More records?"}
    REC_MORE -- Yes --> REC_HASH_LOOP
    REC_MORE -- No --> REC_EMPTY{"All records\nalready processed?"}
    REC_EMPTY -- Yes --> P3_SKIP_REC_ALL(["Skip handler entirely"])
    REC_EMPTY -- No --> REC_NARROW["Narrow applicableRecordIds\nto unprocessed only\nInvalidate Phase 2 cache L2-1"]
    REC_NARROW --> CPU_CHECK

    CPU_CHECK{"CPU Circuit Breaker\ngetCpuTime exceeds\nthreshold fraction?"}
    CPU_CHECK -- No --> SET_HANDLER
    CPU_CHECK -- Yes --> CPU_CRIT{"Non-critical AND\nafter-trigger?"}
    CPU_CRIT -- Yes --> P3_CPU_SKIP(["Skip handler\nCPU circuit breaker"])
    CPU_CRIT -- No --> CPU_WARN["Log WARN proceed\ncritical or before-trigger"]
    CPU_WARN --> SET_HANDLER

    SET_HANDLER["registrar.setCurrentHandler\nhandlerName"]
    SET_HANDLER --> EXEC_PATH(["To executeHandler"])
```

## Phase 3 cont: executeHandler Dispatch Logic

```mermaid
flowchart TD
    EXEC_PATH(["executeHandler"])

    EXEC_PATH --> IS_QA{"handler instanceof\nIQueryAware?"}

    IS_QA -- Yes --> QA_GET["Get applicable records\nfrom Phase 2 cache F-QB10\nor recompute"]
    QA_GET --> QA_CALL["CALL queryAware.onDataReady\napplicableRecords oldMap cache\nREPLACES standard context method"]
    QA_CALL --> QA_EVICT["cache.markHandlerServed\nhandlerName\ntriggers auto-eviction"]
    QA_EVICT --> DML_CHECK

    IS_QA -- No --> STD_DISPATCH["dispatchToHandler handler ctx"]
    STD_DISPATCH --> CTX_SWITCH{"TriggerContext?"}
    CTX_SWITCH -- BEFORE_INSERT --> H_BI["handler.beforeInsert\nTrigger.new"]
    CTX_SWITCH -- BEFORE_UPDATE --> H_BU["handler.beforeUpdate\nTrigger.new Trigger.oldMap"]
    CTX_SWITCH -- BEFORE_DELETE --> H_BD["handler.beforeDelete\nTrigger.oldMap"]
    CTX_SWITCH -- AFTER_INSERT --> H_AI["handler.afterInsert\nTrigger.new"]
    CTX_SWITCH -- AFTER_UPDATE --> H_AU["handler.afterUpdate\nTrigger.new Trigger.oldMap"]
    CTX_SWITCH -- AFTER_DELETE --> H_AD["handler.afterDelete\nTrigger.oldMap"]
    CTX_SWITCH -- AFTER_UNDELETE --> H_AUN["handler.afterUndelete\nTrigger.new"]
    H_BI & H_BU & H_BD & H_AI & H_AU & H_AD & H_AUN --> DML_CHECK

    DML_CHECK{"handler instanceof\nIDmlAware?"}
    DML_CHECK -- No --> HANDLER_DONE(["Handler dispatch\ncomplete"])
    DML_CHECK -- Yes --> DML_CALL["CALL dmlAware.onDmlReady registrar\nALWAYS called IN ADDITION\nto onDataReady or context method"]
    DML_CALL --> HANDLER_DONE

    subgraph REG_API["IDmlRegistrar API: available inside onDmlReady"]
        direction LR
        R_NEW["registerNew record"]
        R_NEW_FK["registerNew record\nfkField relatedTo"]
        R_DIRTY["registerDirty record\ndirtyFields"]
        R_DEL["registerDeleted record"]
        R_DEP["declareDependency\nsourceType targetType"]
    end

    DML_CALL -.-> REG_API
```

## Phase 3 cont: Exception Handling Per Context

```mermaid
flowchart TD
    HANDLER_DONE(["Handler dispatch\nreturned"])

    HANDLER_DONE --> EH_PATH{"Trigger context\n+ criticality?"}

    EH_PATH -- "BEFORE-TRIGGER\nany criticality" --> BT_EXEC["Execute handler\nAll exceptions propagate"]
    BT_EXEC --> BT_OK["On success:\n1 incrementInvocationCount\n2 markProcessedWithHash\nonly if IRecursionAware active"]
    BT_OK --> NEXT_HANDLER

    EH_PATH -- "AFTER-TRIGGER\nIsCritical = true" --> AC_EXEC["Execute handler\nAll exceptions propagate"]
    AC_EXEC --> AC_OK["On success:\n1 incrementInvocationCount\n2 markProcessedWithHash"]
    AC_OK --> NEXT_HANDLER

    EH_PATH -- "AFTER-TRIGGER\nIsCritical = false" --> NC_SNAP["Snapshot registrar state:\nsnapNew snapFk snapDeleted\njournalMark snapConflicts"]
    NC_SNAP --> NC_TRY["try: execute handler"]
    NC_TRY --> NC_RESULT{"Success?"}

    NC_RESULT -- Yes --> NC_OK["1 incrementInvocationCount\n2 markProcessedWithHash"]
    NC_OK --> NEXT_HANDLER

    NC_RESULT -- "Exception caught" --> NC_ROLLBACK["ROLLBACK:\n1 registrar.rollbackTo\n2 rollbackToJournalMark\n3 rollbackConflictsTo\n4 DO NOT mark field hashes\n5 Log ERROR"]
    NC_ROLLBACK --> NEXT_HANDLER

    NEXT_HANDLER{"More handlers?"}
    NEXT_HANDLER -- Yes --> BACK_TO_LOOP(["Back to Phase 3\nhandler loop"])
    NEXT_HANDLER -- No --> POST_PHASE3

    POST_PHASE3["Evict cached query data for\ncircuit-breaker-skipped handlers\nF60: heap leak prevention"]
    POST_PHASE3 --> P4_START(["Proceed to Phase 4"])
```

## Phase 4: DML Commit, After-Trigger Only

```mermaid
flowchart TD
    P4_START(["Phase 4 Start"])

    P4_START --> P4_GUARD{"not isBefore AND\nregistrar.hasPendingDml?"}
    P4_GUARD -- "No: before-trigger\nor no pending DML" --> P4_SKIP(["No DML to commit\ngo to Phase 5"])

    P4_GUARD -- Yes --> COMMIT["DmlExecutor.commitWork registrar"]

    COMMIT --> MIXED{"Mixed DML Guard\nSetup objects detected?\nUser Group PermissionSet\nQueueSObject GroupMember\netc 17 types\nmixed with non-Setup?"}
    MIXED -- Yes --> THROW_MIXED["THROW\nDmlCoordinationException\nMixed DML not allowed"]
    MIXED -- No --> DML_BUDGET

    DML_BUDGET{"DML Budget Guard\nrequired = 1 savepoint\n+ unique new types\n+ unique dirty types\n+ unique deleted types\nfits in remaining limit?"}
    DML_BUDGET -- No --> THROW_DML_BUDGET["THROW\nDmlCoordinationException\nDML budget exhausted"]
    DML_BUDGET -- Yes --> TOPO_SORT

    TOPO_SORT["Topological Sort\nKahns algorithm"]
    TOPO_SORT --> TOPO_INPUTS["Inputs:\n1 Declared dependencies\n2 Schema-derived FK edges\ncached per SObjectType\nSelf-referential FKs filtered"]
    TOPO_INPUTS --> TOPO_CYCLE{"Cycle detected?"}
    TOPO_CYCLE -- Yes --> THROW_CYCLE["THROW\nCyclicDependencyException"]
    TOPO_CYCLE -- No --> TOPO_OUTPUT["Output: ordered\nList of SObjectType"]

    TOPO_OUTPUT --> SAVEPOINT["Database.setSavepoint"]

    SAVEPOINT --> DML_INSERT["INSERTS\nparent types first\ntopological order"]
    DML_INSERT --> FK_RESOLVE["Resolve ForeignKeyBindings\ncopy parent.Id to child FK field"]
    FK_RESOLVE --> FK_FAIL{"Parent has no Id?\nparent insert failed\nallOrNone = false"}
    FK_FAIL -- Yes --> FK_SKIP["Skip child record"]
    FK_FAIL -- No --> FK_OK["FK resolved"]
    FK_SKIP & FK_OK --> DO_INSERT["DmlOperation.forInsert\n.allOrNone.execute"]

    DO_INSERT --> DML_UPDATE["UPDATES\ntopological order"]
    DML_UPDATE --> DO_UPDATE["DmlOperation.forUpdate\n.allOrNone.execute"]

    DO_UPDATE --> DML_DELETE["DELETES\nREVERSE topological order\nchildren first"]
    DML_DELETE --> DO_DELETE["DmlOperation.forDelete\n.allOrNone.execute"]

    DO_DELETE --> DML_EXCEPTION{"DmlException\nthrown?"}
    DML_EXCEPTION -- No --> P4_DONE(["DML commit complete\ngo to Phase 5"])

    DML_EXCEPTION -- Yes --> ROLLBACK["Database.rollback savepoint\nNull out Ids on new records"]
    ROLLBACK --> LOCK_CHECK{"UNABLE_TO_LOCK_ROW?"}
    LOCK_CHECK -- Yes --> THROW_LOCK["THROW\nDmlCoordinationException\nlock row error"]
    LOCK_CHECK -- No --> THROW_DML_OTHER["THROW\nDmlCoordinationException\nchained original cause"]
```

## Cascade Re-Entry Flow

```mermaid
flowchart TD
    subgraph DEPTH1["Cascade Depth 1"]
        direction TB
        T1_BEFORE["Account BEFORE_UPDATE\nTriggerDispatcher.run"]
        T1_BEFORE --> T1_P0_3["Phase 0-3: handlers execute"]
        T1_P0_3 --> T1_P4["Phase 4: DmlExecutor.commitWork"]

        T1_P4 --> T1_INSERT["Database.insert contacts"]
        T1_P4 --> T1_UPDATE["Database.update opportunities"]
        T1_P4 --> T1_DELETE["Database.delete tasks"]

        T1_INSERT --> T1_AFTER_INSERT
        T1_UPDATE --> T1_AFTER_UPDATE
        T1_DELETE --> T1_AFTER_DELETE

        T1_AFTER_INSERT["Return from Contact triggers"]
        T1_AFTER_UPDATE["Return from Opportunity triggers"]
        T1_AFTER_DELETE["Return from Task triggers"]

        T1_AFTER_INSERT & T1_AFTER_UPDATE & T1_AFTER_DELETE --> T1_P5["Phase 5: cleanup"]
    end

    T1_INSERT --> DEPTH2_A
    T1_UPDATE --> DEPTH2_B
    T1_DELETE --> DEPTH2_C

    subgraph DEPTH2_A["Cascade Depth 2: Contact"]
        direction TB
        T2A_BEFORE["Contact BEFORE_INSERT\nnew registrar new cache"]
        T2A_BEFORE --> T2A_PIPE["Full pipeline execution"]
        T2A_PIPE --> T2A_AFTER["Contact AFTER_INSERT\nnew registrar new cache"]
        T2A_AFTER --> T2A_P4{"Phase 4 DML?"}
        T2A_P4 -- Yes --> T2A_CASCADE["May trigger\nCascade Depth 3+\nCascadeDepthLimit enforced"]
        T2A_P4 -- No --> T2A_DONE["Cleanup + return"]
        T2A_CASCADE --> T2A_DONE
    end

    subgraph DEPTH2_B["Cascade Depth 2: Opportunity"]
        direction TB
        T2B_PIPE["Full pipeline execution\nown registrar own cache"]
    end

    subgraph DEPTH2_C["Cascade Depth 2: Task"]
        direction TB
        T2C_PIPE["Full pipeline execution\nown registrar own cache"]
    end

    subgraph GUARANTEES["Cascade Guarantees"]
        direction LR
        G1["Each cascade level:\nown DmlRegistrar\nQueryResultCache\napplicable records"]
        G2["decrementCascadeDepth\nprunes fieldHashes +\ninvocationCounters\nfor exiting SObjectTypes"]
        G3["CascadeDepthLimit__c\nper handler prevents\nunbounded recursion"]
        G4["nextDmlEventBypasses\ncleared on each\npipeline exit"]
    end
```

## DmlRegistrar State Flow Per Context

```mermaid
flowchart LR
    subgraph BEFORE_INSERT["BEFORE_INSERT"]
        direction TB
        BI_NEW["registerNew THROWS\nnot supported in before-trigger"]
        BI_DIRTY["registerDirty THROWS\nno Trigger.newMap in BEFORE_INSERT"]
        BI_DEL["registerDeleted THROWS\nnot supported in before-trigger"]
        BI_NOTE["Handler must modify Trigger.new\ndirectly in beforeInsert or onDataReady"]
    end

    subgraph BEFORE_UPDATE["BEFORE_UPDATE"]
        direction TB
        BU_NEW["registerNew THROWS"]
        BU_DIRTY["registerDirty MUTATES Trigger.new\ndirectly via triggerNewMap\nwith conflict detection"]
        BU_DEL["registerDeleted THROWS"]

        subgraph CONFLICT["Conflict Detection"]
            direction TB
            C1["Same handler sets same field: no-op"]
            C2["Different handler same value: WARN"]
            C3["Different handler different value:\nTHROW FieldConflictException"]
        end

        BU_DIRTY --- CONFLICT
    end

    subgraph BEFORE_DELETE["BEFORE_DELETE"]
        direction TB
        BD_NEW["registerNew THROWS"]
        BD_DIRTY["registerDirty THROWS\nno Trigger.newMap\nold records are read-only"]
        BD_DEL["registerDeleted THROWS"]
    end

    subgraph AFTER_CONTEXTS["AFTER_INSERT AFTER_UPDATE\nAFTER_DELETE AFTER_UNDELETE"]
        direction TB
        AF_NEW["registerNew record\nbuffers in newRecords list"]
        AF_NEW_FK["registerNew record fkField relatedTo\nbuffers + creates ForeignKeyBinding"]
        AF_DIRTY["registerDirty record dirtyFields\nbuffers in dirtyRecords map\njournal entry for rollback"]
        AF_DEL["registerDeleted record\nbuffers in deletedRecords list"]
        AF_DEP["declareDependency source target\nstored for topological sort"]
        AF_COMMIT["All committed atomically\nin Phase 4 via\nDmlExecutor.commitWork"]
        AF_NEW & AF_NEW_FK & AF_DIRTY & AF_DEL & AF_DEP --> AF_COMMIT
    end
```

## Context x Interface Compatibility Matrix

```mermaid
flowchart TD
    subgraph BI_ROW["BEFORE_INSERT"]
        direction LR
        BI_F["IRecordFilter\nisApplicable rec null ctx\ntrack by INDEX"]
        BI_Q["IQueryAware\ndeclareQueryNeeds then onDataReady\nno IDs in records"]
        BI_R["IRecursionAware\nSKIPPED\nno stable IDs"]
        BI_D["IDmlAware\nonDmlReady called\nall registrar methods THROW"]
    end

    subgraph AI_ROW["AFTER_INSERT"]
        direction LR
        AI_F["IRecordFilter\nisApplicable rec null ctx\ntrack by ID"]
        AI_Q["IQueryAware\ndeclareQueryNeeds then onDataReady"]
        AI_R["IRecursionAware\nACTIVE field hash computed\ndeferred marking F48"]
        AI_D["IDmlAware\nonDmlReady called\nall methods work\nDML committed Phase 4"]
    end

    subgraph BU_ROW["BEFORE_UPDATE"]
        direction LR
        BU_F["IRecordFilter\nisApplicable rec old ctx\ntrack by ID"]
        BU_Q["IQueryAware\ndeclareQueryNeeds then onDataReady"]
        BU_R["IRecursionAware\nACTIVE"]
        BU_D["IDmlAware\nregisterDirty mutates\nTrigger.new directly\nregisterNew/Del THROW"]
    end

    subgraph AU_ROW["AFTER_UPDATE"]
        direction LR
        AU_F["IRecordFilter\nisApplicable rec old ctx\ntrack by ID"]
        AU_Q["IQueryAware\ndeclareQueryNeeds then onDataReady"]
        AU_R["IRecursionAware\nACTIVE"]
        AU_D["IDmlAware\nall methods work\nDML committed Phase 4"]
    end

    subgraph BD_ROW["BEFORE_DELETE"]
        direction LR
        BD_F["IRecordFilter\nisApplicable null rec ctx\ntrack by ID"]
        BD_Q["IQueryAware\ndeclareQueryNeeds oldRecs oldMap\nthen onDataReady"]
        BD_R["IRecursionAware\nACTIVE hashes old records"]
        BD_D["IDmlAware\nonDmlReady called\nall registrar methods THROW"]
    end

    subgraph AD_ROW["AFTER_DELETE"]
        direction LR
        AD_F["IRecordFilter\nisApplicable null rec ctx\ntrack by ID"]
        AD_Q["IQueryAware\ndeclareQueryNeeds oldRecs oldMap\nthen onDataReady"]
        AD_R["IRecursionAware\nACTIVE"]
        AD_D["IDmlAware\nall methods work\nDML committed Phase 4"]
    end

    subgraph AUND_ROW["AFTER_UNDELETE"]
        direction LR
        AUND_F["IRecordFilter\nisApplicable rec null ctx\ntrack by ID"]
        AUND_Q["IQueryAware\ndeclareQueryNeeds then onDataReady"]
        AUND_R["IRecursionAware\nACTIVE"]
        AUND_D["IDmlAware\nall methods work\nDML committed Phase 4"]
    end
```

## Exception Propagation Map

```mermaid
flowchart LR
    subgraph PROPAGATE["Exceptions That Propagate: abort transaction"]
        direction TB
        E1["Before-trigger handler throws\nany exception"]
        E2["After-trigger critical handler throws\nany exception"]
        E3["SoqlBudgetException\ncritical queries exceed SOQL budget"]
        E4["TriggerFrameworkException\ncritical queries exceed heap budget"]
        E5["CascadeDepthException\ncascade depth exceeds limit"]
        E6["RecursionLimitException\ncritical handler exceeds MaxReentrancy"]
        E7["FieldConflictException\ndifferent handlers set different values"]
        E8["FlsException\nfield not accessible with enforceFLS"]
        E9["DmlCoordinationException\nmixed DML or budget or lock row"]
        E10["CyclicDependencyException\ncycle in DML dependency graph"]
        E11["TriggerFrameworkException\ncritical handler instantiation failed"]
        E12["TriggerFrameworkException\nIRecursionAware field validation failed"]
    end

    subgraph CAUGHT["Exceptions Caught: handler skipped, continue"]
        direction TB
        C1["After-trigger non-critical handler throws\nregistrar rolled back to snapshot\nfield hashes NOT marked\nlog ERROR next handler runs"]
    end

    subgraph SILENT["Silent Skips: no exception"]
        direction TB
        S1["Non-critical MaxReentrancy exceeded"]
        S2["Non-critical CPU circuit breaker after-trigger"]
        S3["Non-critical SOQL/heap circuit breaker"]
        S4["IRecursionAware: all records already processed"]
        S5["IRecordFilter: 0 applicable records"]
        S6["Handler bypassed any scope"]
        S7["Handler not enabled for context"]
        S8["Non-critical handler instantiation failed"]
    end
```
