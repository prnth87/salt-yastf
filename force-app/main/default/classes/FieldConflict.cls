public inherited sharing class FieldConflict {
  public Id recordId { get; private set; }
  public SObjectField conflictField { get; private set; }
  public String handlerA { get; private set; }
  public String handlerB { get; private set; }
  public Object valueA { get; private set; }
  public Object valueB { get; private set; }

  public FieldConflict(
    Id recordId,
    SObjectField conflictField,
    String handlerA,
    String handlerB,
    Object valueA,
    Object valueB
  ) {
    this.recordId = recordId;
    this.conflictField = conflictField;
    this.handlerA = handlerA;
    this.handlerB = handlerB;
    this.valueA = valueA;
    this.valueB = valueB;
  }
}
