/**
 * Predicate — composable boolean expression for SALT(YASTF) Query Pipeline v1.1.
 *
 * Implementations must support both in-memory evaluation (matches) and SOQL
 * rendering (render) using a shared BindContext to avoid bind name collisions.
 * equalsPredicate provides structural equality used by request/cache merge keys.
 */
public interface Predicate {
  Boolean matches(SObject row);
  String render(BindContext ctx);
  Boolean equalsPredicate(Predicate other);
  Integer getStructuralHash();
}
