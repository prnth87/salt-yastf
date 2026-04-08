public inherited sharing class QueryResultCache {
  // Cache: mergeKey -> List<SObject>
  private Map<String, List<SObject>> cache = new Map<String, List<SObject>>();

  // F-QB11: Indexed lookups — built lazily on first access for O(1) access in
  // getById() and getRelated(), replacing eager index construction.
  // Structure: mergeKey -> (recordId -> List<SObject>)
  private Map<String, Map<Id, List<SObject>>> indexById = new Map<String, Map<Id, List<SObject>>>();
  // Structure: mergeKey -> (parentId -> List<SObject>)
  private Map<String, Map<Id, List<SObject>>> indexByRelField = new Map<String, Map<Id, List<SObject>>>();

  // Lazy index tracking: which merge keys have been indexed
  private Set<String> idIndexBuilt = new Set<String>();
  private Set<String> relIndexBuilt = new Set<String>();

  // Relationship field per merge key — populated during populate() for deferred index building
  private Map<String, SObjectField> relFieldByMergeKey = new Map<String, SObjectField>();

  // Track which handlers have declared interest in each merge key
  private Map<String, Set<String>> handlersByMergeKey = new Map<String, Set<String>>();

  // Track which handlers have been served
  private Map<String, Set<String>> servedHandlersByMergeKey = new Map<String, Set<String>>();

  // ---- v1.1 per-(handler, tag) eviction / cache-eviction adversarial review: per-(handler, tag) declaration + served tracking ----
  // mergeKey -> handler -> Set<tagKey>
  private Map<String, Map<String, Set<String>>> declaredByHandlerTag = new Map<String, Map<String, Set<String>>>();
  private Map<String, Map<String, Set<String>>> servedByHandlerTag = new Map<String, Map<String, Set<String>>>();

  // Eviction counter: mergeKey -> remaining consumer count (decremented on serve, evict at 0)
  private Map<String, Integer> remainingConsumers = new Map<String, Integer>();
  // Dedup: "mergeKey|handler|tagKey" pairs already served
  private Set<String> servedPairs = new Set<String>();

  // mergeKey -> the merged QueryRequest itself, so getForHandler() can read
  // idsByHandler[mergeKey][handler][tag] for declared id/field/filter sets
  // and inspect wasOrMerged for the in-memory matcher conditional matcher.
  private Map<String, QueryRequest> requestByMergeKey = new Map<String, QueryRequest>();

  private static final String NULL_TAG_KEY = '__null';

  private static String tagKey(String tag) {
    return tag == null ? NULL_TAG_KEY : tag;
  }

  public void populate(
    Map<String, List<SObject>> results,
    List<QueryRequest> requests
  ) {
    for (String key : results.keySet()) {
      cache.put(key, results.get(key));
    }

    // Store handler declarations and relationship field references for lazy indexing
    for (QueryRequest req : requests) {
      String key = req.getMergeKey();
      if (!handlersByMergeKey.containsKey(key)) {
        handlersByMergeKey.put(key, new Set<String>());
      }
      for (String handler : req.declaringHandler.split(',')) {
        handlersByMergeKey.get(key).add(handler.trim());
      }
      // Store relationship field for deferred index building in getRelated()
      if (
        req.relationshipField != null && !relFieldByMergeKey.containsKey(key)
      ) {
        relFieldByMergeKey.put(key, req.relationshipField);
      }

      // ---- v1.1 per-(handler, tag) eviction / cache-eviction adversarial review: per-(handler, tag) declaration tracking ----
      // The request's idsByHandler is keyed by mergeKey -> handler -> tagKey.
      // For an OR-merged request the inner map already includes every
      // (handler, tag) pair the merge swallowed.
      requestByMergeKey.put(key, req);
      if (req.idsByHandler != null && req.idsByHandler.containsKey(key)) {
        Map<String, Map<String, Set<Id>>> handlerTagIds = req.idsByHandler.get(
          key
        );
        if (!declaredByHandlerTag.containsKey(key)) {
          declaredByHandlerTag.put(key, new Map<String, Set<String>>());
        }
        Map<String, Set<String>> declared = declaredByHandlerTag.get(key);
        for (String handler : handlerTagIds.keySet()) {
          if (!declared.containsKey(handler)) {
            declared.put(handler, new Set<String>());
          }
          declared.get(handler).addAll(handlerTagIds.get(handler).keySet());
        }
      }
    }

    // Initialize eviction counters from declaredByHandlerTag
    for (String key : declaredByHandlerTag.keySet()) {
      Integer count = 0;
      Map<String, Set<String>> declared = declaredByHandlerTag.get(key);
      for (String handler : declared.keySet()) {
        count += declared.get(handler).size();
      }
      remainingConsumers.put(key, count);
    }
  }

  // F-QB11: O(1) lookup using lazily-built index instead of O(n) linear scan
  public List<SObject> getById(SObjectType objectType, Set<Id> ids) {
    String key = QueryRequest.buildMergeKey(objectType, null);

    // Lazy index build on first access
    if (!idIndexBuilt.contains(key)) {
      List<SObject> records = cache.get(key);
      if (records != null) {
        Map<Id, List<SObject>> idIndex = new Map<Id, List<SObject>>();
        for (SObject record : records) {
          Id recId = record.Id;
          if (recId != null) {
            if (!idIndex.containsKey(recId)) {
              idIndex.put(recId, new List<SObject>());
            }
            idIndex.get(recId).add(record);
          }
        }
        indexById.put(key, idIndex);
      }
      idIndexBuilt.add(key);
    }

    Map<Id, List<SObject>> idIndex = indexById.get(key);
    if (idIndex == null) {
      return new List<SObject>();
    }

    List<SObject> filtered = new List<SObject>();
    for (Id recordId : ids) {
      List<SObject> matches = idIndex.get(recordId);
      if (matches != null) {
        filtered.addAll(matches);
      }
    }
    return filtered;
  }

  // F-QB11: O(1) lookup using lazily-built relationship index instead of O(n) linear scan
  public List<SObject> getRelated(
    SObjectType objectType,
    SObjectField relationshipField,
    Set<Id> parentIds
  ) {
    String key = QueryRequest.buildMergeKey(objectType, relationshipField);

    // Lazy index build on first access
    if (!relIndexBuilt.contains(key)) {
      SObjectField relField = relFieldByMergeKey.get(key);
      List<SObject> records = cache.get(key);
      if (records != null && relField != null) {
        Map<Id, List<SObject>> relIndex = new Map<Id, List<SObject>>();
        for (SObject record : records) {
          Id relId = (Id) record.get(relField);
          if (relId != null) {
            if (!relIndex.containsKey(relId)) {
              relIndex.put(relId, new List<SObject>());
            }
            relIndex.get(relId).add(record);
          }
        }
        indexByRelField.put(key, relIndex);
      }
      relIndexBuilt.add(key);
    }

    Map<Id, List<SObject>> relIndex = indexByRelField.get(key);
    if (relIndex == null) {
      return new List<SObject>();
    }

    List<SObject> filtered = new List<SObject>();
    for (Id parentId : parentIds) {
      List<SObject> matches = relIndex.get(parentId);
      if (matches != null) {
        filtered.addAll(matches);
      }
    }
    return filtered;
  }

  public void markHandlerServed(String handlerName) {
    for (String key : handlersByMergeKey.keySet()) {
      if (handlersByMergeKey.get(key).contains(handlerName)) {
        if (!servedHandlersByMergeKey.containsKey(key)) {
          servedHandlersByMergeKey.put(key, new Set<String>());
        }
        servedHandlersByMergeKey.get(key).add(handlerName);
      }
    }

    evict();
  }

  private void evict() {
    List<String> keysToEvict = new List<String>();
    for (String key : handlersByMergeKey.keySet()) {
      Set<String> declared = handlersByMergeKey.get(key);
      Set<String> served = servedHandlersByMergeKey.containsKey(key)
        ? servedHandlersByMergeKey.get(key)
        : new Set<String>();
      if (served.containsAll(declared)) {
        keysToEvict.add(key);
      }
    }
    for (String key : keysToEvict) {
      cache.remove(key);
      // F-QB11: Evict index maps alongside cache entries to free heap
      indexById.remove(key);
      indexByRelField.remove(key);
      idIndexBuilt.remove(key);
      relIndexBuilt.remove(key);
      relFieldByMergeKey.remove(key);
      handlersByMergeKey.remove(key);
      servedHandlersByMergeKey.remove(key);
      remainingConsumers.remove(key);
      // Clean up servedPairs entries for this key
      List<String> toRemove = new List<String>();
      for (String pair : servedPairs) {
        if (pair.startsWith(key + '|')) {
          toRemove.add(pair);
        }
      }
      servedPairs.removeAll(new Set<String>(toRemove));
    }
  }

  // ---- v1.1 deep-clone preserve-children path/explicit-failure semantics/in-memory matcher isolated read API ----
  //
  // Returns deep clones (deep-clone preserve-children path — preserves child collections from withChildSubquery)
  // of the rows the (handler, tag) consumer declared. Filters by the declared
  // id set; when the merged request was OR-merged AND the consumer declared
  // filters, applies the matcher predicate to drop rows belonging to other
  // OR branches (in-memory matcher conditional matcher — bound to OR-merge scope only).
  //
  // explicit-failure semantics contract:
  //   - cache slot evicted             -> throw TriggerFrameworkException
  //   - unknown (handler, mergeKey, tag) declaration -> throw
  //   - known declaration with empty cache slot      -> empty list (not throw)
  public List<SObject> getForHandler(
    String handler,
    SObjectType objectType,
    SObjectField relationshipField,
    String tag
  ) {
    String key = QueryRequest.buildMergeKey(objectType, relationshipField);
    String tk = tagKey(tag);

    // explicit-failure semantics: cache evicted
    if (!cache.containsKey(key)) {
      throw new TriggerFrameworkException(
        'QueryResultCache slot evicted for mergeKey=' +
          key +
          ' (handler=' +
          handler +
          ', tag=' +
          tag +
          ')',
        handler,
        null,
        'cache-evicted'
      );
    }

    // explicit-failure semantics: unknown (handler, mergeKey, tag)
    Map<String, Set<String>> declared = declaredByHandlerTag.get(key);
    if (
      declared == null ||
      !declared.containsKey(handler) ||
      !declared.get(handler).contains(tk)
    ) {
      throw new TriggerFrameworkException(
        'Unknown (handler, mergeKey, tag) declaration: handler=' +
          handler +
          ' mergeKey=' +
          key +
          ' tag=' +
          tag,
        handler,
        null,
        'unknown-declaration'
      );
    }

    // explicit-failure semantics: empty cache slot for known declaration -> empty list (not throw)
    List<SObject> source = cache.get(key);
    if (source == null || source.isEmpty()) {
      return new List<SObject>();
    }

    // Pull the (handler, tag) declared id/field/filter sets from the merged
    // QueryRequest's 4-level provenance maps.
    QueryRequest mergedReq = requestByMergeKey.get(key);
    Set<Id> declaredIds = mergedReq.idsByHandler.get(key).get(handler).get(tk);
    Set<SObjectField> declaredFields = mergedReq.fieldsByHandler.get(key)
      .get(handler)
      .get(tk);
    List<Predicate> declaredFilters = mergedReq.filtersByHandler.get(key)
      .get(handler)
      .get(tk);

    // in-memory matcher: conditional matcher — only when wasOrMerged AND consumer declared
    // filters. The matcher drops rows that belong to other OR branches but
    // not to this consumer's logical predicate.
    Predicate matcher = null;
    if (
      mergedReq.wasOrMerged &&
      declaredFilters != null &&
      !declaredFilters.isEmpty()
    ) {
      matcher = declaredFilters.size() == 1
        ? declaredFilters[0]
        : CompositePredicate.andOf(declaredFilters);
    }

    Set<String> declaredFieldNames = new Set<String>();
    if (declaredFields != null) {
      for (SObjectField f : declaredFields) {
        declaredFieldNames.add(QueryRequest.cachedFieldName(f));
      }
    }
    if (relationshipField != null) {
      declaredFieldNames.add(QueryRequest.cachedFieldName(relationshipField));
    }
    declaredFieldNames.add('Id');

    List<SObject> result = new List<SObject>();
    for (SObject row : source) {
      // Membership: filter by relationshipField (or Id if no relField).
      Id checkId = relationshipField != null
        ? (Id) row.get(relationshipField)
        : row.Id;
      if (declaredIds != null && !declaredIds.contains(checkId)) {
        continue;
      }
      // in-memory matcher OR-merge matcher
      if (matcher != null && !matcher.matches(row)) {
        continue;
      }
      // deep-clone preserve-children path deep clone — preserves child collections from withChildSubquery.
      // Trade-off note: under OR-merge the clone may carry top-level fields
      // beyond the consumer's declared field set (the union from the merge).
      // Top-level field stripping is not performed because Apex's only
      // serialize/deserialize round-trip would lose child collections, and
      // deep-clone preserve-children path (child collection preservation) takes precedence over per-handler field projection strict
      // top-level field isolation under OR-merge. Documented in ADR 0001.
      SObject clone = row.clone(true, true, true, false);
      result.add(clone);
    }
    return result;
  }

  // per-(handler, tag) eviction / cache-eviction adversarial review: marks a (handler, tag) consumer as served. Cache row
  // storage drops for a mergeKey ONLY when EVERY declared (handler, tag)
  // consumer for that mergeKey has been served — not after the first served
  // handler. This preserves correctness when multiple consumers share an
  // OR-merged slot.
  public void markHandlerTagServed(String handler, String tag) {
    String tk = tagKey(tag);
    List<String> evictKeys = new List<String>();
    for (String key : declaredByHandlerTag.keySet()) {
      Map<String, Set<String>> handlerMap = declaredByHandlerTag.get(key);
      if (
        !handlerMap.containsKey(handler) ||
        !handlerMap.get(handler).contains(tk)
      ) {
        continue;
      }
      // Dedup: skip if this (key, handler, tag) was already served
      String pairKey = key + '|' + handler + '|' + tk;
      if (servedPairs.contains(pairKey)) {
        continue;
      }
      servedPairs.add(pairKey);

      if (!servedByHandlerTag.containsKey(key)) {
        servedByHandlerTag.put(key, new Map<String, Set<String>>());
      }
      Map<String, Set<String>> served = servedByHandlerTag.get(key);
      if (!served.containsKey(handler)) {
        served.put(handler, new Set<String>());
      }
      served.get(handler).add(tk);

      // Decrement eviction counter
      Integer remaining = remainingConsumers.get(key);
      if (remaining != null) {
        remaining--;
        remainingConsumers.put(key, remaining);
        if (remaining <= 0) {
          evictKeys.add(key);
        }
      }
    }
    for (String key : evictKeys) {
      cache.remove(key);
      indexById.remove(key);
      indexByRelField.remove(key);
      idIndexBuilt.remove(key);
      relIndexBuilt.remove(key);
      relFieldByMergeKey.remove(key);
      declaredByHandlerTag.remove(key);
      servedByHandlerTag.remove(key);
      requestByMergeKey.remove(key);
      remainingConsumers.remove(key);
      // Clean up servedPairs entries for this key
      List<String> toRemove = new List<String>();
      for (String pair : servedPairs) {
        if (pair.startsWith(key + '|')) {
          toRemove.add(pair);
        }
      }
      servedPairs.removeAll(new Set<String>(toRemove));
    }
  }

  public Boolean hasData(String mergeKey) {
    return cache.containsKey(mergeKey);
  }
}
