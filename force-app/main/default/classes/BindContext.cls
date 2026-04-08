/**
 * BindContext — per-build bind-name allocator and bindMap collector.
 *
 * A fresh BindContext is created per QueryExecutor.buildSOQL invocation.
 * Predicate.render and ChildSubqueryDescriptor.render call back into this
 * context to allocate unique bind names (__salt_p0, __salt_p1, ...) and to
 * register their bind values. The reserved __salt_ prefix is enforced at
 * FieldFilter factory time so user-supplied field names cannot collide.
 */
public inherited sharing class BindContext {
  public Map<String, Object> bindMap = new Map<String, Object>();
  private Integer predicateCounter = 0;
  private Integer childCounter = 0;

  public BindContext() {
  }

  public String nextPredicateBindName() {
    String name = '__salt_p' + predicateCounter;
    predicateCounter++;
    return name;
  }

  public String nextChildBindName() {
    String name = '__salt_c' + childCounter;
    childCounter++;
    return name;
  }

  public void registerBind(String name, Object value) {
    bindMap.put(name, value);
  }
}
