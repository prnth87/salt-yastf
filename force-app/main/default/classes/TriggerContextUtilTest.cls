@IsTest
private class TriggerContextUtilTest {
  @IsTest
  static void testFromTriggerOperation() {
    System.assertEquals(
      TriggerContext.BEFORE_INSERT,
      TriggerContextUtil.fromTriggerOperation(
        System.TriggerOperation.BEFORE_INSERT
      )
    );
    System.assertEquals(
      TriggerContext.AFTER_UPDATE,
      TriggerContextUtil.fromTriggerOperation(
        System.TriggerOperation.AFTER_UPDATE
      )
    );
    System.assertEquals(
      TriggerContext.AFTER_UNDELETE,
      TriggerContextUtil.fromTriggerOperation(
        System.TriggerOperation.AFTER_UNDELETE
      )
    );
  }

  @IsTest
  static void testGetFieldName() {
    System.assertEquals(
      'BeforeInsert__c',
      TriggerContextUtil.getFieldName(TriggerContext.BEFORE_INSERT)
    );
    System.assertEquals(
      'AfterUpdate__c',
      TriggerContextUtil.getFieldName(TriggerContext.AFTER_UPDATE)
    );
    System.assertEquals(
      'AfterUndelete__c',
      TriggerContextUtil.getFieldName(TriggerContext.AFTER_UNDELETE)
    );
  }

  @IsTest
  static void triggerContextUtil_allOperationsMapped() {
    System.assertEquals(
      TriggerContext.BEFORE_DELETE,
      TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.BEFORE_DELETE)
    );
    System.assertEquals(
      TriggerContext.AFTER_DELETE,
      TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.AFTER_DELETE)
    );
    System.assertEquals(
      TriggerContext.BEFORE_UPDATE,
      TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.BEFORE_UPDATE)
    );
    System.assertEquals(
      TriggerContext.AFTER_INSERT,
      TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.AFTER_INSERT)
    );
  }

  @IsTest
  static void triggerContextUtil_allFieldNamesMapped() {
    System.assertEquals('BeforeInsert__c', TriggerContextUtil.getFieldName(TriggerContext.BEFORE_INSERT));
    System.assertEquals('BeforeUpdate__c', TriggerContextUtil.getFieldName(TriggerContext.BEFORE_UPDATE));
    System.assertEquals('BeforeDelete__c', TriggerContextUtil.getFieldName(TriggerContext.BEFORE_DELETE));
    System.assertEquals('AfterInsert__c', TriggerContextUtil.getFieldName(TriggerContext.AFTER_INSERT));
    System.assertEquals('AfterUpdate__c', TriggerContextUtil.getFieldName(TriggerContext.AFTER_UPDATE));
    System.assertEquals('AfterDelete__c', TriggerContextUtil.getFieldName(TriggerContext.AFTER_DELETE));
    System.assertEquals('AfterUndelete__c', TriggerContextUtil.getFieldName(TriggerContext.AFTER_UNDELETE));
  }

  @IsTest
  static void triggerContextUtil_allFromTriggerOperations() {
    System.assertEquals(TriggerContext.BEFORE_INSERT, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.BEFORE_INSERT));
    System.assertEquals(TriggerContext.BEFORE_UPDATE, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.BEFORE_UPDATE));
    System.assertEquals(TriggerContext.BEFORE_DELETE, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.BEFORE_DELETE));
    System.assertEquals(TriggerContext.AFTER_INSERT, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.AFTER_INSERT));
    System.assertEquals(TriggerContext.AFTER_UPDATE, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.AFTER_UPDATE));
    System.assertEquals(TriggerContext.AFTER_DELETE, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.AFTER_DELETE));
    System.assertEquals(TriggerContext.AFTER_UNDELETE, TriggerContextUtil.fromTriggerOperation(System.TriggerOperation.AFTER_UNDELETE));
  }

  @IsTest
  static void triggerContextUtil_getFieldName_beforeDelete() {
    String field = TriggerContextUtil.getFieldName(TriggerContext.BEFORE_DELETE);
    System.assertEquals('BeforeDelete__c', field);
  }

  @IsTest
  static void triggerContextUtil_getFieldName_afterDelete() {
    String field = TriggerContextUtil.getFieldName(TriggerContext.AFTER_DELETE);
    System.assertEquals('AfterDelete__c', field);
  }

  @IsTest
  static void triggerContextUtil_getFieldName_afterUndelete() {
    String field = TriggerContextUtil.getFieldName(TriggerContext.AFTER_UNDELETE);
    System.assertEquals('AfterUndelete__c', field);
  }

  @IsTest
  static void triggerContextUtil_fromTriggerOp_beforeDelete() {
    TriggerContext ctx = TriggerContextUtil.fromTriggerOperation(
      TriggerOperation.BEFORE_DELETE
    );
    System.assertEquals(TriggerContext.BEFORE_DELETE, ctx);
  }

  @IsTest
  static void triggerContextUtil_fromTriggerOp_afterDelete() {
    TriggerContext ctx = TriggerContextUtil.fromTriggerOperation(
      TriggerOperation.AFTER_DELETE
    );
    System.assertEquals(TriggerContext.AFTER_DELETE, ctx);
  }

  @IsTest
  static void triggerContextUtil_fromTriggerOp_afterUndelete() {
    TriggerContext ctx = TriggerContextUtil.fromTriggerOperation(
      TriggerOperation.AFTER_UNDELETE
    );
    System.assertEquals(TriggerContext.AFTER_UNDELETE, ctx);
  }
}
