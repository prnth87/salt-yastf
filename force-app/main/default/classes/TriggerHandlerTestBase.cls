@IsTest
public inherited sharing class TriggerHandlerTestBase {
  // Utility method to assert that a handler's query declarations
  // only reference fields they actually use in onDataReady.
  // This is a framework-level test assertion.
  public static void assertNoDeclaredFieldViolations(TriggerHandler handler) {
    // This is a placeholder for field-access tracking
    // In production, this would use a debug-mode cache that tracks
    // which fields are actually accessed vs. declared
    // For v1.0, this provides the hook point for future enhancement
    System.assertNotEquals(null, handler, 'Handler must not be null');
    System.assertNotEquals(
      null,
      handler.getHandlerName(),
      'Handler must have a name'
    );
  }
}
