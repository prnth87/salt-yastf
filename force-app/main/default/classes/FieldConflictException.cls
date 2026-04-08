public inherited sharing class FieldConflictException extends TriggerFrameworkException {
  public Id recordId { get; private set; }
  public String conflictField { get; private set; }
  public String handlerA { get; private set; }
  public String handlerB { get; private set; }
  public Object valueA { get; private set; }
  public Object valueB { get; private set; }

  public FieldConflictException(
    String message,
    String handlerName,
    TriggerContext context,
    Id recordId,
    String conflictField,
    String handlerA,
    String handlerB,
    Object valueA,
    Object valueB
  ) {
    super(message, handlerName, context, 'dml-conflict-detection');
    this.recordId = recordId;
    this.conflictField = conflictField;
    this.handlerA = handlerA;
    this.handlerB = handlerB;
    this.valueA = valueA;
    this.valueB = valueB;
  }
}
