@IsTest
private class RecursionGuardTest {
  @IsTest
  static void testFieldHashComputeAndCheck() {
    RecursionGuard.reset();

    List<SObjectField> fields = new List<SObjectField>{
      Account.Name,
      Account.Description
    };
    Account acc = new Account(
      Id = '001000000000001AAA',
      Name = 'Test',
      Description = 'Desc'
    );

    String hash = RecursionGuard.computeFieldHash(acc, fields);
    String handlerKey = RecursionGuard.getHandlerKey(
      'Account',
      'TestHandler',
      TriggerContext.AFTER_UPDATE
    );

    // First time: not processed
    System.assertEquals(
      false,
      RecursionGuard.hasBeenProcessedWithSameFields(handlerKey, acc.Id, hash)
    );

    // Mark processed
    RecursionGuard.markProcessedWithHash(handlerKey, acc.Id, hash);

    // Now should be processed
    System.assertEquals(
      true,
      RecursionGuard.hasBeenProcessedWithSameFields(handlerKey, acc.Id, hash)
    );
  }

  @IsTest
  static void testFieldHashDifferentValues() {
    RecursionGuard.reset();

    List<SObjectField> fields = new List<SObjectField>{ Account.Name };
    Account acc1 = new Account(Id = '001000000000001AAA', Name = 'Old');
    Account acc2 = new Account(Id = '001000000000001AAA', Name = 'New');

    String hash1 = RecursionGuard.computeFieldHash(acc1, fields);
    String hash2 = RecursionGuard.computeFieldHash(acc2, fields);
    String handlerKey = RecursionGuard.getHandlerKey(
      'Account',
      'TestHandler',
      TriggerContext.AFTER_UPDATE
    );

    RecursionGuard.markProcessedWithHash(handlerKey, acc1.Id, hash1);

    // Different hash: should NOT be considered processed
    System.assertEquals(
      false,
      RecursionGuard.hasBeenProcessedWithSameFields(handlerKey, acc1.Id, hash2)
    );
  }

  @IsTest
  static void testInvocationCounter() {
    RecursionGuard.reset();

    String handlerKey = RecursionGuard.getHandlerKey(
      'Account',
      'TestHandler',
      TriggerContext.AFTER_INSERT
    );

    System.assertEquals(0, RecursionGuard.getInvocationCount(handlerKey));
    System.assertEquals(
      false,
      RecursionGuard.isInvocationLimitExceeded(handlerKey, 2)
    );

    RecursionGuard.incrementInvocationCount(handlerKey);
    System.assertEquals(1, RecursionGuard.getInvocationCount(handlerKey));

    RecursionGuard.incrementInvocationCount(handlerKey);
    System.assertEquals(2, RecursionGuard.getInvocationCount(handlerKey));
    System.assertEquals(
      true,
      RecursionGuard.isInvocationLimitExceeded(handlerKey, 2)
    );
  }

  @IsTest
  static void testCascadeDepth() {
    RecursionGuard.reset();

    System.assertEquals(0, RecursionGuard.getCascadeDepth());

    RecursionGuard.incrementCascadeDepth('Account');
    System.assertEquals(1, RecursionGuard.getCascadeDepth());

    RecursionGuard.incrementCascadeDepth('Contact');
    System.assertEquals(2, RecursionGuard.getCascadeDepth());

    RecursionGuard.decrementCascadeDepth();
    System.assertEquals(1, RecursionGuard.getCascadeDepth());

    RecursionGuard.decrementCascadeDepth();
    System.assertEquals(0, RecursionGuard.getCascadeDepth());
  }

  @IsTest
  static void testCascadeDepthLimitThrows() {
    RecursionGuard.reset();

    RecursionGuard.incrementCascadeDepth('Account');
    RecursionGuard.incrementCascadeDepth('Contact');
    RecursionGuard.incrementCascadeDepth('Opportunity');
    RecursionGuard.incrementCascadeDepth('Task');

    try {
      RecursionGuard.checkCascadeDepth(
        'TestHandler',
        TriggerContext.AFTER_UPDATE,
        3
      );
      System.assert(false, 'Should have thrown CascadeDepthException');
    } catch (CascadeDepthException e) {
      System.assert(e.getMessage().contains('exceeds limit'), e.getMessage());
    }
  }

  @IsTest
  static void testFieldHashCaseSensitive() {
    RecursionGuard.reset();

    List<SObjectField> fields = new List<SObjectField>{ Account.Name };
    Account acc1 = new Account(Id = '001000000000001AAA', Name = 'Active');
    Account acc2 = new Account(Id = '001000000000001AAA', Name = 'ACTIVE');

    String hash1 = RecursionGuard.computeFieldHash(acc1, fields);
    String hash2 = RecursionGuard.computeFieldHash(acc2, fields);
    String handlerKey = RecursionGuard.getHandlerKey(
      'Account',
      'TestHandler',
      TriggerContext.AFTER_UPDATE
    );

    RecursionGuard.markProcessedWithHash(handlerKey, acc1.Id, hash1);

    // Case differs: should NOT be considered processed (case-sensitive)
    System.assertEquals(
      false,
      RecursionGuard.hasBeenProcessedWithSameFields(handlerKey, acc1.Id, hash2),
      'Case-different hash should not match'
    );
  }

  @IsTest
  static void testComputeFieldHashPipeCollision() {
    RecursionGuard.reset();

    List<SObjectField> fields = new List<SObjectField>{
      Account.Name,
      Account.Description
    };

    Account acc1 = new Account(Name = 'a|b', Description = 'c');
    Account acc2 = new Account(Name = 'a', Description = 'b|c');

    String hash1 = RecursionGuard.computeFieldHash(acc1, fields);
    String hash2 = RecursionGuard.computeFieldHash(acc2, fields);

    System.assertNotEquals(
      hash1,
      hash2,
      'Pipe in value should not cause hash collision'
    );
  }

  @IsTest
  static void testComputeFieldHashNull() {
    RecursionGuard.reset();

    List<SObjectField> fields = new List<SObjectField>{ Account.Name };

    Account acc = new Account();
    String hash = RecursionGuard.computeFieldHash(acc, fields);
    System.assertNotEquals(null, hash);
    System.assert(
      hash.startsWith('0:'),
      'Null value should produce 0-length prefix'
    );
  }
}
