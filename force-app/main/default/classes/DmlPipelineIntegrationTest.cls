@IsTest
private class DmlPipelineIntegrationTest {
  @IsTest
  static void testMultiHandlerWithFkResolution() {
    DmlExecutor.resetCache();
    QueryRequest.resetCaches();

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);

    // Handler A registers parent + child
    reg.setCurrentHandler('HandlerA');
    Account acc = new Account(Name = 'FkParent');
    reg.registerNew(acc);
    Contact con = new Contact(LastName = 'FkChild');
    reg.registerNew(con, Contact.AccountId, acc);

    // Handler B registers another child to same parent
    reg.setCurrentHandler('HandlerB');
    Opportunity opp = new Opportunity(
      Name = 'FkDeal',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30)
    );
    reg.registerNew(opp, Opportunity.AccountId, acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, acc.Id, 'Account should be inserted');
    System.assertNotEquals(null, con.Id, 'Contact should be inserted');
    System.assertNotEquals(null, opp.Id, 'Opportunity should be inserted');
    System.assertEquals(acc.Id, con.AccountId, 'Contact FK should resolve');
    System.assertEquals(acc.Id, opp.AccountId, 'Opportunity FK should resolve');
  }

  @IsTest
  static void testConflictDetectionDifferentValuesThrows() {
    DmlExecutor.resetCache();
    QueryRequest.resetCaches();

    Account acc = new Account(Name = 'ConflictTest');
    insert acc;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);

    reg.setCurrentHandler('HandlerA');
    Account dirtyA = new Account(Id = acc.Id, Phone = '111');
    reg.registerDirty(dirtyA, new List<SObjectField>{ Account.Phone });

    reg.setCurrentHandler('HandlerB');
    Account dirtyB = new Account(Id = acc.Id, Phone = '222');
    try {
      reg.registerDirty(dirtyB, new List<SObjectField>{ Account.Phone });
      System.assert(false, 'Should throw FieldConflictException');
    } catch (FieldConflictException e) {
      System.assert(
        e.getMessage().contains('HandlerA'),
        'Should mention first handler'
      );
      System.assert(
        e.getMessage().contains('HandlerB'),
        'Should mention second handler'
      );
    }
  }

  @IsTest
  static void testConflictDetectionSameValueNoThrow() {
    DmlExecutor.resetCache();
    QueryRequest.resetCaches();

    Account acc = new Account(Name = 'SameValue');
    insert acc;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);

    reg.setCurrentHandler('HandlerA');
    Account dirtyA = new Account(Id = acc.Id, Phone = '111');
    reg.registerDirty(dirtyA, new List<SObjectField>{ Account.Phone });

    reg.setCurrentHandler('HandlerB');
    Account dirtyB = new Account(Id = acc.Id, Phone = '111');
    // Same value — should NOT throw
    reg.registerDirty(dirtyB, new List<SObjectField>{ Account.Phone });

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    Account result = [SELECT Phone FROM Account WHERE Id = :acc.Id];
    System.assertEquals('111', result.Phone, 'Phone should be updated');
  }

  @IsTest
  static void testJournalRollbackRestoresMultiHandlerState() {
    DmlExecutor.resetCache();
    QueryRequest.resetCaches();

    Account acc = new Account(Name = 'JournalTest');
    insert acc;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);

    // Handler A sets Phone
    reg.setCurrentHandler('HandlerA');
    Account dirtyA = new Account(Id = acc.Id, Phone = '111');
    reg.registerDirty(dirtyA, new List<SObjectField>{ Account.Phone });

    // Capture mark after Handler A
    Integer mark = reg.getJournalMark();

    // Handler B sets Website
    reg.setCurrentHandler('HandlerB');
    Account dirtyB = new Account(Id = acc.Id, Website = 'http://test.com');
    reg.registerDirty(dirtyB, new List<SObjectField>{ Account.Website });

    // Rollback Handler B's changes
    reg.rollbackToJournalMark(mark);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    Account result = [SELECT Phone, Website FROM Account WHERE Id = :acc.Id];
    System.assertEquals('111', result.Phone, 'Handler A Phone should persist');
    System.assertEquals(
      null,
      result.Website,
      'Handler B Website should be rolled back'
    );
  }

  @IsTest
  static void testPartialFailureAllOrNoneFalse() {
    DmlExecutor.resetCache();
    QueryRequest.resetCaches();

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);
    reg.setCurrentHandler('TestHandler');
    reg.setAllOrNone(false);

    Account acc = new Account(Name = 'ValidAccount');
    reg.registerNew(acc);

    Contact con = new Contact(); // Missing required LastName
    reg.registerNew(con, Contact.AccountId, acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    // Account should succeed
    System.assertNotEquals(null, acc.Id, 'Valid Account should be inserted');
  }

  @IsTest
  static void testDmlBudgetExhaustedBeforeExecution() {
    DmlExecutor.resetCache();
    QueryRequest.resetCaches();
    DmlExecutor.setDmlReserve(Limits.getLimitDmlStatements());

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);
    reg.setCurrentHandler('TestHandler');
    reg.registerNew(new Account(Name = 'BudgetTest'));

    try {
      DmlExecutor.commitWork(reg);
      System.assert(false, 'Should throw DmlCoordinationException');
    } catch (DmlCoordinationException e) {
      System.assert(true, 'Budget exhaustion detected');
    }
  }
}
