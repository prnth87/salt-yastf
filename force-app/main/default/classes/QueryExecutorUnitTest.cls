@IsTest
private class QueryExecutorUnitTest {
  @TestSetup
  static void setupData() {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 950; i++) {
      accounts.add(new Account(Name = 'QE Test ' + i));
    }
    insert accounts;
  }

  @IsTest
  static void testSingleQueryUnder900() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> accounts = [SELECT Id FROM Account LIMIT 50];
    Set<Id> ids = new Set<Id>();
    for (Account a : accounts) {
      ids.add(a.Id);
    }

    QueryRequest req = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids,
      null,
      false,
      'TestHandler'
    );

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assert(
      results.containsKey(mergeKey),
      'Results should contain merge key'
    );
    System.assertEquals(
      ids.size(),
      results.get(mergeKey).size(),
      'Should return all queried records'
    );
  }

  @IsTest
  static void testChunkingOver900() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> accounts = [SELECT Id FROM Account];
    System.assert(
      accounts.size() >= 950,
      'TestSetup should have created 950 accounts'
    );

    Set<Id> ids = new Set<Id>();
    for (Account a : accounts) {
      ids.add(a.Id);
    }

    QueryRequest req = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids,
      null,
      false,
      'TestHandler'
    );

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assertEquals(
      ids.size(),
      results.get(mergeKey).size(),
      'Should return all 950+ records across chunks'
    );
  }

  @IsTest
  static void testSoqlBudgetGuardInChunking() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    // Set reserve to the full SOQL limit so any query will exceed budget
    QueryExecutor.setSoqlReserve(Limits.getLimitQueries());

    List<Account> accounts = [SELECT Id FROM Account];
    Set<Id> ids = new Set<Id>();
    for (Account a : accounts) {
      ids.add(a.Id);
    }
    // Ensure we have > 900 IDs to trigger the chunking path
    System.assert(ids.size() > 900, 'Need > 900 IDs to trigger chunking');

    QueryRequest req = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids,
      null,
      false,
      'TestHandler'
    );

    Test.startTest();
    Boolean threw = false;
    try {
      QueryExecutor.execute(new List<QueryRequest>{ req });
    } catch (SoqlBudgetException e) {
      threw = true;
    }
    Test.stopTest();

    System.assert(
      threw,
      'Should throw SoqlBudgetException when budget is exhausted'
    );
  }

  @IsTest
  static void testFlsEnabledAccessibleField() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> accounts = [SELECT Id FROM Account LIMIT 5];
    Set<Id> ids = new Set<Id>();
    for (Account a : accounts) {
      ids.add(a.Id);
    }

    QueryRequest req = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids,
      null,
      true,
      'TestHandler'
    );

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assert(
      results.containsKey(mergeKey),
      'Results should contain merge key'
    );
    System.assertEquals(
      ids.size(),
      results.get(mergeKey).size(),
      'Should return all queried records with FLS enabled'
    );
  }

  @IsTest
  static void testRelationshipFieldInWhere() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    Account acc = [SELECT Id FROM Account LIMIT 1];
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < 3; i++) {
      contacts.add(new Contact(LastName = 'RelTest ' + i, AccountId = acc.Id));
    }
    insert contacts;

    QueryRequest req = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.LastName },
      new Set<Id>{ acc.Id },
      Contact.AccountId,
      false,
      'TestHandler'
    );

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assert(
      results.containsKey(mergeKey),
      'Results should contain merge key'
    );
    System.assertEquals(
      3,
      results.get(mergeKey).size(),
      'Should return all 3 contacts related to the account'
    );
  }

  @IsTest
  static void testEmptyIdSet() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    QueryRequest req = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      new Set<Id>(),
      null,
      false,
      'TestHandler'
    );

    Integer queriesBefore = Limits.getQueries();

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assert(
      results.containsKey(mergeKey),
      'Results should contain merge key'
    );
    System.assertEquals(
      0,
      results.get(mergeKey).size(),
      'Empty ID set should return empty results'
    );
  }

  @IsTest
  static void testMergeKeyGrouping() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> accounts = [SELECT Id FROM Account LIMIT 10];
    Set<Id> ids1 = new Set<Id>();
    Set<Id> ids2 = new Set<Id>();
    Integer i = 0;
    for (Account a : accounts) {
      if (i < 5) {
        ids1.add(a.Id);
      } else {
        ids2.add(a.Id);
      }
      i++;
    }

    QueryRequest req1 = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids1,
      null,
      false,
      'TestHandler'
    );

    QueryRequest req2 = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids2,
      null,
      false,
      'TestHandler'
    );

    // Both requests have same SObjectType + null relationship → same merge key
    System.assertEquals(
      req1.getMergeKey(),
      req2.getMergeKey(),
      'Merge keys should match for same type and relationship'
    );

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req1, req2 }
    );
    Test.stopTest();

    String mergeKey = req1.getMergeKey();
    System.assertEquals(
      10,
      results.get(mergeKey).size(),
      'Merged results should contain all 10 records'
    );
  }

  // ── Migrated from SaltCoverageBoostTest ──

  @IsTest
  static void queryExecutor_flsWithRelField() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    Account acc = new Account(Name = 'FlsRelTest');
    insert acc;
    Contact con = new Contact(LastName = 'FlsRelChild', AccountId = acc.Id);
    insert con;

    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Contact.SObjectType)
      .fields(new List<SObjectField>{ Contact.LastName })
      .forIds(new Set<Id>{ acc.Id })
      .relatedThrough(Contact.AccountId)
      .withFLS()
      .build();

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assertEquals(1, results.get(mergeKey).size());
  }

  @IsTest
  static void queryExecutor_childSubqueryRendering() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    Account acc = new Account(Name = 'SubqueryTest');
    insert acc;
    Contact con = new Contact(LastName = 'SubChild', AccountId = acc.Id);
    insert con;

    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ acc.Id })
      .withChildSubquery(
        'Contacts',
        new List<SObjectField>{ Contact.LastName },
        null,
        5
      )
      .build();

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assertEquals(1, results.get(mergeKey).size());
  }

  @IsTest
  static void queryExecutor_setSoqlReserve() {
    QueryExecutor.resetState();
    QueryExecutor.setSoqlReserve(5);
    QueryExecutor.resetState();
  }

  @IsTest
  static void queryExecutor_flsWithChildSubqueryFieldsNoFilter() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    Account acc = new Account(Name = 'FlsChildTest');
    insert acc;
    Contact con = new Contact(LastName = 'FlsChild', AccountId = acc.Id);
    insert con;

    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ acc.Id })
      .withChildSubquery(
        'Contacts',
        new List<SObjectField>{ Contact.LastName },
        null,
        5
      )
      .withFLS()
      .build();

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    String mergeKey = req.getMergeKey();
    System.assert(results.containsKey(mergeKey));
  }
}
