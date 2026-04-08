@IsTest
private class BindContextTest {
  @IsTest
  static void bindContext_nextChildBindName() {
    BindContext ctx = new BindContext();
    String name1 = ctx.nextChildBindName();
    String name2 = ctx.nextChildBindName();
    System.assertEquals('__salt_c0', name1);
    System.assertEquals('__salt_c1', name2);
  }

  @IsTest
  static void bindContext_registerBindPopulatesMap() {
    BindContext ctx = new BindContext();
    ctx.registerBind('myBind', 42);
    System.assertEquals(42, ctx.bindMap.get('myBind'));
  }

  @IsTest
  static void bindContext_predicateBindNameSequence() {
    BindContext ctx = new BindContext();
    System.assertEquals('__salt_p0', ctx.nextPredicateBindName());
    System.assertEquals('__salt_p1', ctx.nextPredicateBindName());
    System.assertEquals('__salt_p2', ctx.nextPredicateBindName());
  }
}
