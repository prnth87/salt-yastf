public inherited sharing class RecordTypeIs implements IRecordFilter {
  private final String recordTypeDeveloperName;
  private Id cachedRecordTypeId;
  private Boolean cacheInitialized = false;

  // F-PS1: Static cross-instance cache keyed by SObjectType name -> DeveloperName -> RecordTypeId.
  // Avoids redundant getDescribe().getRecordTypeInfosByDeveloperName() calls when
  // multiple handler instances use RecordTypeIs for the same SObjectType.
  private static Map<String, Map<String, Id>> rtCache = new Map<String, Map<String, Id>>();

  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void resetCache() {
    rtCache.clear();
  }

  public RecordTypeIs(String recordTypeDeveloperName) {
    this.recordTypeDeveloperName = recordTypeDeveloperName;
  }

  public Boolean isApplicable(
    SObject newRecord,
    SObject oldRecord,
    TriggerContext ctx
  ) {
    SObject record = (newRecord != null) ? newRecord : oldRecord;
    if (record == null) {
      return false;
    }
    Id recordTypeId = (Id) record.get('RecordTypeId');
    if (recordTypeId == null) {
      return false;
    }
    if (!cacheInitialized) {
      Schema.SObjectType sObjType = record.getSObjectType();
      String typeName = QueryRequest.cachedTypeName(sObjType);

      // F-PS1: Check static cache first
      if (
        rtCache.containsKey(typeName) &&
        rtCache.get(typeName).containsKey(recordTypeDeveloperName)
      ) {
        cachedRecordTypeId = rtCache.get(typeName).get(recordTypeDeveloperName);
      } else {
        Map<String, Schema.RecordTypeInfo> rtInfos = sObjType.getDescribe(
            SObjectDescribeOptions.DEFERRED
          )
          .getRecordTypeInfosByDeveloperName();
        Schema.RecordTypeInfo rtInfo = rtInfos.get(recordTypeDeveloperName);
        cachedRecordTypeId = (rtInfo != null) ? rtInfo.getRecordTypeId() : null;

        // F-PS1: Populate static cache for other instances
        if (!rtCache.containsKey(typeName)) {
          rtCache.put(typeName, new Map<String, Id>());
        }
        rtCache.get(typeName).put(recordTypeDeveloperName, cachedRecordTypeId);
      }
      cacheInitialized = true;
    }
    return cachedRecordTypeId != null && cachedRecordTypeId == recordTypeId;
  }
}
