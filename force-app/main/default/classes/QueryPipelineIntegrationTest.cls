@IsTest
private class QueryPipelineIntegrationTest {
  @TestSetup
  static void setupData() {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 10; i++) {
      accounts.add(
        new Account(
          Name = 'QPInteg ' + i,
          Industry = 'Technology',
          Phone = '555-000' + i,
          Website = 'https://test' + i + '.example.com'
        )
      );
    }
    insert accounts;

    Account parentAcc = accounts[0];
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < 3; i++) {
      contacts.add(
        new Contact(
          LastName = 'QPContact ' + i,
          FirstName = 'Test',
          AccountId = parentAcc.Id
        )
      );
    }
    insert contacts;
  }

  @IsTest
  static void testAggregateExecuteAndCache() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> allAccounts = [SELECT Id FROM Account ORDER BY Name LIMIT 5];
    Set<Id> idsA = new Set<Id>();
    Set<Id> idsB = new Set<Id>();
    Set<Id> allIds = new Set<Id>();

    for (Integer i = 0; i < allAccounts.size(); i++) {
      Id accId = allAccounts[i].Id;
      allIds.add(accId);
      if (i < 3) {
        idsA.add(accId);
      }
      idsB.add(accId);
    }

    // Handler A: Account.Name on 3 IDs
    QueryRequest reqA = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      idsA,
      null,
      false,
      'HandlerA'
    );

    // Handler B: Account.Name + Account.Industry on all 5 IDs
    QueryRequest reqB = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name, Account.Industry },
      idsB,
      null,
      false,
      'HandlerB'
    );

    // Same merge key — both are Account|Id
    System.assertEquals(
      reqA.getMergeKey(),
      reqB.getMergeKey(),
      'Merge keys should match for same type with null relationship'
    );

    // Aggregate
    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ reqA, reqB });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(
      1,
      merged.size(),
      'Overlapping requests should merge into 1'
    );

    // Execute
    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(merged);
    Test.stopTest();

    String mergeKey = merged[0].getMergeKey();
    System.assert(
      results.containsKey(mergeKey),
      'Results should contain the merged key'
    );
    System.assertEquals(
      allIds.size(),
      results.get(mergeKey).size(),
      'Should return all 5 accounts from merged query'
    );

    // Populate cache and verify
    QueryResultCache cache = new QueryResultCache();
    cache.populate(results, merged);

    List<SObject> cached = cache.getById(Account.SObjectType, allIds);
    System.assertEquals(
      allIds.size(),
      cached.size(),
      'Cache getById should return all 5 accounts'
    );

    System.assertEquals(
      true,
      cache.hasData(mergeKey),
      'Cache should report data present for merge key'
    );
  }

  @IsTest
  static void testMergeOccursEvenWithDisjointSets() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> allAccounts = [SELECT Id FROM Account ORDER BY Name LIMIT 6];
    Set<Id> idsA = new Set<Id>();
    Set<Id> idsB = new Set<Id>();

    for (Integer i = 0; i < allAccounts.size(); i++) {
      if (i < 3) {
        idsA.add(allAccounts[i].Id);
      } else {
        idsB.add(allAccounts[i].Id);
      }
    }

    // Completely disjoint IDs and mostly disjoint fields
    QueryRequest reqA = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      idsA,
      null,
      false,
      'HandlerA'
    );

    QueryRequest reqB = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Industry, Account.Phone, Account.Website },
      idsB,
      null,
      false,
      'HandlerB'
    );

    // ID ratio = union(6) / max(3) = 2.0, field ratio = union(4) / max(3) = 1.33
    // Merge-decline requires BOTH > 2.0 (strict), so merge should occur
    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ reqA, reqB });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(
      1,
      merged.size(),
      'Disjoint sets should still merge — ratio 2.0 does not exceed strict > 2.0 threshold'
    );

    // Verify merged request contains union of all IDs
    QueryRequest m = merged[0];
    System.assertEquals(
      6,
      m.recordIds.size(),
      'Merged request should have union of 6 IDs'
    );
    System.assertEquals(
      4,
      m.fields.size(),
      'Merged request should have union of 4 fields'
    );
  }

  @IsTest
  static void testCacheEvictionAfterAllHandlersServed() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> accounts = [SELECT Id, Name FROM Account LIMIT 3];
    Set<Id> ids = new Set<Id>();
    for (Account a : accounts) {
      ids.add(a.Id);
    }

    QueryRequest reqA = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids,
      null,
      false,
      'HandlerA'
    );
    QueryRequest reqB = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      ids,
      null,
      false,
      'HandlerB'
    );

    // Aggregate and execute
    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ reqA, reqB });
    List<QueryRequest> merged = agg.getMergedRequests();

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(merged);
    Test.stopTest();

    String mergeKey = merged[0].getMergeKey();

    // Populate cache with merged request (declaringHandler = "HandlerA,HandlerB")
    QueryResultCache cache = new QueryResultCache();
    cache.populate(results, merged);

    System.assertEquals(
      true,
      cache.hasData(mergeKey),
      'Cache should have data before eviction'
    );

    // Serve first handler — cache should persist (HandlerB not yet served)
    cache.markHandlerServed('HandlerA');
    System.assertEquals(
      true,
      cache.hasData(mergeKey),
      'Cache should persist with one handler still unserved'
    );

    // Serve second handler — all handlers served, cache should evict
    cache.markHandlerServed('HandlerB');
    System.assertEquals(
      false,
      cache.hasData(mergeKey),
      'Cache should evict after all handlers served'
    );
  }

  @IsTest
  static void testCacheLazyIndexConsistency() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    List<Account> accounts = [SELECT Id, Name FROM Account LIMIT 5];
    Set<Id> allIds = new Set<Id>();
    for (Account a : accounts) {
      allIds.add(a.Id);
    }

    QueryRequest req = new QueryRequest(
      Account.SObjectType,
      new Set<SObjectField>{ Account.Name },
      allIds,
      null,
      false,
      'TestHandler'
    );

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(
      new List<QueryRequest>{ req }
    );
    Test.stopTest();

    QueryResultCache cache = new QueryResultCache();
    cache.populate(results, new List<QueryRequest>{ req });

    // First call triggers lazy index build
    Id firstId = accounts[0].Id;
    List<SObject> first = cache.getById(
      Account.SObjectType,
      new Set<Id>{ firstId }
    );
    System.assertEquals(
      1,
      first.size(),
      'First getById should return 1 record'
    );
    System.assertEquals(
      firstId,
      first[0].Id,
      'First getById should return correct record'
    );

    // Second call uses pre-built index — same consistent result
    Id secondId = accounts[1].Id;
    List<SObject> second = cache.getById(
      Account.SObjectType,
      new Set<Id>{ secondId }
    );
    System.assertEquals(
      1,
      second.size(),
      'Second getById should return 1 record'
    );
    System.assertEquals(
      secondId,
      second[0].Id,
      'Second getById should return correct record'
    );

    // Full set retrieval
    List<SObject> all = cache.getById(Account.SObjectType, allIds);
    System.assertEquals(
      allIds.size(),
      all.size(),
      'getById with all IDs should return all records'
    );
  }

  @IsTest
  static void testRelationshipFieldQuerying() {
    QueryExecutor.resetState();
    QueryRequest.resetCaches();

    Account parentAcc = [
      SELECT Id
      FROM Account
      WHERE Name = 'QPInteg 0'
      LIMIT 1
    ];
    Set<Id> parentIds = new Set<Id>{ parentAcc.Id };

    QueryRequest req = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.LastName, Contact.FirstName },
      parentIds,
      Contact.AccountId,
      false,
      'RelHandler'
    );

    String mergeKey = req.getMergeKey();
    System.assertEquals(
      'Contact|AccountId',
      mergeKey,
      'Merge key should reflect relationship field'
    );

    // Execute through full pipeline
    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req });
    List<QueryRequest> merged = agg.getMergedRequests();

    Test.startTest();
    Map<String, List<SObject>> results = QueryExecutor.execute(merged);
    Test.stopTest();

    System.assertEquals(
      3,
      results.get(mergeKey).size(),
      'Should return 3 contacts related to parent account'
    );

    // Populate cache and use getRelated
    QueryResultCache cache = new QueryResultCache();
    cache.populate(results, merged);

    List<SObject> related = cache.getRelated(
      Contact.SObjectType,
      Contact.AccountId,
      parentIds
    );
    System.assertEquals(
      3,
      related.size(),
      'getRelated should return 3 contacts for parent account'
    );

    // Verify eviction via markHandlerServed
    cache.markHandlerServed('RelHandler');
    System.assertEquals(
      false,
      cache.hasData(mergeKey),
      'Cache should evict after handler served'
    );
  }
}
