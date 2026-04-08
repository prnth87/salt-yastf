public inherited sharing class SoqlBudgetException extends TriggerFrameworkException {
  public Integer queriesUsed { get; private set; }
  public Integer threshold { get; private set; }

  public SoqlBudgetException(
    String message,
    String handlerName,
    TriggerContext context,
    Integer queriesUsed,
    Integer threshold
  ) {
    super(message, handlerName, context, 'soql-circuit-breaker');
    this.queriesUsed = queriesUsed;
    this.threshold = threshold;
  }
}
