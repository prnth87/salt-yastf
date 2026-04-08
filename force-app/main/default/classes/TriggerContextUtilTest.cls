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
}
