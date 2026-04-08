@IsTest
private class TriggerContextTest {
  @IsTest
  static void testAllContextValues() {
    // Verify all 7 context values exist
    System.assertEquals(7, TriggerContext.values().size());
    System.assertNotEquals(null, TriggerContext.BEFORE_INSERT);
    System.assertNotEquals(null, TriggerContext.BEFORE_UPDATE);
    System.assertNotEquals(null, TriggerContext.BEFORE_DELETE);
    System.assertNotEquals(null, TriggerContext.AFTER_INSERT);
    System.assertNotEquals(null, TriggerContext.AFTER_UPDATE);
    System.assertNotEquals(null, TriggerContext.AFTER_DELETE);
    System.assertNotEquals(null, TriggerContext.AFTER_UNDELETE);
  }

  @IsTest
  static void triggerContext_allValuesExist() {
    // Reference every enum value to ensure coverage
    TriggerContext bi = TriggerContext.BEFORE_INSERT;
    TriggerContext bu = TriggerContext.BEFORE_UPDATE;
    TriggerContext bd = TriggerContext.BEFORE_DELETE;
    TriggerContext ai = TriggerContext.AFTER_INSERT;
    TriggerContext au = TriggerContext.AFTER_UPDATE;
    TriggerContext ad = TriggerContext.AFTER_DELETE;
    TriggerContext aun = TriggerContext.AFTER_UNDELETE;

    System.assertEquals(7, TriggerContext.values().size());
    System.assertEquals(0, TriggerContext.BEFORE_INSERT.ordinal());
    System.assertEquals('AFTER_UNDELETE', aun.name());
  }
}
