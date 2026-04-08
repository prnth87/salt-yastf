@IsTest
private class DmlSubsystemTest {
  @IsTest
  static void testDmlRegistrarAfterTriggerBuffer() {
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setCurrentHandler('TestHandler');
    registrar.setBeforeTriggerContext(false);

    Account acc = new Account(Name = 'Test');
    registrar.registerNew(acc);

    System.assertEquals(true, registrar.hasPendingDml());
    System.assertEquals(1, registrar.getNewRecords().size());
  }

  @IsTest
  static void testDmlRegistrarBeforeTriggerBlocksNew() {
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setCurrentHandler('TestHandler');
    registrar.setBeforeTriggerContext(true);

    try {
      registrar.registerNew(new Account(Name = 'Test'));
      System.assert(false, 'Should throw in before-trigger context');
    } catch (TriggerFrameworkException e) {
      System.assert(e.getMessage().contains('before-trigger'), e.getMessage());
    }
  }

  @IsTest
  static void testDmlRegistrarBeforeTriggerBlocksDelete() {
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setCurrentHandler('TestHandler');
    registrar.setBeforeTriggerContext(true);

    try {
      registrar.registerDeleted(new Account(Id = '001000000000001AAA'));
      System.assert(false, 'Should throw in before-trigger context');
    } catch (TriggerFrameworkException e) {
      System.assert(e.getMessage().contains('before-trigger'), e.getMessage());
    }
  }

  @IsTest
  static void testFieldConflictValue() {
    FieldConflict fc = new FieldConflict(
      '001000000000001AAA',
      Account.Name,
      'HandlerA',
      'HandlerB',
      'ValueA',
      'ValueB'
    );

    System.assertEquals(Id.valueOf('001000000000001AAA'), fc.recordId);
    System.assertEquals(Account.Name, fc.conflictField);
    System.assertEquals('HandlerA', fc.handlerA);
  }

  @IsTest
  static void testForeignKeyBinding() {
    Account parent = new Account(Id = '001000000000001AAA');
    Contact child = new Contact(LastName = 'Test');

    ForeignKeyBinding binding = new ForeignKeyBinding(
      child,
      Contact.AccountId,
      parent
    );
    binding.resolve();

    System.assertEquals(
      Id.valueOf('001000000000001AAA'),
      child.get('AccountId')
    );
  }

  @IsTest
  static void testDeclaredDependency() {
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setCurrentHandler('TestHandler');
    registrar.setBeforeTriggerContext(false);

    registrar.declareDependency(Contact.SObjectType, Account.SObjectType);

    Map<SObjectType, Set<SObjectType>> deps = registrar.getDeclaredDependencies();
    System.assert(deps.containsKey(Contact.SObjectType));
    System.assert(deps.get(Contact.SObjectType).contains(Account.SObjectType));
  }

  @IsTest
  static void testDmlRegistrarAllOrNoneDefault() {
    DmlRegistrar registrar = new DmlRegistrar();
    System.assertEquals(true, registrar.getAllOrNone());
  }

  @IsTest
  static void testDmlRegistrarAllOrNoneSet() {
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setAllOrNone(false);
    System.assertEquals(false, registrar.getAllOrNone());
  }

  @IsTest
  static void testDmlOperationInsertSuccess() {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 5; i++) {
      accounts.add(new Account(Name = 'Test ' + i));
    }

    DmlOperation op = DmlOperation.forInsert(accounts)
      .allOrNone(true)
      .execute();

    System.assertEquals(true, op.isFullSuccess());
    System.assertEquals(5, op.getSuccessCount());
    System.assertEquals(0, op.getFailureCount());
    System.assertEquals(0, op.getErrors().size());
  }

  @IsTest
  static void testDmlOperationResultAccessors() {
    DmlOperation op = DmlOperation.forInsert(new List<SObject>()).execute();
    System.assertEquals(0, op.getSuccessCount());
    System.assertEquals(0, op.getFailureCount());
    System.assertEquals(true, op.isFullSuccess());
    System.assertNotEquals(null, op.getErrors());
  }

  @IsTest
  static void testJournalRollbackRestoresPriorState() {
    // Verify that journal-based rollback restores a field value set by a prior handler
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setBeforeTriggerContext(false);

    Id accId = '001000000000001AAA';
    Account acc = new Account(Id = accId, Name = 'Original');

    // Handler A sets Name
    registrar.setCurrentHandler('HandlerA');
    registrar.registerDirty(acc, new List<SObjectField>{ Account.Name });

    // Snapshot before Handler B
    Integer mark = registrar.getJournalMark();

    // Handler B overwrites Name (same value to avoid conflict exception)
    registrar.setCurrentHandler('HandlerB');
    Account accB = new Account(Id = accId, Name = 'Original');
    registrar.registerDirty(accB, new List<SObjectField>{ Account.Name });

    // Rollback Handler B's changes
    registrar.rollbackToJournalMark(mark);

    // Verify the buffered record still has the value from Handler A
    SObject buffered = registrar.getDirtyRecords().get(accId);
    System.assertEquals('Original', buffered.get('Name'));

    // Verify provenance restored to Handler A
    Map<String, String> prov = registrar.getFieldProvenance().get(accId);
    System.assertEquals('HandlerA', prov.get('Name'));
  }

  @IsTest
  static void testJournalRollbackNewRecordRemoved() {
    // Verify that rolling back removes a record that was entirely new in the handler
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setBeforeTriggerContext(false);
    registrar.setCurrentHandler('HandlerA');

    Integer mark = registrar.getJournalMark();

    Id accId = '001000000000001AAA';
    Account acc = new Account(Id = accId, Name = 'New');
    registrar.registerDirty(acc, new List<SObjectField>{ Account.Name });

    System.assertEquals(true, registrar.getDirtyRecords().containsKey(accId));

    // Rollback — record should be fully removed
    registrar.rollbackToJournalMark(mark);

    System.assertEquals(
      false,
      registrar.getDirtyRecords().containsKey(accId),
      'New record should be removed after rollback'
    );
  }

  @IsTest
  static void testJournalRollbackEmptyJournal() {
    // Verify that rollback with mark=0 on empty journal is a safe no-op
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setBeforeTriggerContext(false);
    registrar.setCurrentHandler('Handler');

    Integer mark = registrar.getJournalMark();
    System.assertEquals(0, mark);

    // Should not throw
    registrar.rollbackToJournalMark(mark);
    registrar.rollbackToJournalMark(-1);
    registrar.rollbackToJournalMark(999);
  }

  @IsTest
  static void testDmlBudgetGuard() {
    // Verify that DML budget guard throws when headroom is insufficient
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setCurrentHandler('TestHandler');
    registrar.setBeforeTriggerContext(false);

    registrar.registerNew(new Account(Name = 'Test'));

    // Set an extremely high reserve to trigger the guard
    DmlExecutor.setDmlReserve(Limits.getLimitDmlStatements());

    try {
      DmlExecutor.commitWork(registrar);
      System.assert(false, 'Should have thrown DmlCoordinationException');
    } catch (DmlCoordinationException e) {
      System.assert(
        e.getMessage().contains('DML budget exhausted'),
        'Expected DML budget message, got: ' + e.getMessage()
      );
    } finally {
      DmlExecutor.resetCache(); // Reset dmlReserve to default
    }
  }

  @IsTest
  static void testMixedDmlDetection() {
    // cross-SObjectType DML separation rule: Verify that registering both Setup (User) and non-Setup (Account)
    // objects throws DmlCoordinationException before any DML executes
    DmlRegistrar registrar = new DmlRegistrar();
    registrar.setCurrentHandler('TestHandler');
    registrar.setBeforeTriggerContext(false);

    registrar.registerNew(new Account(Name = 'Test'));
    registrar.registerNew(
      new User(
        LastName = 'Test',
        Email = 'test@test.com',
        Username = 'salttest' + DateTime.now().getTime() + '@test.com',
        Alias = 'stest',
        TimeZoneSidKey = 'America/New_York',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        ProfileId = UserInfo.getProfileId(),
        LanguageLocaleKey = 'en_US'
      )
    );

    try {
      DmlExecutor.commitWork(registrar);
      System.assert(false, 'Should have thrown DmlCoordinationException');
    } catch (DmlCoordinationException e) {
      System.assert(
        e.getMessage().contains('Mixed DML'),
        'Expected Mixed DML message, got: ' + e.getMessage()
      );
    }
  }

  // ── Migrated from SaltCoverageBoostTest ──

  @IsTest
  static void dmlRegistrar_registerNewWithFkInBeforeContextThrows() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(true);

    Boolean threw = false;
    try {
      reg.registerNew(new Contact(LastName = 'Test'), Contact.AccountId, new Account(Id = '001000000000001AAA'));
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('before-trigger'));
    }
    System.assert(threw);
  }

  @IsTest
  static void dmlRegistrar_registerDirtyInBeforeInsertWithoutNewMapThrows() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(true);

    Account acc = new Account(Id = '001000000000001AAA', Name = 'Test');
    Boolean threw = false;
    try {
      reg.registerDirty(acc, new List<SObjectField>{ Account.Name });
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('BEFORE_INSERT'));
    }
    System.assert(threw);
  }

  @IsTest
  static void dmlRegistrar_registerDirtyInBeforeTriggerAppliesDirectly() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(true);

    Account triggerRec = new Account(Id = '001000000000001AAA', Name = 'Old');
    Map<Id, SObject> triggerNewMap = new Map<Id, SObject>{ triggerRec.Id => triggerRec };
    reg.setTriggerNewMap(triggerNewMap);

    Account dirtyRec = new Account(Id = '001000000000001AAA', Name = 'New');
    reg.registerDirty(dirtyRec, new List<SObjectField>{ Account.Name });

    System.assertEquals('New', triggerRec.Name, 'Should apply directly to Trigger.new');
  }

  @IsTest
  static void dmlRegistrar_registerDirtyInBeforeTrigger_recordNotInNewMap() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(true);

    Account triggerRec = new Account(Id = '001000000000001AAA', Name = 'Existing');
    Map<Id, SObject> triggerNewMap = new Map<Id, SObject>{ triggerRec.Id => triggerRec };
    reg.setTriggerNewMap(triggerNewMap);

    Account otherRec = new Account(Id = '001000000000002AAA', Name = 'Other');
    reg.registerDirty(otherRec, new List<SObjectField>{ Account.Name });

    System.assertEquals('Existing', triggerRec.Name, 'Original should be unchanged');
  }

  @IsTest
  static void dmlRegistrar_rollbackTo() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setCurrentHandler('TestHandler');
    reg.setBeforeTriggerContext(false);

    reg.registerNew(new Account(Name = 'A'));
    reg.registerNew(new Contact(LastName = 'B'), Contact.AccountId, new Account());
    reg.registerDeleted(new Account(Id = '001000000000001AAA'));

    Integer snapNew = reg.getNewRecordsCount();
    Integer snapFk = reg.getFkBindingsCount();
    Integer snapDel = reg.getDeletedRecordsCount();

    reg.registerNew(new Account(Name = 'C'));
    reg.registerDeleted(new Account(Id = '001000000000002AAA'));

    System.assertEquals(3, reg.getNewRecordsCount());
    System.assertEquals(2, reg.getDeletedRecordsCount());

    reg.rollbackTo(snapNew, snapFk, snapDel);

    System.assertEquals(2, reg.getNewRecordsCount());
    System.assertEquals(1, reg.getDeletedRecordsCount());
  }

  @IsTest
  static void dmlRegistrar_rollbackConflictsTo() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);

    Account acc = new Account(Id = '001000000000001AAA', Name = 'Same');

    reg.setCurrentHandler('HandlerA');
    reg.registerDirty(acc, new List<SObjectField>{ Account.Name });

    reg.setCurrentHandler('HandlerB');
    Account accB = new Account(Id = '001000000000001AAA', Name = 'Same');
    Integer snapConflicts = reg.getConflictsCount();
    reg.registerDirty(accB, new List<SObjectField>{ Account.Name });

    System.assertEquals(1, reg.getConflictsCount());

    reg.rollbackConflictsTo(snapConflicts);
    System.assertEquals(0, reg.getConflictsCount());
  }

  @IsTest
  static void dmlRegistrar_journalRollback_newFieldRemoved() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);
    reg.setCurrentHandler('HandlerA');

    Id accId = '001000000000001AAA';
    Account acc = new Account(Id = accId, Name = 'Original');
    reg.registerDirty(acc, new List<SObjectField>{ Account.Name });

    Integer mark = reg.getJournalMark();

    Account acc2 = new Account(Id = accId, Phone = '555');
    reg.registerDirty(acc2, new List<SObjectField>{ Account.Phone });

    reg.rollbackToJournalMark(mark);

    SObject buffered = reg.getDirtyRecords().get(accId);
    System.assertEquals('Original', buffered.get('Name'));
    System.assertEquals(null, buffered.get('Phone'));
  }

  @IsTest
  static void dmlRegistrar_journalRollback_provenanceRestored() {
    DmlRegistrar reg = new DmlRegistrar();
    reg.setBeforeTriggerContext(false);

    Id accId = '001000000000001AAA';

    reg.setCurrentHandler('HandlerA');
    Account acc = new Account(Id = accId, Name = 'First');
    reg.registerDirty(acc, new List<SObjectField>{ Account.Name });

    Integer mark = reg.getJournalMark();

    reg.setCurrentHandler('HandlerB');
    Account accB = new Account(Id = accId, Name = 'First');
    reg.registerDirty(accB, new List<SObjectField>{ Account.Name });

    reg.rollbackToJournalMark(mark);

    Map<String, String> prov = reg.getFieldProvenance().get(accId);
    System.assertEquals('HandlerA', prov.get('Name'), 'Provenance should be restored to HandlerA');
  }
}
