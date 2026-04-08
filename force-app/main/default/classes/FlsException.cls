public inherited sharing class FlsException extends TriggerFrameworkException {
  public String fieldName { get; private set; }
  public String objectName { get; private set; }

  public FlsException(
    String message,
    String handlerName,
    TriggerContext context,
    String fieldName,
    String objectName
  ) {
    super(message, handlerName, context, 'query-execution');
    this.fieldName = fieldName;
    this.objectName = objectName;
  }
}
