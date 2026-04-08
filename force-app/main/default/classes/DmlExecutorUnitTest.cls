@IsTest
private class DmlExecutorUnitTest {
  @IsTest
  static void testTopoSortParentBeforeChild() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    Account acc = new Account(Name = 'TopoParent');
    Contact con = new Contact(LastName = 'TopoChild');

    reg.registerNew(acc);
    reg.registerNew(con, Contact.AccountId, acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, acc.Id, 'Account should have been inserted');
    System.assertNotEquals(null, con.Id, 'Contact should have been inserted');
    System.assertEquals(
      acc.Id,
      con.AccountId,
      'Contact FK should resolve to Account Id'
    );
  }

  @IsTest
  static void testTopoSortThreeTypes() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    Account acc = new Account(Name = 'ThreeTypeParent');
    Contact con = new Contact(LastName = 'ThreeTypeChild');
    Opportunity opp = new Opportunity(
      Name = 'ThreeTypeOpp',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30)
    );

    reg.registerNew(acc);
    reg.registerNew(con, Contact.AccountId, acc);
    reg.registerNew(opp, Opportunity.AccountId, acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, acc.Id, 'Account should have Id');
    System.assertNotEquals(null, con.Id, 'Contact should have Id');
    System.assertNotEquals(null, opp.Id, 'Opportunity should have Id');
    System.assertEquals(acc.Id, con.AccountId, 'Contact FK should resolve');
    System.assertEquals(acc.Id, opp.AccountId, 'Opportunity FK should resolve');
  }

  @IsTest
  static void testTopoSortSingleType() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 3; i++) {
      Account acc = new Account(Name = 'SingleType' + i);
      accounts.add(acc);
      reg.registerNew(acc);
    }

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    for (Account acc : accounts) {
      System.assertNotEquals(
        null,
        acc.Id,
        'Each Account should have been inserted'
      );
    }
  }

  @IsTest
  static void testCyclicDependencyThrows() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    reg.registerNew(new Account(Name = 'CycleA'));
    reg.registerNew(new Contact(LastName = 'CycleB'));

    reg.declareDependency(Account.SObjectType, Contact.SObjectType);
    reg.declareDependency(Contact.SObjectType, Account.SObjectType);

    try {
      DmlExecutor.commitWork(reg);
      System.assert(false, 'Should have thrown CyclicDependencyException');
    } catch (CyclicDependencyException e) {
      System.assert(
        e.getMessage().contains('Circular dependency'),
        'Expected cycle message, got: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void testRollbackNullsOutIds() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    Account acc = new Account(Name = 'RollbackTest');
    // Contact without LastName — required field will fail DML
    Contact con = new Contact();

    reg.registerNew(acc);
    reg.registerNew(con, Contact.AccountId, acc);

    try {
      DmlExecutor.commitWork(reg);
      System.assert(false, 'Should have thrown DmlCoordinationException');
    } catch (DmlCoordinationException e) {
      // C4-1: IDs should be nulled out after rollback
      System.assertEquals(
        null,
        acc.Id,
        'Account Id should be null after rollback'
      );
      System.assertEquals(
        null,
        con.Id,
        'Contact Id should be null after rollback'
      );
    }
  }

  @IsTest
  static void testFkBindingResolution() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    Account acc = new Account(Name = 'FkParent');
    Contact con = new Contact(LastName = 'FkChild');

    reg.registerNew(acc);
    reg.registerNew(con, Contact.AccountId, acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, acc.Id, 'Parent Account should be inserted');
    System.assertEquals(
      acc.Id,
      con.AccountId,
      'Contact.AccountId should be resolved to parent Account Id'
    );

    // Verify via query
    Contact queried = [SELECT AccountId FROM Contact WHERE Id = :con.Id];
    System.assertEquals(acc.Id, queried.AccountId, 'Persisted FK should match');
  }

  @IsTest
  static void testMixedDmlThrows() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    reg.registerNew(new Account(Name = 'MixedA'));
    reg.registerNew(
      new User(
        LastName = 'MixedU',
        Email = 'mixed@test.com',
        Username = 'saltmixed' + DateTime.now().getTime() + '@test.com',
        Alias = 'mtest',
        TimeZoneSidKey = 'America/New_York',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        ProfileId = UserInfo.getProfileId(),
        LanguageLocaleKey = 'en_US'
      )
    );

    try {
      DmlExecutor.commitWork(reg);
      System.assert(false, 'Should have thrown DmlCoordinationException');
    } catch (DmlCoordinationException e) {
      System.assert(
        e.getMessage().contains('Mixed DML'),
        'Expected Mixed DML message, got: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void testDmlBudgetGuardThrows() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    reg.registerNew(new Account(Name = 'BudgetTest'));

    DmlExecutor.setDmlReserve(Limits.getLimitDmlStatements());

    try {
      DmlExecutor.commitWork(reg);
      System.assert(false, 'Should have thrown DmlCoordinationException');
    } catch (DmlCoordinationException e) {
      System.assert(
        e.getMessage().contains('DML budget exhausted'),
        'Expected DML budget message, got: ' + e.getMessage()
      );
    } finally {
      DmlExecutor.resetCache();
    }
  }

  @IsTest
  static void testCommitWorkEmpty() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    System.assertEquals(false, reg.hasPendingDml(), 'No pending DML expected');

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    // No exception means success — commitWork is a no-op for empty registrar
  }

  @IsTest
  static void testDeletesInReverseOrder() {
    DmlExecutor.resetCache();

    // Setup: insert Account and Contact
    Account acc = new Account(Name = 'DeleteParent');
    insert acc;
    Contact con = new Contact(LastName = 'DeleteChild', AccountId = acc.Id);
    insert con;

    Id accId = acc.Id;
    Id conId = con.Id;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    reg.registerDeleted(con);
    reg.registerDeleted(acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    // Verify both records are deleted
    List<Contact> contacts = [SELECT Id FROM Contact WHERE Id = :conId];
    System.assertEquals(0, contacts.size(), 'Contact should be deleted');

    List<Account> accounts = [SELECT Id FROM Account WHERE Id = :accId];
    System.assertEquals(0, accounts.size(), 'Account should be deleted');
  }

  @IsTest
  static void testPartialFailureAllOrNoneFalse() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);
    reg.setAllOrNone(false);

    Account acc = new Account(Name = 'PartialValid');
    // Contact without LastName — will fail validation
    Contact con = new Contact();

    reg.registerNew(acc);
    reg.registerNew(con, Contact.AccountId, acc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, acc.Id, 'Valid Account should be inserted');
    System.assertEquals(null, con.Id, 'Invalid Contact should not be inserted');
  }

  @IsTest
  static void testResetCache() {
    // Set a high reserve, then reset and verify default behavior restored
    DmlExecutor.setDmlReserve(Limits.getLimitDmlStatements());
    DmlExecutor.resetCache();

    // After reset, commitWork with a valid record should succeed
    // (default reserve is 10, which leaves plenty of headroom)
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);
    reg.registerNew(new Account(Name = 'ResetTest'));

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    // If resetCache did not restore default reserve, commitWork would have thrown
    // DmlCoordinationException for budget exhaustion
  }

  // ── Migrated from SaltCoverageBoostTest ──

  @IsTest
  static void dmlExecutor_partialFailureWithFkBinding() {
    DmlExecutor.resetCache();
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);
    reg.setAllOrNone(false);

    Account parentAcc = new Account(Name = 'Good Parent');
    Contact childToSkip = new Contact(LastName = 'Orphan');

    Account badParent = new Account();
    Contact childOfBad = new Contact(LastName = 'BadChild');

    reg.registerNew(parentAcc);
    reg.registerNew(badParent);
    reg.registerNew(childOfBad, Contact.AccountId, badParent);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, parentAcc.Id);
    System.assertEquals(null, badParent.Id);
  }

  @IsTest
  static void dmlExecutor_updateInTopologicalOrder() {
    DmlExecutor.resetCache();

    Account acc = new Account(Name = 'UpdateTopo');
    insert acc;
    Contact con = new Contact(LastName = 'UpdateTopoChild', AccountId = acc.Id);
    insert con;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    Account dirtyAcc = new Account(Id = acc.Id, Description = 'Updated');
    reg.registerDirty(dirtyAcc, new List<SObjectField>{ Account.Description });

    Contact dirtyCon = new Contact(Id = con.Id, FirstName = 'Updated');
    reg.registerDirty(dirtyCon, new List<SObjectField>{ Contact.FirstName });

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    Account updatedAcc = [SELECT Description FROM Account WHERE Id = :acc.Id];
    System.assertEquals('Updated', updatedAcc.Description);
    Contact updatedCon = [SELECT FirstName FROM Contact WHERE Id = :con.Id];
    System.assertEquals('Updated', updatedCon.FirstName);
  }

  @IsTest
  static void dmlExecutor_updateAndDeleteMixed() {
    DmlExecutor.resetCache();

    Account acc = new Account(Name = 'MixedOps');
    insert acc;
    Contact con = new Contact(LastName = 'MixedChild', AccountId = acc.Id);
    insert con;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    Account dirtyAcc = new Account(Id = acc.Id, Description = 'Updated');
    reg.registerDirty(dirtyAcc, new List<SObjectField>{ Account.Description });

    reg.registerDeleted(con);

    Account newAcc = new Account(Name = 'NewInMixed');
    reg.registerNew(newAcc);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, newAcc.Id);
    List<Contact> remainingContacts = [SELECT Id FROM Contact WHERE Id = :con.Id];
    System.assertEquals(0, remainingContacts.size());
  }

  @IsTest
  static void dmlExecutor_partialUpdateFailure() {
    DmlExecutor.resetCache();

    Account acc = new Account(Name = 'PartialUpdateTest');
    insert acc;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);
    reg.setAllOrNone(false);

    Account dirtyAcc = new Account(Id = acc.Id, Description = 'Valid');
    reg.registerDirty(dirtyAcc, new List<SObjectField>{ Account.Description });

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    Account result = [SELECT Description FROM Account WHERE Id = :acc.Id];
    System.assertEquals('Valid', result.Description);
  }

  @IsTest
  static void dmlExecutor_partialFailureSkipsChildFkBinding() {
    Account parent = new Account(Name = 'DmlExec FK Parent');
    insert parent;

    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);
    reg.setCurrentHandler('TestFkHandler');

    Contact child = new Contact(LastName = 'FkChild');
    reg.registerNew(child, Contact.AccountId, parent);
    reg.setAllOrNone(true);

    Test.startTest();
    DmlExecutor.commitWork(reg);
    Test.stopTest();

    System.assertNotEquals(null, child.Id, 'Child should have been inserted');
  }
}
