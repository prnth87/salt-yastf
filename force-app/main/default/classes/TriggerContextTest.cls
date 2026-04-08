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
}
