/**
 * ChildSubqueryDescriptor — value type describing one child subquery in a
 * parent SOQL SELECT. Rendered inline by QueryExecutor.buildSOQL via the
 * shared BindContext so child filter binds participate in the parent bindMap.
 */
public inherited sharing class ChildSubqueryDescriptor {
  public final String childRelationshipName;
  public final List<SObjectField> childFields;
  public final Predicate childFilter;
  public final Integer childLimit;

  public ChildSubqueryDescriptor(
    String childRelationshipName,
    List<SObjectField> childFields,
    Predicate childFilter,
    Integer childLimit
  ) {
    this.childRelationshipName = childRelationshipName;
    this.childFields = childFields;
    this.childFilter = childFilter;
    this.childLimit = childLimit;
  }

  public String render(BindContext ctx) {
    List<String> fieldNames = new List<String>{ 'Id' };
    if (childFields != null) {
      for (SObjectField f : childFields) {
        String n = QueryRequest.cachedFieldName(f);
        if (n != 'Id') {
          fieldNames.add(n);
        }
      }
    }
    String sql =
      '(SELECT ' +
      String.join(fieldNames, ', ') +
      ' FROM ' +
      childRelationshipName;
    if (childFilter != null) {
      sql += ' WHERE ' + childFilter.render(ctx);
    }
    if (childLimit != null) {
      sql += ' LIMIT ' + childLimit;
    }
    sql += ')';
    return sql;
  }
}
