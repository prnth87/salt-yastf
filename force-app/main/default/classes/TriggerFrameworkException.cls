public inherited sharing virtual class TriggerFrameworkException extends Exception {
  public String handlerName { get; private set; }
  public TriggerContext context { get; private set; }
  public String step { get; private set; }

  public TriggerFrameworkException(
    String message,
    String handlerName,
    TriggerContext context,
    String step
  ) {
    this(message);
    this.handlerName = handlerName;
    this.context = context;
    this.step = step;
  }
}
