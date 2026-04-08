public inherited sharing class TriggerTelemetry {
  // Snapshot of governor limits at a point in time
  public class LimitsSnapshot {
    public Integer soqlQueries { get; private set; }
    public Integer soqlRows { get; private set; }
    public Integer dmlStatements { get; private set; }
    public Integer dmlRows { get; private set; }
    public Integer cpuTime { get; private set; }
    public Integer heapSize { get; private set; }
    public Long timestamp { get; private set; }

    public LimitsSnapshot() {
      this.soqlQueries = Limits.getQueries();
      this.soqlRows = Limits.getQueryRows();
      this.dmlStatements = Limits.getDmlStatements();
      this.dmlRows = Limits.getDmlRows();
      this.cpuTime = Limits.getCpuTime();
      this.heapSize = Limits.getHeapSize();
      this.timestamp = System.currentTimeMillis();
    }
  }

  // Execution manifest entry for one handler
  public class ManifestEntry {
    public String handlerName { get; private set; }
    public String status { get; private set; } // EXECUTED, SKIPPED, QUERY_SKIPPED, BYPASSED, ERROR
    public TriggerContext context { get; private set; }
    public Integer recordCount { get; private set; }
    public LimitsSnapshot beforeSnapshot { get; private set; }
    public LimitsSnapshot afterSnapshot { get; private set; }

    public ManifestEntry(String handlerName, TriggerContext context) {
      this.handlerName = handlerName;
      this.context = context;
      this.status = 'PENDING';
      this.recordCount = 0;
    }

    public void setStatus(String status) {
      this.status = status;
    }
    public void setRecordCount(Integer count) {
      this.recordCount = count;
    }
    public void setBeforeSnapshot(LimitsSnapshot snap) {
      this.beforeSnapshot = snap;
    }
    public void setAfterSnapshot(LimitsSnapshot snap) {
      this.afterSnapshot = snap;
    }

    // Compute delta
    public Integer getSoqlDelta() {
      if (beforeSnapshot == null || afterSnapshot == null)
        return 0;
      return afterSnapshot.soqlQueries - beforeSnapshot.soqlQueries;
    }
    public Integer getCpuDelta() {
      if (beforeSnapshot == null || afterSnapshot == null)
        return 0;
      return afterSnapshot.cpuTime - beforeSnapshot.cpuTime;
    }
    public Integer getHeapDelta() {
      if (beforeSnapshot == null || afterSnapshot == null)
        return 0;
      return afterSnapshot.heapSize - beforeSnapshot.heapSize;
    }
  }

  // Static state for the current execution
  private static Boolean enabled = false;
  private static List<ManifestEntry> manifest = new List<ManifestEntry>();
  private static LimitsSnapshot dispatcherStart;

  public static void enable() {
    enabled = true;
    manifest.clear();
    dispatcherStart = new LimitsSnapshot();
  }

  public static void disable() {
    enabled = false;
  }

  public static Boolean isEnabled() {
    return enabled;
  }

  public static LimitsSnapshot captureSnapshot() {
    return new LimitsSnapshot();
  }

  public static void addManifestEntry(ManifestEntry entry) {
    if (enabled) {
      manifest.add(entry);
    }
  }

  public static List<ManifestEntry> getExecutionManifest() {
    return manifest;
  }

  public static String getReport() {
    if (!enabled || manifest.isEmpty()) {
      return 'Telemetry not enabled or no handlers executed.';
    }

    List<String> lines = new List<String>();
    lines.add('=== SALT-YASTF Execution Report ===');
    lines.add('Handlers: ' + manifest.size());

    LimitsSnapshot now = new LimitsSnapshot();
    if (dispatcherStart != null) {
      lines.add(
        'Total SOQL: ' + (now.soqlQueries - dispatcherStart.soqlQueries)
      );
      lines.add('Total CPU: ' + (now.cpuTime - dispatcherStart.cpuTime) + 'ms');
      lines.add('Total Heap: ' + now.heapSize + ' bytes');
    }

    lines.add('');
    lines.add('--- Handler Details ---');
    for (ManifestEntry entry : manifest) {
      lines.add(
        entry.handlerName +
          ' [' +
          entry.status +
          ']' +
          ' records=' +
          entry.recordCount +
          ' soql=' +
          entry.getSoqlDelta() +
          ' cpu=' +
          entry.getCpuDelta() +
          'ms' +
          ' heap=' +
          entry.getHeapDelta()
      );
    }

    return String.join(lines, '\n');
  }

  // Reset for test isolation
  // Visibility: public for cross-class reset from TriggerDispatcher.resetAll()
  @TestVisible
  public static void reset() {
    enabled = false;
    manifest.clear();
    dispatcherStart = null;
  }
}
