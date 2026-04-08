@IsTest
private class QueryBuilderTest {
  @IsTest
  static void queryBuilder_nullHandlerNameThrows() {
    Boolean threw = false;
    try {
      new QueryBuilder(null);
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('non-empty handler name'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_emptyHandlerNameThrows() {
    Boolean threw = false;
    try {
      new QueryBuilder('');
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_invalidHandlerNameCharThrows() {
    Boolean threw = false;
    try {
      new QueryBuilder('Handler With Spaces');
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('must match'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_reservedPrefixHandlerNameThrows() {
    Boolean threw = false;
    try {
      new QueryBuilder('__salt_reserved');
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('reserved prefix'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_missingObjectThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler')
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' });
    Boolean threw = false;
    try {
      qb.build();
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('onObject'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_missingFieldsThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .forIds(new Set<Id>{ '001000000000001AAA' });
    Boolean threw = false;
    try {
      qb.build();
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('fields'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_whereFilterNullThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.whereFilter(null);
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('non-null Predicate'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_tagNullThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.tag(null);
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_tagEmptyThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.tag('');
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_tagInvalidCharsThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.tag('invalid tag!');
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('must match'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_tagReservedPrefixThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.tag('__salt_reserved');
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('reserved prefix'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_withChildSubqueryNullRelNameThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.withChildSubquery(null, new List<SObjectField>{ Contact.LastName }, null, null);
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('relationship name'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_withChildSubqueryEmptyFieldsThrows() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Boolean threw = false;
    try {
      qb.withChildSubquery('Contacts', new List<SObjectField>(), null, null);
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('at least one child field'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_childSubqueryAndWhereFilterMutuallyExclusive() {
    QueryBuilder qb = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .withChildSubquery('Contacts', new List<SObjectField>{ Contact.LastName }, null, null)
      .whereFilter(FieldFilter.equals(Account.Name, 'Test'));
    Boolean threw = false;
    try {
      qb.build();
    } catch (TriggerFrameworkException e) {
      threw = true;
      System.assert(e.getMessage().contains('mutually exclusive'));
    }
    System.assert(threw);
  }

  @IsTest
  static void queryBuilder_fieldsSetOverload() {
    QueryBuilder qb = new QueryBuilder('TestHandler');
    Set<SObjectField> fieldSet = new Set<SObjectField>{ Account.Name, Account.Industry };
    QueryRequest req = qb
      .onObject(Account.SObjectType)
      .fields(fieldSet)
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .build();
    System.assert(req.fields.contains(Account.Name));
    System.assert(req.fields.contains(Account.Industry));
  }

  @IsTest
  static void queryBuilder_relatedThroughAndTag() {
    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Contact.SObjectType)
      .fields(new List<SObjectField>{ Contact.LastName })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .relatedThrough(Contact.AccountId)
      .tag('myTag')
      .build();
    System.assertEquals('myTag', req.tag);
    System.assertEquals(Contact.AccountId, req.relationshipField);
  }

  @IsTest
  static void queryBuilder_withChildSubquerySuccess() {
    QueryRequest req = new QueryBuilder('TestHandler')
      .onObject(Account.SObjectType)
      .fields(new List<SObjectField>{ Account.Name })
      .forIds(new Set<Id>{ '001000000000001AAA' })
      .withChildSubquery('Contacts', new List<SObjectField>{ Contact.LastName }, null, 5)
      .build();
    System.assertNotEquals(null, req.childSubquery);
    System.assertEquals('Contacts', req.childSubquery.childRelationshipName);
    System.assertEquals(5, req.childSubquery.childLimit);
  }
}
