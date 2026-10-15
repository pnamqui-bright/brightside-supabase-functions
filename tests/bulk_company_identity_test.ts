import { buildCompanyMerges, canonicalCompanyId } from "../functions/hubspot-webhook/lib/bulk_company_identity.ts";
import { loadSnapshot, makeCandidate, matchLocal, supabaseInventorySql } from "../functions/hubspot-webhook/lib/bulk_sync.ts";

function assertEqual(actual: unknown, expected: unknown): void {
  if (actual !== expected) throw Error("expected " + String(expected) + ", got " + String(actual));
}

function assertThrows(fn: () => unknown, message: string): void {
  try { fn(); } catch (error) {
    if (error instanceof Error && error.message === message) return;
    throw Error("unexpected failure: " + String(error));
  }
  throw Error("expected error: " + message);
}

function fakeDb(options: { merged?: boolean; extraCompany?: boolean } = {}) {
  const companies = [
    { company_external_id: "V01-C070", company_name: "Nisa Medi Spa" },
    { company_external_id: "domain:nisamedispa.ca", company_name: "Nisa Medi Spa" },
    ...(options.extraCompany ? [{ company_external_id: "other", company_name: "Other" }] : []),
  ];
  const rows: Record<string, Record<string, unknown>[]> = {
    companies,
    contacts: [{ contact_external_id: "contact-1", company_external_id: "domain:nisamedispa.ca" }],
    company_relationships: options.merged === false ? [] : [
      { from_company_external_id: "domain:nisamedispa.ca", to_company_external_id: "V01-C070" },
    ],
    company_domains: [
      { company_external_id: "V01-C070", domain: "nisamedispa.ca" },
      { company_external_id: "domain:nisamedispa.ca", domain: "nisamedispa.ca" },
      ...(options.extraCompany ? [{ company_external_id: "other", domain: "nisamedispa.ca" }] : []),
    ],
    company_websites: [{ company_external_id: "domain:nisamedispa.ca", website_url: "https://nisamedispa.ca/" }],
    company_phone_numbers: [],
    company_locations: [],
    contact_channels: [{ contact_external_id: "contact-1", email: "owner@nisamedispa.ca" }],
  };
  return {
    unsafe: async (sql: string): Promise<Record<string, unknown>[]> => {
      const table = /from brightside\.([a-z_]+)/.exec(sql)?.[1];
      if (!table || !Object.hasOwn(rows, table)) throw Error("unexpected SQL: " + sql);
      return rows[table];
    },
  } as unknown as Parameters<typeof loadSnapshot>[0];
}

Deno.test("bulk company matching collapses domain and website aliases onto HubSpot's existing ID", async () => {
  const snap = await loadSnapshot(fakeDb(), "companies");
  const domainCandidates = snap.domains.get("nisamedispa.ca");
  assertEqual(domainCandidates?.size, 1);
  assertEqual(domainCandidates?.has("V01-C070"), true);
  for (const properties of [
    { supabase_company_id: "V01-C070", domain: "nisamedispa.ca" },
    { supabase_company_id: "domain:nisamedispa.ca", domain: "nisamedispa.ca" },
    { domain: "nisamedispa.ca" },
    { website: "https://nisamedispa.ca/" },
  ]) {
    const match = matchLocal("companies", { id: "223494704090", properties }, snap);
    assertEqual(match.id, "V01-C070");
    assertEqual(match.reason, undefined);
    assertEqual(match.creating, false);
  }
});

Deno.test("unlinked companies sharing a domain remain ambiguous", async () => {
  const snap = await loadSnapshot(fakeDb({ merged: false }), "companies");
  const match = matchLocal("companies", { id: "223494704090", properties: {
    supabase_company_id: "V01-C070", domain: "nisamedispa.ca",
  } }, snap);
  assertEqual(match.reason, "ambiguous_domain_or_email_match");
});

Deno.test("distinct unmerged canonical companies still trigger domain ambiguity", async () => {
  const snap = await loadSnapshot(fakeDb({ extraCompany: true }), "companies");
  const match = matchLocal("companies", { id: "223494704090", properties: {
    supabase_company_id: "V01-C070", domain: "nisamedispa.ca",
  } }, snap);
  assertEqual(match.reason, "ambiguous_domain_or_email_match");
});

Deno.test("existing contacts associated with merged Supabase company IDs are not mismatches", async () => {
  const snap = await loadSnapshot(fakeDb(), "contacts");
  const contact = { id: "501", properties: { supabase_contact_id: "contact-1", email: "owner@nisamedispa.ca" },
    associations: { companies: { results: [{ id: "223494704090" }] } } };
  const associated = new Map([["223494704090", { id: "223494704090",
    properties: { supabase_company_id: "V01-C070", domain: "nisamedispa.ca" } }]]);
  const views = new Map([["contact-1", [{ "Email": "owner@nisamedispa.ca" }]]]);
  const candidate = makeCandidate("contacts", contact, snap, views, associated);
  assertEqual(candidate.companyId, "V01-C070");
  if (candidate.reason === "mismatched_company_association") {
    throw Error("merged company association incorrectly rejected");
  }
});

Deno.test("merged source IDs are excluded only from company outbound inventory", () => {
  const companySql = supabaseInventorySql("companies");
  if (!companySql.includes("company_relationships") ||
      !companySql.includes("relationship_type = 'merged_into'") ||
      !companySql.includes("rel.from_company_external_id = brightside.companies.company_external_id")) {
    throw Error("company inventory must skip confirmed merged source IDs");
  }
  const contactSql = supabaseInventorySql("contacts");
  if (contactSql.includes("company_relationships") || !contactSql.includes("contact_external_id")) {
    throw Error("contact inventory must remain unchanged");
  }
  if (!companySql.includes("company_external_id > $1") || !companySql.includes("limit $2")) {
    throw Error("company cursor and pagination must be preserved");
  }
});

Deno.test("merged_into chain resolves to final canonical company", () => {
  const ids = new Set(["a", "b", "c"]);
  const merges = buildCompanyMerges([
    { from_company_external_id: "a", to_company_external_id: "b" },
    { from_company_external_id: "b", to_company_external_id: "c" },
  ], ids);
  assertEqual(canonicalCompanyId("a", merges), "c");
});

Deno.test("unsafe merge graphs fail closed instead of assigning arbitrary targets", () => {
  const ids = new Set(["a", "b", "c"]);
  assertThrows(() => buildCompanyMerges([
    { from_company_external_id: "a", to_company_external_id: "b" },
    { from_company_external_id: "a", to_company_external_id: "c" },
  ], ids), "conflicting_company_merge_targets");
  assertThrows(() => buildCompanyMerges([
    { from_company_external_id: "a", to_company_external_id: "b" },
    { from_company_external_id: "b", to_company_external_id: "a" },
  ], ids), "invalid_company_merge_cycle");
  assertThrows(() => buildCompanyMerges([
    { from_company_external_id: "a", to_company_external_id: "missing" },
  ], ids), "invalid_company_merge_reference");
  assertThrows(() => buildCompanyMerges([
    { from_company_external_id: "a", to_company_external_id: "a" },
  ], ids), "invalid_company_merge_self_link");
});
