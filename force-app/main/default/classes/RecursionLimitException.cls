public inherited sharing class RecursionLimitException extends TriggerFrameworkException {
  public Integer maxAllowed { get; private set; }
  public Integer actual { get; private set; }

  public RecursionLimitException(
    String message,
    String handlerName,
    TriggerContext context,
    Integer maxAllowed,
    Integer actual
  ) {
    super(message, handlerName, context, 'recursion-check');
    this.maxAllowed = maxAllowed;
    this.actual = actual;
  }
}
