/**
 * QueryAggregator — v1.1 merge gate for SALT(YASTF) Query Pipeline.
 *
 * Replaces the legacy 2.0-ratio CSV-handler heuristic with a deterministic,
 * structurally-grounded gate (canMergeOrUnion) and n-way OR composition
 * (ARCH-F8). Groups incoming QueryRequests by mergeKey, then per group
 * walks requests pairwise, classifying each pair into one of four modes:
 *
 *   REFUSE          — incompatible (FLS, shape, tier-3 field, etc.)
 *   MERGE_IDENTITY  — structurally equal filter trees; take one tree
 *   MERGE_OR        — differing filter trees; OR-wrap per-handler AND-trees
 *   MERGE_SUBSUME   — one side has no filters; take empty WHERE, defer
 *                     filtered-side predicates to matcher re-application
 *
 * N-way composition: when 3+ requests in a group are mutually mergeable,
 * the merged predicate is built via CompositePredicate.orOf(List) in a
 * single call — NOT pairwise concat — avoiding nested OR towers.
 *
 * Governance invariants:
 *   FLS-mismatch precondition   — FLS posture mismatch => REFUSE
 *   tag dimension  — mixed null/non-null tag within same (handler, mergeKey) => throw
 *   OR-merge with union field sets  — union dominance on fields/ids/handlers/provenance
 *   tier-3 sensitive field defensive walk — tier-3 sensitive field types defensively rejected
 *   BUG H6 — NEVER mutate input QueryRequest fields/recordIds/filters
 */
public inherited sharing class QueryAggregator {
  private Map<String, List<QueryRequest>> requestsByMergeKey = new Map<String, List<QueryRequest>>();

  public enum MergeMode {
    REFUSE,
    MERGE_IDENTITY,
    MERGE_OR,
    MERGE_SUBSUME
  }

  // ---- Public API (signatures unchanged from legacy) ----

  public void addRequests(List<QueryRequest> requests) {
    for (QueryRequest req : requests) {
      String key = req.getMergeKey();
      if (!requestsByMergeKey.containsKey(key)) {
        requestsByMergeKey.put(key, new List<QueryRequest>());
      }
      requestsByMergeKey.get(key).add(req);
    }
    // tag dimension / tag-collision rule: within a (handler, mergeKey) group, reject
    // mixed null/non-null tags immediately at intake time.
    validateNoMixedTags();
  }

  public List<QueryRequest> getMergedRequests() {
    List<QueryRequest> merged = new List<QueryRequest>();

    for (String key : requestsByMergeKey.keySet()) {
      List<QueryRequest> grp = requestsByMergeKey.get(key);
      if (grp.size() == 1) {
        merged.add(grp[0]);
        continue;
      }
      merged.addAll(mergeGroup(grp));
    }
    return merged;
  }

  // ---- Group-level merging ----

  private List<QueryRequest> mergeGroup(List<QueryRequest> grp) {
    // Build clusters of mutually-mergeable requests. A cluster forms only
    // when a candidate is pairwise compatible with every existing member.
    // Non-matching requests become their own singleton clusters.
    List<List<QueryRequest>> clusters = new List<List<QueryRequest>>();
    List<MergeMode> clusterModes = new List<MergeMode>();

    for (QueryRequest req : grp) {
      Boolean placed = false;
      for (Integer i = 0; i < clusters.size(); i++) {
        List<QueryRequest> cluster = clusters[i];
        MergeMode candidateMode = canMergeWithCluster(cluster, req);
        if (candidateMode != MergeMode.REFUSE) {
          cluster.add(req);
          // Mode escalation: IDENTITY < SUBSUME < OR. Once a cluster
          // contains any differing filter, it becomes an OR cluster.
          clusterModes[i] = escalateMode(clusterModes[i], candidateMode);
          placed = true;
          break;
        }
      }
      if (!placed) {
        clusters.add(new List<QueryRequest>{ req });
        clusterModes.add(MergeMode.MERGE_IDENTITY); // singleton baseline
      }
    }

    List<QueryRequest> out = new List<QueryRequest>();
    for (Integer i = 0; i < clusters.size(); i++) {
      List<QueryRequest> cluster = clusters[i];
      if (cluster.size() == 1) {
        out.add(cluster[0]);
      } else {
        out.add(mergeAll(cluster, clusterModes[i]));
      }
    }
    return out;
  }

  private MergeMode canMergeWithCluster(
    List<QueryRequest> cluster,
    QueryRequest candidate
  ) {
    MergeMode worst = MergeMode.MERGE_IDENTITY;
    for (QueryRequest existing : cluster) {
      MergeMode m = canMergeOrUnion(existing, candidate);
      if (m == MergeMode.REFUSE) {
        return MergeMode.REFUSE;
      }
      worst = escalateMode(worst, m);
    }
    return worst;
  }

  private MergeMode escalateMode(MergeMode a, MergeMode b) {
    if (a == MergeMode.MERGE_OR || b == MergeMode.MERGE_OR) {
      return MergeMode.MERGE_OR;
    }
    if (a == MergeMode.MERGE_SUBSUME || b == MergeMode.MERGE_SUBSUME) {
      return MergeMode.MERGE_SUBSUME;
    }
    return MergeMode.MERGE_IDENTITY;
  }

  // ---- canMergeOrUnion — ordered preconditions ----
  //
  // Line refs for the compliance report:
  //  1. FLS mismatch (FLS-mismatch precondition)                 -> see "fls posture" block
  //  2. Different SObjectType             -> see "target object" block
  //  3. Different relationshipField       -> see "relationship field" block
  //  4. Mixed shape (child vs flat where) -> see "mixed shape" block
  //  5. Differing child descriptors       -> see "child descriptor" block
  //  6. Tier-3 sensitive field (tier-3 sensitive field defensive walk)   -> see "tier-3 defensive" block
  //  7. Filter list comparison            -> see "filter comparison" block
  @TestVisible
  private MergeMode canMergeOrUnion(QueryRequest a, QueryRequest b) {
    // (1) fls posture — FLS-mismatch precondition
    if (a.enforceFLS != b.enforceFLS) {
      return MergeMode.REFUSE;
    }
    // (2) target object
    if (a.targetObject != b.targetObject) {
      return MergeMode.REFUSE;
    }
    // (3) relationship field (null-safe)
    if (!nullSafeEq(a.relationshipField, b.relationshipField)) {
      return MergeMode.REFUSE;
    }
    // (4) mixed shape — one has child subquery, other has flat filters
    Boolean aHasChild = (a.childSubquery != null);
    Boolean bHasChild = (b.childSubquery != null);
    Boolean aHasFilters = (a.filters != null && !a.filters.isEmpty());
    Boolean bHasFilters = (b.filters != null && !b.filters.isEmpty());
    if ((aHasChild && bHasFilters) || (bHasChild && aHasFilters)) {
      return MergeMode.REFUSE;
    }
    // (5) both child subqueries — require structural equality
    if (aHasChild && bHasChild) {
      if (!childDescriptorsEqual(a.childSubquery, b.childSubquery)) {
        return MergeMode.REFUSE;
      }
    }
    // (6) tier-3 defensive — FieldFilter factory already rejects these,
    //     so this is a no-op belt-and-suspenders check (tier-3 sensitive field defensive walk).
    if (hasTier3Field(a.filters) || hasTier3Field(b.filters)) {
      return MergeMode.REFUSE;
    }
    // (7) filter list comparison
    if (!aHasFilters && !bHasFilters) {
      return MergeMode.MERGE_IDENTITY;
    }
    if (aHasFilters != bHasFilters) {
      return MergeMode.MERGE_SUBSUME;
    }
    Predicate treeA = andTreeOf(a.filters);
    Predicate treeB = andTreeOf(b.filters);
    if (treeA != null && treeB != null && treeA.equalsPredicate(treeB)) {
      return MergeMode.MERGE_IDENTITY;
    }
    return MergeMode.MERGE_OR;
  }

  // ---- Merging mechanics ----

  private QueryRequest mergeAll(List<QueryRequest> cluster, MergeMode mode) {
    QueryRequest first = cluster[0];

    // Unions (never mutate inputs — fresh collections)
    Set<SObjectField> mergedFields = new Set<SObjectField>();
    Set<Id> mergedIds = new Set<Id>();
    Set<String> mergedHandlers = new Set<String>();
    for (QueryRequest r : cluster) {
      if (r.fields != null) {
        mergedFields.addAll(r.fields);
      }
      if (r.recordIds != null) {
        mergedIds.addAll(r.recordIds);
      }
      if (r.declaringHandlers != null) {
        mergedHandlers.addAll(r.declaringHandlers);
      }
    }

    // Filter composition
    List<Predicate> mergedFilters;
    if (mode == MergeMode.MERGE_SUBSUME) {
      // Empty WHERE — matcher re-applies the filtered side via
      // filtersByHandler at retrieval time (in-memory matcher).
      mergedFilters = new List<Predicate>();
    } else if (mode == MergeMode.MERGE_IDENTITY) {
      // Structurally equal — pick one tree from whichever cluster member
      // has filters. If none do (all empty), emit empty list.
      Predicate chosen = null;
      for (QueryRequest r : cluster) {
        if (r.filters != null && !r.filters.isEmpty()) {
          chosen = andTreeOf(r.filters);
          break;
        }
      }
      mergedFilters = (chosen == null)
        ? new List<Predicate>()
        : new List<Predicate>{ chosen };
    } else {
      // MERGE_OR — n-way composition via a single orOf() call (ARCH-F8).
      // Per-handler AND-tree collapse happens first so each side
      // contributes one node to the OR.
      List<Predicate> perSideTrees = new List<Predicate>();
      for (QueryRequest r : cluster) {
        Predicate t = andTreeOf(r.filters);
        if (t != null) {
          perSideTrees.add(t);
        }
      }
      // If somehow only one tree survives, orOf would collapse it; still safe.
      mergedFilters = new List<Predicate>{
        CompositePredicate.orOf(perSideTrees)
      };
    }

    // Child subquery — already validated equal across cluster, take first.
    ChildSubqueryDescriptor mergedChild = first.childSubquery;

    // 4-level provenance map union (fresh accumulators — no input mutation)
    Map<String, Map<String, Map<String, Set<Id>>>> mergedIdsByHandler = unionIdsByHandler(
      cluster
    );
    Map<String, Map<String, Map<String, Set<SObjectField>>>> mergedFieldsByHandler = unionFieldsByHandler(
      cluster
    );
    Map<String, Map<String, Map<String, List<Predicate>>>> mergedFiltersByHandler = unionFiltersByHandler(
      cluster
    );

    return QueryRequest.forOrMerged(
      first.targetObject,
      mergedFields,
      mergedIds,
      first.relationshipField,
      first.enforceFLS,
      mergedHandlers,
      mergedFilters,
      mergedChild,
      mergedIdsByHandler,
      mergedFieldsByHandler,
      mergedFiltersByHandler
    );
  }

  // ---- Provenance map union helpers ----

  private Map<String, Map<String, Map<String, Set<Id>>>> unionIdsByHandler(
    List<QueryRequest> cluster
  ) {
    Map<String, Map<String, Map<String, Set<Id>>>> out = new Map<String, Map<String, Map<String, Set<Id>>>>();
    for (QueryRequest r : cluster) {
      if (r.idsByHandler == null) {
        continue;
      }
      for (String mk : r.idsByHandler.keySet()) {
        Map<String, Map<String, Set<Id>>> srcHandlerMap = r.idsByHandler.get(
          mk
        );
        if (!out.containsKey(mk)) {
          out.put(mk, new Map<String, Map<String, Set<Id>>>());
        }
        Map<String, Map<String, Set<Id>>> dstHandlerMap = out.get(mk);
        for (String handler : srcHandlerMap.keySet()) {
          Map<String, Set<Id>> srcTagMap = srcHandlerMap.get(handler);
          if (!dstHandlerMap.containsKey(handler)) {
            dstHandlerMap.put(handler, new Map<String, Set<Id>>());
          }
          Map<String, Set<Id>> dstTagMap = dstHandlerMap.get(handler);
          for (String tagK : srcTagMap.keySet()) {
            if (!dstTagMap.containsKey(tagK)) {
              dstTagMap.put(tagK, new Set<Id>());
            }
            dstTagMap.get(tagK).addAll(srcTagMap.get(tagK));
          }
        }
      }
    }
    return out;
  }

  private Map<String, Map<String, Map<String, Set<SObjectField>>>> unionFieldsByHandler(
    List<QueryRequest> cluster
  ) {
    Map<String, Map<String, Map<String, Set<SObjectField>>>> out = new Map<String, Map<String, Map<String, Set<SObjectField>>>>();
    for (QueryRequest r : cluster) {
      if (r.fieldsByHandler == null) {
        continue;
      }
      for (String mk : r.fieldsByHandler.keySet()) {
        Map<String, Map<String, Set<SObjectField>>> srcHandlerMap = r.fieldsByHandler.get(
          mk
        );
        if (!out.containsKey(mk)) {
          out.put(mk, new Map<String, Map<String, Set<SObjectField>>>());
        }
        Map<String, Map<String, Set<SObjectField>>> dstHandlerMap = out.get(mk);
        for (String handler : srcHandlerMap.keySet()) {
          Map<String, Set<SObjectField>> srcTagMap = srcHandlerMap.get(handler);
          if (!dstHandlerMap.containsKey(handler)) {
            dstHandlerMap.put(handler, new Map<String, Set<SObjectField>>());
          }
          Map<String, Set<SObjectField>> dstTagMap = dstHandlerMap.get(handler);
          for (String tagK : srcTagMap.keySet()) {
            if (!dstTagMap.containsKey(tagK)) {
              dstTagMap.put(tagK, new Set<SObjectField>());
            }
            dstTagMap.get(tagK).addAll(srcTagMap.get(tagK));
          }
        }
      }
    }
    return out;
  }

  private Map<String, Map<String, Map<String, List<Predicate>>>> unionFiltersByHandler(
    List<QueryRequest> cluster
  ) {
    Map<String, Map<String, Map<String, List<Predicate>>>> out = new Map<String, Map<String, Map<String, List<Predicate>>>>();
    for (QueryRequest r : cluster) {
      if (r.filtersByHandler == null) {
        continue;
      }
      for (String mk : r.filtersByHandler.keySet()) {
        Map<String, Map<String, List<Predicate>>> srcHandlerMap = r.filtersByHandler.get(
          mk
        );
        if (!out.containsKey(mk)) {
          out.put(mk, new Map<String, Map<String, List<Predicate>>>());
        }
        Map<String, Map<String, List<Predicate>>> dstHandlerMap = out.get(mk);
        for (String handler : srcHandlerMap.keySet()) {
          Map<String, List<Predicate>> srcTagMap = srcHandlerMap.get(handler);
          if (!dstHandlerMap.containsKey(handler)) {
            dstHandlerMap.put(handler, new Map<String, List<Predicate>>());
          }
          Map<String, List<Predicate>> dstTagMap = dstHandlerMap.get(handler);
          for (String tagK : srcTagMap.keySet()) {
            if (!dstTagMap.containsKey(tagK)) {
              dstTagMap.put(tagK, new List<Predicate>());
            }
            // fresh list copy — never share references with input
            dstTagMap.get(tagK).addAll(srcTagMap.get(tagK));
          }
        }
      }
    }
    return out;
  }

  // ---- Small helpers ----

  private Boolean nullSafeEq(Object a, Object b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return a == b;
  }

  private Predicate andTreeOf(List<Predicate> filters) {
    if (filters == null || filters.isEmpty()) {
      return null;
    }
    if (filters.size() == 1) {
      return filters[0];
    }
    return CompositePredicate.andOf(filters);
  }

  private Boolean childDescriptorsEqual(
    ChildSubqueryDescriptor x,
    ChildSubqueryDescriptor y
  ) {
    if (x == null || y == null) {
      return x == y;
    }
    if (x.childRelationshipName != y.childRelationshipName) {
      return false;
    }
    // field set equality (order-insensitive)
    Set<SObjectField> xf = x.childFields == null
      ? new Set<SObjectField>()
      : new Set<SObjectField>(x.childFields);
    Set<SObjectField> yf = y.childFields == null
      ? new Set<SObjectField>()
      : new Set<SObjectField>(y.childFields);
    if (!xf.equals(yf)) {
      return false;
    }
    if (!nullSafeEq(x.childLimit, y.childLimit)) {
      // compare Integer values
      if (x.childLimit == null || y.childLimit == null) {
        return false;
      }
      if (x.childLimit != y.childLimit) {
        return false;
      }
    }
    // filter equality via equalsPredicate (null-safe)
    if (x.childFilter == null && y.childFilter == null) {
      return true;
    }
    if (x.childFilter == null || y.childFilter == null) {
      return false;
    }
    return x.childFilter.equalsPredicate(y.childFilter);
  }

  // Tier-3 defensive walk (tier-3 sensitive field defensive walk). FieldFilter factory already rejects
  // these, so in normal flow this returns false. Kept as defense-in-depth
  // so that any future bypass or refactor does not silently merge a
  // sensitive leaf into an OR.
  private Boolean hasTier3Field(List<Predicate> filters) {
    if (filters == null || filters.isEmpty()) {
      return false;
    }
    for (Predicate p : filters) {
      if (walkHasTier3(p)) {
        return true;
      }
    }
    return false;
  }

  private Boolean walkHasTier3(Predicate p) {
    if (p == null) {
      return false;
    }
    if (p instanceof FieldFilter) {
      FieldFilter ff = (FieldFilter) p;
      Schema.DisplayType t = ff.field.getDescribe().getType();
      // Defense-in-depth tier-3 set; FieldFilter factory already rejects
      // these at construction time.
      if (
        t == Schema.DisplayType.MULTIPICKLIST ||
        t == Schema.DisplayType.ENCRYPTEDSTRING ||
        t == Schema.DisplayType.LOCATION
      ) {
        return true;
      }
      return false;
    }
    if (p instanceof CompositePredicate) {
      CompositePredicate cp = (CompositePredicate) p;
      if (cp.children == null) {
        return false;
      }
      for (Predicate child : cp.children) {
        if (walkHasTier3(child)) {
          return true;
        }
      }
    }
    return false;
  }

  // tag dimension / tag-collision rule: within a (handler, mergeKey) pair, a handler
  // may not appear with both a null tag and a non-null tag. Such mixing
  // implies ambiguous provenance for matcher routing and is rejected
  // at intake time.
  private void validateNoMixedTags() {
    for (String mk : requestsByMergeKey.keySet()) {
      Map<String, Boolean> handlerHasNullTag = new Map<String, Boolean>();
      Map<String, Boolean> handlerHasNonNullTag = new Map<String, Boolean>();
      for (QueryRequest r : requestsByMergeKey.get(mk)) {
        String h = r.declaringHandler;
        if (r.tag == null) {
          handlerHasNullTag.put(h, true);
        } else {
          handlerHasNonNullTag.put(h, true);
        }
        if (
          handlerHasNullTag.get(h) == true &&
          handlerHasNonNullTag.get(h) == true
        ) {
          throw new TriggerFrameworkException(
            'QueryAggregator: handler ' +
              h +
              ' mixes null and non-null tag within mergeKey ' +
              mk +
              ' (provenance ambiguity)'
          );
        }
      }
    }
  }
}
