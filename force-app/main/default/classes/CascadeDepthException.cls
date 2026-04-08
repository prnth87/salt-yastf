public inherited sharing class CascadeDepthException extends TriggerFrameworkException {
  public Integer depthLimit { get; private set; }

  public CascadeDepthException(
    String message,
    String handlerName,
    TriggerContext context,
    Integer depthLimit
  ) {
    super(message, handlerName, context, 'cascade-check');
    this.depthLimit = depthLimit;
  }
}
