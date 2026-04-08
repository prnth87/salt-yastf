public inherited sharing class QueryRequest {
  public SObjectType targetObject { get; private set; }
  public Set<SObjectField> fields { get; private set; }
  public Set<Id> recordIds { get; private set; }
  public SObjectField relationshipField { get; private set; }
  public Boolean enforceFLS { get; private set; }
  // Legacy single-handler field — preserved for back-compat with QueryExecutor
  // exception messages and earlier callers using the String constructor.
  public String declaringHandler { get; private set; }

  // Multi-handler / structured-provenance fields. Together they capture
  // the per-(merge-key, handler, tag) projection that getForHandler uses
  // to return each handler its own slice of an aggregated query result,
  // including filters and field sets, plus the wasOrMerged flag that
  // tells the cache whether the in-memory matcher needs to re-apply.
  public Set<String> declaringHandlers { get; private set; }
  public String tag { get; private set; }
  public List<Predicate> filters { get; private set; }
  public ChildSubqueryDescriptor childSubquery { get; private set; }
  public Map<String, Map<String, Map<String, Set<Id>>>> idsByHandler { get; private set; }
  public Map<String, Map<String, Map<String, Set<SObjectField>>>> fieldsByHandler { get; private set; }
  public Map<String, Map<String, Map<String, List<Predicate>>>> filtersByHandler { get; private set; }
  public Boolean wasOrMerged { get; private set; }

  // Sentinel for null tags inside the 4-level provenance maps
  // (Apex map keys may not be literal null when iterating reliably; we
  // canonicalize null -> '__null' for storage and key lookups).
  public static final String NULL_TAG_KEY = '__null';

  // Identifier validation (handler/tag name validation) — handler names and tags must match.
  // Reserved bind/field prefix is '__salt_' (lowercase per BindContext).
  private static final Pattern IDENT_PATTERN = Pattern.compile('^[A-Za-z0-9_.]+$');
  private static final String RESERVED_PREFIX = '__salt_';

  private final String mergeKey;

  // QB-3: Static caches for SObjectType and SObjectField name strings.
  // Avoids repeated getDescribe().getName() calls when many QueryRequests
  // share the same types/fields within a single transaction.
  private static Map<SObjectType, String> typeNameCache = new Map<SObjectType, String>();
  private static Map<SObjectField, String> fieldNameCache = new Map<SObjectField, String>();

  // QB-3: Cached accessors to avoid redundant describe calls
  public static String cachedTypeName(SObjectType t) {
    String name = typeNameCache.get(t);
    if (name == null) {
      name = t.getDescribe().getName();
      typeNameCache.put(t, name);
    }
    return name;
  }

  public static String cachedFieldName(SObjectField f) {
    String name = fieldNameCache.get(f);
    if (name == null) {
      name = f.getDescribe().getName();
      fieldNameCache.put(f, name);
    }
    return name;
  }

  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void resetCaches() {
    typeNameCache.clear();
    fieldNameCache.clear();
  }

  // ---- helpers ----

  private static String tagKey(String tagValue) {
    return tagValue == null ? NULL_TAG_KEY : tagValue;
  }

  private static void validateHandlerName(String handlerName) {
    if (handlerName == null || handlerName.length() == 0) {
      throw new TriggerFrameworkException(
        'declaringHandler must be a non-empty identifier'
      );
    }
    if (!IDENT_PATTERN.matcher(handlerName).matches()) {
      throw new TriggerFrameworkException(
        'declaringHandler must match ^[A-Za-z0-9_.]+$ — got: ' + handlerName
      );
    }
    if (handlerName.toLowerCase().startsWith(RESERVED_PREFIX)) {
      throw new TriggerFrameworkException(
        'declaringHandler may not start with reserved prefix __salt_ — got: ' +
          handlerName
      );
    }
  }

  private static void validateTag(String tagValue) {
    if (tagValue == null) {
      return;
    }
    if (tagValue.length() == 0) {
      throw new TriggerFrameworkException('tag must be non-empty when set');
    }
    if (!IDENT_PATTERN.matcher(tagValue).matches()) {
      throw new TriggerFrameworkException(
        'tag must match ^[A-Za-z0-9_.]+$ — got: ' + tagValue
      );
    }
    if (tagValue.toLowerCase().startsWith(RESERVED_PREFIX)) {
      throw new TriggerFrameworkException(
        'tag may not start with reserved prefix __salt_ — got: ' + tagValue
      );
    }
  }

  // ---- constructors ----

  // back-compat String constructor back-compat: legacy 6-arg constructor. Seeds v1.1 state with empty
  // filters, null tag/childSubquery, and provenance maps containing only
  // this handler under the null tag key.
  public QueryRequest(
    SObjectType targetObject,
    Set<SObjectField> fields,
    Set<Id> recordIds,
    SObjectField relationshipField,
    Boolean enforceFLS,
    String declaringHandler
  ) {
    this(
      targetObject,
      fields,
      recordIds,
      relationshipField,
      enforceFLS,
      declaringHandler,
      null,
      new List<Predicate>(),
      null
    );
  }

  // v1.1 builder-facing constructor — accepts tag, filters, childSubquery
  // alongside the legacy 6 args. Used by QueryBuilder.build().
  public QueryRequest(
    SObjectType targetObject,
    Set<SObjectField> fields,
    Set<Id> recordIds,
    SObjectField relationshipField,
    Boolean enforceFLS,
    String declaringHandler,
    String tag,
    List<Predicate> filters,
    ChildSubqueryDescriptor childSubquery
  ) {
    validateHandlerName(declaringHandler);
    validateTag(tag);

    this.targetObject = targetObject;
    this.fields = fields;
    this.recordIds = recordIds;
    this.relationshipField = relationshipField;
    this.enforceFLS = enforceFLS;
    this.declaringHandler = declaringHandler;

    this.tag = tag;
    this.filters = (filters == null) ? new List<Predicate>() : filters;
    this.childSubquery = childSubquery;
    this.declaringHandlers = new Set<String>{ declaringHandler };
    this.wasOrMerged = false;

    this.mergeKey = buildMergeKey(targetObject, relationshipField);

    // Seed 4-level provenance maps: mergeKey -> handler -> tagKey -> Set/List
    String tk = tagKey(tag);

    Map<String, Set<Id>> idsTagMap = new Map<String, Set<Id>>();
    idsTagMap.put(
      tk,
      (recordIds == null) ? new Set<Id>() : new Set<Id>(recordIds)
    );
    Map<String, Map<String, Set<Id>>> idsHandlerMap = new Map<String, Map<String, Set<Id>>>();
    idsHandlerMap.put(declaringHandler, idsTagMap);
    this.idsByHandler = new Map<String, Map<String, Map<String, Set<Id>>>>();
    this.idsByHandler.put(this.mergeKey, idsHandlerMap);

    Map<String, Set<SObjectField>> fieldsTagMap = new Map<String, Set<SObjectField>>();
    fieldsTagMap.put(
      tk,
      (fields == null) ? new Set<SObjectField>() : new Set<SObjectField>(fields)
    );
    Map<String, Map<String, Set<SObjectField>>> fieldsHandlerMap = new Map<String, Map<String, Set<SObjectField>>>();
    fieldsHandlerMap.put(declaringHandler, fieldsTagMap);
    this.fieldsByHandler = new Map<String, Map<String, Map<String, Set<SObjectField>>>>();
    this.fieldsByHandler.put(this.mergeKey, fieldsHandlerMap);

    Map<String, List<Predicate>> filtersTagMap = new Map<String, List<Predicate>>();
    filtersTagMap.put(tk, new List<Predicate>(this.filters));
    Map<String, Map<String, List<Predicate>>> filtersHandlerMap = new Map<String, Map<String, List<Predicate>>>();
    filtersHandlerMap.put(declaringHandler, filtersTagMap);
    this.filtersByHandler = new Map<String, Map<String, Map<String, List<Predicate>>>>();
    this.filtersByHandler.put(this.mergeKey, filtersHandlerMap);
  }

  // 14-arg full-fledged private constructor used by withChunkedIds() and
  // forOrMerged() to construct preserved/merged copies without re-running
  // seed logic. Caller is responsible for supplying coherent state.
  private QueryRequest(
    SObjectType targetObject,
    Set<SObjectField> fields,
    Set<Id> recordIds,
    SObjectField relationshipField,
    Boolean enforceFLS,
    String declaringHandler,
    Set<String> declaringHandlers,
    String tag,
    List<Predicate> filters,
    ChildSubqueryDescriptor childSubquery,
    Map<String, Map<String, Map<String, Set<Id>>>> idsByHandler,
    Map<String, Map<String, Map<String, Set<SObjectField>>>> fieldsByHandler,
    Map<String, Map<String, Map<String, List<Predicate>>>> filtersByHandler,
    Boolean wasOrMerged
  ) {
    this.targetObject = targetObject;
    this.fields = fields;
    this.recordIds = recordIds;
    this.relationshipField = relationshipField;
    this.enforceFLS = enforceFLS;
    this.declaringHandler = declaringHandler;
    this.declaringHandlers = declaringHandlers;
    this.tag = tag;
    this.filters = (filters == null) ? new List<Predicate>() : filters;
    this.childSubquery = childSubquery;
    this.idsByHandler = idsByHandler;
    this.fieldsByHandler = fieldsByHandler;
    this.filtersByHandler = filtersByHandler;
    this.wasOrMerged = wasOrMerged;
    this.mergeKey = buildMergeKey(targetObject, relationshipField);
  }

  // ---- factories ----

  // OR-merge with union field sets: constructed by QueryAggregator after merging two compatible
  // requests. Provenance maps are pre-built by the aggregator.
  public static QueryRequest forOrMerged(
    SObjectType targetObject,
    Set<SObjectField> mergedFields,
    Set<Id> mergedIds,
    SObjectField relationshipField,
    Boolean mergedFLS,
    Set<String> mergedHandlers,
    List<Predicate> mergedFilters,
    ChildSubqueryDescriptor mergedChildSubquery,
    Map<String, Map<String, Map<String, Set<Id>>>> mergedIdsByHandler,
    Map<String, Map<String, Map<String, Set<SObjectField>>>> mergedFieldsByHandler,
    Map<String, Map<String, Map<String, List<Predicate>>>> mergedFiltersByHandler
  ) {
    // Legacy single-handler string is a comma-join of merged handlers, used
    // ONLY by QueryExecutor exception messages (lines 50/69/104) — not by
    // any new merge logic. The authoritative set is declaringHandlers.
    String legacyHandler = String.join(
      new List<String>(mergedHandlers),
      ','
    );
    return new QueryRequest(
      targetObject,
      mergedFields,
      mergedIds,
      relationshipField,
      mergedFLS,
      legacyHandler,
      mergedHandlers,
      null, // OR-merged requests have no single tag (multi-tag captured in provenance)
      mergedFilters,
      mergedChildSubquery,
      mergedIdsByHandler,
      mergedFieldsByHandler,
      mergedFiltersByHandler,
      true
    );
  }

  // withChunkedIds dimension preservation: returns a copy with ONLY recordIds replaced. Every other piece
  // of state — filters, tag, childSubquery, provenance maps, wasOrMerged,
  // declaringHandlers, fields, FLS, target, relationshipField — is
  // structurally preserved.
  public QueryRequest withChunkedIds(Set<Id> chunk) {
    return new QueryRequest(
      this.targetObject,
      this.fields,
      chunk,
      this.relationshipField,
      this.enforceFLS,
      this.declaringHandler,
      this.declaringHandlers,
      this.tag,
      this.filters,
      this.childSubquery,
      this.idsByHandler,
      this.fieldsByHandler,
      this.filtersByHandler,
      this.wasOrMerged
    );
  }

  public String getMergeKey() {
    return this.mergeKey;
  }

  // Single source of truth for merge key format — used by QueryResultCache lookups
  // QB-3: Uses cached type/field names to avoid repeated describe calls
  public static String buildMergeKey(
    SObjectType objectType,
    SObjectField relField
  ) {
    String relFieldName = relField != null ? cachedFieldName(relField) : 'Id';
    return cachedTypeName(objectType) + '|' + relFieldName;
  }
}
