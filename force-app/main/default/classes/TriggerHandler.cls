public inherited sharing abstract class TriggerHandler implements ITriggerHandler {
  private static final Map<String, Set<Id>> PROCESSED_RECORDS = new Map<String, Set<Id>>();

  public virtual void beforeInsert(List<SObject> newRecords) {
  }
  public virtual void afterInsert(List<SObject> newRecords) {
  }
  public virtual void beforeUpdate(
    List<SObject> newRecords,
    Map<Id, SObject> oldMap
  ) {
  }
  public virtual void afterUpdate(
    List<SObject> newRecords,
    Map<Id, SObject> oldMap
  ) {
  }
  public virtual void beforeDelete(Map<Id, SObject> oldMap) {
  }
  public virtual void afterDelete(Map<Id, SObject> oldMap) {
  }
  public virtual void afterUndelete(List<SObject> newRecords) {
  }

  public String getHandlerName() {
    String raw = String.valueOf(this);
    // S3-5: Defensive handling — split on ':' but fall back to full string
    // if format changes. Apex toString() currently produces 'ClassName:hashCode'.
    Integer colonIdx = raw.indexOf(':');
    String typeName = colonIdx > 0 ? raw.substring(0, colonIdx) : raw;
    String fullName = TriggerHandler.class.getName();
    if (fullName.contains('.')) {
      String namespace = fullName.substringBefore('.');
      if (!typeName.contains('.')) {
        return namespace + '.' + typeName;
      }
    }
    return typeName;
  }

  // F-SC3: Manual convenience API — not coordinated with RecursionGuard.
  // Prefer implementing IRecursionAware for automatic field-hash recursion guard.
  // This API is retained for backward compatibility but should not be mixed with
  // IRecursionAware on the same handler.
  protected Boolean hasBeenProcessed(Id recordId) {
    String key = getProcessedKey();
    Set<Id> processed = PROCESSED_RECORDS.get(key);
    return processed != null && processed.contains(recordId);
  }

  protected void markProcessed(Id recordId) {
    String key = getProcessedKey();
    if (!PROCESSED_RECORDS.containsKey(key)) {
      PROCESSED_RECORDS.put(key, new Set<Id>());
    }
    PROCESSED_RECORDS.get(key).add(recordId);
  }

  // manual recursion-pruning API: Manual pruning API — unlike IRecursionAware (which is pruned automatically
  // on cascade depth decrement), the manual hasBeenProcessed/markProcessed API is
  // keyed by handler name only and cannot be auto-pruned by SObjectType.
  // Call this in handler code if you need to reset manual recursion state.
  public void clearProcessed() {
    String key = getProcessedKey();
    PROCESSED_RECORDS.remove(key);
  }

  private String getProcessedKey() {
    return getHandlerName();
  }

  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void reset() {
    PROCESSED_RECORDS.clear();
  }
}
