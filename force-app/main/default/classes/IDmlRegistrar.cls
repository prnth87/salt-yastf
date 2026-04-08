public interface IDmlRegistrar {
  void registerNew(SObject record);
  void registerNew(SObject record, SObjectField fkField, SObject relatedTo);
  void registerDirty(SObject record, List<SObjectField> dirtyFields);
  void registerDeleted(SObject record);
  void declareDependency(SObjectType source, SObjectType target);
}
