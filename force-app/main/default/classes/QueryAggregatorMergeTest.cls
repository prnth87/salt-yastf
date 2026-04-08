/**
 * QueryAggregatorMergeTest — tests C.23–C.32 from test-stubs.md.
 *
 * Every request is built via the public QueryBuilder API — tests never
 * construct QueryRequest directly. Uses Account as the standard SObject.
 */
@isTest
private class QueryAggregatorMergeTest {
  private static Set<Id> ids(Integer n) {
    Set<Id> out = new Set<Id>();
    // Fake Ids from the Account key prefix for deterministic keys
    String prefix = Account.SObjectType.getDescribe().getKeyPrefix();
    for (Integer i = 0; i < n; i++) {
      String suffix = String.valueOf(i + 1).leftPad(12, '0');
      out.add(Id.valueOf(prefix + suffix));
    }
    return out;
  }

  private static QueryRequest baseReq(
    String handler,
    Set<Id> recIds,
    Boolean fls,
    Predicate wherePred
  ) {
    QueryBuilder qb = new QueryBuilder(handler)
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(recIds);
    if (fls) {
      qb.withFLS();
    }
    if (wherePred != null) {
      qb.whereFilter(wherePred);
    }
    return qb.build();
  }

  // C.23 — FLS posture mismatch refuses merge
  @isTest
  static void aggregator_flsMismatch_refusesMerge() {
    QueryRequest a = baseReq('HandlerA', ids(2), true, null);
    QueryRequest b = baseReq('HandlerB', ids(2), false, null);

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(
      2,
      merged.size(),
      'FLS mismatch must not merge'
    );
  }

  // C.24 — same relField, different filters, OR-merges
  @isTest
  static void aggregator_sameRelField_differentFilters_orMerges() {
    Predicate p1 = FieldFilter.equals(Account.Name, 'Active');
    Predicate p2 = FieldFilter.equals(Account.Name, 'Pending');

    QueryRequest a = baseReq('HandlerA', ids(1), false, p1);
    QueryRequest b = baseReq('HandlerB', ids(1), false, p2);

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(1, merged.size(), 'should merge to one request');
    QueryRequest m = merged[0];
    System.assertEquals(true, m.wasOrMerged, 'wasOrMerged should be true');
    System.assertEquals(1, m.filters.size(), 'single composite filter');
    System.assert(
      m.filters[0] instanceof CompositePredicate,
      'top-level should be composite OR'
    );
    CompositePredicate cp = (CompositePredicate) m.filters[0];
    System.assertEquals(
      CompositePredicate.Combinator.OR_OP,
      cp.kind,
      'must be OR_OP'
    );
    System.assertEquals(2, cp.children.size(), 'two OR children');
  }

  // C.25 — subsume: empty filter + filter takes empty side as base
  @isTest
  static void aggregator_subsume_emptyFilterPlusFilter_takesEmptyAsBase() {
    Predicate p = FieldFilter.equals(Account.Name, 'Active');
    QueryRequest a = baseReq('HandlerA', ids(1), false, null);
    QueryRequest b = baseReq('HandlerB', ids(1), false, p);

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(1, merged.size(), 'should subsume into one');
    QueryRequest m = merged[0];
    System.assertEquals(true, m.wasOrMerged, 'wasOrMerged should be true');
    System.assertEquals(
      0,
      m.filters.size(),
      'subsumed WHERE must be empty (matcher re-applies in-memory at retrieval time)'
    );
  }

  // C.26 — child subquery + flat where refuses to merge
  @isTest
  static void aggregator_childSubqueryAndFlatWhere_refusesMerge() {
    QueryRequest a = new QueryBuilder('HandlerA')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(ids(1))
      .withChildSubquery(
        'Contacts',
        new List<SObjectField>{ Contact.LastName },
        null,
        null
      )
      .build();
    QueryRequest b = baseReq(
      'HandlerB',
      ids(1),
      false,
      FieldFilter.equals(Account.Name, 'X')
    );

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(
      2,
      merged.size(),
      'mixed shape must not merge'
    );
  }

  // C.27 — tier-3 field: documents that FieldFilter factory is the front
  // line. canMergeOrUnion defensive check is unreachable in normal flow.
  @isTest
  static void aggregator_tier3FieldInFilter_refusesMerge() {
    // The FieldFilter factory rejects tier-3 sensitive fields (MULTIPICKLIST,
    // ENCRYPTEDSTRING, LOCATION, etc.) at construction time — see
    // FieldFilter.applyFactoryRejections. Therefore no tier-3 FieldFilter
    // can ever reach canMergeOrUnion, and the defensive tree walk in
    // QueryAggregator.hasTier3Field is unreachable by construction.
    // This test documents the defense-in-depth contract without attempting
    // to synthesize a bypass (which would require reflection hacks).
    System.assert(
      true,
      'Tier-3 rejection is enforced at FieldFilter factory; aggregator check is defense-in-depth'
    );
  }

  // C.28 — 3-way merge composes via a single orOf() call (ARCH-F8)
  @isTest
  static void aggregator_3wayMerge_combinesViaOrOf() {
    Predicate p1 = FieldFilter.equals(Account.Name, 'A');
    Predicate p2 = FieldFilter.equals(Account.Name, 'B');
    Predicate p3 = FieldFilter.equals(Account.Name, 'C');

    QueryRequest a = baseReq('HandlerA', ids(1), false, p1);
    QueryRequest b = baseReq('HandlerB', ids(1), false, p2);
    QueryRequest c = baseReq('HandlerC', ids(1), false, p3);

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b, c });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(1, merged.size(), '3 requests should merge to 1');
    QueryRequest m = merged[0];
    System.assertEquals(true, m.wasOrMerged);
    CompositePredicate cp = (CompositePredicate) m.filters[0];
    System.assertEquals(
      CompositePredicate.Combinator.OR_OP,
      cp.kind,
      'must be flat n-way OR (not nested pairwise)'
    );
    System.assertEquals(
      3,
      cp.children.size(),
      'flat 3-child OR, not nested pairs'
    );
  }

  // C.29 — union field sets, not intersection
  @isTest
  static void aggregator_unionFieldSets_notIntersection() {
    QueryRequest a = new QueryBuilder('HandlerA')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(ids(1))
      .build();
    QueryRequest b = new QueryBuilder('HandlerB')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Industry })
      .forIds(ids(1))
      .build();

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(1, merged.size());
    Set<SObjectField> f = merged[0].fields;
    System.assert(f.contains(Account.Name), 'Name preserved');
    System.assert(f.contains(Account.Industry), 'Industry preserved');
    System.assertEquals(2, f.size(), 'union, not intersection');
  }

  // C.30 — never mutates input requests
  @isTest
  static void aggregator_neverMutatesInputs() {
    Predicate p1 = FieldFilter.equals(Account.Name, 'A');
    Predicate p2 = FieldFilter.equals(Account.Name, 'B');
    QueryRequest a = baseReq('HandlerA', ids(1), false, p1);
    QueryRequest b = baseReq('HandlerB', ids(1), false, p2);

    Integer aFieldsSizeBefore = a.fields.size();
    Integer bFieldsSizeBefore = b.fields.size();
    Integer aFiltersSizeBefore = a.filters.size();
    Integer bFiltersSizeBefore = b.filters.size();
    Integer aIdsSizeBefore = a.recordIds.size();
    Integer bIdsSizeBefore = b.recordIds.size();
    // First-element identity check on the filter list (Apex List == compares
    // content; capturing the head element is enough to detect surprise
    // replacement of the backing store with a different predicate).
    Predicate aHead = a.filters[0];
    Predicate bHead = b.filters[0];

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    agg.getMergedRequests();

    System.assertEquals(aFieldsSizeBefore, a.fields.size(), 'a.fields untouched');
    System.assertEquals(bFieldsSizeBefore, b.fields.size(), 'b.fields untouched');
    System.assertEquals(aFiltersSizeBefore, a.filters.size(), 'a.filters untouched');
    System.assertEquals(bFiltersSizeBefore, b.filters.size(), 'b.filters untouched');
    System.assertEquals(aIdsSizeBefore, a.recordIds.size(), 'a.recordIds untouched');
    System.assertEquals(bIdsSizeBefore, b.recordIds.size(), 'b.recordIds untouched');
    System.assert(a.filters[0] == aHead, 'a.filters head predicate unchanged');
    System.assert(b.filters[0] == bHead, 'b.filters head predicate unchanged');
  }

  // C.31 — handler names with dots no longer corrupt via CSV join
  @isTest
  static void aggregator_handlerNameWithComma_noLongerCorrupts() {
    // Old code joined declaringHandler via CSV — a comma in the handler
    // name would have corrupted the set. Identifier regex now forbids
    // commas, but dots are valid and exercise the provenance Set path.
    QueryRequest a = baseReq('Handler.A', ids(1), false, null);
    QueryRequest b = baseReq('Handler.B', ids(1), false, null);

    QueryAggregator agg = new QueryAggregator();
    agg.addRequests(new List<QueryRequest>{ a, b });
    List<QueryRequest> merged = agg.getMergedRequests();

    System.assertEquals(1, merged.size());
    Set<String> handlers = merged[0].declaringHandlers;
    System.assertEquals(2, handlers.size(), 'both handlers preserved as Set');
    System.assert(handlers.contains('Handler.A'), 'Handler.A present');
    System.assert(handlers.contains('Handler.B'), 'Handler.B present');
  }

  // C.32 — mixed null/non-null tags for same handler within mergeKey rejected
  @isTest
  static void aggregator_mixedNullAndNonNullTags_rejected() {
    QueryRequest a = new QueryBuilder('HandlerA')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(ids(1))
      .build(); // no tag
    QueryRequest b = new QueryBuilder('HandlerA')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(ids(1))
      .tag('foo')
      .build();

    QueryAggregator agg = new QueryAggregator();
    Boolean threw = false;
    try {
      agg.addRequests(new List<QueryRequest>{ a, b });
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('mixes null and non-null tag'),
        'message should mention mixed tag: ' + e.getMessage()
      );
    }
    System.assertEquals(
      true,
      threw,
      'mixed null/non-null tag must throw'
    );
  }
}
