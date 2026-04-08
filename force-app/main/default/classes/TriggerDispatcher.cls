public inherited sharing class TriggerDispatcher {
  // ── CMDT cache ──────────────────────────────────────────────────────
  private static Map<String, List<TriggerHandler__mdt>> handlerCache = new Map<String, List<TriggerHandler__mdt>>();

  @TestVisible
  private static Map<String, List<TriggerHandler__mdt>> mockHandlers = null;

  // ── Bypass state ────────────────────────────────────────────────────
  private static Map<String, Set<String>> bypasses = new Map<String, Set<String>>();

  private static Set<String> nextDmlEventBypasses = new Set<String>();

  private static Map<String, String> bypassCallers = new Map<String, String>();

  // ── SOQL reserve (for circuit-breaker integration) ──────────────────
  private static Integer soqlReserve = 10;
  private static Integer soqlPerCascadeLevel = 10;

  // F-PS2: Configurable heap threshold fraction (default 0.75 = 75% of limit)
  private static Decimal heapThresholdFraction = 0.75;

  // F-HD1: Test-visible override for heap threshold — allows unit tests to
  // force the heap circuit breaker path without consuming >4.5MB of heap.
  // When non-null, overrides the computed heap threshold.
  @TestVisible
  private static Integer heapThresholdOverride = null;

  // CPU breaker check: CPU time reserve for circuit breaker (default 0.75 = 75% of limit)
  private static Decimal cpuThresholdFraction = 0.75;

  // ── Test-injectable trigger context ────────────────────────────────
  // When non-null, overrides Trigger.* globals. Enables trigger-independent
  // unit testing via runWithContext(). Cleared in finally block and resetAll().
  @TestVisible
  private static List<SObject> ctxNew = null;
  @TestVisible
  private static List<SObject> ctxOld = null;
  @TestVisible
  private static Map<Id, SObject> ctxNewMap = null;
  @TestVisible
  private static Map<Id, SObject> ctxOldMap = null;

  // ── Context accessors — prefer injected context, fall back to Trigger.* ──
  private static List<SObject> getNew() {
    return ctxNew != null ? ctxNew : Trigger.new;
  }
  private static List<SObject> getOld() {
    return ctxOld != null ? ctxOld : Trigger.old;
  }
  private static Map<Id, SObject> getNewMap() {
    return ctxNewMap != null ? ctxNewMap : Trigger.newMap;
  }
  private static Map<Id, SObject> getOldMap() {
    return ctxOldMap != null ? ctxOldMap : Trigger.oldMap;
  }

  // ════════════════════════════════════════════════════════════════════
  //  Entry point — 5-phase pipeline
  // ════════════════════════════════════════════════════════════════════
  public static void run() {
    // When called from a real trigger (including nested triggers fired by Phase 4
    // DML during runWithContext), suspend injected test context so getNew()/getOld()
    // fall through to Trigger.* globals. Restored in finally block.
    List<SObject> savedNew = ctxNew;
    List<SObject> savedOld = ctxOld;
    Map<Id, SObject> savedNewMap = ctxNewMap;
    Map<Id, SObject> savedOldMap = ctxOldMap;
    ctxNew = null;
    ctxOld = null;
    ctxNewMap = null;
    ctxOldMap = null;

    String sObjectName = getSObjectName();

    // F10: Guard against blank SObject name — prevents wasted CMDT query on empty string
    if (String.isBlank(sObjectName)) {
      ctxNew = savedNew;
      ctxOld = savedOld;
      ctxNewMap = savedNewMap;
      ctxOldMap = savedOldMap;
      return;
    }

    // F32: Guard: Platform Events, Change Data Capture, Big Objects, External Objects
    if (
      sObjectName.endsWith('__e') ||
      sObjectName.endsWith('ChangeEvent') ||
      sObjectName.endsWith('__b') ||
      sObjectName.endsWith('__x')
    ) {
      return;
    }

    TriggerContext ctx = TriggerContextUtil.fromTriggerOperation(
      Trigger.operationType
    );
    Boolean isBefore = (ctx == TriggerContext.BEFORE_INSERT ||
    ctx == TriggerContext.BEFORE_UPDATE ||
    ctx == TriggerContext.BEFORE_DELETE);

    // ── Cascade management: increment at entry ──────────────────────
    RecursionGuard.incrementCascadeDepth(sObjectName);

    Boolean phaseThrew = false;
    try {
      runPipeline(sObjectName, ctx, isBefore);
    } catch (Exception e) {
      phaseThrew = true;
      throw e;
    } finally {
      RecursionGuard.decrementCascadeDepth();
      // Clear next-DML-event bypass after the AFTER phase completes (one DML
      // event spans BEFORE+AFTER, so the bypass must survive across both
      // phases of the same event), OR after BEFORE if it threw — preventing
      // the leak that the F21 unconditional-clear was originally guarding
      // against without breaking the cross-phase bypass semantics.
      if (!isBefore || phaseThrew) {
        nextDmlEventBypasses.clear();
      }
      // Restore injected test context for the outer runWithContext call
      ctxNew = savedNew;
      ctxOld = savedOld;
      ctxNewMap = savedNewMap;
      ctxOldMap = savedOldMap;
    }
  }

  // ── Test entry point — bypasses Trigger.* globals ──────────────────
  // Allows trigger-independent unit testing of the full 5-phase pipeline.
  // Context is injected via static fields and cleared in the finally block.
  @TestVisible
  private static void runWithContext(
    List<SObject> newRecords,
    List<SObject> oldRecords,
    TriggerOperation operationType
  ) {
    ctxNew = newRecords;
    ctxOld = oldRecords;
    ctxNewMap = (newRecords != null &&
      !newRecords.isEmpty() &&
      newRecords[0].Id != null)
      ? new Map<Id, SObject>(newRecords)
      : null;
    ctxOldMap = (oldRecords != null &&
      !oldRecords.isEmpty() &&
      oldRecords[0].Id != null)
      ? new Map<Id, SObject>(oldRecords)
      : null;
    try {
      String sObjectName = getSObjectName();
      if (String.isBlank(sObjectName))
        return;
      if (
        sObjectName.endsWith('__e') ||
        sObjectName.endsWith('ChangeEvent') ||
        sObjectName.endsWith('__b') ||
        sObjectName.endsWith('__x')
      ) {
        return;
      }
      TriggerContext ctx = TriggerContextUtil.fromTriggerOperation(
        operationType
      );
      Boolean isBefore = (ctx == TriggerContext.BEFORE_INSERT ||
      ctx == TriggerContext.BEFORE_UPDATE ||
      ctx == TriggerContext.BEFORE_DELETE);
      RecursionGuard.incrementCascadeDepth(sObjectName);
      Boolean phaseThrew = false;
      try {
        runPipeline(sObjectName, ctx, isBefore);
      } catch (Exception e) {
        phaseThrew = true;
        throw e;
      } finally {
        RecursionGuard.decrementCascadeDepth();
        // Same cross-phase bypass survival rule as run() — see comment there.
        if (!isBefore || phaseThrew) {
          nextDmlEventBypasses.clear();
        }
      }
    } finally {
      ctxNew = null;
      ctxOld = null;
      ctxNewMap = null;
      ctxOldMap = null;
    }
  }

  // ════════════════════════════════════════════════════════════════════
  //  Pipeline orchestration
  // ════════════════════════════════════════════════════════════════════
  private static void runPipeline(
    String sObjectName,
    TriggerContext ctx,
    Boolean isBefore
  ) {
    List<TriggerHandler__mdt> configs = getHandlersForSObject(sObjectName);

    // ── Pre-instantiate ALL handlers and apply bypass/enablement ────
    List<TriggerHandler> handlers = new List<TriggerHandler>();
    List<String> handlerNames = new List<String>();
    List<TriggerHandler__mdt> handlerConfigs = new List<TriggerHandler__mdt>();

    // Determine max cascade depth limit across all handlers
    Integer maxCascadeLimit = 0;

    for (TriggerHandler__mdt config : configs) {
      // Context enablement check
      if (!isEnabledForContext(config, ctx)) {
        continue;
      }

      // Instantiate handler
      TriggerHandler handler = instantiateHandler(config);
      if (handler == null) {
        if (config.IsCritical__c) {
          throw new TriggerFrameworkException(
            'Critical handler class not found: ' + config.HandlerClass__c,
            config.HandlerClass__c,
            ctx,
            'instantiation'
          );
        } else {
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: Non-critical handler class not found: ' +
              config.HandlerClass__c +
              '. Skipping.'
          );
          continue;
        }
      }

      String handlerName = handler.getHandlerName();

      // IsCritical=false is meaningless in before-trigger context
      if (isBefore && !config.IsCritical__c) {
        System.debug(
          LoggingLevel.INFO,
          'SALT-YASTF: IsCritical__c=false is ignored in before-trigger context for handler ' +
          handlerName
        );
      }

      // Bypass check
      if (isBypassed(config, handlerName, sObjectName, ctx)) {
        System.debug(
          LoggingLevel.INFO,
          'SALT-YASTF: Handler ' + handlerName + ' bypassed'
        );
        continue;
      }

      // L2-2: Detect duplicate handler names — maps keyed by handlerName
      // would silently overwrite, causing the first handler to use the
      // second handler's record set from Phase 1 filtering.
      if (handlerNames.contains(handlerName)) {
        System.debug(
          LoggingLevel.WARN,
          'SALT-YASTF: Duplicate handler name detected: ' +
            handlerName +
            ' on ' +
            sObjectName +
            '. Second registration (Order=' +
            config.Order__c +
            ') will be skipped to prevent data corruption.'
        );
        continue;
      }

      handlers.add(handler);
      handlerNames.add(handlerName);
      handlerConfigs.add(config);

      if (
        config.CascadeDepthLimit__c != null &&
        config.CascadeDepthLimit__c > maxCascadeLimit
      ) {
        maxCascadeLimit = (Integer) config.CascadeDepthLimit__c;
      }
    }

    // ── Cascade depth check ─────────────────────────────────────────
    if (maxCascadeLimit > 0) {
      // Check against the maximum cascade limit configured across handlers
      for (Integer i = 0; i < handlers.size(); i++) {
        TriggerHandler__mdt cfg = handlerConfigs[i];
        if (cfg.CascadeDepthLimit__c != null && cfg.CascadeDepthLimit__c > 0) {
          RecursionGuard.checkCascadeDepth(
            handlerNames[i],
            ctx,
            (Integer) cfg.CascadeDepthLimit__c
          );
        }
      }
    }

    // ── Determine records to filter ─────────────────────────────────
    List<SObject> recordsToFilter;
    Map<Id, SObject> oldMap = getOldMap();
    if (
      ctx == TriggerContext.BEFORE_DELETE ||
      ctx == TriggerContext.AFTER_DELETE
    ) {
      recordsToFilter = (getOld() != null) ? getOld() : new List<SObject>();
    } else {
      recordsToFilter = (getNew() != null) ? getNew() : new List<SObject>();
    }

    Map<String, Set<Id>> applicableRecordIds = new Map<String, Set<Id>>();
    // Index-based tracking for INSERT contexts where records have no IDs
    Map<String, Set<Integer>> applicableRecordIndices = new Map<String, Set<Integer>>();
    Boolean isInsertContext = (ctx == TriggerContext.BEFORE_INSERT ||
    ctx == TriggerContext.AFTER_INSERT);
    Set<String> skippedHandlers = new Set<String>();

    // ════════════════════════════════════════════════════════════════
    //  Phase 1: Record Filtering (IRecordFilter)
    // ════════════════════════════════════════════════════════════════
    for (Integer i = 0; i < handlers.size(); i++) {
      TriggerHandler handler = handlers[i];
      String handlerName = handlerNames[i];

      if (handler instanceof IRecordFilter) {
        IRecordFilter filter = (IRecordFilter) handler;
        Set<Id> applicable = new Set<Id>();
        Set<Integer> applicableIndices = new Set<Integer>();

        for (Integer r = 0; r < recordsToFilter.size(); r++) {
          SObject record = recordsToFilter[r];
          SObject newRec;
          SObject oldRec;

          if (
            ctx == TriggerContext.BEFORE_DELETE ||
            ctx == TriggerContext.AFTER_DELETE
          ) {
            newRec = null;
            oldRec = record;
          } else if (
            ctx == TriggerContext.BEFORE_INSERT ||
            ctx == TriggerContext.AFTER_INSERT ||
            ctx == TriggerContext.AFTER_UNDELETE
          ) {
            newRec = record;
            oldRec = null;
          } else {
            newRec = record;
            oldRec = (oldMap != null) ? oldMap.get(record.Id) : null;
          }

          try {
            if (filter.isApplicable(newRec, oldRec, ctx)) {
              if (isInsertContext) {
                applicableIndices.add(r);
              } else {
                applicable.add(record.Id);
              }
            }
          } catch (NullPointerException npe) {
            throw new TriggerFrameworkException(
              'NullPointerException in isApplicable() for handler ' +
                handlerName +
                ': ' +
                npe.getMessage(),
              handlerName,
              ctx,
              'record-filtering'
            );
          }
        }

        if (isInsertContext) {
          if (applicableIndices.isEmpty()) {
            skippedHandlers.add(handlerName);
          } else {
            applicableRecordIndices.put(handlerName, applicableIndices);
          }
        } else {
          if (applicable.isEmpty()) {
            skippedHandlers.add(handlerName);
          } else {
            applicableRecordIds.put(handlerName, applicable);
          }
        }
      }
    }

    // ════════════════════════════════════════════════════════════════
    //  Phase 2: Query Declaration + Aggregation + Execution
    // ════════════════════════════════════════════════════════════════
    QueryAggregator aggregator = new QueryAggregator();
    QueryResultCache cache = new QueryResultCache();
    Set<String> querySkippedHandlers = new Set<String>();
    // Cache declareQueryNeeds() results to avoid double-invocation on circuit breaker re-aggregation
    Map<String, List<QueryRequest>> queryRequestCache = new Map<String, List<QueryRequest>>();
    // F-QB10: Cache applicable records computed in Phase 2 for reuse in Phase 3,
    // avoiding redundant getApplicableRecords() calls for IQueryAware handlers.
    Map<String, List<SObject>> applicableRecordsCache = new Map<String, List<SObject>>();

    for (Integer i = 0; i < handlers.size(); i++) {
      TriggerHandler handler = handlers[i];
      String handlerName = handlerNames[i];

      if (skippedHandlers.contains(handlerName)) {
        continue;
      }

      if (handler instanceof IQueryAware) {
        IQueryAware queryAware = (IQueryAware) handler;

        List<SObject> applicable = getApplicableRecords(
          handlerName,
          applicableRecordIds,
          applicableRecordIndices,
          recordsToFilter,
          isInsertContext
        );
        // F-QB10: Cache for Phase 3 reuse
        applicableRecordsCache.put(handlerName, applicable);

        List<QueryRequest> requests = queryAware.declareQueryNeeds(
          applicable,
          oldMap
        );
        if (requests != null && !requests.isEmpty()) {
          queryRequestCache.put(handlerName, requests);
          aggregator.addRequests(requests);
        }
      }
    }

    // Circuit breaker checks
    List<QueryRequest> mergedRequests = aggregator.getMergedRequests();
    // F51: Clamp to 0 — arithmetic can go negative at deep cascade (e.g., depth=10
    // with defaults produces 100-10-100=-10, causing unconditional circuit breaker)
    Integer soqlThreshold = Math.max(
      0,
      Limits.getLimitQueries() -
        soqlReserve -
        (RecursionGuard.getCascadeDepth() * soqlPerCascadeLevel)
    );
    Integer currentQueries = Limits.getQueries();

    if (
      !mergedRequests.isEmpty() &&
      currentQueries + mergedRequests.size() > soqlThreshold
    ) {
      // F-L1: SOQL circuit breaker — skip non-critical handlers first, then
      // re-check whether critical handlers' queries alone fit within budget.
      for (Integer i = 0; i < handlers.size(); i++) {
        TriggerHandler handler = handlers[i];
        String handlerName = handlerNames[i];
        TriggerHandler__mdt cfg = handlerConfigs[i];

        if (handler instanceof IQueryAware && !cfg.IsCritical__c) {
          querySkippedHandlers.add(handlerName);
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: SOQL circuit breaker tripped — skipping non-critical IQueryAware handler ' +
            handlerName
          );
        }
      }

      // Re-aggregate critical-only queries and check fit. Run this re-check
      // unconditionally — even when no non-critical handler was shed (e.g.
      // when ALL IQueryAware handlers are already critical), the original
      // mergedRequests still exceeds the threshold and the framework must
      // throw rather than silently let the critical query exhaust SOQL.
      {
        QueryAggregator criticalAggregator = new QueryAggregator();
        for (String hn : queryRequestCache.keySet()) {
          if (
            !skippedHandlers.contains(hn) && !querySkippedHandlers.contains(hn)
          ) {
            criticalAggregator.addRequests(queryRequestCache.get(hn));
          }
        }
        List<QueryRequest> criticalMerged = criticalAggregator.getMergedRequests();
        // F30: Refresh query count — previous capture may be stale after declaration phase
        currentQueries = Limits.getQueries();
        if (currentQueries + criticalMerged.size() > soqlThreshold) {
          // Critical queries alone still exceed budget — find the first critical handler to name in error
          String criticalName = 'unknown';
          for (Integer i = 0; i < handlers.size(); i++) {
            if (
              handlers[i] instanceof IQueryAware &&
              handlerConfigs[i].IsCritical__c
            ) {
              criticalName = handlerNames[i];
              break;
            }
          }
          // F54: Throw SoqlBudgetException (not generic TriggerFrameworkException)
          // so callers can catch the specific documented exception type
          throw new SoqlBudgetException(
            'SOQL circuit breaker tripped — even after skipping non-critical handlers, ' +
              'critical queries (' +
              criticalMerged.size() +
              ') exceed budget. ' +
              'Queries used: ' +
              currentQueries +
              ', threshold: ' +
              soqlThreshold,
            criticalName,
            ctx,
            currentQueries,
            soqlThreshold
          );
        }
        // Critical queries fit — update mergedRequests to use critical-only set
        mergedRequests = criticalMerged;
      }
    }

    // Heap circuit breaker
    // F-LA3: This breaker may re-add handlers already shed by the SOQL breaker above.
    // querySkippedHandlers is a Set, so duplicates are harmless. Pass 2 correctly
    // filters out already-skipped handlers when checking for critical-only breach.
    // F49: Two-pass approach — shed ALL non-critical handlers first, then check
    // if critical handlers alone still exceed threshold. Previous code threw
    // immediately on the first critical handler without finishing shedding.
    // F-PS2: Configurable fraction. F-HD1: Test-visible override for unit testing.
    Integer heapThreshold = (heapThresholdOverride != null)
      ? heapThresholdOverride
      : (Integer) (Limits.getLimitHeapSize() * heapThresholdFraction);
    if (!mergedRequests.isEmpty() && Limits.getHeapSize() > heapThreshold) {
      // Pass 1: shed all non-critical IQueryAware handlers
      for (Integer i = 0; i < handlers.size(); i++) {
        if (
          handlers[i] instanceof IQueryAware && !handlerConfigs[i].IsCritical__c
        ) {
          querySkippedHandlers.add(handlerNames[i]);
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: Heap circuit breaker tripped — skipping non-critical IQueryAware handler ' +
            handlerNames[i]
          );
        }
      }
      // Pass 2: if critical IQueryAware handlers exist, they cannot be shed — throw
      // F62: Skip handlers already filtered out or query-skipped — they won't execute queries
      for (Integer i = 0; i < handlers.size(); i++) {
        if (
          handlers[i] instanceof IQueryAware &&
          handlerConfigs[i].IsCritical__c &&
          !skippedHandlers.contains(handlerNames[i]) &&
          !querySkippedHandlers.contains(handlerNames[i])
        ) {
          throw new TriggerFrameworkException(
            'Heap circuit breaker tripped but handler ' +
              handlerNames[i] +
              ' is critical and cannot be skipped. ' +
              'Heap used: ' +
              Limits.getHeapSize() +
              ', threshold: ' +
              heapThreshold +
              '. Mitigations: reduce query result size via selective fields/IDs, ' +
              'move to async context for higher heap limit, or reduce handler count on this SObject.',
            handlerNames[i],
            ctx,
            'heap-circuit-breaker'
          );
        }
      }
    }

    // Execute queries (only if no circuit breaker fully tripped)
    if (!mergedRequests.isEmpty() && querySkippedHandlers.isEmpty()) {
      Map<String, List<SObject>> results = QueryExecutor.execute(
        mergedRequests
      );
      cache.populate(results, mergedRequests);
    } else if (!mergedRequests.isEmpty()) {
      // Some handlers were skipped — re-aggregate using cached declarations
      QueryAggregator filteredAggregator = new QueryAggregator();
      for (String handlerName : queryRequestCache.keySet()) {
        if (
          !skippedHandlers.contains(handlerName) &&
          !querySkippedHandlers.contains(handlerName)
        ) {
          filteredAggregator.addRequests(queryRequestCache.get(handlerName));
        }
      }
      List<QueryRequest> filteredMerged = filteredAggregator.getMergedRequests();
      if (!filteredMerged.isEmpty()) {
        Map<String, List<SObject>> results = QueryExecutor.execute(
          filteredMerged
        );
        cache.populate(results, filteredMerged);
      }
    }

    // ════════════════════════════════════════════════════════════════
    //  Phase 3: Handler Execution (single pass, Order__c)
    // ════════════════════════════════════════════════════════════════
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setBeforeTriggerContext(isBefore);
    if (isBefore && getNewMap() != null) {
      registrar.setTriggerNewMap(getNewMap());
    }

    List<String> circuitBreakerSkipped = new List<String>();

    for (Integer i = 0; i < handlers.size(); i++) {
      TriggerHandler handler = handlers[i];
      String handlerName = handlerNames[i];
      TriggerHandler__mdt config = handlerConfigs[i];

      // Skip if filtered out in Phase 1
      if (skippedHandlers.contains(handlerName)) {
        System.debug(
          LoggingLevel.INFO,
          'SALT-YASTF: Handler ' +
            handlerName +
            ' SKIPPED — zero applicable records after filtering'
        );
        continue;
      }

      // Skip if query-skipped in Phase 2
      if (querySkippedHandlers.contains(handlerName)) {
        System.debug(
          LoggingLevel.WARN,
          'SALT-YASTF: Handler ' +
            handlerName +
            ' QUERY_SKIPPED — circuit breaker'
        );
        circuitBreakerSkipped.add(handlerName);
        continue;
      }

      // ── Recursion guard ─────────────────────────────────────────
      // F48: pendingHashes collects hashes for records that passed the recursion
      // guard but have not yet been marked. Marking is deferred to after successful
      // handler execution so failed non-critical handlers don't permanently skip records.
      Map<Id, String> pendingHashes = null;
      String handlerKey = RecursionGuard.getHandlerKey(
        sObjectName,
        handlerName,
        ctx
      );

      // Check invocation limit (MaxReentrancy__c)
      // F53: Throw RecursionLimitException for critical handlers (per documented contract).
      // Non-critical handlers are silently skipped — throwing would halt the pipeline
      // for a handler the admin explicitly marked as non-essential.
      if (config.MaxReentrancy__c != null && config.MaxReentrancy__c > 0) {
        if (
          RecursionGuard.isInvocationLimitExceeded(
            handlerKey,
            (Integer) config.MaxReentrancy__c
          )
        ) {
          Integer actual = RecursionGuard.getInvocationCount(handlerKey);
          if (config.IsCritical__c) {
            throw new RecursionLimitException(
              'Handler ' +
                handlerName +
                ' exceeded MaxReentrancy limit (' +
                (Integer) config.MaxReentrancy__c +
                '). Actual invocations: ' +
                actual,
              handlerName,
              ctx,
              (Integer) config.MaxReentrancy__c,
              actual
            );
          }
          System.debug(
            LoggingLevel.INFO,
            'SALT-YASTF: Handler ' +
              handlerName +
              ' skipped — invocation limit exceeded (' +
              config.MaxReentrancy__c +
              ')'
          );
          continue;
        }
      }
      // L2-4: Field-hash recursion guard — only skip BEFORE_INSERT (no stable IDs).
      // AFTER_INSERT records have platform-assigned IDs and can be hashed.
      Boolean isBeforeInsert = (ctx == TriggerContext.BEFORE_INSERT);
      if (handler instanceof IRecursionAware && !isBeforeInsert) {
        IRecursionAware recursionAware = (IRecursionAware) handler;
        List<SObjectField> recursionFields = recursionAware.getRecursionFields();

        if (recursionFields != null && !recursionFields.isEmpty()) {
          // circuit-breaker fairness rule: Validate recursion fields belong to the trigger's SObject
          if (!recordsToFilter.isEmpty()) {
            SObjectType triggerType = recordsToFilter[0].getSObjectType();
            Map<String, SObjectField> triggerFieldMap = triggerType.getDescribe(
                SObjectDescribeOptions.DEFERRED
              )
              .fields.getMap();
            Set<SObjectField> triggerFieldSet = new Set<SObjectField>(
              triggerFieldMap.values()
            );
            for (SObjectField f : recursionFields) {
              if (!triggerFieldSet.contains(f)) {
                throw new TriggerFrameworkException(
                  'IRecursionAware.getRecursionFields() returned field ' +
                    QueryRequest.cachedFieldName(f) +
                    ' which does not belong to ' +
                    QueryRequest.cachedTypeName(triggerType) +
                    '. Recursion fields must be from the trigger SObject.',
                  handlerName,
                  ctx,
                  'recursion-field-validation'
                );
              }
            }
          }
          // Filter out already-processed records with same field hash
          Set<Id> applicable = applicableRecordIds.containsKey(handlerName)
            ? applicableRecordIds.get(handlerName)
            : null;

          // F48: Collect unprocessed records and their hashes WITHOUT marking yet.
          // Marking happens after successful handler execution to prevent permanently
          // skipping records when a non-critical handler throws on first attempt.
          Set<Id> unprocessedIds = new Set<Id>();
          pendingHashes = new Map<Id, String>();
          for (SObject record : recordsToFilter) {
            Id recordId = record.Id;
            if (applicable != null && !applicable.contains(recordId)) {
              continue;
            }

            String hash = RecursionGuard.computeFieldHash(
              record,
              recursionFields
            );
            if (
              !RecursionGuard.hasBeenProcessedWithSameFields(
                handlerKey,
                recordId,
                hash
              )
            ) {
              unprocessedIds.add(recordId);
              pendingHashes.put(recordId, hash);
            }
          }

          if (unprocessedIds.isEmpty()) {
            System.debug(
              LoggingLevel.INFO,
              'SALT-YASTF: Handler ' +
                handlerName +
                ' skipped — all records already processed with same field values'
            );
            continue;
          }

          // Update applicable record IDs to only unprocessed ones
          applicableRecordIds.put(handlerName, unprocessedIds);
          // L2-1: Invalidate Phase 2 cache so executeHandler() recomputes from narrowed set
          applicableRecordsCache.remove(handlerName);
        }
      }

      // CPU breaker check: CPU circuit breaker — skip non-critical after-trigger handlers if CPU time
      // exceeds threshold. Unlike SOQL/heap breakers (checked once before query execution),
      // CPU is checked per-handler as it accumulates during Phase 3 execution.
      if (
        Limits.getCpuTime() >
        (Integer) (Limits.getLimitCpuTime() * cpuThresholdFraction)
      ) {
        if (!config.IsCritical__c && !isBefore) {
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: CPU circuit breaker tripped — skipping non-critical handler ' +
              handlerName +
              '. CPU used: ' +
              Limits.getCpuTime() +
              'ms, threshold: ' +
              (Integer) (Limits.getLimitCpuTime() * cpuThresholdFraction) +
              'ms'
          );
          circuitBreakerSkipped.add(handlerName);
          continue;
        }
        if (config.IsCritical__c || isBefore) {
          // Critical handler or before-trigger — cannot skip, log warning
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: CPU approaching limit for critical handler ' +
              handlerName +
              '. CPU used: ' +
              Limits.getCpuTime() +
              'ms, limit: ' +
              Limits.getLimitCpuTime() +
              'ms'
          );
        }
      }

      // ── Execute handler ─────────────────────────────────────────
      registrar.setCurrentHandler(handlerName);

      if (isBefore) {
        // Before-trigger: ALL exceptions propagate
        executeHandler(
          handler,
          handlerName,
          ctx,
          isBefore,
          config,
          applicableRecordIds,
          applicableRecordIndices,
          recordsToFilter,
          oldMap,
          cache,
          registrar,
          isInsertContext,
          applicableRecordsCache
        );
        // F-L4: Only increment invocation count after successful execution
        RecursionGuard.incrementInvocationCount(handlerKey);
        // F48: Mark records as processed only after successful execution
        if (pendingHashes != null) {
          for (Id recId : pendingHashes.keySet()) {
            RecursionGuard.markProcessedWithHash(
              handlerKey,
              recId,
              pendingHashes.get(recId)
            );
          }
        }
      } else {
        if (config.IsCritical__c) {
          // After-trigger + critical: exception propagates
          executeHandler(
            handler,
            handlerName,
            ctx,
            isBefore,
            config,
            applicableRecordIds,
            applicableRecordIndices,
            recordsToFilter,
            oldMap,
            cache,
            registrar,
            isInsertContext,
            applicableRecordsCache
          );
          // F-L4: Only increment invocation count after successful execution
          RecursionGuard.incrementInvocationCount(handlerKey);
          // F48: Mark records as processed only after successful execution
          if (pendingHashes != null) {
            for (Id recId : pendingHashes.keySet()) {
              RecursionGuard.markProcessedWithHash(
                handlerKey,
                recId,
                pendingHashes.get(recId)
              );
            }
          }
        } else {
          // After-trigger + non-critical: catch, log, continue
          // F-C1: Snapshot registrar state before non-critical handler execution.
          // If the handler throws, rollback partial DML registrations to prevent
          // silent data corruption from half-completed mutations.
          Integer snapNew = registrar.getNewRecordsCount();
          Integer snapFk = registrar.getFkBindingsCount();
          Integer journalMark = registrar.getJournalMark();
          Integer snapDeleted = registrar.getDeletedRecordsCount();
          Integer snapConflicts = registrar.getConflictsCount(); // F59: snapshot conflicts for rollback
          try {
            executeHandler(
              handler,
              handlerName,
              ctx,
              isBefore,
              config,
              applicableRecordIds,
              applicableRecordIndices,
              recordsToFilter,
              oldMap,
              cache,
              registrar,
              isInsertContext,
              applicableRecordsCache
            );
            // F-L4: Only increment invocation count after successful execution
            RecursionGuard.incrementInvocationCount(handlerKey);
            // F48: Mark records as processed only after successful execution
            if (pendingHashes != null) {
              for (Id recId : pendingHashes.keySet()) {
                RecursionGuard.markProcessedWithHash(
                  handlerKey,
                  recId,
                  pendingHashes.get(recId)
                );
              }
            }
          } catch (Exception e) {
            // F-C1: Rollback partial DML registrations from failed handler
            registrar.rollbackTo(snapNew, snapFk, snapDeleted);
            registrar.rollbackToJournalMark(journalMark);
            registrar.rollbackConflictsTo(snapConflicts); // F59: rollback conflict entries from failed handler
            // F48: pendingHashes NOT marked — handler failed, records should be
            // retried on re-entry rather than permanently skipped
            System.debug(
              LoggingLevel.ERROR,
              'SALT-YASTF: Non-critical handler ' +
                handlerName +
                ' failed (DML registrations rolled back): ' +
                e.getMessage()
            );
          }
        }
      }
    }

    // F60: Evict cached query data for circuit-breaker-skipped handlers.
    // Without this, their data is never evicted (markHandlerServed never called),
    // causing a memory leak for the remainder of the transaction.
    for (String skipped : querySkippedHandlers) {
      cache.markHandlerServed(skipped);
    }

    // ════════════════════════════════════════════════════════════════
    //  Phase 4: DML Commit (after-trigger only)
    // ════════════════════════════════════════════════════════════════
    if (!isBefore && registrar.hasPendingDml()) {
      DmlExecutor.commitWork(registrar);
    }

    // ── Circuit breaker alerting ────────────────────────────────────
    if (!circuitBreakerSkipped.isEmpty()) {
      publishCircuitBreakerAlert(sObjectName, ctx, circuitBreakerSkipped);
    }

    // F9: Gate bypass warning behind telemetry — prevents false-positive log noise
    // from intentionally persistent bypasses on every trigger execution
    if (TriggerTelemetry.isEnabled() && !bypassCallers.isEmpty()) {
      for (String key : bypassCallers.keySet()) {
        System.debug(
          LoggingLevel.WARN,
          'SALT-YASTF: Active bypass for ' +
            key +
            ', set by ' +
            bypassCallers.get(key)
        );
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════
  //  Handler execution — dispatches based on interface capabilities
  // ════════════════════════════════════════════════════════════════════
  private static void executeHandler(
    TriggerHandler handler,
    String handlerName,
    TriggerContext ctx,
    Boolean isBefore,
    TriggerHandler__mdt config,
    Map<String, Set<Id>> applicableRecordIds,
    Map<String, Set<Integer>> applicableRecordIndices,
    List<SObject> recordsToFilter,
    Map<Id, SObject> oldMap,
    QueryResultCache cache,
    DmlRegistrar registrar,
    Boolean isInsertContext,
    Map<String, List<SObject>> applicableRecordsCache
  ) {
    // IQueryAware: call onDataReady() INSTEAD of standard context method
    if (handler instanceof IQueryAware) {
      IQueryAware queryAware = (IQueryAware) handler;
      // F-QB10: Reuse applicable records cached in Phase 2 if available,
      // avoiding redundant list construction in Phase 3.
      List<SObject> applicable = applicableRecordsCache.containsKey(handlerName)
        ? applicableRecordsCache.get(handlerName)
        : getApplicableRecords(
            handlerName,
            applicableRecordIds,
            applicableRecordIndices,
            recordsToFilter,
            isInsertContext
          );
      queryAware.onDataReady(applicable, oldMap, cache);

      // Cache eviction after IQueryAware handler is served
      cache.markHandlerServed(handlerName);
    } else {
      // Standard context dispatch
      dispatchToHandler(handler, ctx);
    }

    // IDmlAware: call onDmlReady() IN ADDITION to context method/onDataReady
    if (handler instanceof IDmlAware) {
      IDmlAware dmlAware = (IDmlAware) handler;
      dmlAware.onDmlReady(registrar);
    }
  }

  // ════════════════════════════════════════════════════════════════════
  //  Applicable records helper — defensive copy
  // ════════════════════════════════════════════════════════════════════
  private static List<SObject> getApplicableRecords(
    String handlerName,
    Map<String, Set<Id>> applicableRecordIds,
    Map<String, Set<Integer>> applicableRecordIndices,
    List<SObject> allRecords,
    Boolean isInsertContext
  ) {
    if (isInsertContext) {
      if (!applicableRecordIndices.containsKey(handlerName)) {
        return new List<SObject>(allRecords);
      }
      Set<Integer> indices = applicableRecordIndices.get(handlerName);
      List<SObject> result = new List<SObject>();
      for (Integer i = 0; i < allRecords.size(); i++) {
        if (indices.contains(i)) {
          result.add(allRecords[i]);
        }
      }
      return result;
    }

    if (!applicableRecordIds.containsKey(handlerName)) {
      return new List<SObject>(allRecords);
    }
    Set<Id> ids = applicableRecordIds.get(handlerName);
    List<SObject> result = new List<SObject>();
    for (SObject record : allRecords) {
      if (ids.contains(record.Id)) {
        result.add(record);
      }
    }
    return result;
  }

  // ════════════════════════════════════════════════════════════════════
  //  Circuit breaker alerting
  // ════════════════════════════════════════════════════════════════════
  private static void publishCircuitBreakerAlert(
    String sObjectName,
    TriggerContext ctx,
    List<String> skippedHandlers
  ) {
    // Publish TriggerFrameworkAlert__e if the platform event exists.
    // Uses Type.forName to avoid compile-time dependency on the PE.
    Type alertType = Type.forName('TriggerFrameworkAlert__e');
    if (alertType != null) {
      SObject alert = (SObject) alertType.newInstance();
      alert.put('SObjectType__c', sObjectName);
      // C4-2: Truncate at last comma boundary to avoid splitting handler names
      String handlerList = String.join(skippedHandlers, ',');
      if (handlerList.length() > 255) {
        Integer lastComma = handlerList.substring(0, 255).lastIndexOf(',');
        handlerList = lastComma > 0
          ? handlerList.substring(0, lastComma)
          : handlerList.left(255);
      }
      alert.put('HandlerName__c', handlerList);
      alert.put('CircuitBreakerType__c', 'soql-or-heap');
      // F-CH3: Truncate Message__c to prevent EventBus.publish() failure
      // if the composed message exceeds the platform event field length.
      alert.put(
        'Message__c',
        ('Circuit breaker skipped handlers [' +
          String.join(skippedHandlers, ', ') +
          '] on ' +
          sObjectName +
          ' ' +
          ctx.name())
          .left(255)
      );
      alert.put('Timestamp__c', Datetime.now());
      try {
        EventBus.publish(alert);
      } catch (Exception e) {
        System.debug(
          LoggingLevel.ERROR,
          'SALT-YASTF: Failed to publish circuit breaker alert: ' +
          e.getMessage()
        );
      }
    } else {
      System.debug(
        LoggingLevel.WARN,
        'SALT-YASTF: Circuit breaker skipped handlers [' +
          String.join(skippedHandlers, ', ') +
          '] on ' +
          sObjectName +
          ' ' +
          ctx.name() +
          '. TriggerFrameworkAlert__e not deployed — alert not published.'
      );
    }
  }

  // ════════════════════════════════════════════════════════════════════
  //  CMDT loading — bulk query, 1 SOQL per transaction
  // ════════════════════════════════════════════════════════════════════
  private static Boolean allHandlersLoaded = false;

  private static List<TriggerHandler__mdt> getHandlersForSObject(
    String sObjectName
  ) {
    if (mockHandlers != null && mockHandlers.containsKey(sObjectName)) {
      return mockHandlers.get(sObjectName);
    }
    if (!allHandlersLoaded) {
      List<TriggerHandler__mdt> allHandlers = [
        SELECT
          DeveloperName,
          HandlerClass__c,
          Namespace__c,
          SObjectType__c,
          Order__c,
          IsActive__c,
          BeforeInsert__c,
          BeforeUpdate__c,
          BeforeDelete__c,
          AfterInsert__c,
          AfterUpdate__c,
          AfterDelete__c,
          AfterUndelete__c,
          BypassPermission__c,
          BypassUsers__c,
          BypassProfiles__c,
          AllowBypass__c,
          MaxReentrancy__c,
          CascadeDepthLimit__c,
          IsCritical__c
        FROM TriggerHandler__mdt
        WHERE IsActive__c = TRUE
        ORDER BY SObjectType__c, Order__c ASC
      ];
      for (TriggerHandler__mdt h : allHandlers) {
        String objName = h.SObjectType__c;
        if (!handlerCache.containsKey(objName)) {
          handlerCache.put(objName, new List<TriggerHandler__mdt>());
        }
        handlerCache.get(objName).add(h);
      }
      allHandlersLoaded = true;
    }
    List<TriggerHandler__mdt> result = handlerCache.get(sObjectName);
    return result != null ? result : new List<TriggerHandler__mdt>();
  }

  // ════════════════════════════════════════════════════════════════════
  //  Handler instantiation
  // ════════════════════════════════════════════════════════════════════
  private static TriggerHandler instantiateHandler(TriggerHandler__mdt config) {
    String ns = String.isBlank(config.Namespace__c)
      ? null
      : config.Namespace__c.trim();
    // F22: Trim HandlerClass__c and strip namespace prefix if already present
    // to prevent Type.forName("ns", "ns.Class") returning null
    String handlerClass = config.HandlerClass__c;
    if (String.isBlank(handlerClass)) {
      return null;
    }
    handlerClass = handlerClass.trim();
    if (ns != null && handlerClass.startsWith(ns + '.')) {
      handlerClass = handlerClass.substringAfter('.');
    }
    Type handlerType = Type.forName(ns, handlerClass);
    if (handlerType == null) {
      return null;
    }
    Object instance = handlerType.newInstance();
    if (!(instance instanceof TriggerHandler)) {
      return null;
    }
    return (TriggerHandler) instance;
  }

  // ════════════════════════════════════════════════════════════════════
  //  Context dispatch
  // ════════════════════════════════════════════════════════════════════
  private static void dispatchToHandler(
    TriggerHandler handler,
    TriggerContext ctx
  ) {
    switch on ctx {
      when BEFORE_INSERT {
        handler.beforeInsert(getNew());
      }
      when AFTER_INSERT {
        handler.afterInsert(getNew());
      }
      when BEFORE_UPDATE {
        handler.beforeUpdate(getNew(), getOldMap());
      }
      when AFTER_UPDATE {
        handler.afterUpdate(getNew(), getOldMap());
      }
      when BEFORE_DELETE {
        handler.beforeDelete(getOldMap());
      }
      when AFTER_DELETE {
        handler.afterDelete(getOldMap());
      }
      when AFTER_UNDELETE {
        handler.afterUndelete(getNew());
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════
  //  Context enablement
  // ════════════════════════════════════════════════════════════════════
  private static Boolean isEnabledForContext(
    TriggerHandler__mdt config,
    TriggerContext ctx
  ) {
    String fieldName = TriggerContextUtil.getFieldName(ctx);
    return (Boolean) config.get(fieldName);
  }

  // ════════════════════════════════════════════════════════════════════
  //  SObject name resolution
  // ════════════════════════════════════════════════════════════════════
  // F-QB5: Use QB-3 cached type name to avoid redundant describe on every trigger entry
  private static String getSObjectName() {
    List<SObject> newRecs = getNew();
    List<SObject> oldRecs = getOld();
    if (newRecs != null && !newRecs.isEmpty()) {
      return QueryRequest.cachedTypeName(newRecs[0].getSObjectType());
    }
    if (oldRecs != null && !oldRecs.isEmpty()) {
      return QueryRequest.cachedTypeName(oldRecs[0].getSObjectType());
    }
    return '';
  }

  // ════════════════════════════════════════════════════════════════════
  //  Bypass API — Type-safe + Sealed
  // ════════════════════════════════════════════════════════════════════

  // F8: Namespace-aware handler type name resolution — mirrors getHandlerName() logic
  // to ensure bypass keys match handler names in managed package contexts
  private static String resolveHandlerTypeName(Type handlerType) {
    String typeName = handlerType.getName();
    String frameworkName = TriggerHandler.class.getName();
    if (frameworkName.contains('.')) {
      String namespace = frameworkName.substringBefore('.');
      if (!typeName.contains('.')) {
        return namespace + '.' + typeName;
      }
    }
    return typeName;
  }

  /** Global bypass — handler skipped in every context on every SObject. */
  public static void bypass(Type handlerType) {
    String typeName = resolveHandlerTypeName(handlerType);
    if (!bypasses.containsKey('global')) {
      bypasses.put('global', new Set<String>());
    }
    bypasses.get('global').add(typeName);
    bypassCallers.put(typeName, getCallerInfo());
    System.debug(
      LoggingLevel.WARN,
      'SALT-YASTF: Bypass set for ' + typeName + ' by ' + getCallerInfo()
    );
  }

  /** SObject-scoped bypass — handler skipped only on the given SObject. */
  public static void bypass(Type handlerType, SObjectType sObjectType) {
    String typeName = resolveHandlerTypeName(handlerType);
    // F-QB9: Use QB-3 cached type name to avoid redundant describe per bypass call
    String key = typeName + '|' + QueryRequest.cachedTypeName(sObjectType);
    if (!bypasses.containsKey('sobject')) {
      bypasses.put('sobject', new Set<String>());
    }
    bypasses.get('sobject').add(key);
    bypassCallers.put(key, getCallerInfo());
    System.debug(
      LoggingLevel.WARN,
      'SALT-YASTF: Bypass set for ' +
        typeName +
        ' on ' +
        sObjectType +
        ' by ' +
        getCallerInfo()
    );
  }

  /** Context-scoped bypass — handler skipped only for a specific SObject + context. */
  public static void bypass(
    Type handlerType,
    SObjectType sObjectType,
    TriggerContext ctx
  ) {
    String typeName = resolveHandlerTypeName(handlerType);
    // F-QB9: Use QB-3 cached type name
    String key =
      typeName +
      '|' +
      QueryRequest.cachedTypeName(sObjectType) +
      '|' +
      ctx.name();
    if (!bypasses.containsKey('context')) {
      bypasses.put('context', new Set<String>());
    }
    bypasses.get('context').add(key);
    bypassCallers.put(key, getCallerInfo());
    System.debug(
      LoggingLevel.WARN,
      'SALT-YASTF: Bypass set for ' +
        typeName +
        ' on ' +
        sObjectType +
        ' context ' +
        ctx +
        ' by ' +
        getCallerInfo()
    );
  }

  /** Auto-clearing bypass — handler skipped for the next DML event only. */
  public static void bypassForNextDmlEvent(Type handlerType) {
    String typeName = resolveHandlerTypeName(handlerType);
    nextDmlEventBypasses.add(typeName);
    System.debug(
      LoggingLevel.WARN,
      'SALT-YASTF: Next-DML-event bypass set for ' +
        typeName +
        ' by ' +
        getCallerInfo()
    );
  }

  /** Remove all bypass scopes for the given handler type. */
  public static void clearBypass(Type handlerType) {
    String typeName = resolveHandlerTypeName(handlerType);
    for (String scope : bypasses.keySet()) {
      Set<String> scopeSet = bypasses.get(scope);
      List<String> toRemove = new List<String>();
      for (String key : scopeSet) {
        if (key == typeName || key.startsWith(typeName + '|')) {
          toRemove.add(key);
        }
      }
      scopeSet.removeAll(new Set<String>(toRemove));
    }
    nextDmlEventBypasses.remove(typeName);
    List<String> callerKeysToRemove = new List<String>();
    for (String key : bypassCallers.keySet()) {
      if (key == typeName || key.startsWith(typeName + '|')) {
        callerKeysToRemove.add(key);
      }
    }
    for (String key : callerKeysToRemove) {
      bypassCallers.remove(key);
    }
  }

  /** Remove every bypass currently registered. */
  public static void clearAllBypasses() {
    bypasses.clear();
    nextDmlEventBypasses.clear();
    bypassCallers.clear();
  }

  // ── Bypass evaluation (most-specific-first) ─────────────────────────
  private static Boolean isBypassed(
    TriggerHandler__mdt config,
    String handlerName,
    String sObjectName,
    TriggerContext ctx
  ) {
    // AllowBypass__c seal — when false the handler CANNOT be bypassed
    if (config.AllowBypass__c == false) {
      return false;
    }

    // BypassPermission__c (Custom Permission)
    if (String.isNotBlank(config.BypassPermission__c)) {
      if (FeatureManagement.checkPermission(config.BypassPermission__c)) {
        return true;
      }
    }

    // F-BP1: BypassUsers__c (comma-separated User Ids) — trim entries,
    // skip blanks, normalize to 18-char IDs so 15-char and 18-char forms match.
    if (String.isNotBlank(config.BypassUsers__c)) {
      Set<String> userIds = new Set<String>();
      for (String entry : config.BypassUsers__c.split(',')) {
        String trimmed = entry.trim();
        if (String.isBlank(trimmed)) {
          continue;
        }
        try {
          userIds.add(String.valueOf((Id) trimmed));
        } catch (Exception e) {
          // F-BP1: skip malformed ID rather than breaking the bypass check
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: Invalid ID in BypassUsers__c: ' + trimmed
          );
        }
      }
      if (userIds.contains(String.valueOf(UserInfo.getUserId()))) {
        return true;
      }
    }

    // F-BP1: BypassProfiles__c (comma-separated Profile Ids) — trim entries,
    // skip blanks, normalize to 18-char IDs so 15-char and 18-char forms match.
    if (String.isNotBlank(config.BypassProfiles__c)) {
      Set<String> profileIds = new Set<String>();
      for (String entry : config.BypassProfiles__c.split(',')) {
        String trimmed = entry.trim();
        if (String.isBlank(trimmed)) {
          continue;
        }
        try {
          profileIds.add(String.valueOf((Id) trimmed));
        } catch (Exception e) {
          // F-BP1: skip malformed ID rather than breaking the bypass check
          System.debug(
            LoggingLevel.WARN,
            'SALT-YASTF: Invalid ID in BypassProfiles__c: ' + trimmed
          );
        }
      }
      if (profileIds.contains(String.valueOf(UserInfo.getProfileId()))) {
        return true;
      }
    }

    // Programmatic bypasses — most specific first
    // Context-scoped
    if (bypasses.containsKey('context')) {
      String contextKey = handlerName + '|' + sObjectName + '|' + ctx.name();
      if (bypasses.get('context').contains(contextKey)) {
        return true;
      }
    }

    // SObject-scoped
    if (bypasses.containsKey('sobject')) {
      String sobjectKey = handlerName + '|' + sObjectName;
      if (bypasses.get('sobject').contains(sobjectKey)) {
        return true;
      }
    }

    // Global — check both runtime name and config-registered name
    // (inner classes return short name from String.valueOf() but Type.getName()
    // returns the outer-qualified name)
    if (bypasses.containsKey('global')) {
      Set<String> globalBypasses = bypasses.get('global');
      if (
        globalBypasses.contains(handlerName) ||
        globalBypasses.contains(config.HandlerClass__c)
      ) {
        return true;
      }
    }

    // Next-DML-event — same dual check
    if (
      nextDmlEventBypasses.contains(handlerName) ||
      nextDmlEventBypasses.contains(config.HandlerClass__c)
    ) {
      return true;
    }

    return false;
  }

  // ── Caller info for bypass audit trail ───────────────────────────────
  private static String getCallerInfo() {
    String stackTrace = new DmlException().getStackTraceString();
    List<String> lines = stackTrace.split('\n');
    // Skip this method + the calling bypass method
    if (lines.size() > 2) {
      return lines[2].trim();
    }
    return 'unknown';
  }

  // ── DML reserve configuration ──────────────────────────────────────
  public static void setDmlReserve(Integer reserve) {
    DmlExecutor.setDmlReserve(reserve);
  }

  // ── SOQL reserve configuration ──────────────────────────────────────
  public static void setSoqlReserve(Integer reserve) {
    soqlReserve = reserve;
  }

  public static void setSoqlReservePerCascadeLevel(Integer reserve) {
    soqlPerCascadeLevel = reserve;
  }

  // F-PS2: Configurable heap threshold fraction (default 0.75)
  public static void setHeapThresholdFraction(Decimal fraction) {
    heapThresholdFraction = fraction;
  }

  // CPU breaker check: Configurable CPU threshold fraction (default 0.75)
  public static void setCpuThresholdFraction(Decimal fraction) {
    cpuThresholdFraction = fraction;
  }

  // ── Test isolation — resets all static state ────────────────────────
  // F27: Comprehensive reset — chains all static state resets for test isolation
  @TestVisible
  private static void resetAll() {
    clearAllBypasses();
    allHandlersLoaded = false;
    handlerCache.clear();
    mockHandlers = null;
    soqlReserve = 10;
    soqlPerCascadeLevel = 10;
    heapThresholdFraction = 0.75;
    heapThresholdOverride = null;
    cpuThresholdFraction = 0.75;
    ctxNew = null;
    ctxOld = null;
    ctxNewMap = null;
    ctxOldMap = null;
    RecursionGuard.reset();
    TriggerHandler.reset();
    QueryRequest.resetCaches();
    DmlExecutor.resetCache();
    QueryExecutor.resetState();
    RecordTypeIs.resetCache();
    TriggerTelemetry.reset();
  }
}
