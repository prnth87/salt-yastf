public inherited sharing class DmlOperation {
  public class DmlError {
    public Id recordId { get; private set; }
    public String message { get; private set; }
    public StatusCode statusCode { get; private set; }
    public List<String> fields { get; private set; }
    // F-DE1: Position in the original DML list, useful for identifying
    // the failing record when recordId is null (e.g. failed inserts).
    public Integer listIndex { get; private set; }

    public DmlError(Id recordId, Database.Error err, Integer listIndex) {
      this.recordId = recordId;
      this.message = err.getMessage();
      this.statusCode = err.getStatusCode();
      this.fields = err.getFields();
      this.listIndex = listIndex;
    }
  }

  private enum OpType {
    DML_INSERT,
    DML_UPDATE,
    DML_DELETE
  }

  private OpType opType;
  private List<SObject> records;
  private Boolean allOrNoneFlag = true;

  private Integer successCount = 0;
  private Integer failureCount = 0;
  private List<DmlError> errors = new List<DmlError>();

  private DmlOperation(OpType opType, List<SObject> records) {
    this.opType = opType;
    this.records = records;
  }

  public static DmlOperation forInsert(List<SObject> records) {
    return new DmlOperation(OpType.DML_INSERT, records);
  }

  public static DmlOperation forUpdate(List<SObject> records) {
    return new DmlOperation(OpType.DML_UPDATE, records);
  }

  public static DmlOperation forDelete(List<SObject> records) {
    return new DmlOperation(OpType.DML_DELETE, records);
  }

  public DmlOperation allOrNone(Boolean value) {
    this.allOrNoneFlag = value;
    return this;
  }

  public DmlOperation execute() {
    if (records == null || records.isEmpty()) {
      return this;
    }
    switch on this.opType {
      when DML_INSERT {
        processSaveResults(Database.insert(records, allOrNoneFlag));
      }
      when DML_UPDATE {
        processSaveResults(Database.update(records, allOrNoneFlag));
      }
      when DML_DELETE {
        processDeleteResults(Database.delete(records, allOrNoneFlag));
      }
    }
    logOutcome();
    return this;
  }

  public Integer getSuccessCount() {
    return successCount;
  }

  public Integer getFailureCount() {
    return failureCount;
  }

  public List<DmlError> getErrors() {
    return errors;
  }

  public Boolean isFullSuccess() {
    return failureCount == 0;
  }

  private void processSaveResults(List<Database.SaveResult> results) {
    for (Integer i = 0; i < results.size(); i++) {
      Database.SaveResult sr = results[i];
      if (sr.isSuccess()) {
        successCount++;
      } else {
        failureCount++;
        Id recordId = (i < records.size()) ? records[i].Id : null;
        for (Database.Error err : sr.getErrors()) {
          errors.add(new DmlError(recordId, err, i)); // F-DE1: pass list index
        }
      }
    }
  }

  private void processDeleteResults(List<Database.DeleteResult> results) {
    for (Integer i = 0; i < results.size(); i++) {
      Database.DeleteResult dr = results[i];
      if (dr.isSuccess()) {
        successCount++;
      } else {
        failureCount++;
        Id recordId = (i < records.size()) ? records[i].Id : null;
        for (Database.Error err : dr.getErrors()) {
          errors.add(new DmlError(recordId, err, i)); // F-DE1: pass list index
        }
      }
    }
  }

  private void logOutcome() {
    String opLabel = opType.name().replace('DML_', '');
    // F-QB7: Use QB-3 cached type name to avoid redundant describe per DML operation
    String sObjLabel = (!records.isEmpty())
      ? QueryRequest.cachedTypeName(records[0].getSObjectType())
      : 'Unknown';

    if (isFullSuccess()) {
      System.debug(
        LoggingLevel.DEBUG,
        'SALT-YASTF DML: ' +
          opLabel +
          ' ' +
          sObjLabel +
          ' — ' +
          successCount +
          ' succeeded, allOrNone=' +
          allOrNoneFlag
      );
    } else {
      System.debug(
        LoggingLevel.WARN,
        'SALT-YASTF DML: ' +
          opLabel +
          ' ' +
          sObjLabel +
          ' — ' +
          successCount +
          ' succeeded, ' +
          failureCount +
          ' failed, allOrNone=' +
          allOrNoneFlag
      );
      for (DmlError err : errors) {
        System.debug(
          LoggingLevel.ERROR,
          'SALT-YASTF DML Error: ' +
            err.statusCode +
            ' on ' +
            err.recordId +
            ' — ' +
            err.message +
            ' [fields: ' +
            err.fields +
            ']'
        );
      }
    }
  }
}
