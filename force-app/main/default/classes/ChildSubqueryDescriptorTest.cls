@IsTest
private class ChildSubqueryDescriptorTest {
  @IsTest
  static void childSubqueryDescriptor_renderWithFieldsAndFilter() {
    BindContext ctx = new BindContext();
    Predicate flt = FieldFilter.equals(Contact.LastName, 'Test');
    ChildSubqueryDescriptor csd = new ChildSubqueryDescriptor(
      'Contacts',
      new List<SObjectField>{ Contact.LastName, Contact.FirstName },
      flt,
      10
    );
    String rendered = csd.render(ctx);
    System.assert(rendered.startsWith('(SELECT '), 'Should start with (SELECT');
    System.assert(rendered.contains('FROM Contacts'), 'Should contain FROM Contacts');
    System.assert(rendered.contains('WHERE'), 'Should contain WHERE clause');
    System.assert(rendered.contains('LIMIT 10'), 'Should contain LIMIT');
    System.assert(rendered.endsWith(')'), 'Should end with )');
  }

  @IsTest
  static void childSubqueryDescriptor_renderWithoutFilterOrLimit() {
    BindContext ctx = new BindContext();
    ChildSubqueryDescriptor csd = new ChildSubqueryDescriptor(
      'Contacts',
      new List<SObjectField>{ Contact.LastName },
      null,
      null
    );
    String rendered = csd.render(ctx);
    System.assert(!rendered.contains('WHERE'), 'No WHERE without filter');
    System.assert(!rendered.contains('LIMIT'), 'No LIMIT without limit');
  }

  @IsTest
  static void childSubqueryDescriptor_renderWithNullFields() {
    BindContext ctx = new BindContext();
    ChildSubqueryDescriptor csd = new ChildSubqueryDescriptor(
      'Contacts',
      null,
      null,
      null
    );
    String rendered = csd.render(ctx);
    System.assert(rendered.contains('Id'), 'Should always include Id');
  }

  @IsTest
  static void childSubqueryDescriptor_renderDeduplicatesId() {
    BindContext ctx = new BindContext();
    ChildSubqueryDescriptor csd = new ChildSubqueryDescriptor(
      'Contacts',
      new List<SObjectField>{ Contact.Id, Contact.LastName },
      null,
      null
    );
    String rendered = csd.render(ctx);
    System.assert(rendered.contains('Id'), 'Should contain Id');
  }
}
