public inherited sharing class CyclicDependencyException extends TriggerFrameworkException {
  public List<String> cycle { get; private set; }

  public CyclicDependencyException(
    String message,
    String handlerName,
    TriggerContext context,
    List<String> cycle
  ) {
    super(message, handlerName, context, 'dml-ordering');
    this.cycle = cycle;
  }
}
