public inherited sharing class QueryExecutor {
  private static final Integer MAX_IDS_PER_QUERY = 900;
  private static Integer soqlReserve = 10;

  public static void setSoqlReserve(Integer r) {
    soqlReserve = r;
  }

  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void resetState() {
    soqlReserve = 10;
  }

  public static Map<String, List<SObject>> execute(
    List<QueryRequest> requests
  ) {
    Map<String, List<SObject>> results = new Map<String, List<SObject>>();

    for (QueryRequest req : requests) {
      String mergeKey = req.getMergeKey();

      if (!results.containsKey(mergeKey)) {
        results.put(mergeKey, new List<SObject>());
      }

      if (req.recordIds.size() > MAX_IDS_PER_QUERY) {
        // Split large ID sets into chunks to avoid SOQL IN clause limits (withChunkedIds dimension preservation).
        List<Id> allIds = new List<Id>(req.recordIds);
        for (
          Integer offset = 0;
          offset < allIds.size();
          offset += MAX_IDS_PER_QUERY
        ) {
          // SOQL budget guard: ensure headroom before each chunk query
          if (
            Limits.getQueries() + 1 >
            Limits.getLimitQueries() - soqlReserve
          ) {
            throw new SoqlBudgetException(
              'SOQL budget exhausted while splitting large ID set (' +
                allIds.size() +
                ' IDs): used ' +
                Limits.getQueries() +
                ' of ' +
                Limits.getLimitQueries() +
                ' (reserve=' +
                soqlReserve +
                ')',
              req.declaringHandler,
              null,
              Limits.getQueries(),
              Limits.getLimitQueries() - soqlReserve
            );
          }

          Integer endIdx = Math.min(offset + MAX_IDS_PER_QUERY, allIds.size());
          Set<Id> chunk = new Set<Id>();
          for (Integer i = offset; i < endIdx; i++) {
            chunk.add(allIds[i]);
          }

          // withChunkedIds dimension preservation: preserve all v1.1 state (filters, tag, childSubquery,
          // provenance maps, wasOrMerged) on the chunked request.
          QueryRequest chunkReq = req.withChunkedIds(chunk);
          BuiltQuery bq = buildSOQLAndBinds(chunkReq);
          // explicit AccessLevel: explicit SYSTEM_MODE on every Database.queryWithBinds call
          List<SObject> queryResults = Database.queryWithBinds(
            bq.soql,
            bq.bindMap,
            AccessLevel.SYSTEM_MODE
          );
          results.get(mergeKey).addAll(queryResults);
        }
      } else if (!req.recordIds.isEmpty()) {
        BuiltQuery bq = buildSOQLAndBinds(req);
        // explicit AccessLevel: explicit SYSTEM_MODE on every Database.queryWithBinds call
        List<SObject> queryResults = Database.queryWithBinds(
          bq.soql,
          bq.bindMap,
          AccessLevel.SYSTEM_MODE
        );
        results.get(mergeKey).addAll(queryResults);
      }
    }

    return results;
  }

  // Small wrapper bundling rendered SOQL with the bindMap collected by
  // BindContext during render. bind-name isolation: a fresh BindContext is created per
  // buildSOQLAndBinds invocation so bind names never leak across requests.
  private class BuiltQuery {
    String soql;
    Map<String, Object> bindMap;
    BuiltQuery(String s, Map<String, Object> b) {
      this.soql = s;
      this.bindMap = b;
    }
  }

  // Renders SELECT, WHERE (relField IN :saltIds [+ AND predicate-tree]),
  // and optional child subquery via the shared BindContext. Performs the
  // FLS gate scope FLS gate over fields ∪ predicateFields ∪ childSubqueryFields when
  // req.enforceFLS is true.
  private static BuiltQuery buildSOQLAndBinds(QueryRequest req) {
    BindContext ctx = new BindContext(); // bind-name isolation: fresh per invocation
    String objectName = QueryRequest.cachedTypeName(req.targetObject);

    // 1. Collect SELECT field names. OR-merge with union field sets: req.fields is the union (post-merge).
    Set<String> fieldNames = new Set<String>();
    fieldNames.add('Id');
    for (SObjectField f : req.fields) {
      fieldNames.add(QueryRequest.cachedFieldName(f));
    }
    if (req.relationshipField != null) {
      fieldNames.add(QueryRequest.cachedFieldName(req.relationshipField));
    }

    // 2. FLS gate scope: when enforceFLS, gate scope = fields ∪ predicateFields ∪
    //    childSubqueryFields. Predicate field FLS prevents oracle inference
    //    via filter shape on inaccessible fields.
    if (req.enforceFLS) {
      Set<SObjectField> allFlsFields = new Set<SObjectField>();
      if (req.fields != null) {
        allFlsFields.addAll(req.fields);
      }
      if (req.relationshipField != null) {
        allFlsFields.add(req.relationshipField);
      }
      if (req.filters != null) {
        for (Predicate p : req.filters) {
          collectLeafFields(p, allFlsFields);
        }
      }
      if (req.childSubquery != null) {
        if (req.childSubquery.childFields != null) {
          allFlsFields.addAll(req.childSubquery.childFields);
        }
        if (req.childSubquery.childFilter != null) {
          collectLeafFields(req.childSubquery.childFilter, allFlsFields);
        }
      }
      for (SObjectField field : allFlsFields) {
        DescribeFieldResult dfr = field.getDescribe();
        if (!dfr.isAccessible()) {
          throw new FlsException(
            'Field ' +
              dfr.getName() +
              ' on ' +
              objectName +
              ' is not accessible to the current user',
            req.declaringHandler,
            null,
            dfr.getName(),
            objectName
          );
        }
      }
    }

    // 3. WHERE clause: relField IN :saltIds [+ AND (predicate-tree)]
    String relFieldName = req.relationshipField != null
      ? QueryRequest.cachedFieldName(req.relationshipField)
      : 'Id';
    ctx.registerBind('saltIds', req.recordIds);
    String whereClause = relFieldName + ' IN :saltIds';

    if (req.filters != null && !req.filters.isEmpty()) {
      Predicate combined = req.filters.size() == 1
        ? req.filters[0]
        : CompositePredicate.andOf(req.filters);
      whereClause += ' AND ' + combined.render(ctx);
    }

    // 4. SELECT clause + optional child subquery (child-subquery support) — child binds flow
    //    through the shared BindContext into the parent bindMap.
    String selectClause = String.join(new List<String>(fieldNames), ', ');
    if (req.childSubquery != null) {
      selectClause += ', ' + req.childSubquery.render(ctx);
    }

    String soql =
      'SELECT ' +
      selectClause +
      ' FROM ' +
      objectName +
      ' WHERE ' +
      whereClause;

    return new BuiltQuery(soql, ctx.bindMap);
  }

  // Recursively walks a Predicate tree and accumulates the SObjectField of
  // every FieldFilter leaf into acc. Used by the FLS gate scope FLS gate.
  private static void collectLeafFields(Predicate p, Set<SObjectField> acc) {
    if (p instanceof FieldFilter) {
      acc.add(((FieldFilter) p).field);
      return;
    }
    if (p instanceof CompositePredicate) {
      for (Predicate child : ((CompositePredicate) p).children) {
        collectLeafFields(child, acc);
      }
    }
  }
}
