/**
 * CompositePredicate — AND/OR/NOT combinator implementing Predicate.
 *
 * Construction is via static factories which enforce the v1.1 depth cap of 16
 * (predicate-tree adversarial review) and degenerate-collapse semantics: a single-child AND/OR returns
 * the child unwrapped. Empty children lists and null NOT children are rejected
 * with TriggerFrameworkException.
 *
 * matches() short-circuits AND/OR walks. render() ALWAYS parenthesizes (Predicate tree)
 * to keep operator precedence safe across nested compositions.
 */
public inherited sharing class CompositePredicate implements Predicate {
  public enum Combinator {
    AND_OP,
    OR_OP,
    NOT_OP
  }

  public static final Integer MAX_DEPTH = 16;

  public final Combinator kind;
  public final List<Predicate> children;
  private final Integer structuralHash;

  private CompositePredicate(Combinator c, List<Predicate> kids) {
    this.kind = c;
    this.children = kids;
    // Compute structural hash from combinator ordinal and children hashes
    Integer h = c.ordinal();
    for (Predicate child : kids) {
      h = 31 * h + child.getStructuralHash();
    }
    this.structuralHash = h;
  }

  // ---- factories ----

  public static Predicate andOf(List<Predicate> children) {
    if (children == null || children.isEmpty()) {
      throw new TriggerFrameworkException(
        'CompositePredicate.andOf requires at least one child predicate'
      );
    }
    if (children.size() == 1) {
      return children[0];
    }
    checkChildrenDepth(children);
    return new CompositePredicate(Combinator.AND_OP, children);
  }

  public static Predicate orOf(List<Predicate> children) {
    if (children == null || children.isEmpty()) {
      throw new TriggerFrameworkException(
        'CompositePredicate.orOf requires at least one child predicate'
      );
    }
    if (children.size() == 1) {
      return children[0];
    }
    checkChildrenDepth(children);
    return new CompositePredicate(Combinator.OR_OP, children);
  }

  public static Predicate notOf(Predicate child) {
    if (child == null) {
      throw new TriggerFrameworkException(
        'CompositePredicate.notOf requires a non-null child predicate'
      );
    }
    List<Predicate> kids = new List<Predicate>{ child };
    checkChildrenDepth(kids);
    return new CompositePredicate(Combinator.NOT_OP, kids);
  }

  // varargs convenience
  public static Predicate andOf(Predicate a, Predicate b) {
    return andOf(new List<Predicate>{ a, b });
  }
  public static Predicate andOf(Predicate a, Predicate b, Predicate c) {
    return andOf(new List<Predicate>{ a, b, c });
  }
  public static Predicate orOf(Predicate a, Predicate b) {
    return orOf(new List<Predicate>{ a, b });
  }
  public static Predicate orOf(Predicate a, Predicate b, Predicate c) {
    return orOf(new List<Predicate>{ a, b, c });
  }

  // ---- depth check ----

  private static void checkChildrenDepth(List<Predicate> kids) {
    for (Predicate p : kids) {
      Integer d = depthOf(p);
      // The new node will sit one level above its deepest child, so the
      // resulting tree depth is d + 1. Reject when that would exceed MAX_DEPTH.
      if (d + 1 > MAX_DEPTH) {
        throw new TriggerFrameworkException(
          'CompositePredicate depth cap exceeded (max ' +
            MAX_DEPTH +
            ', got ' +
            (d + 1) +
            ')'
        );
      }
    }
  }

  private static Integer depthOf(Predicate p) {
    if (!(p instanceof CompositePredicate)) {
      return 1;
    }
    CompositePredicate cp = (CompositePredicate) p;
    Integer maxChild = 0;
    for (Predicate k : cp.children) {
      Integer d = depthOf(k);
      if (d > maxChild) {
        maxChild = d;
      }
    }
    return maxChild + 1;
  }

  // ---- Predicate impl ----

  public Boolean matches(SObject row) {
    if (kind == CompositePredicate.Combinator.NOT_OP) {
      return !children[0].matches(row);
    }
    if (kind == CompositePredicate.Combinator.AND_OP) {
      for (Predicate p : children) {
        if (!p.matches(row)) {
          return false;
        }
      }
      return true;
    }
    // OR_OP
    for (Predicate p : children) {
      if (p.matches(row)) {
        return true;
      }
    }
    return false;
  }

  public String render(BindContext ctx) {
    if (kind == CompositePredicate.Combinator.NOT_OP) {
      return 'NOT (' + children[0].render(ctx) + ')';
    }
    List<String> rendered = new List<String>();
    for (Predicate p : children) {
      rendered.add(p.render(ctx));
    }
    String joiner = (kind == CompositePredicate.Combinator.AND_OP) ? ' AND ' : ' OR ';
    return '(' + String.join(rendered, joiner) + ')';
  }

  public Boolean equalsPredicate(Predicate other) {
    if (!(other instanceof CompositePredicate)) {
      return false;
    }
    CompositePredicate o = (CompositePredicate) other;
    if (o.kind != this.kind) {
      return false;
    }
    if (o.children.size() != this.children.size()) {
      return false;
    }
    for (Integer i = 0; i < this.children.size(); i++) {
      if (!this.children[i].equalsPredicate(o.children[i])) {
        return false;
      }
    }
    return true;
  }

  public Integer getStructuralHash() {
    return structuralHash;
  }
}
