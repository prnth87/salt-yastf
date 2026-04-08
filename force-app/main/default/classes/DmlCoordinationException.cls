public inherited sharing class DmlCoordinationException extends TriggerFrameworkException {
  public String fieldProvenance { get; private set; }

  public DmlCoordinationException(
    String message,
    String handlerName,
    TriggerContext context,
    String fieldProvenance
  ) {
    super(message, handlerName, context, 'dml-commit');
    this.fieldProvenance = fieldProvenance;
  }
}
