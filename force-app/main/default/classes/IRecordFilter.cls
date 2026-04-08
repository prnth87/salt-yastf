public interface IRecordFilter {
  Boolean isApplicable(
    SObject newRecord,
    SObject oldRecord,
    TriggerContext ctx
  );
}
