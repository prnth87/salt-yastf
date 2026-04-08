@IsTest
private class TriggerDispatcherUnitTest {
  // ── Shared state (outer-class static — inner classes cannot have static) ──
  private static Boolean simpleBeforeInsertCalled = false;
  private static Boolean simpleAfterInsertCalled = false;
  private static Boolean simpleAfterUpdateCalled = false;
  private static Integer simpleRecordCount = 0;

  private static Boolean dmlAwareOnDmlReadyCalled = false;

  private static Integer trackerAExecutionOrder = -1;
  private static Integer trackerACounter = 0;
  private static Integer trackerBExecutionOrder = -1;

  // ── Inner handler classes ──────────────────────────────────────────
  public class SimpleHandler extends TriggerHandler {
    public override void beforeInsert(List<SObject> newRecords) {
      simpleBeforeInsertCalled = true;
      simpleRecordCount = newRecords.size();
    }
    public override void afterInsert(List<SObject> newRecords) {
      simpleAfterInsertCalled = true;
    }
    public override void afterUpdate(
      List<SObject> newRecords,
      Map<Id, SObject> oldMap
    ) {
      simpleAfterUpdateCalled = true;
    }
  }

  public class ThrowingHandler extends TriggerHandler {
    public override void afterInsert(List<SObject> newRecords) {
      throw new TriggerFrameworkException('Intentional test failure');
    }
    public override void beforeInsert(List<SObject> newRecords) {
      throw new TriggerFrameworkException('Intentional before failure');
    }
  }

  public class DmlAwareHandler extends TriggerHandler implements IDmlAware {
    public override void afterInsert(List<SObject> newRecords) {
    }
    public void onDmlReady(IDmlRegistrar registrar) {
      dmlAwareOnDmlReadyCalled = true;
      registrar.registerNew(new Contact(LastName = 'DmlCreated'));
    }
  }

  public class OrderTrackerA extends TriggerHandler {
    public override void afterInsert(List<SObject> newRecords) {
      trackerAExecutionOrder = trackerACounter++;
    }
  }

  public class OrderTrackerB extends TriggerHandler {
    public override void afterInsert(List<SObject> newRecords) {
      trackerBExecutionOrder = trackerACounter++;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────
  private static TriggerHandler__mdt buildConfig(
    String handlerClass,
    Decimal order,
    Boolean isCritical,
    Boolean ai,
    Boolean au,
    Boolean bi
  ) {
    Map<String, Object> fields = new Map<String, Object>{
      'DeveloperName' => handlerClass.replace('.', '_'),
      'HandlerClass__c' => handlerClass,
      'Namespace__c' => null,
      'Order__c' => order,
      'IsActive__c' => true,
      'BeforeInsert__c' => bi,
      'BeforeUpdate__c' => false,
      'BeforeDelete__c' => false,
      'AfterInsert__c' => ai,
      'AfterUpdate__c' => au,
      'AfterDelete__c' => false,
      'AfterUndelete__c' => false,
      'AllowBypass__c' => true,
      'MaxReentrancy__c' => null,
      'CascadeDepthLimit__c' => null,
      'IsCritical__c' => isCritical,
      'BypassPermission__c' => null,
      'BypassUsers__c' => null,
      'BypassProfiles__c' => null
    };
    return (TriggerHandler__mdt) JSON.deserialize(
      JSON.serialize(fields),
      TriggerHandler__mdt.class
    );
  }

  private static void setupMock(List<TriggerHandler__mdt> configs) {
    TriggerDispatcher.mockHandlers = new Map<String, List<TriggerHandler__mdt>>{
      'Account' => configs
    };
  }

  private static void resetAll() {
    TriggerDispatcher.resetAll();
    simpleBeforeInsertCalled = false;
    simpleAfterInsertCalled = false;
    simpleAfterUpdateCalled = false;
    simpleRecordCount = 0;
    dmlAwareOnDmlReadyCalled = false;
    trackerAExecutionOrder = -1;
    trackerACounter = 0;
    trackerBExecutionOrder = -1;
  }

  private static final String SIMPLE = 'TriggerDispatcherUnitTest.SimpleHandler';
  private static final String THROWING = 'TriggerDispatcherUnitTest.ThrowingHandler';
  private static final String DML_AWARE = 'TriggerDispatcherUnitTest.DmlAwareHandler';
  private static final String TRACKER_A = 'TriggerDispatcherUnitTest.OrderTrackerA';
  private static final String TRACKER_B = 'TriggerDispatcherUnitTest.OrderTrackerB';

  // ── Tests ──────────────────────────────────────────────────────────

  @IsTest
  static void testHandlerExecutedOnInsert() {
    resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, true, false, false)
      }
    );
    Account acc = new Account(Name = 'Test Insert');
    insert acc;
    simpleAfterInsertCalled = false;
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(simpleAfterInsertCalled, 'afterInsert should fire');
  }

  @IsTest
  static void testHandlerExecutedOnUpdate() {
    resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, false, true, false)
      }
    );
    Account acc = new Account(Name = 'Test Update');
    insert acc;
    Account newAcc = acc.clone(true);
    newAcc.Name = 'Updated';
    simpleAfterUpdateCalled = false;
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ newAcc },
      new List<SObject>{ acc },
      TriggerOperation.AFTER_UPDATE
    );
    Test.stopTest();
    System.assert(simpleAfterUpdateCalled, 'afterUpdate should fire');
  }

  @IsTest
  static void testHandlerNotExecutedWhenContextDisabled() {
    resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, false, false, false)
      }
    );
    Account acc = new Account(Name = 'Test Disabled');
    insert acc;
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(
      !simpleAfterInsertCalled,
      'afterInsert should NOT fire when disabled'
    );
  }

  @IsTest
  static void testHandlerOrderingRespected() {
    resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(TRACKER_A, 10, true, true, false, false),
        buildConfig(TRACKER_B, 20, true, true, false, false)
      }
    );
    Account acc = new Account(Name = 'Test Order');
    insert acc;
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(
      trackerAExecutionOrder < trackerBExecutionOrder,
      'A (order=10) should execute before B (order=20). A=' +
        trackerAExecutionOrder +
        ' B=' +
        trackerBExecutionOrder
    );
  }

  @IsTest
  static void testCriticalHandlerNotFoundThrows() {
    resetAll();
    Account acc = new Account(Name = 'Test Critical Missing');
    insert acc;
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig('BogusClassName', 10, true, true, false, false)
      }
    );
    Boolean threw = false;
    Test.startTest();
    try {
      TriggerDispatcher.runWithContext(
        new List<SObject>{ acc },
        null,
        TriggerOperation.AFTER_INSERT
      );
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(threw, 'Critical missing handler should throw');
  }

  @IsTest
  static void testNonCriticalHandlerNotFoundSkips() {
    resetAll();
    Account acc = new Account(Name = 'Test NonCritical Missing');
    insert acc;
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig('BogusClassName', 10, false, true, false, false)
      }
    );
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    // No exception means pass
  }

  @IsTest
  static void testNonCriticalAfterThrowCaught() {
    resetAll();
    Account acc = new Account(Name = 'Test NonCritical Throw');
    insert acc;
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(THROWING, 10, false, true, false, false)
      }
    );
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    // Non-critical after-trigger exception is caught — no exception propagates
  }

  @IsTest
  static void testCriticalAfterThrowPropagates() {
    resetAll();
    Account acc = new Account(Name = 'Test Critical Throw');
    insert acc;
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(THROWING, 10, true, true, false, false)
      }
    );
    Boolean threw = false;
    Test.startTest();
    try {
      TriggerDispatcher.runWithContext(
        new List<SObject>{ acc },
        null,
        TriggerOperation.AFTER_INSERT
      );
    } catch (TriggerFrameworkException e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(threw, 'Critical after-trigger exception should propagate');
  }

  @IsTest
  static void testBeforeThrowAlwaysPropagates() {
    resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(THROWING, 10, false, false, false, true)
      }
    );
    Account acc = new Account(Name = 'Test Before Throw');
    Boolean threw = false;
    Test.startTest();
    try {
      TriggerDispatcher.runWithContext(
        new List<SObject>{ acc },
        null,
        TriggerOperation.BEFORE_INSERT
      );
    } catch (Exception e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(
      threw,
      'Before-trigger exception should always propagate regardless of IsCritical'
    );
  }

  @IsTest
  static void testBypassGlobal() {
    resetAll();
    Account acc = new Account(Name = 'Test Bypass');
    insert acc;
    // Reset framework state corrupted by real trigger during insert
    TriggerDispatcher.resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, true, false, false)
      }
    );
    simpleAfterInsertCalled = false;
    TriggerDispatcher.bypass(SimpleHandler.class);
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(
      !simpleAfterInsertCalled,
      'Bypassed handler should not execute'
    );
    TriggerDispatcher.clearBypass(SimpleHandler.class);
  }

  @IsTest
  static void testBypassForNextDmlEvent() {
    resetAll();
    Account acc = new Account(Name = 'Test BypassNext');
    insert acc;
    // Reset framework state corrupted by real trigger during insert
    TriggerDispatcher.resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, true, false, false)
      }
    );
    simpleAfterInsertCalled = false;
    TriggerDispatcher.bypassForNextDmlEvent(SimpleHandler.class);
    Test.startTest();
    // First call — bypass active, handler should not fire
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(!simpleAfterInsertCalled, 'First call should be bypassed');

    // After the first runWithContext, next-event bypass is cleared
    simpleAfterInsertCalled = false;
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    System.assert(
      simpleAfterInsertCalled,
      'Second call should run (bypass consumed)'
    );
  }

  @IsTest
  static void testBypassSealedAllowBypassFalse() {
    resetAll();
    // Build sealed config (AllowBypass__c = false) — cannot use buildConfig helper
    TriggerHandler__mdt sealedConfig = (TriggerHandler__mdt) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'DeveloperName' => SIMPLE.replace('.', '_'),
          'HandlerClass__c' => SIMPLE,
          'Namespace__c' => null,
          'Order__c' => 10,
          'IsActive__c' => true,
          'BeforeInsert__c' => false,
          'BeforeUpdate__c' => false,
          'BeforeDelete__c' => false,
          'AfterInsert__c' => true,
          'AfterUpdate__c' => false,
          'AfterDelete__c' => false,
          'AfterUndelete__c' => false,
          'AllowBypass__c' => false,
          'MaxReentrancy__c' => null,
          'CascadeDepthLimit__c' => null,
          'IsCritical__c' => true,
          'BypassPermission__c' => null,
          'BypassUsers__c' => null,
          'BypassProfiles__c' => null
        }
      ),
      TriggerHandler__mdt.class
    );
    setupMock(new List<TriggerHandler__mdt>{ sealedConfig });
    Account acc = new Account(Name = 'Test Sealed');
    insert acc;
    TriggerDispatcher.bypass(SimpleHandler.class);
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(
      simpleAfterInsertCalled,
      'Handler with AllowBypass__c=false should still execute despite bypass'
    );
    TriggerDispatcher.clearBypass(SimpleHandler.class);
  }

  @IsTest
  static void testClearAllBypasses() {
    resetAll();
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, true, false, false)
      }
    );
    Account acc = new Account(Name = 'Test ClearAll');
    insert acc;
    TriggerDispatcher.bypass(SimpleHandler.class);
    TriggerDispatcher.clearAllBypasses();
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(
      simpleAfterInsertCalled,
      'Handler should run after clearAllBypasses'
    );
  }

  @IsTest
  static void testDmlAwareCommitsDml() {
    resetAll();
    Account acc = new Account(Name = 'Test DmlAware');
    insert acc;
    // Reset and set up mock for Account only; Contact trigger will use
    // mock (empty Contact list) to prevent cascading from DML-created Contact
    TriggerDispatcher.resetAll();
    TriggerDispatcher.mockHandlers = new Map<String, List<TriggerHandler__mdt>>{
      'Account' => new List<TriggerHandler__mdt>{
        buildConfig(DML_AWARE, 10, true, true, false, false)
      },
      'Contact' => new List<TriggerHandler__mdt>()
    };
    dmlAwareOnDmlReadyCalled = false;
    Test.startTest();
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    Test.stopTest();
    System.assert(
      dmlAwareOnDmlReadyCalled,
      'onDmlReady should have been called'
    );
    List<Contact> contacts = [
      SELECT Id
      FROM Contact
      WHERE LastName = 'DmlCreated'
    ];
    System.assertEquals(
      1,
      contacts.size(),
      'DML-registered Contact should be committed'
    );
  }

  @IsTest
  static void testResetAllClearsState() {
    // Set up mock handlers and a bypass
    TriggerDispatcher.mockHandlers = new Map<String, List<TriggerHandler__mdt>>{
      'Account' => new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, true, false, false)
      }
    };
    TriggerDispatcher.bypass(SimpleHandler.class);
    System.assertNotEquals(
      null,
      TriggerDispatcher.mockHandlers,
      'mockHandlers should be set'
    );

    TriggerDispatcher.resetAll();

    System.assertEquals(
      null,
      TriggerDispatcher.mockHandlers,
      'resetAll should clear mockHandlers'
    );
    // Verify bypass cleared: re-setup mock and run — handler should fire
    setupMock(
      new List<TriggerHandler__mdt>{
        buildConfig(SIMPLE, 10, true, true, false, false)
      }
    );
    simpleAfterInsertCalled = false;
    Account acc = new Account(Name = 'Test ResetAll');
    insert acc;
    TriggerDispatcher.runWithContext(
      new List<SObject>{ acc },
      null,
      TriggerOperation.AFTER_INSERT
    );
    System.assert(
      simpleAfterInsertCalled,
      'Handler should run after resetAll clears bypasses'
    );
  }
}
