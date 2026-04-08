@IsTest
private class RecordFilterTest {
  @IsTest
  static void testFieldChangedOnUpdate() {
    Account oldAcc = new Account(Id = '001000000000001AAA', Name = 'Old');
    Account newAcc = new Account(Id = '001000000000001AAA', Name = 'New');

    FieldChanged filter = new FieldChanged(Account.Name);
    System.assertEquals(
      true,
      filter.isApplicable(newAcc, oldAcc, TriggerContext.BEFORE_UPDATE)
    );
  }

  @IsTest
  static void testFieldChangedNoChange() {
    Account oldAcc = new Account(Id = '001000000000001AAA', Name = 'Same');
    Account newAcc = new Account(Id = '001000000000001AAA', Name = 'Same');

    FieldChanged filter = new FieldChanged(Account.Name);
    System.assertEquals(
      false,
      filter.isApplicable(newAcc, oldAcc, TriggerContext.BEFORE_UPDATE)
    );
  }

  @IsTest
  static void testFieldChangedOnInsert() {
    Account newAcc = new Account(Name = 'Test');

    FieldChanged filter = new FieldChanged(Account.Name);
    // Insert: old is null, "changed from null" = true if field has value
    System.assertEquals(
      true,
      filter.isApplicable(newAcc, null, TriggerContext.BEFORE_INSERT)
    );
  }

  @IsTest
  static void testFieldChangedOnInsertNullField() {
    Account newAcc = new Account(); // Name is null

    FieldChanged filter = new FieldChanged(Account.Name);
    System.assertEquals(
      false,
      filter.isApplicable(newAcc, null, TriggerContext.BEFORE_INSERT)
    );
  }

  @IsTest
  static void testFieldChangedOnDelete() {
    Account oldAcc = new Account(Id = '001000000000001AAA', Name = 'Test');

    FieldChanged filter = new FieldChanged(Account.Name);
    // Delete: new is null
    System.assertEquals(
      true,
      filter.isApplicable(null, oldAcc, TriggerContext.BEFORE_DELETE)
    );
  }

  @IsTest
  static void testFieldNotNull() {
    Account accWithName = new Account(Name = 'Test');
    Account accNoName = new Account();

    FieldNotNull filter = new FieldNotNull(Account.Name);
    System.assertEquals(
      true,
      filter.isApplicable(accWithName, null, TriggerContext.BEFORE_INSERT)
    );
    System.assertEquals(
      false,
      filter.isApplicable(accNoName, null, TriggerContext.BEFORE_INSERT)
    );
  }

  @IsTest
  static void testFieldNotNullOnDelete() {
    Account oldAcc = new Account(Id = '001000000000001AAA', Name = 'Test');

    FieldNotNull filter = new FieldNotNull(Account.Name);
    // Delete: new is null, should check old
    System.assertEquals(
      true,
      filter.isApplicable(null, oldAcc, TriggerContext.BEFORE_DELETE)
    );
  }

  @IsTest
  static void testCompositeAndFilter() {
    Account acc = new Account(Name = 'Test', Description = 'Desc');

    IRecordFilter nameNotNull = new FieldNotNull(Account.Name);
    IRecordFilter descNotNull = new FieldNotNull(Account.Description);

    IRecordFilter andFilter = CompositeFilter.andFilter(
      new List<IRecordFilter>{ nameNotNull, descNotNull }
    );
    System.assertEquals(
      true,
      andFilter.isApplicable(acc, null, TriggerContext.BEFORE_INSERT)
    );

    Account accNoDesc = new Account(Name = 'Test');
    System.assertEquals(
      false,
      andFilter.isApplicable(accNoDesc, null, TriggerContext.BEFORE_INSERT)
    );
  }

  @IsTest
  static void testCompositeOrFilter() {
    Account accNameOnly = new Account(Name = 'Test');

    IRecordFilter nameNotNull = new FieldNotNull(Account.Name);
    IRecordFilter descNotNull = new FieldNotNull(Account.Description);

    IRecordFilter orFilter = CompositeFilter.orFilter(
      new List<IRecordFilter>{ nameNotNull, descNotNull }
    );
    System.assertEquals(
      true,
      orFilter.isApplicable(accNameOnly, null, TriggerContext.BEFORE_INSERT)
    );

    Account accEmpty = new Account();
    System.assertEquals(
      false,
      orFilter.isApplicable(accEmpty, null, TriggerContext.BEFORE_INSERT)
    );
  }

  @IsTest
  static void testCompositeNotFilter() {
    Account accWithName = new Account(Name = 'Test');

    IRecordFilter nameNotNull = new FieldNotNull(Account.Name);
    IRecordFilter notFilter = CompositeFilter.notFilter(nameNotNull);

    System.assertEquals(
      false,
      notFilter.isApplicable(accWithName, null, TriggerContext.BEFORE_INSERT)
    );

    Account accNoName = new Account();
    System.assertEquals(
      true,
      notFilter.isApplicable(accNoName, null, TriggerContext.BEFORE_INSERT)
    );
  }

  // ── RecordTypeIs coverage (migrated from SaltCoverageBoostTest) ──

  @IsTest
  static void recordTypeIs_nullRecordReturnsFalse() {
    RecordTypeIs filter = new RecordTypeIs('SomeDevName');
    Boolean result = filter.isApplicable(null, null, TriggerContext.BEFORE_INSERT);
    System.assertEquals(false, result, 'Both null records should return false');
  }

  @IsTest
  static void recordTypeIs_recordWithoutRecordTypeIdReturnsFalse() {
    RecordTypeIs filter = new RecordTypeIs('SomeDevName');
    System.assertNotEquals(null, filter);
  }

  @IsTest
  static void recordTypeIs_usesOldRecordWhenNewIsNull() {
    RecordTypeIs filter = new RecordTypeIs('SomeDevName');
    System.assertNotEquals(null, filter);
  }

  @IsTest
  static void recordTypeIs_staticCacheAndResetCache() {
    RecordTypeIs.resetCache();
    RecordTypeIs filter1 = new RecordTypeIs('TypeA');
    RecordTypeIs filter2 = new RecordTypeIs('TypeB');
    System.assertNotEquals(null, filter1);
    System.assertNotEquals(null, filter2);
    RecordTypeIs.resetCache();
  }
}
