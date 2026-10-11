import postgres from "npm:postgres@3.4.7";
import { isAuthorizedSecretRequest } from "../hubspot-webhook/lib/auth.ts";
import { decide } from "../hubspot-webhook/lib/decide.ts";

// Temporary test setting. Change to false after inspecting the full dry-run report.
// Neither the request body nor query string can override it.
const DRY_RUN: boolean = true;
const HUBSPOT_API = "https://api.hubapi.com";
const PAGE_SIZE = 100;

type Entity = "companies" | "contacts";
type Row = Record<string, unknown>;
type Pg = ReturnType<typeof postgres>;
type Field = { property: string; table: string; column: string };
type Change = { table: string; column: string; value: string; targetId?: string };
type Plan = {
  entity: Entity;
  hubspotId: string;
  localId: string;
  create: boolean;
  companyId?: string;
  changes: Change[];
};
type Summary = {
  scanned: number;
  wouldCreate: number;
  wouldUpdate: number;
  unchanged: number;
  conflicts: number;
  conflictingFields: number;
  skipped: number;
  applied: number;
};
type Snapshot = {
  parents: Record<Entity, Map<string, Row>>;
  children: Record<string, Map<string, Row[]>>;
  domains: Map<string, Set<string>>;
  emails: Map<string, Set<string>>;
};
type Report = {
  dryRun: boolean;
  generatedAt: string;
  direction: "hubspot_to_supabase";
  summary: Record<Entity, Summary>;
  conflicts: Row[];
  skipped: Row[];
  errors: Row[];
  complete: boolean;
};

const FIELDS: Record<Entity, Field[]> = {
  companies: [
    { property: "name", table: "companies", column: "company_name" },
    { property: "domain", table: "company_domains", column: "domain" },
    { property: "phone", table: "company_phone_numbers", column: "phone" },
    { property: "address", table: "company_locations", column: "street_address_1" },
    { property: "address2", table: "company_locations", column: "street_address_2" },
    { property: "city", table: "company_locations", column: "city" },
    { property: "state", table: "company_locations", column: "state_province" },
    { property: "zip", table: "company_locations", column: "postal_code" },
    { property: "country", table: "company_locations", column: "country" },
    { property: "website", table: "company_websites", column: "website_url" },
    { property: "numberofemployees", table: "companies", column: "employee_count_best" },
  ],
  contacts: [
    { property: "firstname", table: "contacts", column: "first_name" },
    { property: "lastname", table: "contacts", column: "last_name" },
    { property: "jobtitle", table: "contacts", column: "job_title" },
    { property: "seniority", table: "contacts", column: "seniority" },
    { property: "email", table: "contact_channels", column: "email" },
    { property: "phone", table: "contact_channels", column: "phone" },
    { property: "hs_linkedin_url", table: "contact_channels", column: "linkedin_url" },
    { property: "role_category_supabase", table: "contacts", column: "role_category" },
  ],
};
const CHILD_TABLES = [
  "company_domains", "company_phone_numbers", "company_locations",
  "company_websites", "contact_channels",
] as const;
const CHILD_PARENT: Record<string, string> = {
  company_domains: "company_external_id",
  company_phone_numbers: "company_external_id",
  company_locations: "company_external_id",
  company_websites: "company_external_id",
  contact_channels: "contact_external_id",
};
const KEY: Record<Entity, string> = {
  companies: "company_external_id",
  contacts: "contact_external_id",
};

function str(value: unknown): string {
  return value === null || value === undefined ? "" : String(value).trim();
}
function domain(value: unknown): string {
  const raw = str(value);
  if (!raw) return "";
  try {
    const url = new URL(raw.includes("://") ? raw : "https://" + raw);
    return url.hostname.toLowerCase().replace(/^www\./, "").replace(/\.$/, "");
  } catch {
    return "";
  }
}
function email(value: unknown): string {
  return str(value).toLowerCase();
}
function indexKey(index: Map<string, Set<string>>, key: string, id: string): void {
  if (!key) return;
  let ids = index.get(key);
  if (!ids) { ids = new Set(); index.set(key, ids); }
  ids.add(id);
}
function errorMessage(e: unknown): string {
  // Upstream body, query parameters, credentials, and SQL arguments are never returned.
  const message = e instanceof Error ? e.message : "unexpected_failure";
  return message.slice(0, 180);
}
function stamp(value: unknown): string {
  const t = Date.parse(str(value));
  return Number.isFinite(t) ? new Date(t).toISOString() : "";
}
function latestPropertyChange(object: Row, property: string): string {
  const history = object.propertiesWithHistory as Row | undefined;
  const versions = history?.[property];
  if (!Array.isArray(versions)) return "";
  let max = 0;
  for (const version of versions) {
    const t = Date.parse(str((version as Row)?.timestamp));
    if (Number.isFinite(t) && t > max) max = t;
  }
  return max ? new Date(max).toISOString() : "";
}
function newSummary(): Summary {
  return { scanned: 0, wouldCreate: 0, wouldUpdate: 0, unchanged: 0, conflicts: 0, conflictingFields: 0, skipped: 0, applied: 0 };
}

async function hubspotGet(token: string, path: string): Promise<Row> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const response = await fetch(HUBSPOT_API + path, {
      headers: { Authorization: "Bearer " + token, Accept: "application/json" },
      signal: AbortSignal.timeout(20000),
      redirect: "error",
    });
    if ((response.status === 429 || response.status >= 500) && attempt < 4) {
      const seconds = Number(response.headers.get("Retry-After"));
      const delay = Number.isFinite(seconds) && seconds > 0
        ? Math.min(seconds * 1000, 12000) : 500 * (2 ** attempt);
      await new Promise((resolve) => setTimeout(resolve, delay));
      continue;
    }
    if (!response.ok) throw new Error("HubSpot HTTP " + response.status);
    return await response.json() as Row;
  }
  throw new Error("HubSpot request failed");
}

async function loadSnapshot(db: Pg): Promise<Snapshot> {
  const parents: Snapshot["parents"] = { companies: new Map(), contacts: new Map() };
  const children: Snapshot["children"] = {};
  const domains = new Map<string, Set<string>>();
  const emails = new Map<string, Set<string>>();

  // Select only columns included in the synchronization contract.
  for (const entity of ["companies", "contacts"] as const) {
    const cols = new Set([KEY[entity], "hubspot_export_updated_at"]);
    if (entity === "contacts") cols.add("company_external_id");
    for (const f of FIELDS[entity]) if (f.table === entity) cols.add(f.column);
    const rows = await db.unsafe("select " + [...cols].join(",") + " from brightside." + entity);
    for (const row of rows) parents[entity].set(str(row[KEY[entity]]), row as Row);
  }
  for (const table of CHILD_TABLES) {
    const fields = [...FIELDS.companies, ...FIELDS.contacts].filter((f) => f.table === table);
    const cols = new Set(["id", CHILD_PARENT[table], ...fields.map((f) => f.column)]);
    const rows = await db.unsafe("select " + [...cols].join(",") + " from brightside." + table);
    const byParent = new Map<string, Row[]>();
    for (const row of rows) {
      const localId = str(row[CHILD_PARENT[table]]);
      const list = byParent.get(localId) ?? [];
      list.push(row as Row);
      byParent.set(localId, list);
      if (table === "company_domains") indexKey(domains, domain(row.domain), localId);
      if (table === "company_websites") indexKey(domains, domain(row.website_url), localId);
      if (table === "contact_channels") indexKey(emails, email(row.email), localId);
    }
    children[table] = byParent;
  }
  return { parents, children, domains, emails };
}

function matchLocal(entity: Entity, props: Row, snapshot: Snapshot): { id: string; issue?: string } {
  const linked = str(props[entity === "companies" ? "supabase_company_id" : "supabase_contact_id"]);
  if (linked && snapshot.parents[entity].has(linked)) return { id: linked };
  const keys = entity === "companies"
    ? [domain(props.domain), domain(props.website)]
    : [email(props.email)];
  const index = entity === "companies" ? snapshot.domains : snapshot.emails;
  const choices = new Set<string>();
  for (const key of keys) for (const id of index.get(key) ?? []) choices.add(id);
  if (choices.size > 1) return { id: "", issue: "ambiguous_domain_or_email_match" };
  if (choices.size === 1) return { id: [...choices][0] };
  return { id: linked };
}

function requiredCompanyForNewContact(
  remote: Row, props: Row, snapshot: Snapshot, hubspotCompanies: Map<string, string>,
): string {
  const direct = str(props.supabase_company_id);
  if (direct && snapshot.parents.companies.has(direct)) return direct;
  if (direct && [...hubspotCompanies.values()].includes(direct)) return direct;
  const associations = (remote.associations as Row | undefined)?.companies as Row | undefined;
  const results = Array.isArray(associations?.results) ? associations.results as Row[] : [];
  const candidates = new Set<string>();
  for (const association of results) {
    const id = hubspotCompanies.get(str(association.id));
    if (id) candidates.add(id);
  }
  return candidates.size === 1 ? [...candidates][0] : "";
}

function appendConflict(
  report: Report, entity: Entity, hubspotId: string, localId: string,
  field: Field, local: string, remote: string,
  localStamp: string, hubspotStamp: string, reason: string,
): void {
  report.conflicts.push({
    objectType: entity, hubspotId, supabaseId: localId,
    property: field.property, table: field.table, column: field.column,
    supabaseValue: local, hubspotValue: remote,
    supabaseRowUpdatedAt: localStamp, hubspotPropertyUpdatedAt: hubspotStamp,
    reason,
  });
  report.summary[entity].conflictingFields++;
}

function planRecord(
  entity: Entity,
  remote: Row,
  snapshot: Snapshot,
  report: Report,
  hubspotCompanies: Map<string, string>,
  claimed: Set<string>,
): Plan | null {
  const hubspotId = str(remote.id);
  const props = (remote.properties ?? {}) as Row;
  const match = matchLocal(entity, props, snapshot);
  const summary = report.summary[entity];
  if (match.issue) {
    summary.skipped++;
    report.skipped.push({ objectType: entity, hubspotId, reason: match.issue });
    return null;
  }
  const localId = match.id || "hubspot-" + entity.slice(0, -1) + "-" + hubspotId;
  if (claimed.has(localId)) {
    summary.skipped++;
    report.skipped.push({ objectType: entity, hubspotId, supabaseId: localId, reason: "multiple_hubspot_records_match_one_supabase_record" });
    return null;
  }
  const parent = snapshot.parents[entity].get(localId);
  const create = !parent;
  let companyId: string | undefined;
  if (entity === "contacts" && create) {
    companyId = requiredCompanyForNewContact(remote, props, snapshot, hubspotCompanies);
    if (!companyId) {
      summary.skipped++;
      report.skipped.push({ objectType: entity, hubspotId, reason: "missing_required_supabase_company" });
      return null;
    }
  }

  const changes: Change[] = [];
  const localStamp = stamp(parent?.hubspot_export_updated_at);
  const beforeConflicts = summary.conflictingFields;
  for (const field of FIELDS[entity]) {
    const source = str(props[field.property]);
    if (!source) continue; // Empty source never erases a populated destination.
    const childRows = field.table === entity ? [] : snapshot.children[field.table].get(localId) ?? [];
    const destinationRow = field.table === entity ? parent : childRows[0];
    const local = str(destinationRow?.[field.column]);
    if (childRows.length > 1) {
      if (childRows.some((row) => str(row[field.column]) === source)) continue;
      appendConflict(report, entity, hubspotId, localId, field,
        childRows.map((row) => str(row[field.column])).join(" | "),
        source, localStamp, latestPropertyChange(remote, field.property), "ambiguous_child_rows");
      continue;
    }
    const decision = create
      ? { action: "update", reason: "new_record" }
      : decide("pull", local, source, localStamp, latestPropertyChange(remote, field.property));
    if (decision.action === "update") {
      changes.push({ table: field.table, column: field.column, value: source,
        targetId: field.table === entity ? localId : str(destinationRow?.id) || undefined });
    } else if (local && local !== source) {
      appendConflict(report, entity, hubspotId, localId, field, local, source,
        localStamp, latestPropertyChange(remote, field.property), decision.reason);
    }
  }
  if (create && changes.length === 0) {
    summary.skipped++;
    report.skipped.push({ objectType: entity, hubspotId, reason: "no_mapped_source_values" });
    return null;
  }

  claimed.add(localId);
  if (entity === "companies") {
    hubspotCompanies.set(hubspotId, localId);
    if (create) {
      indexKey(snapshot.domains, domain(props.domain), localId);
      indexKey(snapshot.domains, domain(props.website), localId);
    }
  } else if (create) {
    indexKey(snapshot.emails, email(props.email), localId);
  }
  if (summary.conflictingFields > beforeConflicts) summary.conflicts++;
  if (create) summary.wouldCreate++;
  else if (changes.length) summary.wouldUpdate++;
  else summary.unchanged++;
  return { entity, hubspotId, localId, create, companyId, changes };
}

function identifiers(columns: string[]): string {
  if (!columns.every((c) => /^[a-z][a-z0-9_]*$/.test(c))) {
    throw new Error("invalid_column_mapping");
  }
  return columns.join(",");
}
async function applyPlan(db: Pg, plan: Plan): Promise<void> {
  // This path is deliberately unreachable while DRY_RUN is true.
  await db.begin(async (tx) => {
    const groups = new Map<string, Change[]>();
    for (const change of plan.changes) {
      const group = groups.get(change.table) ?? [];
      group.push(change);
      groups.set(change.table, group);
    }
    const parentChanges = groups.get(plan.entity) ?? [];
    if (plan.create) {
      const columns = [KEY[plan.entity]];
      const values: string[] = [plan.localId];
      if (plan.entity === "contacts") {
        columns.push("company_external_id");
        values.push(plan.companyId ?? "");
      }
      for (const change of parentChanges) { columns.push(change.column); values.push(change.value); }
      await tx.unsafe(
        "insert into brightside." + plan.entity + " (" + identifiers(columns) + ") values (" +
          values.map((_, i) => "$" + (i + 1)).join(",") + ")",
        values,
      );
    } else if (parentChanges.length) {
      await tx.unsafe(
        "update brightside." + plan.entity + " set " +
          parentChanges.map((c, i) => c.column + " = $" + (i + 1)).join(",") +
          " where " + KEY[plan.entity] + " = $" + (parentChanges.length + 1),
        [...parentChanges.map((c) => c.value), plan.localId],
      );
    }
    for (const table of CHILD_TABLES) {
      const changes = groups.get(table);
      if (!changes?.length) continue;
      const targetId = changes[0].targetId;
      if (targetId) {
        await tx.unsafe(
          "update brightside." + table + " set " +
            changes.map((c, i) => c.column + " = $" + (i + 1)).join(",") +
            " where id = $" + (changes.length + 1),
          [...changes.map((c) => c.value), targetId],
        );
      } else {
        const columns = ["id", CHILD_PARENT[table], ...changes.map((c) => c.column)];
        const values = [crypto.randomUUID(), plan.localId, ...changes.map((c) => c.value)];
        await tx.unsafe(
          "insert into brightside." + table + " (" + identifiers(columns) + ") values (" +
            values.map((_, i) => "$" + (i + 1)).join(",") + ")",
          values,
        );
      }
    }
  });
}

async function run(db: Pg, token: string): Promise<Report> {
  const report: Report = {
    dryRun: DRY_RUN, generatedAt: new Date().toISOString(),
    direction: "hubspot_to_supabase",
    summary: { companies: newSummary(), contacts: newSummary() },
    conflicts: [], skipped: [], errors: [], complete: false,
  };
  const snapshot = await loadSnapshot(db);
  const companyIds = new Map<string, string>();

  for (const entity of ["companies", "contacts"] as const) {
    const claimed = new Set<string>();
    const names = [
      ...FIELDS[entity].map((f) => f.property),
      entity === "companies" ? "supabase_company_id" : "supabase_contact_id",
      ...(entity === "contacts" ? ["supabase_company_id"] : []),
    ];
    const properties = [...new Set(names)].join(",");
    const history = FIELDS[entity].map((f) => f.property).join(",");
    let after = "";
    do {
      const params = new URLSearchParams({
        limit: String(PAGE_SIZE),
        properties,
        propertiesWithHistory: history,
      });
      if (entity === "contacts") params.set("associations", "companies");
      if (after) params.set("after", after);
      const page = await hubspotGet(token, "/crm/v3/objects/" + entity + "?" + params);
      const records = Array.isArray(page.results) ? page.results as Row[] : [];
      for (const remote of records) {
        const hubspotId = str(remote.id);
        report.summary[entity].scanned++;
        try {
          const plan = planRecord(entity, remote, snapshot, report, companyIds, claimed);
          if (plan && !DRY_RUN && (plan.create || plan.changes.length)) {
            await applyPlan(db, plan);
            report.summary[entity].applied++;
          }
        } catch (e) {
          report.errors.push({ objectType: entity, hubspotId, reason: errorMessage(e) });
        }
      }
      const next = str(((page.paging as Row | undefined)?.next as Row | undefined)?.after);
      if (next && next === after) throw new Error("HubSpot returned an unchanged pagination cursor");
      after = next;
    } while (after);
  }
  report.complete = true;
  return report;
}

Deno.serve(async (request: Request): Promise<Response> => {
  const headers = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
  if (request.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405, headers });
  }
  if (!await isAuthorizedSecretRequest(request, {
    SUPABASE_SECRET_KEYS: Deno.env.get("SUPABASE_SECRET_KEYS"),
    SUPABASE_SECRET_KEY: Deno.env.get("SUPABASE_SECRET_KEY"),
  })) {
    return Response.json({ error: "Unauthorized" }, { status: 401, headers });
  }

  const url = Deno.env.get("SUPABASE_DB_URL");
  if (!url) return Response.json({ error: "SUPABASE_DB_URL is not configured" }, { status: 500, headers });
  const db = postgres(url, { max: 1, prepare: false, connect_timeout: 5, idle_timeout: 5 });
  try {
    const keys = await db.unsafe(
      "select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1",
      ["HUBSPOT_ACCESS_TOKEN"],
    );
    const token = str(keys[0]?.decrypted_secret);
    if (!token) throw new Error("HubSpot Vault token not configured");
    // No body, query parameters, preview/apply modes, or background scheduling.
    const report = await run(db, token);
    return Response.json(report, { headers });
  } catch (e) {
    return Response.json({
      dryRun: DRY_RUN, complete: false, error: errorMessage(e),
      message: "Full scan did not complete; counts cannot be treated as final.",
    }, { status: 500, headers });
  } finally {
    await db.end({ timeout: 2 }).catch(() => {});
  }
});
