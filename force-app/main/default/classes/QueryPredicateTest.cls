@isTest
private class QueryPredicateTest {
  // ---- A.1 / A.2 / A.3: empty / null factory rejections ----

  @isTest
  static void andOf_emptyChildren_throws() {
    Boolean threw = false;
    try {
      CompositePredicate.andOf(new List<Predicate>());
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw, 'andOf empty list should throw');
  }

  @isTest
  static void orOf_emptyChildren_throws() {
    Boolean threw = false;
    try {
      CompositePredicate.orOf(new List<Predicate>());
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw, 'orOf empty list should throw');
  }

  @isTest
  static void notOf_null_throws() {
    Boolean threw = false;
    try {
      CompositePredicate.notOf(null);
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw, 'notOf null should throw');
  }

  // ---- A.4 / A.5: degenerate single-child collapse ----

  @isTest
  static void andOf_singleChild_collapses_returnsChild() {
    FieldFilter ff = FieldFilter.equals(Account.Name, 'X');
    Predicate result = CompositePredicate.andOf(new List<Predicate>{ ff });
    System.assert(result == ff, 'single-child andOf should return child unwrapped');
  }

  @isTest
  static void orOf_singleChild_collapses_equalsLeaf() {
    FieldFilter ff = FieldFilter.equals(Account.Name, 'Y');
    Predicate result = CompositePredicate.orOf(new List<Predicate>{ ff });
    System.assert(result == ff, 'single-child orOf should return child unwrapped');
  }

  // ---- A.6 / A.7: depth cap ----

  @isTest
  static void andOf_depth17_throws() {
    Predicate p = FieldFilter.equals(Account.Name, 'leaf');
    // build 15 wrappers -> depth 16, OK
    for (Integer i = 0; i < 15; i++) {
      p = CompositePredicate.andOf(
        new List<Predicate>{ p, FieldFilter.equals(Account.Name, 'x' + i) }
      );
    }
    // attempt to wrap once more -> depth 17 -> throw
    Boolean threw = false;
    try {
      CompositePredicate.andOf(
        new List<Predicate>{ p, FieldFilter.equals(Account.Name, 'over') }
      );
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw, 'depth 17 andOf should throw');
  }

  @isTest
  static void notOf_depth17_throws() {
    Predicate p = FieldFilter.equals(Account.Name, 'leaf');
    for (Integer i = 0; i < 15; i++) {
      p = CompositePredicate.notOf(p);
    }
    // p is now depth 16. notOf one more -> 17 -> throw.
    Boolean threw = false;
    try {
      CompositePredicate.notOf(p);
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw, 'depth 17 notOf should throw');
  }

  // ---- A.8: render always parenthesizes ----

  @isTest
  static void compositePredicate_renderAlwaysParenthesizes() {
    Predicate p = CompositePredicate.andOf(
      new List<Predicate>{
        FieldFilter.equals(Account.Name, 'A'),
        FieldFilter.equals(Account.Industry, 'Tech')
      }
    );
    String s = p.render(new BindContext());
    System.assert(s.startsWith('('), 'render should start with (');
    System.assert(s.endsWith(')'), 'render should end with )');

    Predicate notP = CompositePredicate.notOf(
      FieldFilter.equals(Account.Name, 'A')
    );
    String ns = notP.render(new BindContext());
    System.assert(ns.startsWith('NOT ('), 'NOT render should start with NOT (');
    System.assert(ns.endsWith(')'), 'NOT render should end with )');
  }

  // ---- A.9: matches walks tree ----

  @isTest
  static void compositePredicate_matchesWalksTree() {
    Account row = new Account(Name = 'Acme', Industry = 'Tech');
    Predicate eqName = FieldFilter.equals(Account.Name, 'Acme');
    Predicate eqIndOther = FieldFilter.equals(Account.Industry, 'Other');
    Predicate eqIndTech = FieldFilter.equals(Account.Industry, 'Tech');

    // andOf( orOf(eqName, eqIndOther), notOf(eqIndOther) )
    Predicate tree = CompositePredicate.andOf(
      new List<Predicate>{
        CompositePredicate.orOf(new List<Predicate>{ eqName, eqIndOther }),
        CompositePredicate.notOf(eqIndOther)
      }
    );
    System.assertEquals(true, tree.matches(row));

    // change row so eqName false, orOf falls to eqIndOther
    Account row2 = new Account(Name = 'Other', Industry = 'Other');
    Predicate tree2 = CompositePredicate.andOf(
      new List<Predicate>{
        CompositePredicate.orOf(new List<Predicate>{ eqName, eqIndOther }),
        CompositePredicate.notOf(eqIndTech)
      }
    );
    System.assertEquals(true, tree2.matches(row2));

    // and that AND short-circuits to false
    Predicate tree3 = CompositePredicate.andOf(
      new List<Predicate>{
        FieldFilter.equals(Account.Name, 'NoMatch'),
        eqIndTech
      }
    );
    System.assertEquals(false, tree3.matches(row));
  }

  // ---- A.10: equalsPredicate is order-sensitive ----

  @isTest
  static void equalsPredicate_structural_orderSensitive() {
    Predicate p1 = FieldFilter.equals(Account.Name, 'A');
    Predicate p2 = FieldFilter.equals(Account.Industry, 'Tech');

    Predicate left = CompositePredicate.andOf(new List<Predicate>{ p1, p2 });
    Predicate right = CompositePredicate.andOf(new List<Predicate>{ p2, p1 });
    System.assertEquals(false, left.equalsPredicate(right), 'andOf is order-sensitive');

    Predicate same = CompositePredicate.andOf(
      new List<Predicate>{
        FieldFilter.equals(Account.Name, 'A'),
        FieldFilter.equals(Account.Industry, 'Tech')
      }
    );
    System.assertEquals(true, left.equalsPredicate(same));
  }
}
