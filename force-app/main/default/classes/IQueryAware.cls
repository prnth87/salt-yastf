public interface IQueryAware {
  List<QueryRequest> declareQueryNeeds(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap
  );
  void onDataReady(
    List<SObject> applicableRecords,
    Map<Id, SObject> oldMap,
    QueryResultCache cache
  );
}
