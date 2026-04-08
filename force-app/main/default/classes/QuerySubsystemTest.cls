@IsTest
private class QuerySubsystemTest {
  @IsTest
  static void testQueryBuilderSuccess() {
    QueryBuilder builder = new QueryBuilder('TestHandler');
    QueryRequest req = builder
      .onObject(Contact.SObjectType)
      .fields(new List<SObjectField>{ Contact.FirstName, Contact.LastName })
      .forIds(new Set<Id>{ '003000000000001AAA' })
      .build();

    System.assertNotEquals(null, req);
    System.assertEquals(Contact.SObjectType, req.targetObject);
    System.assertEquals(false, req.enforceFLS);
    System.assertEquals('TestHandler', req.declaringHandler);
  }

  @IsTest
  static void testQueryBuilderWithFLS() {
    QueryBuilder builder = new QueryBuilder('TestHandler');
    QueryRequest req = builder
      .onObject(Contact.SObjectType)
      .fields(new List<SObjectField>{ Contact.FirstName })
      .forIds(new Set<Id>{ '003000000000001AAA' })
      .withFLS()
      .build();

    System.assertEquals(true, req.enforceFLS);
  }

  @IsTest
  static void testQueryBuilderMissingIds() {
    QueryBuilder builder = new QueryBuilder('TestHandler');
    builder.onObject(Contact.SObjectType)
      .fields(new List<SObjectField>{ Contact.FirstName });

    try {
      builder.build();
      System.assert(false, 'Should have thrown exception for missing forIds');
    } catch (TriggerFrameworkException e) {
      System.assert(e.getMessage().contains('forIds'), e.getMessage());
    }
  }

  @IsTest
  static void testQueryAggregatorMerge() {
    // Two requests for same SObjectType + relationship should merge
    QueryRequest req1 = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.FirstName },
      new Set<Id>{ '003000000000001AAA' },
      Contact.AccountId,
      false,
      'Handler1'
    );
    QueryRequest req2 = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.LastName },
      new Set<Id>{ '003000000000001AAA' },
      Contact.AccountId,
      false,
      'Handler2'
    );

    QueryAggregator aggregator = new QueryAggregator();
    aggregator.addRequests(new List<QueryRequest>{ req1, req2 });
    List<QueryRequest> merged = aggregator.getMergedRequests();

    // Should merge into 1 request (same merge key, overlapping IDs)
    System.assertEquals(
      1,
      merged.size(),
      'Overlapping requests should merge into 1'
    );
  }

  @IsTest
  static void testQueryResultCache() {
    QueryResultCache cache = new QueryResultCache();

    // Simulate populated cache
    Contact c1 = new Contact(Id = '003000000000001AAA', FirstName = 'John');
    Contact c2 = new Contact(Id = '003000000000002AAA', FirstName = 'Jane');

    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      'Contact|Id' => new List<SObject>{ c1, c2 }
    };

    QueryRequest req = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.FirstName },
      new Set<Id>{ '003000000000001AAA', '003000000000002AAA' },
      null,
      false,
      'TestHandler'
    );

    cache.populate(results, new List<QueryRequest>{ req });

    List<SObject> found = cache.getById(
      Contact.SObjectType,
      new Set<Id>{ '003000000000001AAA' }
    );
    System.assertEquals(1, found.size());
    System.assertEquals('John', found[0].get('FirstName'));
  }

  @IsTest
  static void testQueryResultCacheLazyIndex() {
    // Verify that indexes are built lazily — populate() stores raw data,
    // getById() builds the index on first access
    QueryResultCache cache = new QueryResultCache();

    Contact c1 = new Contact(Id = '003000000000001AAA', FirstName = 'Alice');
    Contact c2 = new Contact(Id = '003000000000002AAA', FirstName = 'Bob');

    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      'Contact|Id' => new List<SObject>{ c1, c2 }
    };

    QueryRequest req = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.FirstName },
      new Set<Id>{ '003000000000001AAA', '003000000000002AAA' },
      null,
      false,
      'TestHandler'
    );

    cache.populate(results, new List<QueryRequest>{ req });

    // First getById call triggers lazy index build
    List<SObject> found = cache.getById(
      Contact.SObjectType,
      new Set<Id>{ '003000000000001AAA' }
    );
    System.assertEquals(1, found.size());
    System.assertEquals('Alice', found[0].get('FirstName'));

    // Second call uses pre-built index — same result
    List<SObject> found2 = cache.getById(
      Contact.SObjectType,
      new Set<Id>{ '003000000000002AAA' }
    );
    System.assertEquals(1, found2.size());
    System.assertEquals('Bob', found2[0].get('FirstName'));

    // Verify getById for non-existent ID returns empty
    List<SObject> empty = cache.getById(
      Contact.SObjectType,
      new Set<Id>{ '003000000000003AAA' }
    );
    System.assertEquals(0, empty.size());
  }

  @IsTest
  static void testQueryResultCacheEviction() {
    QueryResultCache cache = new QueryResultCache();

    Contact c1 = new Contact(Id = '003000000000001AAA', FirstName = 'John');

    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      'Contact|Id' => new List<SObject>{ c1 }
    };

    QueryRequest req = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.FirstName },
      new Set<Id>{ '003000000000001AAA' },
      null,
      false,
      'OnlyHandler'
    );

    cache.populate(results, new List<QueryRequest>{ req });

    // Before eviction
    System.assertEquals(true, cache.hasData('Contact|Id'));

    // Mark handler served -- should trigger eviction since only handler
    cache.markHandlerServed('OnlyHandler');

    // After eviction
    System.assertEquals(false, cache.hasData('Contact|Id'));
  }
}
