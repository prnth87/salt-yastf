public inherited sharing class DmlExecutor {
  // QB-2: Cache schema-derived FK edges per SObjectType to avoid repeated
  // describe calls across multiple commitWork invocations in the same transaction.
  private static Map<SObjectType, Set<SObjectType>> fkEdgeCache = new Map<SObjectType, Set<SObjectType>>();

  private static Integer dmlReserve = 10;

  public static void setDmlReserve(Integer r) {
    dmlReserve = r;
  }

  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void resetCache() {
    fkEdgeCache.clear();
    dmlReserve = 10;
  }

  // cross-SObjectType DML separation rule+F-CH1: Known Salesforce Setup objects that cannot be mixed with non-Setup
  // DML in the same transaction. Expanded from 8 to 17 types per Salesforce docs.
  // Not exhaustive — new Setup objects may be added in future platform releases.
  private static final Set<String> SETUP_OBJECTS = new Set<String>{
    'User',
    'Group',
    'GroupMember',
    'PermissionSet',
    'PermissionSetAssignment',
    'QueueSobject',
    'PermissionSetLicense',
    'PermissionSetLicenseAssign',
    'UserRole',
    'Territory2',
    'Territory2Model',
    'UserPackageLicense',
    'CustomPermission',
    'SetupEntityAccess',
    'EmailServicesAddress',
    'BrandTemplate',
    'ConnectedApplication'
  };

  public static void commitWork(DmlRegistrar registrar) {
    if (!registrar.hasPendingDml()) {
      return;
    }

    // Collect all SObjectTypes once for checkMixedDml and getTopologicalOrder
    Set<SObjectType> allTypes = collectAllTypes(registrar);

    // Mixed DML guard runs FIRST — only needs type names, not dependency order.
    // Must precede getTopologicalOrder() because mutual FK references between
    // Setup and non-Setup objects (e.g., Account.OwnerId->User, User.AccountId->Account)
    // can cause CyclicDependencyException, masking the mixed DML error.
    checkMixedDml(allTypes, registrar);

    // DML statement budget guard: count required DML statements and check headroom
    // before acquiring the savepoint or computing topological order.
    checkDmlBudget(registrar);

    // Resolve dependencies and determine order
    List<SObjectType> orderedTypes = getTopologicalOrder(allTypes, registrar);

    Savepoint sp = Database.setSavepoint();

    try {
      // Group records by SObjectType
      Map<SObjectType, List<SObject>> newByType = groupByType(
        registrar.getNewRecords()
      );
      Map<SObjectType, List<SObject>> dirtyByType = groupDirtyByType(
        registrar.getDirtyRecords()
      );
      Map<SObjectType, List<SObject>> deletedByType = groupByType(
        registrar.getDeletedRecords()
      );

      Boolean useAllOrNone = registrar.getAllOrNone();

      // Execute DML in dependency order
      // 1. Inserts (parents before children per topological order)
      for (SObjectType sObjType : orderedTypes) {
        if (newByType.containsKey(sObjType)) {
          // deferred fix: Resolve FK bindings and skip children whose parent insert failed.
          // When allOrNone=false, a failed parent leaves parentRecord.Id as null.
          // Without this guard, children would be inserted with null FK — silent
          // data corruption on nullable FK fields. Cascading to grandchildren is
          // handled naturally: if B is skipped, B has no ID, so C's binding to B
          // fails on the next iteration.
          List<ForeignKeyBinding> typeBindings = registrar.getFkBindingsForType(sObjType);
          Set<SObject> skipRecords = new Set<SObject>();
          for (ForeignKeyBinding binding : typeBindings) {
            if (!binding.resolve()) {
              if (!useAllOrNone) {
                skipRecords.add(binding.childRecord);
              }
            }
          }
          List<SObject> toInsert = newByType.get(sObjType);
          if (!skipRecords.isEmpty()) {
            List<SObject> filtered = new List<SObject>();
            for (SObject rec : toInsert) {
              if (!skipRecords.contains(rec)) {
                filtered.add(rec);
              }
            }
            toInsert = filtered;
            // F-QB8: Use QB-3 cached type name in skip-records log
            System.debug(
              LoggingLevel.WARN,
              'SALT-YASTF: Skipped ' +
                skipRecords.size() +
                ' ' +
                QueryRequest.cachedTypeName(sObjType) +
                ' records due to unresolved FK bindings (parent insert failed)'
            );
          }
          if (!toInsert.isEmpty()) {
            DmlOperation op = DmlOperation.forInsert(toInsert)
              .allOrNone(useAllOrNone)
              .execute();
            if (!op.isFullSuccess() && !useAllOrNone) {
              logPartialFailure(op, registrar);
            }
          }
        }
      }

      // 2. Updates
      for (SObjectType sObjType : orderedTypes) {
        if (dirtyByType.containsKey(sObjType)) {
          DmlOperation op = DmlOperation.forUpdate(dirtyByType.get(sObjType))
            .allOrNone(useAllOrNone)
            .execute();
          if (!op.isFullSuccess() && !useAllOrNone) {
            logPartialFailure(op, registrar);
          }
        }
      }

      // 3. Deletes (reverse order — children before parents, direct backward iteration)
      for (Integer i = orderedTypes.size() - 1; i >= 0; i--) {
        SObjectType sObjType = orderedTypes[i];
        if (deletedByType.containsKey(sObjType)) {
          DmlOperation op = DmlOperation.forDelete(deletedByType.get(sObjType))
            .allOrNone(useAllOrNone)
            .execute();
          if (!op.isFullSuccess() && !useAllOrNone) {
            logPartialFailure(op, registrar);
          }
        }
      }
    } catch (DmlException e) {
      Database.rollback(sp);
      // C4-1: Null out IDs on new records after rollback — platform assigned IDs
      // that were reversed by the rollback, preventing stale ID references
      for (SObject rec : registrar.getNewRecords()) {
        rec.Id = null;
      }

      // Check for UNABLE_TO_LOCK_ROW
      if (e.getMessage().contains('UNABLE_TO_LOCK_ROW')) {
        DmlCoordinationException lockErr = new DmlCoordinationException(
          'Record lock contention detected. This is a transient error, not a handler fault. ' +
          e.getMessage(),
          'DmlExecutor',
          null,
          buildProvenanceMessage(registrar.getFieldProvenance())
        );
        lockErr.initCause(e);
        throw lockErr;
      }

      // F-C2: Chain original DmlException to preserve stack trace
      DmlCoordinationException dmlErr = new DmlCoordinationException(
        'DML failed: ' + e.getMessage(),
        'DmlExecutor',
        null,
        buildProvenanceMessage(registrar.getFieldProvenance())
      );
      dmlErr.initCause(e);
      throw dmlErr;
    } catch (Exception e) {
      Database.rollback(sp);
      // C4-1: Null out IDs on new records after rollback — platform assigned IDs
      // that were reversed by the rollback, preventing stale ID references
      for (SObject rec : registrar.getNewRecords()) {
        rec.Id = null;
      }
      DmlCoordinationException wrapped = new DmlCoordinationException(
        'Unexpected error during DML commit: ' + e.getMessage(),
        'DmlExecutor',
        null,
        buildProvenanceMessage(registrar.getFieldProvenance())
      );
      wrapped.initCause(e);
      throw wrapped;
    }
  }

  private static Set<SObjectType> collectAllTypes(DmlRegistrar registrar) {
    Set<SObjectType> allTypes = new Set<SObjectType>();
    for (SObject rec : registrar.getNewRecords()) {
      allTypes.add(rec.getSObjectType());
    }
    for (SObject rec : registrar.getDirtyRecords().values()) {
      allTypes.add(rec.getSObjectType());
    }
    for (SObject rec : registrar.getDeletedRecords()) {
      allTypes.add(rec.getSObjectType());
    }
    return allTypes;
  }

  // F50+cross-SObjectType DML separation rule: Mixed DML guard extracted from commitWork() so it runs before
  // getTopologicalOrder(). Uses pre-collected allTypes set to avoid redundant
  // iteration over registrar records.
  private static void checkMixedDml(Set<SObjectType> allTypes, DmlRegistrar registrar) {
    Boolean hasSetup = false;
    Boolean hasNonSetup = false;
    List<String> setupNames = new List<String>();
    List<String> nonSetupNames = new List<String>();
    for (SObjectType t : allTypes) {
      // F-QB6: Use QB-3 cached type name to avoid redundant describe calls
      String typeName = QueryRequest.cachedTypeName(t);
      if (SETUP_OBJECTS.contains(typeName)) {
        hasSetup = true;
        setupNames.add(typeName);
      } else {
        hasNonSetup = true;
        nonSetupNames.add(typeName);
      }
    }
    if (hasSetup && hasNonSetup) {
      throw new DmlCoordinationException(
        'Mixed DML detected: cannot mix Setup objects (' +
          String.join(setupNames, ', ') +
          ') with non-Setup objects (' +
          String.join(nonSetupNames, ', ') +
          ') in the same transaction. Separate Setup DML into @future or Queueable.',
        'DmlExecutor',
        null,
        buildProvenanceMessage(registrar.getFieldProvenance())
      );
    }
  }

  // DML statement budget guard: ensures sufficient headroom before starting commit.
  // Counts 1 (savepoint) + distinct types across new/dirty/deleted records.
  private static void checkDmlBudget(DmlRegistrar registrar) {
    Set<SObjectType> newTypes = new Set<SObjectType>();
    for (SObject rec : registrar.getNewRecords()) {
      newTypes.add(rec.getSObjectType());
    }
    Set<SObjectType> dirtyTypes = new Set<SObjectType>();
    for (SObject rec : registrar.getDirtyRecords().values()) {
      dirtyTypes.add(rec.getSObjectType());
    }
    Set<SObjectType> deletedTypes = new Set<SObjectType>();
    for (SObject rec : registrar.getDeletedRecords()) {
      deletedTypes.add(rec.getSObjectType());
    }

    Integer requiredDml =
      1 +
      newTypes.size() +
      dirtyTypes.size() +
      deletedTypes.size();
    Integer limitDml = Limits.getLimitDmlStatements();
    Integer usedDml = Limits.getDmlStatements();

    if (usedDml + requiredDml > limitDml - dmlReserve) {
      throw new DmlCoordinationException(
        'DML budget exhausted: need ' +
          requiredDml +
          ' statements but only ' +
          (limitDml -
          dmlReserve -
          usedDml) +
          ' available (used=' +
          usedDml +
          ', limit=' +
          limitDml +
          ', reserve=' +
          dmlReserve +
          ')',
        'DmlExecutor',
        null,
        buildProvenanceMessage(registrar.getFieldProvenance())
      );
    }
  }

  // Topological sort using Kahn's algorithm
  private static List<SObjectType> getTopologicalOrder(Set<SObjectType> allTypes, DmlRegistrar registrar) {
    // Build dependency map: source depends on target (target must come first)
    Map<SObjectType, Set<SObjectType>> dependencies = new Map<SObjectType, Set<SObjectType>>();

    // Initialize
    for (SObjectType t : allTypes) {
      dependencies.put(t, new Set<SObjectType>());
    }

    // Add declared dependencies
    Map<SObjectType, Set<SObjectType>> declared = registrar.getDeclaredDependencies();
    for (SObjectType source : declared.keySet()) {
      if (dependencies.containsKey(source)) {
        for (SObjectType target : declared.get(source)) {
          if (allTypes.contains(target)) {
            dependencies.get(source).add(target);
          }
        }
      }
    }

    // QB-2: Add schema-derived dependencies using cached FK edges.
    // Cache avoids redundant describe calls when commitWork runs multiple
    // times in one transaction (e.g. cascading triggers).
    for (SObjectType t : allTypes) {
      Set<SObjectType> cachedRefs = fkEdgeCache.get(t);
      if (cachedRefs == null) {
        cachedRefs = new Set<SObjectType>();
        // fields.getMap() requires field metadata — DEFERRED would be immediately
        // defeated. fkEdgeCache ensures this runs once per type per transaction.
        DescribeSObjectResult describe = t.getDescribe();
        Map<String, SObjectField> fieldsMap = describe.fields.getMap();
        for (SObjectField field : fieldsMap.values()) {
          DescribeFieldResult dfr = field.getDescribe();
          if (dfr.getType() == Schema.DisplayType.REFERENCE) {
            cachedRefs.addAll(dfr.getReferenceTo());
          }
        }
        fkEdgeCache.put(t, cachedRefs);
      }
      for (SObjectType refType : cachedRefs) {
        if (allTypes.contains(refType) && refType != t) {
          dependencies.get(t).add(refType);
        }
      }
    }

    // F-P1: Build reverse adjacency map (parent -> set of dependents) for O(V+E)
    // Kahn's traversal. Without this, the inner loop iterated all nodes per dequeue.
    Map<SObjectType, Set<SObjectType>> dependents = new Map<SObjectType, Set<SObjectType>>();
    for (SObjectType t : allTypes) {
      dependents.put(t, new Set<SObjectType>());
    }
    for (SObjectType child : allTypes) {
      for (SObjectType parent : dependencies.get(child)) {
        dependents.get(parent).add(child);
      }
    }

    // Kahn's algorithm
    // In-degree = number of dependencies a node has (nodes it must wait for)
    Map<SObjectType, Integer> inDegree = new Map<SObjectType, Integer>();
    for (SObjectType t : allTypes) {
      inDegree.put(t, dependencies.get(t).size());
    }

    // Queue: nodes with in-degree 0 (no dependencies - they go first)
    List<SObjectType> queue = new List<SObjectType>();
    for (SObjectType t : allTypes) {
      if (inDegree.get(t) == 0) {
        queue.add(t);
      }
    }

    // F23+F-P1: Index pointer avoids O(n) shift on dequeue. Reverse adjacency
    // map (dependents) avoids O(V) scan per dequeue — true O(V+E) Kahn's.
    List<SObjectType> sorted = new List<SObjectType>();
    Integer queueIdx = 0;
    while (queueIdx < queue.size()) {
      SObjectType current = queue[queueIdx];
      queueIdx++;
      sorted.add(current);

      // For each node that depends on current, reduce in-degree
      for (SObjectType dependent : dependents.get(current)) {
        Integer deg = inDegree.get(dependent) - 1;
        inDegree.put(dependent, deg);
        if (deg == 0) {
          queue.add(dependent);
        }
      }
    }

    // F34: Cycle detection — use Set for O(1) lookup instead of List.contains() O(n)
    if (sorted.size() != allTypes.size()) {
      Set<SObjectType> sortedSet = new Set<SObjectType>(sorted);
      // F-CH2: Use QB-3 cached type names in cycle detection error path
      List<String> cycleTypes = new List<String>();
      for (SObjectType t : allTypes) {
        if (!sortedSet.contains(t)) {
          cycleTypes.add(QueryRequest.cachedTypeName(t));
        }
      }
      throw new CyclicDependencyException(
        'Circular dependency detected in DML ordering: ' +
        String.join(cycleTypes, ', '),
        'DmlExecutor',
        null,
        cycleTypes
      );
    }

    return sorted;
  }

  private static Map<SObjectType, List<SObject>> groupByType(
    List<SObject> records
  ) {
    Map<SObjectType, List<SObject>> grouped = new Map<SObjectType, List<SObject>>();
    for (SObject rec : records) {
      SObjectType t = rec.getSObjectType();
      if (!grouped.containsKey(t)) {
        grouped.put(t, new List<SObject>());
      }
      grouped.get(t).add(rec);
    }
    return grouped;
  }

  private static Map<SObjectType, List<SObject>> groupDirtyByType(
    Map<Id, SObject> dirtyMap
  ) {
    Map<SObjectType, List<SObject>> grouped = new Map<SObjectType, List<SObject>>();
    for (SObject rec : dirtyMap.values()) {
      SObjectType t = rec.getSObjectType();
      if (!grouped.containsKey(t)) {
        grouped.put(t, new List<SObject>());
      }
      grouped.get(t).add(rec);
    }
    return grouped;
  }

  private static String buildProvenanceMessage(
    Map<Id, Map<String, String>> provenance
  ) {
    List<String> parts = new List<String>();
    for (Id recordId : provenance.keySet()) {
      Map<String, String> fields = provenance.get(recordId);
      for (String fieldName : fields.keySet()) {
        parts.add(
          'field ' +
            fieldName +
            ' on ' +
            recordId +
            ' set by ' +
            fields.get(fieldName)
        );
      }
    }
    return String.join(parts, '; ');
  }

  private static void logPartialFailure(
    DmlOperation op,
    DmlRegistrar registrar
  ) {
    Map<Id, Map<String, String>> provenance = registrar.getFieldProvenance();
    for (DmlOperation.DmlError err : op.getErrors()) {
      String prov = 'no provenance data';
      if (err.recordId != null && provenance.containsKey(err.recordId)) {
        Map<String, String> fields = provenance.get(err.recordId);
        List<String> parts = new List<String>();
        for (String fieldName : fields.keySet()) {
          parts.add(fieldName + ' set by ' + fields.get(fieldName));
        }
        prov = String.join(parts, '; ');
      }
      // F-DE1: Include listIndex in log when recordId is null (e.g. failed inserts)
      // so the failing record can be correlated with the original DML list position.
      String recordRef = err.recordId != null
        ? String.valueOf(err.recordId)
        : 'listIndex=' + err.listIndex;
      System.debug(
        LoggingLevel.ERROR,
        'SALT-YASTF Partial DML failure on ' +
          recordRef +
          ': ' +
          err.message +
          ' | Provenance: ' +
          prov
      );
    }
  }
}
