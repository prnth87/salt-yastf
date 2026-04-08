public inherited sharing class CompositeFilter {
  public static IRecordFilter andFilter(List<IRecordFilter> filters) {
    return new AndFilter(filters);
  }

  public static IRecordFilter orFilter(List<IRecordFilter> filters) {
    return new OrFilter(filters);
  }

  public static IRecordFilter notFilter(IRecordFilter filter) {
    return new NotFilter(filter);
  }

  private class AndFilter implements IRecordFilter {
    private final List<IRecordFilter> filters;
    AndFilter(List<IRecordFilter> filters) {
      this.filters = filters;
    }
    public Boolean isApplicable(
      SObject newRecord,
      SObject oldRecord,
      TriggerContext ctx
    ) {
      for (IRecordFilter f : filters) {
        if (!f.isApplicable(newRecord, oldRecord, ctx))
          return false;
      }
      return true;
    }
  }

  private class OrFilter implements IRecordFilter {
    private final List<IRecordFilter> filters;
    OrFilter(List<IRecordFilter> filters) {
      this.filters = filters;
    }
    public Boolean isApplicable(
      SObject newRecord,
      SObject oldRecord,
      TriggerContext ctx
    ) {
      for (IRecordFilter f : filters) {
        if (f.isApplicable(newRecord, oldRecord, ctx))
          return true;
      }
      return false;
    }
  }

  private class NotFilter implements IRecordFilter {
    private final IRecordFilter filter;
    NotFilter(IRecordFilter filter) {
      this.filter = filter;
    }
    public Boolean isApplicable(
      SObject newRecord,
      SObject oldRecord,
      TriggerContext ctx
    ) {
      return !filter.isApplicable(newRecord, oldRecord, ctx);
    }
  }
}
