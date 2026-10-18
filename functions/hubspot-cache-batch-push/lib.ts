/**
 * Pure candidate and preflight logic for the proposed cache -> HubSpot manual
 * batch updater. Neither this module nor its tests make HTTP/DB calls.
 */
export type Entity = "companies" | "contacts";
export type Json = Record<string, unknown>;

export type CacheRow = {
  sync_key: string;
  hubspot_id: string;
  supabase_external_id: string;
  last_changed_at: string;
  hubspot_source_updated_at: string | null;
  unified_fields: Json | null;
  hubspot_fields: Json | null;
  hubspot_records: unknown;
};

export type Candidate = {
  syncKey: string;
  hubspotId: string;
  localId: string;
  cacheVersion: string;
  remoteVersion: string;
  properties: Record<string, string>;
  cachedRemote: Record<string, string>;
  problems: string[];
};

const COMPANIES = [
  "name", "domain", "phone", "address", "address2", "city", "state",
  "zip", "country", "website", "numberofemployees", "founded_year",
  "linkedin_company_page", "facebook_company_page", "instagram_url",
  "tiktok_url", "x___twitter_url", "pinterest_url",
  "prospect_score_supabase", "marketing_maturity_supabase",
  "icp_vertical", "revenue_tier", "last_prospect_scan",
] as const;

const CONTACTS = [
  "firstname", "lastname", "email", "phone", "jobtitle",
  "seniority", "hs_linkedin_url", "role_category_supabase",
  "contact_provenance_supabase", "email_provenance_supabase",
  "supabase_company_id",
] as const;

// Snapshot of the portal's live enum definitions checked on 2026-10-18.
// Unknown options are rejected; refresh these from HubSpot before first apply.
const ENUM_OPTIONS: Record<string, ReadonlySet<string>> = {
  marketing_maturity_supabase: new Set(["Upper_T2", "T2", "Unknown", "T3", "Lower_T4", "T1"]),
  revenue_tier: new Set(["T4", "T2", "T3", "T1", "T0", "Mega", "Unknown"]),
  icp_vertical: new Set([
    "Plumbing contractors", "Electrical contractors", "Landscaping companies",
    "Commercial cleaning companies", "Massage therapy clinics",
    "Personal training studios", "Acupuncture clinics",
    "Chiropractic clinics", "Roofing contractors", "Event staging companies",
    "Tent rental companies", "Event lighting companies",
    "Event production companies", "Party rental companies",
    "Event entertainment companies", "AV production companies",
    "Wedding planners", "Counselling clinics", "Yoga studios",
    "Pilates studios", "Medical spas", "Aesthetic clinics",
    "hvac_contractor", "Physiotherapy clinics", "Wedding venues",
    "Banquet halls", "Event venues", "Event rental companies",
    "Event DJ companies", "Psychology clinics", "Naturopathic clinics",
    "Corporate event planners",
  ]),
  role_category_supabase: new Set([
    "clinical_provider", "office_admin", "executive", "owner_founder", "other",
  ]),
  contact_provenance_supabase: new Set([
    "published", "single_source", "verified_first_party",
    "observed_generic_channel", "published_secondary",
    "observed_public_directory", "observed_generic", "generic_channel",
  ]),
  email_provenance_supabase: new Set([
    "published", "unavailable", "published_first_party", "observed",
    "not_observed", "verified_first_party",
    "published_first_party_document",
    "verified_first_party_with_prior_observation",
  ]),
};

function clean(v: unknown): string {
  return v === null || v === undefined ? "" : String(v).trim();
}

export function writableProperties(entity: Entity): readonly string[] {
  return entity === "companies" ? COMPANIES : CONTACTS;
}

export function mappingProperty(entity: Entity): string {
  return entity === "companies" ? "supabase_company_id" : "supabase_contact_id";
}

function normalized(key: string, value: string): string {
  if (!value) return "";
  if (key === "last_prospect_scan") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? new Date(parsed).toISOString() : value;
  }
  return value;
}

export function propertyProblems(properties: Record<string, string>): string[] {
  const problems: string[] = [];
  for (const [key, value] of Object.entries(properties)) {
    if (ENUM_OPTIONS[key] && !ENUM_OPTIONS[key].has(value)) {
      problems.push(key + ":unsupported_enum");
    }
    if (["prospect_score_supabase", "numberofemployees"].includes(key) &&
      !/^\d+(\.\d+)?$/.test(value)) {
      problems.push(key + ":invalid_number");
    }
    if (key === "last_prospect_scan" && !Number.isFinite(Date.parse(value))) {
      problems.push(key + ":invalid_datetime");
    }
  }
  return problems.sort();
}

/**
 * Only fill cached empty HubSpot fields from non-empty reconciled values.
 * A row with conflicting fields never reaches this function from the SQL query;
 * callers must additionally verify identity_status=matched and status=no_conflict.
 * HubSpot external-ID backfill is allowed only when the cached remote link is blank.
 */
export function candidateFromCache(entity: Entity, row: CacheRow): Candidate | null {
  if (!/^\d+$/.test(row.hubspot_id) || !row.supabase_external_id ||
      !row.sync_key || !row.last_changed_at) return null;
  const local = row.unified_fields ?? {};
  const remote = row.hubspot_fields ?? {};
  const changes: Record<string, string> = {};
  const before: Record<string, string> = {};

  for (const field of writableProperties(entity)) {
    const desired = normalized(field, clean(local[field]));
    const previous = normalized(field, clean(remote[field]));
    if (desired && !previous) {
      changes[field] = desired;
      before[field] = previous;
    }
  }

  const firstRecord = Array.isArray(row.hubspot_records)
    ? (row.hubspot_records[0] as Json | undefined)
    : undefined;
  const idProperty = mappingProperty(entity);
  const oldExternalId = clean(firstRecord?.[idProperty]);
  if (!oldExternalId) {
    changes[idProperty] = row.supabase_external_id;
    before[idProperty] = "";
  }
  if (!Object.keys(changes).length) return null;

  const sortedProperties = Object.fromEntries(
    Object.entries(changes).sort(([a], [b]) => a.localeCompare(b)),
  );
  return {
    syncKey: row.sync_key,
    hubspotId: row.hubspot_id,
    localId: row.supabase_external_id,
    cacheVersion: row.last_changed_at,
    remoteVersion: row.hubspot_source_updated_at ?? "",
    properties: sortedProperties,
    cachedRemote: before,
    problems: propertyProblems(sortedProperties),
  };
}

export type RemoteDecision =
  | { kind: "already_aligned"; properties: Record<string, string> }
  | { kind: "update"; properties: Record<string, string> }
  | { kind: "skipped"; reason: string; properties: Record<string, string> };

/** Fail closed on stale/overwritten remote values, missing timestamps and invalid options. */
export function decideRemote(
  candidate: Candidate, remoteRecord: Json | null,
): RemoteDecision {
  if (candidate.problems.length) {
    return { kind: "skipped", reason: candidate.problems.join(","), properties: {} };
  }
  if (!remoteRecord || remoteRecord.archived === true ||
      clean(remoteRecord.id) !== candidate.hubspotId) {
    return { kind: "skipped", reason: "missing_or_archived_remote_record", properties: {} };
  }
  const properties = remoteRecord.properties;
  if (!properties || typeof properties !== "object" || Array.isArray(properties)) {
    return { kind: "skipped", reason: "invalid_remote_properties", properties: {} };
  }
  const current = properties as Json;
  const patch: Record<string, string> = {};
  for (const [key, desired] of Object.entries(candidate.properties)) {
    const actual = normalized(key, clean(current[key]));
    const target = normalized(key, desired);
    if (actual === target) continue; // Remote already has the intended value.
    if (actual) {
      return { kind: "skipped", reason: key + ":remote_value_changed", properties: {} };
    }
    patch[key] = desired;
  }
  if (!Object.keys(patch).length) {
    return { kind: "already_aligned", properties: {} };
  }
  const cachedTime = Date.parse(candidate.remoteVersion);
  const remoteTime = Date.parse(clean(remoteRecord.updatedAt));
  if (!Number.isFinite(cachedTime) || !Number.isFinite(remoteTime) ||
      cachedTime !== remoteTime) {
    return { kind: "skipped", reason: "hubspot_changed_since_cache_refresh", properties: {} };
  }
  return { kind: "update", properties: patch };
}
