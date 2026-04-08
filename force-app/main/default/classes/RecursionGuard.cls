public inherited sharing class RecursionGuard {
  // Field-hash storage: handlerKey -> (recordId -> fieldHash)
  private static Map<String, Map<Id, String>> fieldHashes = new Map<String, Map<Id, String>>();

  // Invocation counters: handlerKey -> invocation count
  private static Map<String, Integer> invocationCounters = new Map<String, Integer>();

  // Cascade depth
  private static Integer cascadeDepth = 0;

  // SObject types at each cascade level (for pruning)
  private static Map<Integer, Set<String>> cascadeSObjectTypes = new Map<Integer, Set<String>>();

  // Generate a handler key including SObjectType for pruning support
  public static String getHandlerKey(
    String sObjectName,
    String handlerName,
    TriggerContext ctx
  ) {
    return sObjectName + ':' + handlerName + '|' + ctx.name();
  }

  // --- Field Hash Methods ---

  // Compute field hash for a record based on declared fields
  public static String computeFieldHash(
    SObject record,
    List<SObjectField> fields
  ) {
    List<String> values = new List<String>();
    for (SObjectField field : fields) {
      Object val = record.get(field);
      // Length-prefix eliminates delimiter collision (e.g. 'a|b' vs 'a','b|c')
      String strVal = val == null ? '' : String.valueOf(val);
      values.add(strVal.length() + ':' + strVal);
    }
    return String.join(values, '|');
  }

  // Check if record has been processed with same field values
  // Returns true if the record should be SKIPPED (already processed with same values)
  public static Boolean hasBeenProcessedWithSameFields(
    String handlerKey,
    Id recordId,
    String currentHash
  ) {
    if (!fieldHashes.containsKey(handlerKey)) {
      return false;
    }
    Map<Id, String> hashes = fieldHashes.get(handlerKey);
    return hashes.containsKey(recordId) &&
      hashes.get(recordId).equals(currentHash);
  }

  // Mark record as processed with its current field hash
  public static void markProcessedWithHash(
    String handlerKey,
    Id recordId,
    String hash
  ) {
    if (!fieldHashes.containsKey(handlerKey)) {
      fieldHashes.put(handlerKey, new Map<Id, String>());
    }
    fieldHashes.get(handlerKey).put(recordId, hash);
  }

  // --- Invocation Counter Methods (for INSERT context) ---

  // Increment invocation counter for a handler, return the new count
  public static Integer incrementInvocationCount(String handlerKey) {
    Integer count = invocationCounters.containsKey(handlerKey)
      ? invocationCounters.get(handlerKey)
      : 0;
    count++;
    invocationCounters.put(handlerKey, count);
    return count;
  }

  // Get current invocation count
  public static Integer getInvocationCount(String handlerKey) {
    return invocationCounters.containsKey(handlerKey)
      ? invocationCounters.get(handlerKey)
      : 0;
  }

  // Check if invocation limit is exceeded
  public static Boolean isInvocationLimitExceeded(
    String handlerKey,
    Integer maxReentrancy
  ) {
    return getInvocationCount(handlerKey) >= maxReentrancy;
  }

  // --- Cascade Depth Methods ---

  public static void incrementCascadeDepth(String sObjectName) {
    cascadeDepth++;
    if (!cascadeSObjectTypes.containsKey(cascadeDepth)) {
      cascadeSObjectTypes.put(cascadeDepth, new Set<String>());
    }
    cascadeSObjectTypes.get(cascadeDepth).add(sObjectName);
  }

  public static void decrementCascadeDepth() {
    // Prune recursion guard entries for SObjectTypes at this cascade level
    if (cascadeSObjectTypes.containsKey(cascadeDepth)) {
      Set<String> sObjectTypes = cascadeSObjectTypes.get(cascadeDepth);
      pruneForSObjectTypes(sObjectTypes);
      cascadeSObjectTypes.remove(cascadeDepth);
    }
    if (cascadeDepth > 0) {
      cascadeDepth--;
    }
  }

  public static Integer getCascadeDepth() {
    return cascadeDepth;
  }

  public static void checkCascadeDepth(
    String handlerName,
    TriggerContext ctx,
    Integer depthLimit
  ) {
    if (cascadeDepth > depthLimit) {
      throw new CascadeDepthException(
        'Cascade depth ' +
          cascadeDepth +
          ' exceeds limit ' +
          depthLimit +
          ' for handler ' +
          handlerName,
        handlerName,
        ctx,
        depthLimit
      );
    }
  }

  // --- Pruning ---

  private static void pruneForSObjectTypes(Set<String> sObjectTypes) {
    List<String> keysToRemove = new List<String>();
    for (String key : fieldHashes.keySet()) {
      for (String sObjType : sObjectTypes) {
        if (key.startsWith(sObjType + ':')) {
          keysToRemove.add(key);
          break; // F-PR1: key matches at most one SObjectType prefix (delimited by ':')
        }
      }
    }
    for (String key : keysToRemove) {
      fieldHashes.remove(key);
    }

    keysToRemove.clear();
    for (String key : invocationCounters.keySet()) {
      for (String sObjType : sObjectTypes) {
        if (key.startsWith(sObjType + ':')) {
          keysToRemove.add(key);
          break; // F-PR1: key matches at most one SObjectType prefix (delimited by ':')
        }
      }
    }
    for (String key : keysToRemove) {
      invocationCounters.remove(key);
    }
  }

  // --- Reset (for testing) ---

  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void reset() {
    fieldHashes.clear();
    invocationCounters.clear();
    cascadeDepth = 0;
    cascadeSObjectTypes.clear();
  }
}
