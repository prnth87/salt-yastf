public inherited sharing class FieldNotNull implements IRecordFilter {
  private final SObjectField field;

  public FieldNotNull(SObjectField field) {
    this.field = field;
  }

  public Boolean isApplicable(
    SObject newRecord,
    SObject oldRecord,
    TriggerContext ctx
  ) {
    SObject record = (newRecord != null) ? newRecord : oldRecord;
    return record != null && record.get(field) != null;
  }
}
