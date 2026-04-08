@IsTest
private class QueryResultCacheTest {
  @IsTest
  static void queryResultCache_getById_noDataReturnsEmpty() {
    QueryResultCache cache = new QueryResultCache();
    List<SObject> result = cache.getById(Account.SObjectType, new Set<Id>{ '001000000000001AAA' });
    System.assertEquals(0, result.size());
  }

  @IsTest
  static void queryResultCache_getRelated_noDataReturnsEmpty() {
    QueryResultCache cache = new QueryResultCache();
    List<SObject> result = cache.getRelated(
      Contact.SObjectType,
      Contact.AccountId,
      new Set<Id>{ '001000000000001AAA' }
    );
    System.assertEquals(0, result.size());
  }

  @IsTest
  static void queryResultCache_getRelated_lazyIndex() {
    QueryResultCache cache = new QueryResultCache();
    Contact c1 = new Contact(Id = '003000000000001AAA', AccountId = '001000000000001AAA', LastName = 'A');
    Contact c2 = new Contact(Id = '003000000000002AAA', AccountId = '001000000000001AAA', LastName = 'B');
    Contact c3 = new Contact(Id = '003000000000003AAA', AccountId = '001000000000002AAA', LastName = 'C');

    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      'Contact|AccountId' => new List<SObject>{ c1, c2, c3 }
    };

    QueryRequest req = new QueryRequest(
      Contact.SObjectType,
      new Set<SObjectField>{ Contact.LastName },
      new Set<Id>{ '001000000000001AAA', '001000000000002AAA' },
      Contact.AccountId,
      false,
      'TestHandler'
    );

    cache.populate(results, new List<QueryRequest>{ req });

    // First call triggers lazy index build
    List<SObject> related = cache.getRelated(
      Contact.SObjectType,
      Contact.AccountId,
      new Set<Id>{ '001000000000001AAA' }
    );
    System.assertEquals(2, related.size());

    // Second call uses pre-built index
    List<SObject> related2 = cache.getRelated(
      Contact.SObjectType,
      Contact.AccountId,
      new Set<Id>{ '001000000000002AAA' }
    );
    System.assertEquals(1, related2.size());

    // Non-existent parent returns empty
    List<SObject> empty = cache.getRelated(
      Contact.SObjectType,
      Contact.AccountId,
      new Set<Id>{ '001000000000099AAA' }
    );
    System.assertEquals(0, empty.size());
  }

  @IsTest
  static void queryResultCache_markHandlerTagServed_evictsWhenAllServed() {
    QueryResultCache cache = new QueryResultCache();

    QueryRequest req1 = new QueryBuilder('HandlerA')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .tag('tagA')
      .build();
    QueryRequest req2 = new QueryBuilder('HandlerB')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .tag('tagB')
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req1, req2 });
    List<QueryRequest> merged = agg.getMergedRequests();

    Account acc = new Account(Id = '001000000000001AAA', Name = 'Test');
    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      merged[0].getMergeKey() => new List<SObject>{ acc }
    };
    cache.populate(results, merged);
    String mergeKey = merged[0].getMergeKey();

    System.assertEquals(true, cache.hasData(mergeKey));

    cache.markHandlerTagServed('HandlerA', 'tagA');
    System.assertEquals(true, cache.hasData(mergeKey), 'Not all consumers served yet');

    cache.markHandlerTagServed('HandlerB', 'tagB');
    System.assertEquals(false, cache.hasData(mergeKey), 'All consumers served, should evict');
  }

  @IsTest
  static void queryResultCache_markHandlerTagServed_dedupSkip() {
    QueryResultCache cache = new QueryResultCache();

    QueryRequest req1 = new QueryBuilder('HandlerA')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .tag('tagA')
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req1 });
    List<QueryRequest> merged = agg.getMergedRequests();

    Account acc = new Account(Id = '001000000000001AAA', Name = 'Test');
    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      merged[0].getMergeKey() => new List<SObject>{ acc }
    };
    cache.populate(results, merged);

    cache.markHandlerTagServed('HandlerA', 'tagA');
    cache.markHandlerTagServed('HandlerA', 'tagA');
    // No exception means success
  }

  @IsTest
  static void queryResultCache_getForHandler_evictedThrows() {
    QueryResultCache cache = new QueryResultCache();
    Boolean threw = false;
    try {
      cache.getForHandler('SomeHandler', Account.SObjectType, null, null);
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('evicted'));
    }
    System.assert(threw, 'getForHandler on evicted slot should throw');
  }

  @IsTest
  static void queryResultCache_getForHandler_unknownDeclarationThrows() {
    QueryResultCache cache = new QueryResultCache();

    QueryRequest req = new QueryBuilder('KnownHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req });
    List<QueryRequest> merged = agg.getMergedRequests();

    Account acc = new Account(Id = '001000000000001AAA', Name = 'Test');
    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      merged[0].getMergeKey() => new List<SObject>{ acc }
    };
    cache.populate(results, merged);

    Boolean threw = false;
    try {
      cache.getForHandler('UnknownHandler', Account.SObjectType, null, null);
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('Unknown'));
    }
    System.assert(threw, 'getForHandler with unknown handler should throw');
  }

  @IsTest
  static void queryResultCache_getForHandler_emptySlotReturnsEmpty() {
    QueryResultCache cache = new QueryResultCache();

    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req });
    List<QueryRequest> merged = agg.getMergedRequests();

    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      merged[0].getMergeKey() => new List<SObject>()
    };
    cache.populate(results, merged);

    List<SObject> result = cache.getForHandler('TestHandler', Account.SObjectType, null, null);
    System.assertEquals(0, result.size(), 'Empty cache slot should return empty list');
  }

  @IsTest
  static void queryResultCache_getForHandler_success() {
    QueryResultCache cache = new QueryResultCache();

    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req });
    List<QueryRequest> merged = agg.getMergedRequests();

    Account acc = new Account(Id = '001000000000001AAA', Name = 'Test');
    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      merged[0].getMergeKey() => new List<SObject>{ acc }
    };
    cache.populate(results, merged);

    List<SObject> result = cache.getForHandler('TestHandler', Account.SObjectType, null, null);
    System.assertEquals(1, result.size());
    System.assertEquals('Test', result[0].get('Name'));
  }

  @IsTest
  static void queryResultCache_getForHandler_withRelationshipField() {
    QueryResultCache cache = new QueryResultCache();

    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Contact.SObjectType)
      .fields(new List<SObjectField>{ Contact.LastName })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .relatedThrough(Contact.AccountId)
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ req });
    List<QueryRequest> merged = agg.getMergedRequests();

    Contact con = new Contact(Id = '003000000000001AAA', AccountId = '001000000000001AAA', LastName = 'Test');
    Map<String, List<SObject>> results = new Map<String, List<SObject>>{
      merged[0].getMergeKey() => new List<SObject>{ con }
    };
    cache.populate(results, merged);

    List<SObject> result = cache.getForHandler('TestHandler', Contact.SObjectType, Contact.AccountId, null);
    System.assertEquals(1, result.size());
  }

  @IsTest
  static void queryResultCache_markHandlerTagServed_noMatchNoop() {
    QueryResultCache cache = new QueryResultCache();
    cache.markHandlerTagServed('NonExistent', 'noTag');
  }
}
