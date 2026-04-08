@IsTest
private class TriggerTelemetryTest {
  @IsTest
  static void testEnableDisable() {
    TriggerTelemetry.reset();

    System.assertEquals(false, TriggerTelemetry.isEnabled());

    TriggerTelemetry.enable();
    System.assertEquals(true, TriggerTelemetry.isEnabled());

    TriggerTelemetry.disable();
    System.assertEquals(false, TriggerTelemetry.isEnabled());
  }

  @IsTest
  static void testCaptureSnapshot() {
    TriggerTelemetry.LimitsSnapshot snap = TriggerTelemetry.captureSnapshot();
    System.assertNotEquals(null, snap);
    System.assert(snap.timestamp > 0);
  }

  @IsTest
  static void testManifestEntry() {
    TriggerTelemetry.reset();
    TriggerTelemetry.enable();

    TriggerTelemetry.ManifestEntry entry = new TriggerTelemetry.ManifestEntry(
      'TestHandler',
      TriggerContext.BEFORE_INSERT
    );
    entry.setStatus('EXECUTED');
    entry.setRecordCount(10);
    entry.setBeforeSnapshot(TriggerTelemetry.captureSnapshot());
    entry.setAfterSnapshot(TriggerTelemetry.captureSnapshot());

    TriggerTelemetry.addManifestEntry(entry);

    List<TriggerTelemetry.ManifestEntry> manifest = TriggerTelemetry.getExecutionManifest();
    System.assertEquals(1, manifest.size());
    System.assertEquals('EXECUTED', manifest[0].status);
  }

  @IsTest
  static void testGetReport() {
    TriggerTelemetry.reset();
    TriggerTelemetry.enable();

    TriggerTelemetry.ManifestEntry entry = new TriggerTelemetry.ManifestEntry(
      'TestHandler',
      TriggerContext.BEFORE_INSERT
    );
    entry.setStatus('EXECUTED');
    entry.setRecordCount(5);
    entry.setBeforeSnapshot(TriggerTelemetry.captureSnapshot());
    entry.setAfterSnapshot(TriggerTelemetry.captureSnapshot());
    TriggerTelemetry.addManifestEntry(entry);

    String report = TriggerTelemetry.getReport();
    System.assert(report.contains('SALT-YASTF'), report);
    System.assert(report.contains('TestHandler'), report);
  }

  @IsTest
  static void testReportWhenDisabled() {
    TriggerTelemetry.reset();
    String report = TriggerTelemetry.getReport();
    System.assert(report.contains('not enabled'), report);
  }
}
