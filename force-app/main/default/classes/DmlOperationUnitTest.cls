@IsTest
private class DmlOperationUnitTest {
  @IsTest
  static void testInsertSuccess() {
    List<Account> accs = new List<Account>();
    for (Integer i = 0; i < 5; i++) {
      accs.add(new Account(Name = 'DmlOp Test ' + i));
    }

    Test.startTest();
    DmlOperation op = DmlOperation.forInsert(accs).execute();
    Test.stopTest();

    System.assertEquals(true, op.isFullSuccess(), 'All inserts should succeed');
    System.assertEquals(5, op.getSuccessCount(), 'Should have 5 successes');
    System.assertEquals(0, op.getFailureCount(), 'Should have 0 failures');
    System.assertEquals(0, op.getErrors().size(), 'Should have no errors');
  }

  @IsTest
  static void testInsertPartialFailure() {
    List<Contact> contacts = new List<Contact>();
    contacts.add(new Contact(LastName = 'Valid Contact'));
    contacts.add(new Contact()); // Missing required LastName

    Test.startTest();
    DmlOperation op = DmlOperation.forInsert(contacts)
      .allOrNone(false)
      .execute();
    Test.stopTest();

    System.assert(op.getFailureCount() > 0, 'Should have at least one failure');
    System.assert(!op.isFullSuccess(), 'Should not be full success');

    List<DmlOperation.DmlError> errors = op.getErrors();
    System.assert(!errors.isEmpty(), 'Should have error details');
    DmlOperation.DmlError firstErr = errors[0];
    System.assertNotEquals(
      null,
      firstErr.message,
      'Error message should be populated'
    );
    System.assertNotEquals(
      null,
      firstErr.statusCode,
      'Status code should be populated'
    );
  }

  @IsTest
  static void testInsertAllOrNoneThrows() {
    List<Contact> contacts = new List<Contact>();
    contacts.add(new Contact()); // Missing required LastName

    Test.startTest();
    Boolean threw = false;
    try {
      DmlOperation.forInsert(contacts).allOrNone(true).execute();
    } catch (DmlException e) {
      threw = true;
    }
    Test.stopTest();

    System.assert(
      threw,
      'Should throw DmlException when allOrNone is true and record is invalid'
    );
  }

  @IsTest
  static void testInsertEmptyList() {
    List<Account> accs = new List<Account>();

    Test.startTest();
    DmlOperation op = DmlOperation.forInsert(accs).execute();
    Test.stopTest();

    System.assertEquals(
      true,
      op.isFullSuccess(),
      'Empty list should be full success'
    );
    System.assertEquals(0, op.getSuccessCount(), 'No records processed');
    System.assertEquals(0, op.getFailureCount(), 'No failures');
  }

  @IsTest
  static void testInsertNullList() {
    Test.startTest();
    DmlOperation op = DmlOperation.forInsert(null).execute();
    Test.stopTest();

    System.assertEquals(
      true,
      op.isFullSuccess(),
      'Null list should be full success'
    );
    System.assertEquals(0, op.getSuccessCount(), 'No records processed');
    System.assertEquals(0, op.getFailureCount(), 'No failures');
  }

  @IsTest
  static void testUpdateSuccess() {
    Account acc = new Account(Name = 'Before Update');
    insert acc;

    acc.Name = 'After Update';

    Test.startTest();
    DmlOperation op = DmlOperation.forUpdate(new List<Account>{ acc })
      .execute();
    Test.stopTest();

    System.assertEquals(true, op.isFullSuccess(), 'Update should succeed');
    System.assertEquals(1, op.getSuccessCount(), 'Should have 1 success');

    Account updated = [SELECT Name FROM Account WHERE Id = :acc.Id];
    System.assertEquals('After Update', updated.Name, 'Name should be updated');
  }

  @IsTest
  static void testDeleteSuccess() {
    Account acc = new Account(Name = 'To Delete');
    insert acc;

    Test.startTest();
    DmlOperation op = DmlOperation.forDelete(new List<Account>{ acc })
      .execute();
    Test.stopTest();

    System.assertEquals(true, op.isFullSuccess(), 'Delete should succeed');
    System.assertEquals(1, op.getSuccessCount(), 'Should have 1 success');

    List<Account> remaining = [SELECT Id FROM Account WHERE Id = :acc.Id];
    System.assertEquals(0, remaining.size(), 'Account should be deleted');
  }

  @IsTest
  static void testDmlErrorFields() {
    List<Contact> contacts = new List<Contact>();
    contacts.add(new Contact(LastName = 'Good Contact'));
    contacts.add(new Contact()); // Missing required LastName — index 1

    Test.startTest();
    DmlOperation op = DmlOperation.forInsert(contacts)
      .allOrNone(false)
      .execute();
    Test.stopTest();

    List<DmlOperation.DmlError> errors = op.getErrors();
    System.assert(!errors.isEmpty(), 'Should have at least one DmlError');

    DmlOperation.DmlError err = errors[0];
    System.assertNotEquals(
      null,
      err.statusCode,
      'statusCode should be populated'
    );
    System.assertNotEquals(null, err.message, 'message should be populated');
    System.assert(err.message.length() > 0, 'message should be non-empty');
    System.assertNotEquals(
      null,
      err.listIndex,
      'listIndex should be populated'
    );
    System.assertEquals(
      1,
      err.listIndex,
      'listIndex should be 1 for second record'
    );
  }
}
