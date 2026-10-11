import postgres from "npm:postgres@3.4.7";
import { decide, type Direction } from "./decide.ts";

// Both entry points import this file from the existing hubspot-webhook mount.
// No additional Docker bind mount is required.
export type Entity = "companies" | "contacts";
type Action = "preview" | "apply";
type Field = {
  hubspot: string;
  local: string;
  table: string;
  column: string;
  direction?: "push";
  kind?: "datetime";
};
type Json = Record<string, unknown>;
type Row = Record<string, unknown>;
type Pg = ReturnType<typeof postgres>;
type PlannedField = {
  property: string;
  table: string;
  column: string;
  targetId: string;
  before: string;
  after: string;
  action: "update" | "skip";
  reason: string;
};
type RecordPlan = {
  id: string;
  localId?: string;
  hubspotId?: string;
  status: "ready" | "skipped" | "error";
  reason?: string;
  localStamp?: string;
  changes: PlannedField[];
};
type RequestPayload = {
  action: Action;
  objectType: Entity;
  ids?: string[];
  cursor?: string;
  limit?: number;
  previewHash?: string;
  confirm?: string;
};

const HUBSPOT = "https://api.hubapi.com";
const MAX_ITEMS = 5;
const FIELDS: Record<Entity, Field[]> = {
  companies: [
    { hubspot: "name", local: "Company name", table: "companies", column: "company_name" },
    { hubspot: "domain", local: "Company Domain Name", table: "company_domains", column: "domain" },
    { hubspot: "phone", local: "Phone Number", table: "company_phone_numbers", column: "phone" },
    { hubspot: "address", local: "Street Address", table: "company_locations", column: "street_address_1" },
    { hubspot: "address2", local: "Street Address 2", table: "company_locations", column: "street_address_2" },
    { hubspot: "city", local: "City", table: "company_locations", column: "city" },
    { hubspot: "state", local: "State/Region", table: "company_locations", column: "state_province" },
    { hubspot: "zip", local: "Postal Code", table: "company_locations", column: "postal_code" },
    { hubspot: "country", local: "Country/Region", table: "company_locations", column: "country" },
    { hubspot: "website", local: "Website URL", table: "company_websites", column: "website_url" },
    { hubspot: "numberofemployees", local: "Number of Employees", table: "companies", column: "employee_count_best" },
    { hubspot: "linkedin_company_page", local: "LinkedIn Company Page", table: "", column: "", direction: "push" },
    { hubspot: "facebook_company_page", local: "Facebook Company Page", table: "", column: "", direction: "push" },
    { hubspot: "instagram_url", local: "Instagram URL", table: "", column: "", direction: "push" },
    { hubspot: "tiktok_url", local: "TikTok URL", table: "", column: "", direction: "push" },
    { hubspot: "prospect_score_supabase", local: "Prospect Score", table: "", column: "", direction: "push" },
    { hubspot: "marketing_maturity_supabase", local: "Marketing Maturity", table: "", column: "", direction: "push" },
    { hubspot: "icp_vertical", local: "ICP Vertical", table: "", column: "", direction: "push" },
    { hubspot: "revenue_tier", local: "Revenue Tier", table: "", column: "", direction: "push" },
    { hubspot: "last_prospect_scan", local: "Last Prospect Scan", table: "", column: "", direction: "push", kind: "datetime" },
  ],
  contacts: [
    { hubspot: "firstname", local: "First Name", table: "contacts", column: "first_name" },
    { hubspot: "lastname", local: "Last Name", table: "contacts", column: "last_name" },
    { hubspot: "jobtitle", local: "Job Title", table: "contacts", column: "job_title" },
    { hubspot: "seniority", local: "Seniority", table: "contacts", column: "seniority" },
    { hubspot: "email", local: "Email", table: "contact_channels", column: "email" },
    { hubspot: "phone", local: "Phone Number", table: "contact_channels", column: "phone" },
    { hubspot: "hs_linkedin_url", local: "LinkedIn URL", table: "contact_channels", column: "linkedin_url" },
    { hubspot: "role_category_supabase", local: "Role Category", table: "contacts", column: "role_category" },
    { hubspot: "contact_provenance_supabase", local: "Contact Provenance", table: "", column: "", direction: "push" },
    { hubspot: "email_provenance_supabase", local: "Email Provenance", table: "", column: "", direction: "push" },
  ],
};
const CHILDREN: Record<string, string> = {
  company_domains: "company_external_id",
  company_phone_numbers: "company_external_id",
  company_locations: "company_external_id",
  company_websites: "company_external_id",
  contact_channels: "contact_external_id",
};
const SAFE_IDENT = /^[a-z][a-z0-9_]*$/;

/** HubSpot dropdown option values verified against this portal (Oct 2026).
 * Re-check options if CRM properties are edited; unknown values are skipped. */
const HUBSPOT_ENUM_OPTIONS: Record<string, ReadonlySet<string>> = {
  marketing_maturity_supabase: new Set(["Upper_T2", "T2", "Unknown", "T3", "Lower_T4", "T1"]),
  revenue_tier: new Set(["T4", "T2", "T3", "T1", "T0", "Mega", "Unknown"]),
  role_category_supabase: new Set(["clinical_provider", "office_admin", "executive", "owner_founder", "other"]),
  contact_provenance_supabase: new Set([
    "published", "single_source", "verified_first_party", "observed_generic_channel",
    "published_secondary", "observed_public_directory", "observed_generic", "generic_channel",
  ]),
  email_provenance_supabase: new Set([
    "published", "unavailable", "published_first_party", "observed", "not_observed",
    "verified_first_party", "published_first_party_document",
    "verified_first_party_with_prior_observation",
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
    "Banquet halls", "Event venues", "Event rental companies",
    "Event DJ companies", "Psychology clinics", "Naturopathic clinics",
    "Corporate event planners",
  ]),
};


// Hash comparison avoids secret-length and prefix timing leaks.
async function equalSecret(a: string, b: string): Promise<boolean> {
  const digest = async (value: string): Promise<Uint8Array> =>
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const x = await digest(a);
  const y = await digest(b);
  let result = 0;
  for (let i = 0; i < x.length; i++) result |= x[i] ^ y[i];
  return result === 0;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}
function text(value: unknown): string {
  return value === null || value === undefined ? "" : String(value).trim();
}
function stamp(value: unknown): string {
  return text(value);
}
function dateValue(value: unknown): string {
  if (!text(value)) return "";
  const parsed = Date.parse(text(value));
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : "";
}
function errorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : "Unexpected failure";
  // Never include credentials, upstream response bodies, or SQL query arguments.
  return message.length > 160 ? message.slice(0, 160) : message;
}
function ensure(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error("invalid_request: " + message);
}
function fieldValue(value: unknown, field: Field): string {
  const raw = text(value);
  if (field.kind === "datetime") return dateValue(raw);
  return raw;
}
function identify(field: Field): void {
  ensure(SAFE_IDENT.test(field.table) && SAFE_IDENT.test(field.column), "invalid field map");
}

async function hubspotRequest(token: string, path: string, method = "GET", body?: Json): Promise<Json> {
  const url = HUBSPOT + path;
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await fetch(url, {
      method,
      headers: {
        Authorization: "Bearer " + token,
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(9000),
      redirect: "error",
    });
    if ((response.status === 429 || response.status >= 500) && attempt === 0) {
      const retry = Number(response.headers.get("Retry-After"));
      await new Promise((resolve) => setTimeout(resolve, Number.isFinite(retry) && retry > 0 ? Math.min(retry * 1000, 2000) : 600));
      continue;
    }
    if (!response.ok) throw new Error("HubSpot HTTP " + response.status);
    if (response.status === 204) return {};
    return await response.json() as Json;
  }
  throw new Error("HubSpot temporary failure");
}

async function tokenFromVault(db: Pg): Promise<string> {
  const rows = await db.unsafe(
    "select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1",
    ["HUBSPOT_ACCESS_TOKEN"],
  );
  const token = text(rows[0]?.decrypted_secret);
  if (!token) throw new Error("HubSpot token missing from Vault");
  return token;
}

function historyTimestamp(remote: Json, name: string): string {
  const histories = remote.propertiesWithHistory as Record<string, unknown> | undefined;
  const versions = histories?.[name];
  if (!Array.isArray(versions)) return "";
  let last = 0;
  for (const value of versions) {
    if (!value || typeof value !== "object") continue;
    const ts = Date.parse(text((value as Json).timestamp));
    if (Number.isFinite(ts) && ts > last) last = ts;
  }
  return last ? new Date(last).toISOString() : "";
}

async function remoteObject(token: string, entity: Entity, id: string): Promise<Json> {
  const names = FIELDS[entity].map((field) => field.hubspot);
  names.push(entity === "companies" ? "supabase_company_id" : "supabase_contact_id");
  if (entity === "contacts") names.push("supabase_company_id");
  const params = new URLSearchParams();
  params.set("properties", names.join(","));
  params.set("propertiesWithHistory", FIELDS[entity].map((field) => field.hubspot).join(","));
  return await hubspotRequest(token, "/crm/v3/objects/" + entity + "/" + encodeURIComponent(id) + "?" + params);
}

async function matchRemote(token: string, entity: Entity, localId: string): Promise<{ id?: string; error?: string }> {
  const property = entity === "companies" ? "supabase_company_id" : "supabase_contact_id";
  const response = await hubspotRequest(token, "/crm/v3/objects/" + entity + "/search", "POST", {
    filterGroups: [{ filters: [{ propertyName: property, operator: "EQ", value: localId }] }],
    properties: [property],
    limit: 2,
  });
  const results = Array.isArray(response.results) ? response.results as Json[] : [];
  if (results.length === 0) return { error: "no_matching_hubspot_record" };
  if (results.length > 1) return { error: "duplicate_hubspot_id_mapping" };
  return { id: text(results[0].id) };
}

async function associatedWithCorrectCompany(
  token: string,
  contactId: string,
  supabaseCompanyId: string,
): Promise<boolean> {
  const associations = await hubspotRequest(
    token,
    "/crm/v4/objects/contacts/" + encodeURIComponent(contactId) + "/associations/companies?limit=100",
  );
  const links = Array.isArray(associations.results) ? associations.results as Json[] : [];
  if (links.length === 0 || associations.paging) return false;
  // Prevent expensive or surprising association traversal.
  for (const association of links.slice(0, 10)) {
    const associatedId = text(association.toObjectId);
    if (!/^[0-9]+$/.test(associatedId)) continue;
    const company = await hubspotRequest(
      token,
      "/crm/v3/objects/companies/" + associatedId + "?properties=supabase_company_id",
    );
    if (text((company.properties as Json | undefined)?.supabase_company_id) === supabaseCompanyId) {
      return true;
    }
  }
  return false;
}

async function localObject(db: Pg, entity: Entity, localId: string): Promise<{
  rows: Row[];
  stamp: string;
  companyId: string;
  childIds: Record<string, string>;
} | null> {
  const parent = entity === "companies" ? "companies" : "contacts";
  const key = entity === "companies" ? "company_external_id" : "contact_external_id";
  const base = await db.unsafe(
    "select hubspot_export_updated_at::text as stamp, company_external_id from brightside." +
      parent + " where " + key + " = $1",
    [localId],
  );
  if (base.length !== 1) return null;
  const viewName = entity === "companies" ? "hubspot_companies_export" : "hubspot_contacts_export";
  const viewKey = entity === "companies" ? "Supabase Company ID" : "Supabase Contact ID";
  const rows = await db.unsafe(
    'select * from brightside.' + viewName + ' where "' + viewKey + '" = $1 limit 100',
    [localId],
  );
  if (rows.length === 0) return null;
  const childIds: Record<string, string> = {};
  const tables = [...new Set(FIELDS[entity].map((f) => f.table).filter((t) => t in CHILDREN))];
  for (const table of tables) {
    const ids = await db.unsafe(
      "select id from brightside." + table + " where " + CHILDREN[table] + " = $1 limit 2",
      [localId],
    );
    if (ids.length === 1) childIds[table] = text(ids[0].id);
  }
  return { rows, stamp: stamp(base[0].stamp), companyId: text(base[0].company_external_id), childIds };
}

function viewCell(rows: Row[], label: string): { value: string; ambiguous: boolean } {
  const values = [...new Set(rows.map((row) => text(row[label])).filter(Boolean))];
  return { value: values[0] ?? "", ambiguous: values.length > 1 };
}

async function planOne(
  db: Pg, token: string, direction: Direction, entity: Entity, id: string,
): Promise<RecordPlan> {
  const plan: RecordPlan = { id, status: "skipped", changes: [] };
  let hubspotId = "";
  let localId = "";
  let remote: Json;

  if (direction === "pull") {
    if (!/^[0-9]+$/.test(id)) return { ...plan, reason: "invalid_hubspot_id" };
    remote = await remoteObject(token, entity, id);
    hubspotId = id;
    const props = remote.properties as Json | undefined;
    localId = text(props?.[entity === "companies" ? "supabase_company_id" : "supabase_contact_id"]);
    if (!localId) return { ...plan, hubspotId, reason: "no_supabase_id_link" };
  } else {
    localId = id;
    const result = await matchRemote(token, entity, id);
    if (!result.id) return { ...plan, localId, reason: result.error };
    hubspotId = result.id;
    remote = await remoteObject(token, entity, hubspotId);
    const props = remote.properties as Json | undefined;
    if (text(props?.[entity === "companies" ? "supabase_company_id" : "supabase_contact_id"]) !== id) {
      return { ...plan, localId, hubspotId, reason: "mismatched_record_link" };
    }
  }
  plan.localId = localId;
  plan.hubspotId = hubspotId;
  const local = await localObject(db, entity, localId);
  if (!local) return { ...plan, reason: "no_matching_supabase_export_record" };
  plan.localStamp = local.stamp;
  if (entity === "contacts" && !await associatedWithCorrectCompany(token, hubspotId, local.companyId)) {
    return { ...plan, reason: "no_matching_company_association" };
  }

  const props = remote!.properties as Json | undefined ?? {};
  for (const field of FIELDS[entity]) {
    if (field.direction === "push" && direction === "pull") continue;
    const cell = viewCell(local.rows, field.local);
    const remoteValue = fieldValue(props[field.hubspot], field);
    const localValue = fieldValue(cell.value, field);
    const targetId = field.table === entity ? localId : local.childIds[field.table] ?? "";
    let outcome = decide(direction, localValue, remoteValue, local.stamp, historyTimestamp(remote!, field.hubspot));
    if (cell.ambiguous) outcome = { action: "skip", reason: "ambiguous_supabase_export_values" };
    if (direction === "pull" && !targetId) outcome = { action: "skip", reason: "missing_or_ambiguous_target_row" };
    if (field.kind === "datetime" && cell.value && !dateValue(cell.value)) {
      outcome = { action: "skip", reason: "invalid_datetime" };
    }
    if (direction === "push" && localValue &&
      HUBSPOT_ENUM_OPTIONS[field.hubspot] &&
      !HUBSPOT_ENUM_OPTIONS[field.hubspot].has(localValue)) {
      outcome = { action: "skip", reason: "unsupported_hubspot_dropdown_value" };
    }
    const source = direction === "pull" ? remoteValue : localValue;
    const destination = direction === "pull" ? localValue : remoteValue;
    plan.changes.push({
      property: field.hubspot,
      table: field.table,
      column: field.column,
      targetId,
      before: destination,
      after: source,
      action: outcome.action,
      reason: outcome.reason,
    });
  }
  plan.status = "ready";
  return plan;
}

async function selectedIds(db: Pg, token: string, direction: Direction, entity: Entity, cursor: string, limit: number):
  Promise<{ ids: string[]; nextCursor?: string }> {
  if (direction === "pull") {
    const property = entity === "companies" ? "supabase_company_id" : "supabase_contact_id";
    const query: Json = {
      filterGroups: [{ filters: [{ propertyName: property, operator: "HAS_PROPERTY" }] }],
      properties: [property],
      limit,
    };
    if (cursor) query.after = cursor;
    const response = await hubspotRequest(token, "/crm/v3/objects/" + entity + "/search", "POST", query);
    const items = Array.isArray(response.results) ? response.results as Json[] : [];
    const paging = response.paging as Json | undefined;
    return { ids: items.map((r) => text(r.id)).filter(Boolean), nextCursor: text((paging?.next as Json | undefined)?.after) || undefined };
  }
  const parent = entity === "companies" ? "companies" : "contacts";
  const key = entity === "companies" ? "company_external_id" : "contact_external_id";
  const rows = await db.unsafe(
    "select " + key + " as id from brightside." + parent +
      " where " + key + " > $1 order by " + key + " asc limit $2",
    [cursor, limit],
  );
  const ids = rows.map((r) => text(r.id));
  return { ids, nextCursor: ids.length === limit ? ids[ids.length - 1] : undefined };
}

async function digest(value: unknown): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return Array.from(new Uint8Array(bytes)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function applyInbound(db: Pg, entity: Entity, plan: RecordPlan): Promise<number> {
  const changes = plan.changes.filter((change) => change.action === "update");
  if (!changes.length) return 0;
  const parent = entity === "companies" ? "companies" : "contacts";
  const key = entity === "companies" ? "company_external_id" : "contact_external_id";
  return await db.begin(async (tx: any) => {
    const checked = await tx.unsafe(
      "select hubspot_export_updated_at::text as stamp from brightside." + parent +
        " where " + key + " = $1 for update",
      [plan.localId],
    );
    if (checked.length !== 1 || text(checked[0].stamp) !== plan.localStamp) {
      throw new Error("Supabase record changed since preview");
    }
    for (const change of changes) {
      identify({ hubspot: change.property, local: "", table: change.table, column: change.column });
      // Identifiers originate only from our fixed, checked mapping; data is parameterized.
      const primary = change.table === parent ? key : "id";
      const result = await tx.unsafe(
        "update brightside." + change.table + " set " + change.column + " = $1" +
          " where " + primary + " = $2 returning " + primary,
        [change.after, change.targetId],
      );
      if (result.length !== 1) throw new Error("Supabase target row missing during apply");
    }
    return changes.length;
  });
}

async function applyOutbound(token: string, entity: Entity, plan: RecordPlan): Promise<number> {
  const changes = plan.changes.filter((change) => change.action === "update");
  if (!changes.length) return 0;
  const properties: Record<string, string> = {};
  for (const change of changes) properties[change.property] = change.after;
  await hubspotRequest(
    token,
    "/crm/v3/objects/" + entity + "/" + encodeURIComponent(plan.hubspotId ?? ""),
    "PATCH",
    { properties },
  );
  return changes.length;
}

function parsePayload(value: unknown): RequestPayload {
  ensure(value && typeof value === "object" && !Array.isArray(value), "expected a JSON object");
  const input = value as Json;
  const action = input.action ?? "preview";
  ensure(action === "preview" || action === "apply", "action must be preview or apply");
  ensure(input.objectType === "companies" || input.objectType === "contacts", "objectType must be companies or contacts");
  const ids = input.ids;
  ensure(ids === undefined || (Array.isArray(ids) && ids.length > 0 && ids.length <= MAX_ITEMS &&
    ids.every((id) => typeof id === "string" && id.length > 0 && id.length <= 200)), "ids must contain 1-5 nonempty strings");
  ensure(input.cursor === undefined || typeof input.cursor === "string", "invalid cursor");
  const limit = input.limit ?? MAX_ITEMS;
  ensure(Number.isInteger(limit) && Number(limit) >= 1 && Number(limit) <= MAX_ITEMS, "limit must be between 1 and 5");
  if (action === "apply") {
    ensure(ids !== undefined, "apply requires explicit ids from a preview");
    ensure(input.confirm === "APPLY", "apply requires confirm: APPLY");
    ensure(typeof input.previewHash === "string" && /^[a-f0-9]{64}$/.test(input.previewHash), "apply requires previewHash");
  }
  return {
    action, objectType: input.objectType as Entity, ids: ids as string[] | undefined,
    cursor: (input.cursor as string | undefined) ?? "",
    limit: Number(limit), previewHash: input.previewHash as string | undefined,
    confirm: input.confirm as string | undefined,
  };
}

export function serveManual(direction: Direction): void {
  Deno.serve(async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "POST only" }, 405);
    const supplied = request.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1] ?? "";
    const authorizedKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!supplied || !authorizedKey || !await equalSecret(supplied, authorizedKey)) {
      return json({ error: "Unauthorized: server-side service role token required" }, 401);
    }

    let db: Pg | undefined;
    try {
      const raw = await request.text();
      ensure(raw.length <= 8192, "request too large");
      const input = parsePayload(JSON.parse(raw));
      const connection = Deno.env.get("SUPABASE_DB_URL");
      if (!connection) throw new Error("SUPABASE_DB_URL not configured");
      db = postgres(connection, { max: 1, prepare: false, connect_timeout: 5, idle_timeout: 5 });
      const token = await tokenFromVault(db);
      const scope = input.ids
        ? { ids: [...new Set(input.ids)], nextCursor: undefined }
        : await selectedIds(db, token, direction, input.objectType, input.cursor ?? "", input.limit ?? MAX_ITEMS);

      const records: RecordPlan[] = [];
      for (const id of scope.ids) {
        try {
          records.push(await planOne(db, token, direction, input.objectType, id));
        } catch (error) {
          records.push({ id, status: "error", reason: errorMessage(error), changes: [] });
        }
      }
      const hash = await digest({ direction, objectType: input.objectType, records });
      const base = {
        direction,
        objectType: input.objectType,
        action: input.action,
        records,
        previewHash: hash,
        nextCursor: scope.nextCursor,
        summary: {
          records: records.length,
          matched: records.filter((record) => record.status === "ready").length,
          skipped: records.filter((record) => record.status === "skipped").length,
          errors: records.filter((record) => record.status === "error").length,
          proposedFieldUpdates: records.reduce(
            (n, record) => n + record.changes.filter((change) => change.action === "update").length, 0
          ),
        },
      };
      if (input.action === "preview") return json(base);
      if (hash !== input.previewHash) return json({ error: "Preview changed; generate a new preview", ...base }, 409);
      if (records.some((record) => record.status === "error")) {
        return json({ error: "Cannot apply a batch with planning errors", ...base }, 409);
      }
      const applied: { id: string; fieldsUpdated: number; status: string; error?: string }[] = [];
      for (const record of records) {
        if (record.status !== "ready") {
          applied.push({ id: record.id, fieldsUpdated: 0, status: "skipped" });
          continue;
        }
        try {
          const count = direction === "pull"
            ? await applyInbound(db, input.objectType, record)
            : await applyOutbound(token, input.objectType, record);
          applied.push({ id: record.id, fieldsUpdated: count, status: "applied" });
        } catch (error) {
          applied.push({ id: record.id, fieldsUpdated: 0, status: "error", error: errorMessage(error) });
        }
      }
      return json({ ...base, applied }, applied.some((item) => item.status === "error") ? 207 : 200);
    } catch (error) {
      const message = errorMessage(error);
      if (message.startsWith("invalid_request:") || error instanceof SyntaxError) {
        return json({ error: message }, 400);
      }
      return json({ error: message }, 500);
    } finally {
      if (db) await db.end({ timeout: 2 }).catch(() => {});
    }
  });
}
