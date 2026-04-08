public inherited sharing class TriggerContextUtil {
  private static final Map<System.TriggerOperation, TriggerContext> OPERATION_TO_CONTEXT = new Map<System.TriggerOperation, TriggerContext>{
    System.TriggerOperation.BEFORE_INSERT => TriggerContext.BEFORE_INSERT,
    System.TriggerOperation.BEFORE_UPDATE => TriggerContext.BEFORE_UPDATE,
    System.TriggerOperation.BEFORE_DELETE => TriggerContext.BEFORE_DELETE,
    System.TriggerOperation.AFTER_INSERT => TriggerContext.AFTER_INSERT,
    System.TriggerOperation.AFTER_UPDATE => TriggerContext.AFTER_UPDATE,
    System.TriggerOperation.AFTER_DELETE => TriggerContext.AFTER_DELETE,
    System.TriggerOperation.AFTER_UNDELETE => TriggerContext.AFTER_UNDELETE
  };

  private static final Map<TriggerContext, String> CONTEXT_TO_FIELD = new Map<TriggerContext, String>{
    TriggerContext.BEFORE_INSERT => 'BeforeInsert__c',
    TriggerContext.BEFORE_UPDATE => 'BeforeUpdate__c',
    TriggerContext.BEFORE_DELETE => 'BeforeDelete__c',
    TriggerContext.AFTER_INSERT => 'AfterInsert__c',
    TriggerContext.AFTER_UPDATE => 'AfterUpdate__c',
    TriggerContext.AFTER_DELETE => 'AfterDelete__c',
    TriggerContext.AFTER_UNDELETE => 'AfterUndelete__c'
  };

  public static TriggerContext fromTriggerOperation(
    System.TriggerOperation operation
  ) {
    TriggerContext ctx = OPERATION_TO_CONTEXT.get(operation);
    if (ctx == null) {
      throw new IllegalArgumentException(
        'Unsupported TriggerOperation: ' + operation
      );
    }
    return ctx;
  }

  public static String getFieldName(TriggerContext ctx) {
    String fieldName = CONTEXT_TO_FIELD.get(ctx);
    if (fieldName == null) {
      throw new IllegalArgumentException('Unsupported TriggerContext: ' + ctx);
    }
    return fieldName;
  }
}
