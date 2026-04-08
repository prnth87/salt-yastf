@IsTest
private class ExceptionClassesTest {
  @IsTest
  static void testTriggerFrameworkException() {
    TriggerFrameworkException ex = new TriggerFrameworkException(
      'Test error',
      'TestHandler',
      TriggerContext.BEFORE_INSERT,
      'test-step'
    );
    System.assertEquals('TestHandler', ex.handlerName);
    System.assertEquals(TriggerContext.BEFORE_INSERT, ex.context);
    System.assertEquals('test-step', ex.step);
  }

  @IsTest
  static void testRecursionLimitException() {
    RecursionLimitException ex = new RecursionLimitException(
      'Max exceeded',
      'TestHandler',
      TriggerContext.AFTER_UPDATE,
      2,
      3
    );
    System.assertEquals(2, ex.maxAllowed);
    System.assertEquals(3, ex.actual);
  }

  @IsTest
  static void testCascadeDepthException() {
    CascadeDepthException ex = new CascadeDepthException(
      'Too deep',
      'TestHandler',
      TriggerContext.AFTER_INSERT,
      3
    );
    System.assertEquals(3, ex.depthLimit);
  }

  @IsTest
  static void testFlsException() {
    FlsException ex = new FlsException(
      'No access',
      'TestHandler',
      TriggerContext.AFTER_UPDATE,
      'SSN__c',
      'Contact'
    );
    System.assertEquals('SSN__c', ex.fieldName);
    System.assertEquals('Contact', ex.objectName);
  }

  @IsTest
  static void testFieldConflictException() {
    FieldConflictException ex = new FieldConflictException(
      'Conflict',
      'TestHandler',
      TriggerContext.AFTER_UPDATE,
      '001000000000001AAA',
      'Name',
      'HandlerA',
      'HandlerB',
      'Val1',
      'Val2'
    );
    System.assertEquals(Id.valueOf('001000000000001AAA'), ex.recordId);
    System.assertEquals('Name', ex.conflictField);
  }

  @IsTest
  static void testDmlCoordinationException() {
    DmlCoordinationException ex = new DmlCoordinationException(
      'DML failed',
      'TestHandler',
      TriggerContext.AFTER_UPDATE,
      'field Name set by HandlerA'
    );
    System.assertEquals('field Name set by HandlerA', ex.fieldProvenance);
  }

  @IsTest
  static void testSoqlBudgetException() {
    SoqlBudgetException ex = new SoqlBudgetException(
      'Over budget',
      'TestHandler',
      TriggerContext.AFTER_UPDATE,
      95,
      90
    );
    System.assertEquals(95, ex.queriesUsed);
    System.assertEquals(90, ex.threshold);
  }

  @IsTest
  static void testCyclicDependencyException() {
    CyclicDependencyException ex = new CyclicDependencyException(
      'Cycle detected',
      'TestHandler',
      TriggerContext.AFTER_UPDATE,
      new List<String>{ 'Account', 'Contact', 'Account' }
    );
    System.assertEquals(3, ex.cycle.size());
  }
}
