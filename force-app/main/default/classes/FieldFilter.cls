/**
 * FieldFilter — leaf Predicate over a single SObjectField.
 *
 * Supports 8 operators (EQUALS, NOT_EQUALS, IN_OP, NOT_IN, LT, LE, GT, GE).
 * Construction is via static factories which apply factory-time rejections
 * for unsupported field types and operator combinations:
 *
 *   - reserved __salt_ field name prefix          -> reject (bind safety)
 *   - Currency field on multi-currency org        -> reject (no in-memory conversion)
 *   - EncryptedString field                       -> reject (cannot match in-memory)
 *   - Location field                              -> reject (geolocation matcher mismatch)
 *   - Cross-object formula field                  -> reject (cannot resolve in-memory)
 *   - Picklist with LT/LE/GT/GE                   -> reject (locale-dependent ordering)
 *   - String with LT/LE/GT/GE                     -> reject (locale-dependent ordering)
 *   - Date field with Datetime bind on inequality -> reject (cross-type comparison)
 *   - Datetime field with Date bind on inequality -> reject (cross-type comparison)
 *
 * Polymorphic-id allowance: lookup fields like Task.WhatId / OwnerId are
 * allowed for EQ/NE/IN/NOT_IN with Id binds. Polymorphic id-type mismatch
 * silently returns 0 rows from SOQL — this is intentional and not validated.
 *
 * matches(SObject row) implements per-type normalization for the in-memory matcher:
 *   - Id          : 15->18 canonicalization
 *   - String      : case-insensitive equality
 *   - Decimal     : compareTo (scale-tolerant)
 *   - Datetime    : truncate to second
 */
public inherited sharing class FieldFilter implements Predicate {
  public enum Op {
    EQUALS,
    NOT_EQUALS,
    IN_OP,
    NOT_IN,
    LT,
    LE,
    GT,
    GE
  }

  public final SObjectField field;
  public final Op operator;
  public final Object bindValue;

  // cached describe — fetched once at construction
  private final Schema.DescribeFieldResult fieldDescribe;
  private final Schema.DisplayType fieldType;
  private final String fieldName;
  private final Integer structuralHash;

  private FieldFilter(SObjectField f, Op opVal, Object v) {
    this.field = f;
    this.operator = opVal;
    this.bindValue = v;
    this.fieldDescribe = f.getDescribe();
    this.fieldType = this.fieldDescribe.getType();
    this.fieldName = QueryRequest.cachedFieldName(f);
    // Compute structural hash from field, operator, and bindValue
    Integer h = System.hashCode(f);
    h = 31 * h + opVal.ordinal();
    h = 31 * h + (v == null ? 0 : System.hashCode(v));
    this.structuralHash = h;
  }

  // ---- factories ----

  public static FieldFilter equals(SObjectField f, Object v) {
    return build(f, Op.EQUALS, v);
  }
  public static FieldFilter notEquals(SObjectField f, Object v) {
    return build(f, Op.NOT_EQUALS, v);
  }
  public static FieldFilter inSet(SObjectField f, Set<Object> vs) {
    return build(f, Op.IN_OP, vs);
  }
  public static FieldFilter notInSet(SObjectField f, Set<Object> vs) {
    return build(f, Op.NOT_IN, vs);
  }
  public static FieldFilter lt(SObjectField f, Object v) {
    return build(f, Op.LT, v);
  }
  public static FieldFilter le(SObjectField f, Object v) {
    return build(f, Op.LE, v);
  }
  public static FieldFilter gt(SObjectField f, Object v) {
    return build(f, Op.GT, v);
  }
  public static FieldFilter ge(SObjectField f, Object v) {
    return build(f, Op.GE, v);
  }

  private static FieldFilter build(SObjectField f, Op opVal, Object v) {
    if (f == null) {
      throw new TriggerFrameworkException(
        'FieldFilter requires a non-null SObjectField'
      );
    }
    FieldFilter ff = new FieldFilter(f, opVal, v);
    ff.applyFactoryRejections();
    return ff;
  }

  private void applyFactoryRejections() {
    // handler/tag name validation — reserved bind/field prefix collision
    if (fieldName != null && fieldName.toLowerCase().startsWith('__salt_')) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects reserved __salt_ field name prefix: ' + fieldName
      );
    }

    Boolean isOrdered = (operator == Op.LT ||
      operator == Op.LE ||
      operator == Op.GT ||
      operator == Op.GE);

    // tier-2 factory rejection — Currency on multi-currency org
    if (
      fieldType == Schema.DisplayType.CURRENCY &&
      UserInfo.isMultiCurrencyOrganization()
    ) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects Currency field ' +
          fieldName +
          ' on multi-currency org (no in-memory currency conversion)'
      );
    }

    // tier-2 factory rejection — EncryptedString
    if (fieldType == Schema.DisplayType.ENCRYPTEDSTRING) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects EncryptedString field ' + fieldName + ' (cannot match in-memory)'
      );
    }

    // tier-2 factory rejection — Location (geolocation compound)
    if (fieldType == Schema.DisplayType.LOCATION) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects Location field ' +
          fieldName +
          ' — DISTANCE not supported in v1.1 (cannot match in-memory)'
      );
    }

    // tier-2 factory rejection — cross-object formula
    String formula = fieldDescribe.getCalculatedFormula();
    if (formula != null && formula.contains('.')) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects cross-object formula field ' + fieldName + ' (cannot match in-memory)'
      );
    }

    // tier-3 sensitive field defensive walk tier-3 — picklist inequality
    if (
      isOrdered &&
      (fieldType == Schema.DisplayType.PICKLIST ||
      fieldType == Schema.DisplayType.MULTIPICKLIST)
    ) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects ordered comparison on picklist field ' +
          fieldName +
          ' (locale-dependent ordering)'
      );
    }

    // tier-3 sensitive field defensive walk tier-3 — string inequality (locale collation hazard)
    if (
      isOrdered &&
      (fieldType == Schema.DisplayType.STRING ||
      fieldType == Schema.DisplayType.TEXTAREA ||
      fieldType == Schema.DisplayType.EMAIL ||
      fieldType == Schema.DisplayType.URL ||
      fieldType == Schema.DisplayType.PHONE)
    ) {
      throw new TriggerFrameworkException(
        'FieldFilter rejects ordered comparison on text field ' +
          fieldName +
          ' (locale-dependent ordering)'
      );
    }

    // Date↔Datetime cross-type rejection — Date/Datetime mismatch on ordered ops
    if (isOrdered && bindValue != null) {
      if (fieldType == Schema.DisplayType.DATE && bindValue instanceof Datetime && !(bindValue instanceof Date)) {
        throw new TriggerFrameworkException(
          'FieldFilter rejects Datetime bind for Date field ' +
            fieldName +
            ' on ordered comparison (Date/Datetime cross-type)'
        );
      }
      if (fieldType == Schema.DisplayType.DATETIME && bindValue instanceof Date && !(bindValue instanceof Datetime)) {
        throw new TriggerFrameworkException(
          'FieldFilter rejects Date bind for Datetime field ' +
            fieldName +
            ' on ordered comparison (Date/Datetime cross-type)'
        );
      }
    }
  }

  // ---- matches ----

  public Boolean matches(SObject row) {
    Object actual = row.get(field);

    if (operator == Op.EQUALS) {
      return scalarEquals(actual, bindValue);
    }
    if (operator == Op.NOT_EQUALS) {
      if (actual == null) {
        return false;
      }
      return !scalarEquals(actual, bindValue);
    }
    if (operator == Op.IN_OP || operator == Op.NOT_IN) {
      Boolean found = false;
      Iterable<Object> items = asIterable(bindValue);
      if (items != null) {
        for (Object v : items) {
          if (scalarEquals(actual, v)) {
            found = true;
            break;
          }
        }
      }
      return (operator == Op.IN_OP) ? found : !found;
    }
    // ordered ops
    if (actual == null || bindValue == null) {
      return false;
    }
    Integer cmp = compareOrdered(actual, bindValue);
    if (operator == Op.LT) {
      return cmp < 0;
    }
    if (operator == Op.LE) {
      return cmp <= 0;
    }
    if (operator == Op.GT) {
      return cmp > 0;
    }
    return cmp >= 0; // GE
  }

  private Boolean scalarEquals(Object actual, Object bind) {
    if (bind == null) {
      return actual == null;
    }
    if (actual == null) {
      return false;
    }
    // Id / Reference: canonicalize 15->18 by Id cast.
    if (
      fieldType == Schema.DisplayType.ID ||
      fieldType == Schema.DisplayType.REFERENCE
    ) {
      Id a = toId(actual);
      Id b = toId(bind);
      return a == b;
    }
    if (fieldType == Schema.DisplayType.STRING ||
        fieldType == Schema.DisplayType.TEXTAREA ||
        fieldType == Schema.DisplayType.EMAIL ||
        fieldType == Schema.DisplayType.URL ||
        fieldType == Schema.DisplayType.PHONE) {
      return String.valueOf(actual).equalsIgnoreCase(String.valueOf(bind));
    }
    if (fieldType == Schema.DisplayType.CURRENCY ||
        fieldType == Schema.DisplayType.DOUBLE ||
        fieldType == Schema.DisplayType.PERCENT) {
      Decimal a = toDecimal(actual);
      Decimal b = toDecimal(bind);
      return (a - b) == 0;
    }
    if (fieldType == Schema.DisplayType.DATETIME) {
      Datetime a = (Datetime) actual;
      Datetime b = (Datetime) bind;
      return truncSec(a) == truncSec(b);
    }
    return actual == bind;
  }

  private Id toId(Object v) {
    if (v == null) {
      return null;
    }
    if (v instanceof Id) {
      return (Id) v;
    }
    return (Id) String.valueOf(v);
  }

  private Decimal toDecimal(Object v) {
    if (v instanceof Decimal) {
      return (Decimal) v;
    }
    if (v instanceof Integer) {
      return Decimal.valueOf((Integer) v);
    }
    if (v instanceof Long) {
      return Decimal.valueOf((Long) v);
    }
    if (v instanceof Double) {
      return Decimal.valueOf((Double) v);
    }
    return Decimal.valueOf(String.valueOf(v));
  }

  private Datetime truncSec(Datetime dt) {
    return Datetime.newInstance(
      dt.year(),
      dt.month(),
      dt.day(),
      dt.hour(),
      dt.minute(),
      dt.second()
    );
  }

  private Integer compareOrdered(Object actual, Object bind) {
    if (actual instanceof Decimal || bind instanceof Decimal ||
        actual instanceof Integer || actual instanceof Long ||
        actual instanceof Double) {
      Decimal da = toDecimal(actual);
      Decimal db = toDecimal(bind);
      if (da == db) { return 0; }
      return da < db ? -1 : 1;
    }
    if (actual instanceof Datetime) {
      Datetime a = truncSec((Datetime) actual);
      Datetime b = truncSec((Datetime) bind);
      if (a == b) {
        return 0;
      }
      return a < b ? -1 : 1;
    }
    if (actual instanceof Date) {
      Date a = (Date) actual;
      Date b = (Date) bind;
      if (a == b) {
        return 0;
      }
      return a < b ? -1 : 1;
    }
    // fallback
    String sa = String.valueOf(actual);
    String sb = String.valueOf(bind);
    return sa.compareTo(sb);
  }

  private Iterable<Object> asIterable(Object v) {
    if (v == null) {
      return null;
    }
    if (v instanceof List<Object>) {
      return (List<Object>) v;
    }
    if (v instanceof Set<Object>) {
      List<Object> out = new List<Object>();
      out.addAll((Set<Object>) v);
      return out;
    }
    return null;
  }

  // ---- render ----

  public String render(BindContext ctx) {
    String b = ctx.nextPredicateBindName();
    ctx.registerBind(b, bindValue);
    if (operator == Op.IN_OP) {
      return fieldName + ' IN :' + b;
    }
    if (operator == Op.NOT_IN) {
      return fieldName + ' NOT IN :' + b;
    }
    return fieldName + ' ' + opSymbol(operator) + ' :' + b;
  }

  private static String opSymbol(Op opVal) {
    if (opVal == Op.EQUALS) {
      return '=';
    }
    if (opVal == Op.NOT_EQUALS) {
      return '!=';
    }
    if (opVal == Op.LT) {
      return '<';
    }
    if (opVal == Op.LE) {
      return '<=';
    }
    if (opVal == Op.GT) {
      return '>';
    }
    if (opVal == Op.GE) {
      return '>=';
    }
    return '=';
  }

  // ---- equalsPredicate ----

  public Boolean equalsPredicate(Predicate other) {
    if (!(other instanceof FieldFilter)) {
      return false;
    }
    FieldFilter o = (FieldFilter) other;
    if (this.field != o.field) {
      return false;
    }
    if (this.operator != o.operator) {
      return false;
    }
    return bindEquals(this.bindValue, o.bindValue);
  }

  public Integer getStructuralHash() {
    return structuralHash;
  }

  private Boolean bindEquals(Object a, Object b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    Boolean isIdField = (fieldType == Schema.DisplayType.ID ||
      fieldType == Schema.DisplayType.REFERENCE);
    if (isIdField) {
      // canonicalize
      if (a instanceof Set<Object> || a instanceof List<Object>) {
        Set<Id> sa = canonIdSet(a);
        Set<Id> sb = canonIdSet(b);
        if (sa == null || sb == null) {
          return false;
        }
        return sa.equals(sb);
      }
      Id ca = toId(a);
      Id cb = toId(b);
      return ca == cb;
    }
    // collections — compare as sets when possible
    if (a instanceof Set<Object> && b instanceof Set<Object>) {
      return ((Set<Object>) a).equals((Set<Object>) b);
    }
    if (a instanceof List<Object> && b instanceof List<Object>) {
      return ((List<Object>) a).equals((List<Object>) b);
    }
    return a == b;
  }

  private Set<Id> canonIdSet(Object v) {
    Set<Id> out = new Set<Id>();
    if (v instanceof Set<Object>) {
      for (Object o : (Set<Object>) v) {
        if (o == null) {
          continue;
        }
        out.add(toId(o));
      }
      return out;
    }
    if (v instanceof List<Object>) {
      for (Object o : (List<Object>) v) {
        if (o == null) {
          continue;
        }
        out.add(toId(o));
      }
      return out;
    }
    return null;
  }
}
