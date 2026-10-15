/** Manual BULK-ONLY reconciliation. Each invocation performs a bounded slice of a full sweep.
 * The CLI, not Edge Runtime, owns the plan, queue, and checkpoint.
 */
import postgres from "npm:postgres@3.4.7";
import { isAuthorizedSecretRequest } from "./auth.ts";
import { evaluate, populated, type Direction, type Pair } from "./bulk_decide.ts";
import { buildCompanyMerges, canonicalCompanyId } from "./bulk_company_identity.ts";

type Entity = "companies" | "contacts";
type Json = Record<string, unknown>;
type Row = Record<string, unknown>;
type Pg = ReturnType<typeof postgres>;
type Field = { property: string; label: string; table: string; column: string; pushOnly?: boolean; datetime?: boolean };
type Local = { id: string; data: Row; stamp: string; baseline: string; companyId: string };
type Snapshot = {
  companies: Map<string, Local>;
  contacts: Map<string, Local>;
  companyMerges: Map<string, string>;
  children: Map<string, Map<string, Row[]>>;
  domains: Map<string, Set<string>>;
  emails: Map<string, Set<string>>;
};
type Match = { id: string; creating: boolean; reason?: string };
type Candidate = {
  hubspotId: string; localId: string; entity: Entity; creating: boolean;
  status: "work" | "conflict" | "equal" | "skipped";
  reason: string; operations: { entity: Entity; id: string; direction: Direction }[];
  pullFields: Field[]; pushFields: Field[];
  remote: Row; local: Local | undefined; companyId: string; views: Row[];
};
const HUBSPOT_API = "https://api.hubapi.com";
const MAX_BATCH = 100;
const PAGE_SIZE = 50;
const KEY: Record<Entity, string> = { companies: "company_external_id", contacts: "contact_external_id" };
const CHILD_PARENT: Record<string, string> = {
  company_domains: "company_external_id", company_websites: "company_external_id",
  company_phone_numbers: "company_external_id", company_locations: "company_external_id",
  contact_channels: "contact_external_id",
};
const FIELDS: Record<Entity, Field[]> = {
  companies: [
    { property: "name", label: "Company name", table: "companies", column: "company_name" },
    { property: "domain", label: "Company Domain Name", table: "company_domains", column: "domain" },
    { property: "phone", label: "Phone Number", table: "company_phone_numbers", column: "phone" },
    { property: "address", label: "Street Address", table: "company_locations", column: "street_address_1" },
    { property: "address2", label: "Street Address 2", table: "company_locations", column: "street_address_2" },
    { property: "city", label: "City", table: "company_locations", column: "city" },
    { property: "state", label: "State/Region", table: "company_locations", column: "state_province" },
    { property: "zip", label: "Postal Code", table: "company_locations", column: "postal_code" },
    { property: "country", label: "Country/Region", table: "company_locations", column: "country" },
    { property: "website", label: "Website URL", table: "company_websites", column: "website_url" },
    { property: "numberofemployees", label: "Number of Employees", table: "companies", column: "employee_count_best" },
    { property: "linkedin_company_page", label: "LinkedIn Company Page", table: "", column: "", pushOnly: true },
    { property: "facebook_company_page", label: "Facebook Company Page", table: "", column: "", pushOnly: true },
    { property: "instagram_url", label: "Instagram URL", table: "", column: "", pushOnly: true },
    { property: "tiktok_url", label: "TikTok URL", table: "", column: "", pushOnly: true },
    { property: "prospect_score_supabase", label: "Prospect Score", table: "", column: "", pushOnly: true },
    { property: "marketing_maturity_supabase", label: "Marketing Maturity", table: "", column: "", pushOnly: true },
    { property: "icp_vertical", label: "ICP Vertical", table: "", column: "", pushOnly: true },
    { property: "revenue_tier", label: "Revenue Tier", table: "", column: "", pushOnly: true },
    { property: "last_prospect_scan", label: "Last Prospect Scan", table: "", column: "", pushOnly: true, datetime: true },
  ],
  contacts: [
    { property: "firstname", label: "First Name", table: "contacts", column: "first_name" },
    { property: "lastname", label: "Last Name", table: "contacts", column: "last_name" },
    { property: "jobtitle", label: "Job Title", table: "contacts", column: "job_title" },
    { property: "seniority", label: "Seniority", table: "contacts", column: "seniority" },
    { property: "email", label: "Email", table: "contact_channels", column: "email" },
    { property: "phone", label: "Phone Number", table: "contact_channels", column: "phone" },
    { property: "hs_linkedin_url", label: "LinkedIn URL", table: "contact_channels", column: "linkedin_url" },
    { property: "role_category_supabase", label: "Role Category", table: "contacts", column: "role_category" },
    { property: "contact_provenance_supabase", label: "Contact Provenance", table: "", column: "", pushOnly: true },
    { property: "email_provenance_supabase", label: "Email Provenance", table: "", column: "", pushOnly: true },
  ],
};
// Existing portal dropdown allowlists (same values as legacy sync.ts).
const ENUMS: Record<string, Set<string>> = {
  marketing_maturity_supabase: new Set(["Upper_T2", "T2", "Unknown", "T3", "Lower_T4", "T1"]),
  revenue_tier: new Set(["T4", "T2", "T3", "T1", "T0", "Mega", "Unknown"]),
  role_category_supabase: new Set(["clinical_provider", "office_admin", "executive", "owner_founder", "other"]),
  contact_provenance_supabase: new Set([
    "published", "single_source", "verified_first_party", "observed_generic_channel",
    "published_secondary", "observed_public_directory", "observed_generic", "generic_channel",
  ]),
  email_provenance_supabase: new Set([
    "published", "unavailable", "published_first_party", "observed", "not_observed",
    "verified_first_party", "published_first_party_document", "verified_first_party_with_prior_observation",
  ]),
  icp_vertical: new Set([
    "Plumbing contractors", "Electrical contractors", "Landscaping companies",
    "Commercial cleaning companies", "Massage therapy clinics", "Personal training studios",
    "Acupuncture clinics", "Chiropractic clinics", "Roofing contractors",
    "Event staging companies", "Tent rental companies", "Event lighting companies",
    "Event production companies", "Party rental companies", "Event entertainment companies",
    "AV production companies", "Wedding planners", "Counselling clinics",
    "Yoga studios", "Pilates studios", "Medical spas", "Aesthetic clinics",
    "hvac_contractor", "Physiotherapy clinics", "Wedding venues",
    "Banquet halls", "Event venues", "Event rental companies", "Event DJ companies",
    "Psychology clinics", "Naturopathic clinics", "Corporate event planners",
  ]),
};
const s = populated;
function fail(message: string): never { throw new Error("invalid_request: " + message); }
function errorMessage(error: unknown): string {
  const m = error instanceof Error ? error.message : "unexpected_failure";
  return m.slice(0, 180); // No upstream bodies, tokens, or SQL parameters.
}
function safeResponse(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}
function normalizeDomain(value: unknown): string {
  const v = s(value);
  if (!v) return "";
  try { return new URL(v.includes("://") ? v : "https://" + v).hostname.toLowerCase().replace(/^www\./, "").replace(/\.$/, ""); }
  catch { return ""; }
}
function index(index: Map<string, Set<string>>, key: string, id: string): void {
  if (!key) return;
  const ids = index.get(key) ?? new Set<string>();
  ids.add(id);
  index.set(key, ids);
}
function uniqueMatch(index: Map<string, Set<string>>, keys: string[]): { id: string; reason?: string } {
  const ids = new Set<string>();
  for (const key of keys) for (const id of index.get(key) ?? []) ids.add(id);
  if (ids.size > 1) return { id: "", reason: "ambiguous_domain_or_email_match" };
  return { id: [...ids][0] ?? "" };
}
export function rowStamp(value: unknown): string {
  // postgres.js returns timestamptz as a Date; String(Date) discards milliseconds.
  // The locking query uses ::text and retains fractions. Compare both at the
  // same millisecond precision to avoid false "changed during execution" errors.
  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.toISOString() : "";
  }
  const valueText = s(value);
  if (!valueText) return "";
  const t = Date.parse(valueText);
  return Number.isFinite(t) ? new Date(t).toISOString() : "";
}

async function hubspot(token: string, path: string, method = "GET", body?: Row): Promise<Row> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const response = await fetch(HUBSPOT_API + path, {
      method, headers: { Authorization: "Bearer " + token, Accept: "application/json", "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15000), redirect: "error",
    });
    if ((response.status === 429 || response.status >= 500) && attempt < 2) {
      const delay = Number(response.headers.get("Retry-After"));
      await new Promise((resolve) => setTimeout(resolve, Number.isFinite(delay) && delay > 0 ? Math.min(delay * 1000, 2000) : 400 * (2 ** attempt)));
      continue;
    }
    if (!response.ok) throw new Error("HubSpot HTTP " + response.status);
    if (response.status === 204) return {};
    return await response.json() as Row;
  }
  throw new Error("HubSpot temporary failure");
}
async function vaultToken(db: Pg): Promise<string> {
  const rows = await db.unsafe("select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1", ["HUBSPOT_ACCESS_TOKEN"]);
  const token = s(rows[0]?.decrypted_secret);
  if (!token) throw new Error("HubSpot Vault token missing");
  return token;
}

export async function loadSnapshot(db: Pg, entity: Entity): Promise<Snapshot> {
  const snap: Snapshot = { companies: new Map(), contacts: new Map(), companyMerges: new Map(), children: new Map(), domains: new Map(), emails: new Map() };
  const types: Entity[] = entity === "contacts" ? ["companies", "contacts"] : ["companies"];
  for (const typ of types) {
    const cols = typ === "companies"
      ? "company_external_id, company_name, employee_count_best, hubspot_export_updated_at, hubspot_last_synced_at"
      : "contact_external_id, company_external_id, first_name, last_name, job_title, seniority, role_category, hubspot_export_updated_at, hubspot_last_synced_at";
    const rows = await db.unsafe("select " + cols + " from brightside." + typ);
    for (const row of rows) {
      const id = s(row[KEY[typ]]);
      (snap[typ] as Map<string, Local>).set(id, {
        id, data: row as Row, stamp: rowStamp(row.hubspot_export_updated_at),
        baseline: rowStamp(row.hubspot_last_synced_at), companyId: s(row.company_external_id),
      });
    }
  }
  const mergedRows = await db.unsafe(
    "select from_company_external_id, to_company_external_id from brightside.company_relationships where relationship_type = $1",
    ["merged_into"],
  );
  snap.companyMerges = buildCompanyMerges(mergedRows.map((row) => ({
    from_company_external_id: row.from_company_external_id,
    to_company_external_id: row.to_company_external_id,
  })), new Set(snap.companies.keys()));
  const tables = entity === "companies"
    ? ["company_domains", "company_websites", "company_phone_numbers", "company_locations"]
    : ["company_domains", "company_websites", "contact_channels"];
  for (const table of tables) {
    const rows = await db.unsafe("select * from brightside." + table);
    const byId = new Map<string, Row[]>();
    for (const row of rows) {
      const id = s(row[CHILD_PARENT[table]]);
      const list = byId.get(id) ?? [];
      list.push(row as Row);
      byId.set(id, list);
      if (table === "company_domains") index(snap.domains, normalizeDomain(row.domain), canonicalCompanyId(id, snap.companyMerges));
      if (table === "company_websites") index(snap.domains, normalizeDomain(row.website_url), canonicalCompanyId(id, snap.companyMerges));
      if (table === "contact_channels") index(snap.emails, s(row.email).toLowerCase(), id);
    }
    snap.children.set(table, byId);
  }
  return snap;
}
export function matchLocal(entity: Entity, remote: Row, snap: Snapshot): Match {
  const props = (remote.properties ?? {}) as Row;
  const rawLink = s(props[entity === "companies" ? "supabase_company_id" : "supabase_contact_id"]);
  const link = entity === "companies" ? canonicalCompanyId(rawLink, snap.companyMerges) : rawLink;
  const domain = entity === "companies" ? [normalizeDomain(props.domain), normalizeDomain(props.website)] : [];
  const natural = entity === "companies" ? uniqueMatch(snap.domains, domain)
    : uniqueMatch(snap.emails, [s(props.email).toLowerCase()]);
  if (natural.reason) return { id: "", creating: false, reason: natural.reason };
  if (link && natural.id && link !== natural.id) {
    return { id: "", creating: false, reason: "external_id_conflicts_with_natural_match" };
  }
  const id = link || natural.id || ("hubspot-" + (entity === "companies" ? "company" : "contact") + "-" + s(remote.id));
  return { id, creating: !snap[entity].has(id) };
}
async function remoteById(token: string, entity: Entity, id: string): Promise<Row> {
  const names = FIELDS[entity].map((f) => f.property);
  names.push(entity === "companies" ? "supabase_company_id" : "supabase_contact_id");
  if (entity === "contacts") names.push("supabase_company_id");
  const params = new URLSearchParams({ properties: [...new Set(names)].join(",") });
  if (entity === "contacts") params.set("associations", "companies");
  return await hubspot(token, "/crm/v3/objects/" + entity + "/" + encodeURIComponent(id) + "?" + params);
}
async function remoteByLocalId(token: string, entity: Entity, id: string): Promise<Row | null> {
  const property = entity === "companies" ? "supabase_company_id" : "supabase_contact_id";
  const matches = await hubspot(token, "/crm/v3/objects/" + entity + "/search", "POST", {
    filterGroups: [{ filters: [{ propertyName: property, operator: "EQ", value: id }] }],
    properties: [property], limit: 2,
  });
  const found = Array.isArray(matches.results) ? matches.results as Row[] : [];
  if (found.length > 1) throw new Error("duplicate_hubspot_external_id");
  return found.length ? await remoteById(token, entity, s(found[0].id)) : null;
}
function companyAssociationIds(contact: Row): string[] {
  const associations = contact.associations as Row | undefined;
  const companies = associations?.companies as Row | undefined;
  const results = Array.isArray(companies?.results) ? companies.results as Row[] : [];
  return results.map((r) => s(r.id || r.toObjectId)).filter((id) => /^\d+$/.test(id));
}
async function loadAssociatedCompanies(token: string, contacts: Row[]): Promise<Map<string, Row>> {
  const ids = [...new Set(contacts.flatMap(companyAssociationIds))];
  const companies = new Map<string, Row>();
  for (let i = 0; i < ids.length; i += 100) {
    const response = await hubspot(token, "/crm/v3/objects/companies/batch/read", "POST", {
      inputs: ids.slice(i, i + 100).map((id) => ({ id })),
      properties: ["supabase_company_id", "domain", "website"],
    });
    for (const row of (Array.isArray(response.results) ? response.results as Row[] : [])) companies.set(s(row.id), row);
  }
  return companies;
}
async function contactCompanies(token: string, remote: Row): Promise<Map<string, Row>> {
  if (!companyAssociationIds(remote).length) {
    const res = await hubspot(token, "/crm/v4/objects/contacts/" + encodeURIComponent(s(remote.id)) + "/associations/companies?limit=100");
    if (res.paging) return new Map(); // avoid incomplete association evaluation
    remote.associations = { companies: { results: (Array.isArray(res.results) ? res.results as Row[] : []).map((r) => ({ id: r.toObjectId })) } };
  }
  return await loadAssociatedCompanies(token, [remote]);
}
function parentCompany(contact: Row, snap: Snapshot, associated: Map<string, Row>): { id: string; reason?: string } {
  const ids = companyAssociationIds(contact);
  if (!ids.length) return { id: "", reason: "missing_company_association" };
  const matched = new Set<string>();
  for (const id of ids) {
    const company = associated.get(id);
    if (!company) continue;
    const m = matchLocal("companies", company, snap);
    if (!m.reason && m.id) matched.add(m.id);
  }
  if (matched.size !== 1) return { id: "", reason: "ambiguous_or_unmatched_company_association" };
  return { id: [...matched][0] };
}
// For a single ID, equality lets PostgreSQL push the filter through the export
// view's scoring join. ANY(text[]) caused a full score aggregation (~16s/record).
// Retain the multi-ID query used by the planner.
export function exportViewLookup(entity: Entity, localIds: string[]) {
  const view = entity === "companies" ? "hubspot_companies_export" : "hubspot_contacts_export";
  const key = entity === "companies" ? "Supabase Company ID" : "Supabase Contact ID";
  const single = localIds.length === 1;
  return {
    key,
    sql: 'select * from brightside.' + view + ' where "' + key + (single ? '" = $1' : '" = any($1::text[])'),
    params: single ? [localIds[0]] : [localIds],
  };
}
async function viewRows(db: Pg, entity: Entity, localIds: string[]): Promise<Map<string, Row[]>> {
  const map = new Map<string, Row[]>();
  if (!localIds.length) return map;
  const { key, sql, params } = exportViewLookup(entity, localIds);
  const rows = await db.unsafe(sql, params);
  for (const row of rows) {
    const id = s(row[key]);
    const list = map.get(id) ?? [];
    list.push(row as Row);
    map.set(id, list);
  }
  return map;
}
function viewCell(rows: Row[], label: string): { value: string; ambiguous: boolean } {
  const values = [...new Set(rows.map((r) => s(r[label])).filter(Boolean))];
  return { value: values[0] ?? "", ambiguous: values.length > 1 };
}
function fieldValue(raw: unknown, field: Field): string {
  const value = s(raw);
  if (!field.datetime || !value) return value;
  const dt = Date.parse(value);
  return Number.isFinite(dt) ? new Date(dt).toISOString() : "";
}
export function makeCandidate(
  entity: Entity, remote: Row, snap: Snapshot, views: Map<string, Row[]>,
  associated: Map<string, Row>, force: Direction | null = null,
): Candidate {
  const hubspotId = s(remote.id);
  const matched = matchLocal(entity, remote, snap);
  const localId = matched.id;
  const local = snap[entity].get(localId);
  const candidate: Candidate = {
    hubspotId, localId, entity, creating: matched.creating,
    status: "skipped", reason: matched.reason ?? "", operations: [],
    pullFields: [], pushFields: [], remote, local, companyId: "", views: views.get(localId) ?? [],
  };
  if (matched.reason) return candidate;
  if (entity === "contacts") {
    const company = parentCompany(remote, snap, associated);
    if (company.reason) { candidate.reason = company.reason; return candidate; }
    candidate.companyId = company.id;
    if (local && canonicalCompanyId(local.companyId, snap.companyMerges) !== company.id) {
      candidate.reason = "mismatched_company_association"; return candidate;
    }
  }
  if (local && !candidate.views.length) { candidate.reason = "missing_supabase_export_view"; return candidate; }
  const props = (remote.properties ?? {}) as Row;
  const pairs: Pair[] = [];
  let ambiguous = false;
  for (const field of FIELDS[entity]) {
    const cell = local ? viewCell(candidate.views, field.label) : { value: "", ambiguous: false };
    if (cell.ambiguous) ambiguous = true;
    const localValue = fieldValue(cell.value, field);
    const remoteValue = fieldValue(props[field.property], field);
    const invalid = Boolean(localValue && ENUMS[field.property] && !ENUMS[field.property].has(localValue));
    pairs.push({ property: field.property, local: localValue, remote: remoteValue, pushOnly: field.pushOnly, invalid });
  }
  if (ambiguous) { candidate.reason = "ambiguous_supabase_export_values"; return candidate; }
  const decision = evaluate(pairs, local?.stamp ?? "", s(remote.updatedAt), local?.baseline ?? "", force);
  if (decision.status === "conflict") {
    candidate.status = "conflict"; candidate.reason = decision.reason; return candidate;
  }
  const pull = new Set(decision.pull.map((p) => p.property));
  const push = new Set(decision.push.map((p) => p.property));
  candidate.pullFields = FIELDS[entity].filter((f) => pull.has(f.property));
  candidate.pushFields = FIELDS[entity].filter((f) => push.has(f.property));
  if (matched.creating) {
    if (!candidate.pullFields.length) { candidate.reason = "new_record_has_no_mapped_values"; return candidate; }
    candidate.operations.push({ entity, id: hubspotId, direction: "pull" });
  } else {
    if (candidate.pullFields.length || !local?.baseline) {
      candidate.operations.push({ entity, id: hubspotId, direction: "pull" });
    }
    if (candidate.pushFields.length) {
      const link = s(props[entity === "companies" ? "supabase_company_id" : "supabase_contact_id"]);
      if (link === localId) candidate.operations.push({ entity, id: localId, direction: "push" });
      else if (!candidate.operations.length) { candidate.reason = "outbound_requires_external_id_link"; return candidate; }
    }
  }
  candidate.status = candidate.operations.length ? "work" : "equal";
  candidate.reason = candidate.status === "equal" ? "already_equal" : decision.reason;
  return candidate;
}
function publicCandidate(c: Candidate): Row {
  const props = (c.remote.properties ?? {}) as Row;
  const matchKey = c.creating ? (c.entity === "companies"
    ? (normalizeDomain(props.domain) || normalizeDomain(props.website))
    : s(props.email).toLowerCase()) : "";
  return {
    entity: c.entity, hubspotId: c.hubspotId, supabaseId: c.localId, matchKey,
    status: c.status, reason: c.reason, operations: c.operations,
    localUpdatedAt: c.local?.stamp ?? null, hubspotUpdatedAt: s(c.remote.updatedAt),
    lastSyncedAt: c.local?.baseline ?? null,
  };
}
export function supabaseInventorySql(entity: Entity): string {
  const key = KEY[entity];
  const mergedExclusion = entity === "companies"
    ? " and not exists (select 1 from brightside.company_relationships rel" +
      " where rel.relationship_type = 'merged_into' and rel.from_company_external_id = brightside.companies.company_external_id)"
    : "";
  return "select " + key + " as id from brightside." + entity + " where " + key + " > $1" +
    mergedExclusion + " order by " + key + " limit $2";
}
async function planPage(db: Pg, token: string, input: Row): Promise<Row> {
  const entity = input.objectType;
  if (entity !== "companies" && entity !== "contacts") fail("objectType must be companies or contacts");
  const source = input.source ?? "hubspot";
  if (source !== "hubspot" && source !== "supabase") fail("source must be hubspot or supabase");
  const rawLimit = input.limit ?? (source === "hubspot" ? PAGE_SIZE : 500);
  if (typeof rawLimit !== "number" || !Number.isInteger(rawLimit) || rawLimit < 1 || rawLimit > (source === "hubspot" ? PAGE_SIZE : 500)) fail("invalid page limit");
  const limit = rawLimit;
  const cursor = s(input.cursor);
  if (source === "supabase") {
    const key = KEY[entity];
    const rows = await db.unsafe(supabaseInventorySql(entity), [cursor, limit]);
    const ids = rows.map((r) => s(r.id));
    return { source, objectType: entity, ids, nextCursor: ids.length === limit ? ids[ids.length - 1] : null };
  }
  const names = [...new Set([...FIELDS[entity].map((f) => f.property), entity === "companies" ? "supabase_company_id" : "supabase_contact_id", ...(entity === "contacts" ? ["supabase_company_id"] : [])])];
  const params = new URLSearchParams({ properties: names.join(","), limit: String(limit) });
  if (entity === "contacts") params.set("associations", "companies");
  if (cursor) params.set("after", cursor);
  const page = await hubspot(token, "/crm/v3/objects/" + entity + "?" + params);
  const remotes = Array.isArray(page.results) ? page.results as Row[] : [];
  const snap = await loadSnapshot(db, entity);
  const associated = entity === "contacts" ? await loadAssociatedCompanies(token, remotes) : new Map<string, Row>();
  const prelim = remotes.map((remote) => ({ remote, matched: matchLocal(entity, remote, snap) }));
  const ids = [...new Set(prelim.map((p) => p.matched.id).filter((id) => snap[entity].has(id)))];
  const views = await viewRows(db, entity, ids);
  const candidates = remotes.map((remote) => makeCandidate(entity, remote, snap, views, associated));
  const next = ((page.paging as Row | undefined)?.next as Row | undefined)?.after;
  return { source, objectType: entity, records: candidates.map(publicCandidate), nextCursor: next ? s(next) : null, scanned: remotes.length };
}

async function lockAndApplyPull(db: Pg, candidate: Candidate): Promise<number> {
  const parent = candidate.entity;
  const key = KEY[parent];
  const localId = candidate.localId;
  const fields = candidate.pullFields;
  return await db.begin(async (tx: any) => {
    const old = await tx.unsafe("select hubspot_export_updated_at::text as stamp, hubspot_last_synced_at::text as baseline from brightside." + parent + " where " + key + " = $1 for update", [localId]);
    if (candidate.creating) {
      if (old.length) throw new Error("stale_existing_record_retry");
      const cols = [key, ...(parent === "contacts" ? ["company_external_id"] : [])];
      const args = [localId, ...(parent === "contacts" ? [candidate.companyId] : [])];
      await tx.unsafe("insert into brightside." + parent + " (" + cols.join(",") + ") values (" + args.map((_, i) => "$" + (i + 1)).join(",") + ")", args);
    } else if (old.length !== 1 || rowStamp(old[0].stamp) !== candidate.local?.stamp || rowStamp(old[0].baseline) !== candidate.local?.baseline) {
      throw new Error("supabase_changed_during_execution");
    }
    for (const field of fields) {
      // The Field definitions above are fixed, not caller-supplied SQL identifiers.
      const value = fieldValue(((candidate.remote.properties ?? {}) as Row)[field.property], field);
      if (!value) continue;
      if (field.table === parent) {
        const updated = await tx.unsafe("update brightside." + parent + " set " + field.column + " = $1 where " + key + " = $2 returning " + key, [value, localId]);
        if (updated.length !== 1) throw new Error("missing_parent_during_update");
      } else {
        const childRows = await tx.unsafe("select id from brightside." + field.table + " where " + CHILD_PARENT[field.table] + " = $1 for update", [localId]);
        if (childRows.length > 1) throw new Error("ambiguous_child_rows_during_apply");
        if (childRows.length === 1) {
          await tx.unsafe("update brightside." + field.table + " set " + field.column + " = $1 where id = $2", [value, childRows[0].id]);
        } else {
          await tx.unsafe("insert into brightside." + field.table + " (id," + CHILD_PARENT[field.table] + "," + field.column + ") values ($1,$2,$3)", [crypto.randomUUID(), localId, value]);
        }
      }
    }
    // New timestamp is after all parent/child triggers; the modified-data stamp
    // does not advance just because this baseline column changes.
    await tx.unsafe("update brightside." + parent + " set hubspot_last_synced_at = clock_timestamp() where " + key + " = $1", [localId]);
    return fields.length;
  });
}
async function applyPush(db: Pg, token: string, candidate: Candidate): Promise<number> {
  if (!candidate.local) throw new Error("outbound_creation_not_allowed");
  const key = KEY[candidate.entity];
  const properties: Record<string, string> = {};
  for (const field of candidate.pushFields) {
    const cell = viewCell(candidate.views, field.label);
    const v = fieldValue(cell.value, field);
    if (v && !cell.ambiguous) properties[field.property] = v;
  }
  if (Object.keys(properties).length) {
    await hubspot(token, "/crm/v3/objects/" + candidate.entity + "/" + encodeURIComponent(candidate.hubspotId), "PATCH", { properties });
    // Treat a lost response as uncertain; verify before recording the baseline.
    const refreshed = await remoteById(token, candidate.entity, candidate.hubspotId);
    for (const [property, value] of Object.entries(properties)) {
      const got = fieldValue(((refreshed.properties ?? {}) as Row)[property], FIELDS[candidate.entity].find((f) => f.property === property)!);
      if (got !== value) throw new Error("hubspot_patch_not_verified");
    }
  }
  const rows = await db.unsafe(
    "update brightside." + candidate.entity + " set hubspot_last_synced_at = clock_timestamp() where " + key + " = $1" +
    " and hubspot_export_updated_at is not distinct from $2::timestamptz and hubspot_last_synced_at is not distinct from $3::timestamptz returning " + key,
    [candidate.localId, candidate.local.stamp || null, candidate.local.baseline || null],
  );
  if (rows.length !== 1) throw new Error("supabase_changed_during_outbound_patch");
  return Object.keys(properties).length;
}
async function executeBatch(db: Pg, token: string, input: Row): Promise<Row> {
  const entity = input.objectType;
  const direction = input.direction;
  if (entity !== "companies" && entity !== "contacts") fail("invalid objectType");
  if (direction !== "pull" && direction !== "push") fail("invalid direction");
  const ids = input.ids;
  if (!Array.isArray(ids) || !ids.length || ids.length > MAX_BATCH || !ids.every((v) => typeof v === "string" && !!v && v.length <= 200) || new Set(ids).size !== ids.length) fail("ids must be 1-100 unique strings");
  if (direction === "pull" && !ids.every((v) => /^\d+$/.test(v))) fail("pull IDs must be numeric HubSpot IDs");
  const force = input.force === true;
  if (input.force !== undefined && typeof input.force !== "boolean") fail("invalid force flag");
  if (input.confirm !== (force ? "FORCE_" + direction.toUpperCase() : "APPLY")) fail("missing explicit execution confirmation");
  const snapshot = await loadSnapshot(db, entity);
  const outcomes: Row[] = [];
  for (const id of ids) {
    try {
      const remote = direction === "pull" ? await remoteById(token, entity, id) : await remoteByLocalId(token, entity, id);
      if (!remote) { outcomes.push({ id, status: "skipped", reason: "unmatched_hubspot_record" }); continue; }
      const match = matchLocal(entity, remote, snapshot);
      if (match.reason || (direction === "push" && match.id !== id)) {
        outcomes.push({ id, status: "skipped", reason: match.reason ?? "mismatched_external_id_link" }); continue;
      }
      const associated = entity === "contacts" ? await contactCompanies(token, remote) : new Map<string, Row>();
      const views = await viewRows(db, entity, snapshot[entity].has(match.id) ? [match.id] : []);
      const cand = makeCandidate(entity, remote, snapshot, views, associated, force ? direction : null);
      if (cand.status === "conflict" || cand.status === "skipped") {
        outcomes.push({ id, status: cand.status, reason: cand.reason, hubspotId: cand.hubspotId, supabaseId: cand.localId }); continue;
      }
      if (direction === "push" && (!cand.local || s(((remote.properties ?? {}) as Row)[entity === "companies" ? "supabase_company_id" : "supabase_contact_id"]) !== id)) {
        outcomes.push({ id, status: "skipped", reason: "outbound_requires_exact_external_id_link" }); continue;
      }
      const applicable = direction === "pull" ? cand.pullFields : cand.pushFields;
      // An empty applicable set can still establish a missing bootstrap baseline,
      // but must not stamp an existing baseline for an operation now in the wrong direction.
      if (!applicable.length && cand.local?.baseline) {
        outcomes.push({ id, status: "already_synchronized", fieldsUpdated: 0 }); continue;
      }
      const count = direction === "pull" ? await lockAndApplyPull(db, cand) : await applyPush(db, token, cand);
      outcomes.push({ id, status: cand.creating ? "created" : (count ? "applied" : "already_synchronized"), fieldsUpdated: count });
    } catch (e) {
      outcomes.push({ id, status: "failed", reason: errorMessage(e) });
    }
  }
  return { action: "execute", direction, objectType: entity, results: outcomes,
    summary: { total: outcomes.length, created: outcomes.filter((r) => r.status === "created").length,
      applied: outcomes.filter((r) => r.status === "applied").length,
      conflicted: outcomes.filter((r) => r.status === "conflict").length,
      skipped: outcomes.filter((r) => r.status === "skipped").length,
      failed: outcomes.filter((r) => r.status === "failed").length } };
}

export function serveBulk(mode: "plan" | "execute"): void {
  Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return safeResponse({ error: "POST only" }, 405);
    if (!await isAuthorizedSecretRequest(req, {
      SUPABASE_SECRET_KEYS: Deno.env.get("SUPABASE_SECRET_KEYS"),
      SUPABASE_SECRET_KEY: Deno.env.get("SUPABASE_SECRET_KEY"),
    })) return safeResponse({ error: "Unauthorized" }, 401);
    let db: Pg | undefined;
    try {
      const raw = await req.text();
      if (raw.length > 35000) fail("request too large");
      const input = JSON.parse(raw) as Row;
      if (!input || typeof input !== "object" || Array.isArray(input)) fail("expected JSON object");
      const conn = Deno.env.get("SUPABASE_DB_URL");
      if (!conn) throw new Error("SUPABASE_DB_URL not configured");
      db = postgres(conn, { max: 1, prepare: false, connect_timeout: 5, idle_timeout: 5 });
      const token = await vaultToken(db);
      if (mode === "plan") return safeResponse(await planPage(db, token, input));
      const result = await executeBatch(db, token, input);
      const failed = ((result.results as Row[]) ?? []).some((x) => x.status === "failed");
      return safeResponse(result, failed ? 207 : 200);
    } catch (e) {
      const m = errorMessage(e);
      return safeResponse({ error: m }, m.startsWith("invalid_request:") || e instanceof SyntaxError ? 400 : 500);
    } finally { if (db) await db.end({ timeout: 2 }).catch(() => {}); }
  });
}
