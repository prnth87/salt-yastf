public interface ITriggerHandler {
  void beforeInsert(List<SObject> newRecords);
  void afterInsert(List<SObject> newRecords);
  void beforeUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap);
  void afterUpdate(List<SObject> newRecords, Map<Id, SObject> oldMap);
  void beforeDelete(Map<Id, SObject> oldMap);
  void afterDelete(Map<Id, SObject> oldMap);
  void afterUndelete(List<SObject> newRecords);
}
