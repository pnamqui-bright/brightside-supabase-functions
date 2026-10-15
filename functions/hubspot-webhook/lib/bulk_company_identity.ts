/** Canonical company identity for the bulk planner and executor.
 * Only confirmed merged_into relationships participate; linked branches stay distinct.
 */
export type CompanyMergeRow = {
  from_company_external_id: unknown;
  to_company_external_id: unknown;
};

export function canonicalCompanyId(id: string, merges: ReadonlyMap<string, string>): string {
  let current = id;
  const visited = new Set<string>();
  while (merges.has(current)) {
    if (visited.has(current)) throw new Error("invalid_company_merge_cycle");
    visited.add(current);
    current = merges.get(current)!;
  }
  return current;
}

export function buildCompanyMerges(
  rows: readonly CompanyMergeRow[],
  companyIds: ReadonlySet<string>,
): Map<string, string> {
  const merges = new Map<string, string>();
  for (const row of rows) {
    const from = String(row.from_company_external_id ?? "").trim();
    const to = String(row.to_company_external_id ?? "").trim();
    if (!from || !to || !companyIds.has(from) || !companyIds.has(to)) {
      throw new Error("invalid_company_merge_reference");
    }
    if (from === to) throw new Error("invalid_company_merge_self_link");
    const prior = merges.get(from);
    if (prior && prior !== to) throw new Error("conflicting_company_merge_targets");
    merges.set(from, to);
  }
  // Validate the complete graph before indexing any domains or planning writes.
  for (const from of merges.keys()) canonicalCompanyId(from, merges);
  return merges;
}
