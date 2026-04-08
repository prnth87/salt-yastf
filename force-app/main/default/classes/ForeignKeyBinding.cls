public inherited sharing class ForeignKeyBinding {
  public SObject childRecord { get; private set; }
  public SObjectField fkField { get; private set; }
  public SObject parentRecord { get; private set; }

  public ForeignKeyBinding(
    SObject childRecord,
    SObjectField fkField,
    SObject parentRecord
  ) {
    this.childRecord = childRecord;
    this.fkField = fkField;
    this.parentRecord = parentRecord;
  }

  // deferred fix: Returns true if FK was resolved successfully, false if parent has no Id.
  // DmlExecutor uses the return value to skip child records whose parent insert failed.
  public Boolean resolve() {
    if (parentRecord.Id != null) {
      childRecord.put(fkField, parentRecord.Id);
      return true;
    } else {
      System.debug(
        LoggingLevel.WARN,
        'SALT-YASTF: FK binding skipped — parent record has no Id. ' +
          'Child ' +
          QueryRequest.cachedTypeName(childRecord.getSObjectType()) +
          ' field ' +
          QueryRequest.cachedFieldName(fkField) +
          ' will remain null. Parent insert may have failed.'
      );
      return false;
    }
  }
}
