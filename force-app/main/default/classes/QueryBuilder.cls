public inherited sharing class QueryBuilder {
  private SObjectType targetObject;
  private Set<SObjectField> fields = new Set<SObjectField>();
  private Set<Id> recordIds;
  private SObjectField relationshipField;
  private Boolean enforceFLS = false;
  private String declaringHandler;

  // v1.1 additions (child-subquery support/tag dimension/Predicate tree)
  private String tag;
  private List<Predicate> filters = new List<Predicate>();
  private ChildSubqueryDescriptor childSubquery;

  // handler/tag name validation — handler/tag identifier validation
  private static final Pattern IDENT_PATTERN = Pattern.compile('^[A-Za-z0-9_.]+$');
  private static final String RESERVED_PREFIX = 'salt_';

  public QueryBuilder(String handlerName) {
    if (handlerName == null || handlerName.length() == 0) {
      throw new TriggerFrameworkException(
        'QueryBuilder requires a non-empty handler name',
        handlerName,
        null,
        'query-build'
      );
    }
    if (!IDENT_PATTERN.matcher(handlerName).matches()) {
      throw new TriggerFrameworkException(
        'QueryBuilder handler name must match ^[A-Za-z0-9_.]+$ — got: ' +
          handlerName,
        handlerName,
        null,
        'query-build'
      );
    }
    if (handlerName.toLowerCase().startsWith(RESERVED_PREFIX)) {
      throw new TriggerFrameworkException(
        'QueryBuilder handler name may not start with reserved prefix salt_ — got: ' +
          handlerName,
        handlerName,
        null,
        'query-build'
      );
    }
    this.declaringHandler = handlerName;
  }

  public QueryBuilder onObject(SObjectType objectType) {
    this.targetObject = objectType;
    return this;
  }

  public QueryBuilder fields(List<SObjectField> fieldList) {
    this.fields.addAll(fieldList);
    return this;
  }

  public QueryBuilder fields(Set<SObjectField> fieldSet) {
    this.fields.addAll(fieldSet);
    return this;
  }

  public QueryBuilder relatedThrough(SObjectField field) {
    this.relationshipField = field;
    return this;
  }

  public QueryBuilder forIds(Set<Id> ids) {
    this.recordIds = ids;
    return this;
  }

  public QueryBuilder withFLS() {
    this.enforceFLS = true;
    return this;
  }

  // child-subquery support/Predicate tree: top-level AND of predicates. Multiple .where() calls accumulate.
  // Each predicate may be a leaf FieldFilter or a CompositePredicate tree.
  public QueryBuilder whereFilter(Predicate flt) {
    if (flt == null) {
      throw new TriggerFrameworkException(
        'whereFilter() requires a non-null Predicate',
        declaringHandler,
        null,
        'query-build'
      );
    }
    this.filters.add(flt);
    return this;
  }

  // handler/tag name validation/tag dimension: tag the request for per-tag eviction and provenance.
  public QueryBuilder tag(String tagValue) {
    if (tagValue == null || tagValue.length() == 0) {
      throw new TriggerFrameworkException(
        'tag() requires a non-empty value',
        declaringHandler,
        null,
        'query-build'
      );
    }
    if (!IDENT_PATTERN.matcher(tagValue).matches()) {
      throw new TriggerFrameworkException(
        'tag must match ^[A-Za-z0-9_.]+$ — got: ' + tagValue,
        declaringHandler,
        null,
        'query-build'
      );
    }
    if (tagValue.toLowerCase().startsWith(RESERVED_PREFIX)) {
      throw new TriggerFrameworkException(
        'tag may not start with reserved prefix salt_ — got: ' + tagValue,
        declaringHandler,
        null,
        'query-build'
      );
    }
    this.tag = tagValue;
    return this;
  }

  // Predicate tree: child subquery on the parent SELECT. Mutually exclusive with .where()
  // at the request level — the aggregator separately refuses to merge across
  // shapes, but a single QueryBuilder request must declare only one.
  public QueryBuilder withChildSubquery(
    String childRelationshipName,
    List<SObjectField> childFields,
    Predicate childFilter,
    Integer childLimit
  ) {
    if (childRelationshipName == null || childRelationshipName.length() == 0) {
      throw new TriggerFrameworkException(
        'withChildSubquery() requires a relationship name',
        declaringHandler,
        null,
        'query-build'
      );
    }
    if (childFields == null || childFields.isEmpty()) {
      throw new TriggerFrameworkException(
        'withChildSubquery() requires at least one child field',
        declaringHandler,
        null,
        'query-build'
      );
    }
    this.childSubquery = new ChildSubqueryDescriptor(
      childRelationshipName,
      childFields,
      childFilter,
      childLimit
    );
    return this;
  }

  public QueryRequest build() {
    if (recordIds == null || recordIds.isEmpty()) {
      throw new TriggerFrameworkException(
        'forIds() is mandatory on QueryBuilder. Unbounded SOQL in trigger context is never correct.',
        declaringHandler,
        null,
        'query-build'
      );
    }
    if (targetObject == null) {
      throw new TriggerFrameworkException(
        'onObject() must specify a target SObjectType.',
        declaringHandler,
        null,
        'query-build'
      );
    }
    if (fields.isEmpty()) {
      throw new TriggerFrameworkException(
        'fields() must specify at least one field.',
        declaringHandler,
        null,
        'query-build'
      );
    }
    // OR-merge with union field sets: a single QueryRequest is either flat-WHERE or child-subquery,
    // not both. The two shapes are exclusive at the request level.
    if (childSubquery != null && !filters.isEmpty()) {
      throw new TriggerFrameworkException(
        'withChildSubquery() and where() are mutually exclusive on a single QueryBuilder request.',
        declaringHandler,
        null,
        'query-build'
      );
    }
    return new QueryRequest(
      targetObject,
      fields,
      recordIds,
      relationshipField,
      enforceFLS,
      declaringHandler,
      tag,
      filters,
      childSubquery
    );
  }
}
