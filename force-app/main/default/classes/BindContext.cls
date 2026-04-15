/**
 * BindContext — per-build bind-name allocator and bindMap collector.
 *
 * A fresh BindContext is created per QueryExecutor.buildSOQL invocation.
 * Predicate.render and ChildSubqueryDescriptor.render call back into this
 * context to allocate unique bind names (salt_p0, salt_p1, ...) and to
 * register their bind values. The reserved salt_ prefix is enforced at
 * FieldFilter factory time so user-supplied field names cannot collide.
 * Note: bind names use single-underscore prefix (salt_) not double (__salt_)
 * because Database.queryWithBinds rejects identifiers starting with '__'.
 */
public inherited sharing class BindContext {
  public Map<String, Object> bindMap = new Map<String, Object>();
  private Integer predicateCounter = 0;
  private Integer childCounter = 0;

  public BindContext() {
  }

  public String nextPredicateBindName() {
    String name = 'salt_p' + predicateCounter;
    predicateCounter++;
    return name;
  }

  public String nextChildBindName() {
    String name = 'salt_c' + childCounter;
    childCounter++;
    return name;
  }

  public void registerBind(String name, Object value) {
    bindMap.put(name, value);
  }
}
