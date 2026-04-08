@IsTest
private class TriggerHandlerTest {
  // Test fixture handler
  private class TestHandler extends TriggerHandler {
    public Boolean beforeInsertCalled = false;
    public Boolean afterUpdateCalled = false;

    public override void beforeInsert(List<SObject> newRecords) {
      beforeInsertCalled = true;
    }

    public override void afterUpdate(
      List<SObject> newRecords,
      Map<Id, SObject> oldMap
    ) {
      afterUpdateCalled = true;
    }

    // Expose protected methods for testing
    public Boolean testHasBeenProcessed(Id recordId) {
      return hasBeenProcessed(recordId);
    }

    public void testMarkProcessed(Id recordId) {
      markProcessed(recordId);
    }
  }

  @IsTest
  static void testNoOpDefaults() {
    TestHandler handler = new TestHandler();
    // These should not throw
    handler.afterInsert(new List<SObject>());
    handler.beforeUpdate(new List<SObject>(), new Map<Id, SObject>());
    handler.beforeDelete(new Map<Id, SObject>());
    handler.afterDelete(new Map<Id, SObject>());
    handler.afterUndelete(new List<SObject>());
  }

  @IsTest
  static void testGetHandlerName() {
    TestHandler handler = new TestHandler();
    String name = handler.getHandlerName();
    System.assert(
      name.contains('TestHandler'),
      'Handler name should contain class name: ' + name
    );
  }

  @IsTest
  static void testRecursionGuard() {
    TestHandler handler = new TestHandler();
    Id fakeId = '001000000000001AAA';

    System.assertEquals(false, handler.testHasBeenProcessed(fakeId));
    handler.testMarkProcessed(fakeId);
    System.assertEquals(true, handler.testHasBeenProcessed(fakeId));
  }

  // ── Migrated from SaltCoverageBoostTest ──

  private class CoverageHandler extends TriggerHandler {
    public Boolean testHasBeenProcessed(Id recordId) {
      return hasBeenProcessed(recordId);
    }
    public void testMarkProcessed(Id recordId) {
      markProcessed(recordId);
    }
  }

  @IsTest
  static void triggerHandler_clearProcessed() {
    TriggerHandler.reset();
    CoverageHandler handler = new CoverageHandler();
    Id fakeId = '001000000000001AAA';

    handler.testMarkProcessed(fakeId);
    System.assertEquals(true, handler.testHasBeenProcessed(fakeId));

    handler.clearProcessed();
    System.assertEquals(false, handler.testHasBeenProcessed(fakeId));
  }

  @IsTest
  static void triggerHandler_getHandlerNameContainsClassName() {
    CoverageHandler handler = new CoverageHandler();
    String name = handler.getHandlerName();
    System.assert(name.contains('CoverageHandler'), 'Name should contain class name: ' + name);
  }

  @IsTest
  static void triggerHandler_allDefaultMethodsNoOp() {
    CoverageHandler handler = new CoverageHandler();
    handler.beforeInsert(new List<SObject>());
    handler.afterInsert(new List<SObject>());
    handler.beforeUpdate(new List<SObject>(), new Map<Id, SObject>());
    handler.afterUpdate(new List<SObject>(), new Map<Id, SObject>());
    handler.beforeDelete(new Map<Id, SObject>());
    handler.afterDelete(new Map<Id, SObject>());
    handler.afterUndelete(new List<SObject>());
  }

  @IsTest
  static void triggerHandler_reset() {
    CoverageHandler handler = new CoverageHandler();
    Id fakeId = '001000000000001AAA';
    handler.testMarkProcessed(fakeId);
    TriggerHandler.reset();
    System.assertEquals(false, handler.testHasBeenProcessed(fakeId));
  }
}
