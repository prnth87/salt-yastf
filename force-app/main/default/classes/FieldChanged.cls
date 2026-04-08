public inherited sharing class FieldChanged implements IRecordFilter {
  private final SObjectField field;

  public FieldChanged(SObjectField field) {
    this.field = field;
  }

  public Boolean isApplicable(
    SObject newRecord,
    SObject oldRecord,
    TriggerContext ctx
  ) {
    if (newRecord == null) {
      // Delete context
      return oldRecord.get(field) != null;
    }
    if (oldRecord == null) {
      // Insert/undelete context
      return newRecord.get(field) != null;
    }
    // Update context
    return newRecord.get(field) != oldRecord.get(field);
  }
}
