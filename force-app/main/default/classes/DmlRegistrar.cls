public inherited sharing class DmlRegistrar implements IDmlRegistrar {
  // Current handler name (set by dispatcher before calling onDmlReady)
  private String currentHandler;

  // Whether we're in before-trigger context
  private Boolean isBeforeTriggerContext = false;

  // Before-trigger: reference to Trigger.new records for direct mutation
  private Map<Id, SObject> triggerNewMap;

  // After-trigger buffers
  private List<SObject> newRecords = new List<SObject>();
  private List<ForeignKeyBinding> fkBindings = new List<ForeignKeyBinding>();
  private Map<SObjectType, List<ForeignKeyBinding>> fkBindingsByChildType = new Map<SObjectType, List<ForeignKeyBinding>>();
  private Map<Id, SObject> dirtyRecords = new Map<Id, SObject>();
  private List<SObject> deletedRecords = new List<SObject>();

  // Field provenance: recordId -> fieldName -> handlerName
  private Map<Id, Map<String, String>> fieldProvenance = new Map<Id, Map<String, String>>();

  // Dirty fields tracking: recordId -> Set<fieldName>
  private Map<Id, Set<String>> dirtyFieldsByRecord = new Map<Id, Set<String>>();

  // Declared dependencies for topological sort
  private Map<SObjectType, Set<SObjectType>> declaredDependencies = new Map<SObjectType, Set<SObjectType>>();

  // Conflict tracking
  private List<FieldConflict> conflicts = new List<FieldConflict>();

  // Write-ahead journal for rollback of dirty-record mutations
  private List<JournalEntry> journal = new List<JournalEntry>();

  public class JournalEntry {
    public Id recordId;
    public SObjectField field;
    public Object previousValue;
    public String previousHandler;
    public Boolean isNewRecord;
    public Boolean isNewField;
  }

  // DML mode — default true preserves all-or-none behavior
  private Boolean allOrNone = true;

  public void setAllOrNone(Boolean value) {
    this.allOrNone = value;
  }

  public Boolean getAllOrNone() {
    return this.allOrNone;
  }

  public void setCurrentHandler(String handlerName) {
    this.currentHandler = handlerName;
  }

  public void setBeforeTriggerContext(Boolean isBefore) {
    this.isBeforeTriggerContext = isBefore;
  }

  public void setTriggerNewMap(Map<Id, SObject> newMap) {
    this.triggerNewMap = newMap;
  }

  // --- IDmlRegistrar Implementation ---

  public void registerNew(SObject record) {
    if (isBeforeTriggerContext) {
      throw new TriggerFrameworkException(
        'registerNew() is not supported in before-trigger context. Use registerDirty() to modify Trigger.new records.',
        currentHandler,
        null,
        'dml-registration'
      );
    }
    newRecords.add(record);
    // deferred fix: Provenance not tracked for new records (no Id before insert). Accepted risk.
  }

  public void registerNew(
    SObject record,
    SObjectField fkField,
    SObject relatedTo
  ) {
    if (isBeforeTriggerContext) {
      throw new TriggerFrameworkException(
        'registerNew() with FK binding is not supported in before-trigger context.',
        currentHandler,
        null,
        'dml-registration'
      );
    }
    newRecords.add(record);
    ForeignKeyBinding binding = new ForeignKeyBinding(record, fkField, relatedTo);
    fkBindings.add(binding);
    // index by child type
    SObjectType childType = record.getSObjectType();
    if (!fkBindingsByChildType.containsKey(childType)) {
      fkBindingsByChildType.put(childType, new List<ForeignKeyBinding>());
    }
    fkBindingsByChildType.get(childType).add(binding);
    // deferred fix: Provenance not tracked for new records (no Id before insert). Accepted risk.
  }

  public void registerDirty(SObject record, List<SObjectField> dirtyFields) {
    if (isBeforeTriggerContext && triggerNewMap == null) {
      throw new TriggerFrameworkException(
        'registerDirty() requires Trigger.newMap which is not available in BEFORE_INSERT. ' +
        'Modify Trigger.new records directly in beforeInsert() instead.',
        currentHandler,
        null,
        'dml-registration'
      );
    }
    if (isBeforeTriggerContext && triggerNewMap != null) {
      // Before-trigger: apply directly to Trigger.new with conflict detection
      Id recordId = record.Id;
      SObject triggerRecord = triggerNewMap.get(recordId);
      if (triggerRecord == null) {
        System.debug(
          LoggingLevel.WARN,
          'SALT-YASTF: registerDirty() called with record ' +
            recordId +
            ' not found in Trigger.newMap by handler ' +
            currentHandler +
            '. No-op in before-trigger context.'
        );
        return;
      }

      for (SObjectField field : dirtyFields) {
        // P1-1: Use QB-3 cached describe instead of per-field getDescribe()
        String fieldName = QueryRequest.cachedFieldName(field);
        Object newValue = record.get(field);

        // Conflict detection
        checkConflict(recordId, field, fieldName, newValue);

        // Apply to Trigger.new
        triggerRecord.put(field, newValue);

        // Track provenance
        trackFieldProvenance(recordId, fieldName);
      }
    } else {
      // After-trigger: buffer for Phase 4
      Id recordId = record.Id;

      Boolean isNewRecord = !dirtyRecords.containsKey(recordId);
      if (isNewRecord) {
        // Journal: record creation
        JournalEntry je = new JournalEntry();
        je.recordId = recordId;
        je.isNewRecord = true;
        je.isNewField = false;
        journal.add(je);

        dirtyRecords.put(
          recordId,
          record.getSObjectType().newSObject(recordId)
        );
      }
      SObject buffered = dirtyRecords.get(recordId);

      for (SObjectField field : dirtyFields) {
        // P1-1: Use QB-3 cached describe instead of per-field getDescribe()
        String fieldName = QueryRequest.cachedFieldName(field);
        Object newValue = record.get(field);

        // Journal: capture previous field value before mutation
        Boolean isNewField =
          !dirtyFieldsByRecord.containsKey(recordId) ||
          !dirtyFieldsByRecord.get(recordId).contains(fieldName);
        JournalEntry je = new JournalEntry();
        je.recordId = recordId;
        je.field = field;
        je.previousValue = isNewField ? null : buffered.get(field);
        je.previousHandler = fieldProvenance.containsKey(recordId)
          ? fieldProvenance.get(recordId).get(fieldName)
          : null;
        je.isNewRecord = false;
        je.isNewField = isNewField;
        journal.add(je);

        // Conflict detection
        checkConflict(recordId, field, fieldName, newValue);

        // Buffer the field value
        buffered.put(field, newValue);

        // Track provenance and dirty fields
        trackFieldProvenance(recordId, fieldName);
        if (!dirtyFieldsByRecord.containsKey(recordId)) {
          dirtyFieldsByRecord.put(recordId, new Set<String>());
        }
        dirtyFieldsByRecord.get(recordId).add(fieldName);
      }
    }
  }

  public void registerDeleted(SObject record) {
    if (isBeforeTriggerContext) {
      throw new TriggerFrameworkException(
        'registerDeleted() is not supported in before-trigger context.',
        currentHandler,
        null,
        'dml-registration'
      );
    }
    deletedRecords.add(record);
  }

  public void declareDependency(SObjectType source, SObjectType target) {
    if (!declaredDependencies.containsKey(source)) {
      declaredDependencies.put(source, new Set<SObjectType>());
    }
    declaredDependencies.get(source).add(target);
  }

  // --- Internal Methods ---

  private void checkConflict(
    Id recordId,
    SObjectField field,
    String fieldName,
    Object newValue
  ) {
    if (!fieldProvenance.containsKey(recordId)) {
      return;
    }
    Map<String, String> provenance = fieldProvenance.get(recordId);
    if (!provenance.containsKey(fieldName)) {
      return;
    }

    String previousHandler = provenance.get(fieldName);
    if (previousHandler == currentHandler) {
      return; // Same handler setting the same field again - no conflict
    }

    // Get the previously set value
    Object previousValue;
    if (isBeforeTriggerContext && triggerNewMap != null) {
      previousValue = triggerNewMap.get(recordId).get(field);
    } else if (dirtyRecords.containsKey(recordId)) {
      previousValue = dirtyRecords.get(recordId).get(field);
    } else {
      // F6: Defensive log — provenance tracked but record not in dirtyRecords.
      // Architecturally unreachable (separate registrar per before/after) but
      // logs if invariant is ever broken.
      System.debug(
        LoggingLevel.WARN,
        'SALT-YASTF: Conflict check for record ' +
          recordId +
          ' field ' +
          fieldName +
          ' — provenance exists but record ' +
          'not found in dirtyRecords. Handler: ' +
          currentHandler
      );
      return;
    }

    if (
      newValue == previousValue ||
      (newValue != null && newValue.equals(previousValue))
    ) {
      // Same value - WARN
      System.debug(
        LoggingLevel.WARN,
        'SALT-YASTF: Field ' +
          fieldName +
          ' on record ' +
          recordId +
          ' set to same value by handlers ' +
          previousHandler +
          ' and ' +
          currentHandler
      );
      FieldConflict conflict = new FieldConflict(
        recordId,
        field,
        previousHandler,
        currentHandler,
        previousValue,
        newValue
      );
      conflicts.add(conflict);
    } else {
      // Different value - FAIL
      throw new FieldConflictException(
        'Field ' +
          fieldName +
          ' on record ' +
          recordId +
          ' set to different values by handlers ' +
          previousHandler +
          ' (' +
          previousValue +
          ') and ' +
          currentHandler +
          ' (' +
          newValue +
          ')',
        currentHandler,
        null,
        recordId,
        fieldName,
        previousHandler,
        currentHandler,
        previousValue,
        newValue
      );
    }
  }

  private void trackFieldProvenance(Id recordId, String fieldName) {
    if (!fieldProvenance.containsKey(recordId)) {
      fieldProvenance.put(recordId, new Map<String, String>());
    }
    fieldProvenance.get(recordId).put(fieldName, currentHandler);
  }

  // F-C1: Rollback partial DML registrations from a failed non-critical handler.
  // Restores buffer sizes to a previously captured snapshot, discarding any
  // registrations made after the snapshot.
  public void rollbackTo(
    Integer newCount,
    Integer fkCount,
    Integer deletedCount
  ) {
    while (newRecords.size() > newCount) {
      newRecords.remove(newRecords.size() - 1);
    }
    while (fkBindings.size() > fkCount) {
      fkBindings.remove(fkBindings.size() - 1);
    }
    while (deletedRecords.size() > deletedCount) {
      deletedRecords.remove(deletedRecords.size() - 1);
    }
    rebuildFkBindingIndex();
  }

  // F-C1: Capture snapshot of current buffer sizes for rollback.
  public Integer getNewRecordsCount() {
    return newRecords.size();
  }

  public Integer getFkBindingsCount() {
    return fkBindings.size();
  }

  // Journal-based rollback: lightweight alternative to deep-snapshot.
  // Records incremental mutations so rollback replays them in reverse.
  public Integer getJournalMark() {
    return journal.size();
  }

  public void rollbackToJournalMark(Integer mark) {
    if (mark == null || mark < 0 || mark > journal.size()) {
      return; // Safe no-op
    }
    for (Integer i = journal.size() - 1; i >= mark; i--) {
      JournalEntry je = journal[i];
      if (je.isNewRecord) {
        // Remove the entire record that was added by the failed handler
        dirtyRecords.remove(je.recordId);
        dirtyFieldsByRecord.remove(je.recordId);
        fieldProvenance.remove(je.recordId);
      } else {
        // Restore previous field value
        SObject buffered = dirtyRecords.get(je.recordId);
        if (buffered != null) {
          if (je.isNewField) {
            // Field did not exist before — remove it from dirty tracking and restore null
            buffered.put(je.field, null);
            if (dirtyFieldsByRecord.containsKey(je.recordId)) {
              String fieldName = QueryRequest.cachedFieldName(je.field);
              dirtyFieldsByRecord.get(je.recordId).remove(fieldName);
            }
          } else {
            buffered.put(je.field, je.previousValue);
          }
        }
        // Restore provenance
        if (je.previousHandler == null) {
          if (fieldProvenance.containsKey(je.recordId)) {
            String fieldName = QueryRequest.cachedFieldName(je.field);
            fieldProvenance.get(je.recordId).remove(fieldName);
          }
        } else {
          if (fieldProvenance.containsKey(je.recordId)) {
            String fieldName = QueryRequest.cachedFieldName(je.field);
            fieldProvenance.get(je.recordId).put(fieldName, je.previousHandler);
          }
        }
      }
    }
    // Truncate the journal back to the mark
    while (journal.size() > mark) {
      journal.remove(journal.size() - 1);
    }
  }

  public Integer getDeletedRecordsCount() {
    return deletedRecords.size();
  }

  public Integer getConflictsCount() {
    return conflicts.size();
  }

  // F59: Rollback conflicts list to a previously captured size.
  // Discards conflict entries logged by a failed non-critical handler.
  public void rollbackConflictsTo(Integer size) {
    while (conflicts.size() > size) {
      conflicts.remove(conflicts.size() - 1);
    }
  }

  public List<ForeignKeyBinding> getFkBindingsForType(SObjectType t) {
    if (fkBindingsByChildType.containsKey(t)) {
      return fkBindingsByChildType.get(t);
    }
    return new List<ForeignKeyBinding>();
  }

  private void rebuildFkBindingIndex() {
    fkBindingsByChildType.clear();
    for (ForeignKeyBinding binding : fkBindings) {
      SObjectType childType = binding.childRecord.getSObjectType();
      if (!fkBindingsByChildType.containsKey(childType)) {
        fkBindingsByChildType.put(childType, new List<ForeignKeyBinding>());
      }
      fkBindingsByChildType.get(childType).add(binding);
    }
  }

  // --- Accessors for DmlExecutor (framework-internal) ---
  // Returns live references. Safe because the only consumers are DmlExecutor and
  // TriggerDispatcher — both framework code that never mutates these collections.
  // Handlers interact through IDmlRegistrar (write-only) and never see these getters.

  public List<SObject> getNewRecords() {
    return newRecords;
  }
  public List<ForeignKeyBinding> getFkBindings() {
    return fkBindings;
  }
  public Map<Id, SObject> getDirtyRecords() {
    return dirtyRecords;
  }
  public List<SObject> getDeletedRecords() {
    return deletedRecords;
  }
  public Map<SObjectType, Set<SObjectType>> getDeclaredDependencies() {
    return declaredDependencies;
  }
  public Map<Id, Map<String, String>> getFieldProvenance() {
    return fieldProvenance;
  }
  public List<FieldConflict> getConflicts() {
    return conflicts;
  }

  public Boolean hasPendingDml() {
    return !newRecords.isEmpty() ||
      !dirtyRecords.isEmpty() ||
      !deletedRecords.isEmpty();
  }
}
