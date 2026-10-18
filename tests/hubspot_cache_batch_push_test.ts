import {
  candidateFromCache, decideRemote, mappingProperty, propertyProblems,
  writableProperties, type CacheRow,
} from "../functions/hubspot-cache-batch-push/lib.ts";

function companyRow(overrides: Partial<CacheRow> = {}): CacheRow {
  return {
    sync_key: "s:V31-C0032",
    hubspot_id: "223494703042",
    supabase_external_id: "V31-C0032",
    last_changed_at: "2026-10-18T12:00:00.000Z",
    hubspot_source_updated_at: "2026-10-18T11:59:00.000Z",
    hubspot_records: [{ supabase_company_id: "V31-C0032" }],
    hubspot_fields: { name: "Company", phone: null, icp_vertical: null },
    unified_fields: { name: "Company", phone: "+17805550001", icp_vertical: "Roofing contractors" },
    ...overrides,
  };
}
function check(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

Deno.test("cached missing values become outbound proposals, not overwrites", () => {
  const candidate = candidateFromCache("companies", companyRow());
  check(candidate, "missing candidate");
  check(candidate.properties.phone === "+17805550001", "missing phone patch");
  check(candidate.properties.icp_vertical === "Roofing contractors", "missing vertical patch");
  check(candidate.properties.name === undefined, "should not resend populated names");
  check(candidate.properties.supabase_company_id === undefined, "already-linked ID should not be changed");
});

Deno.test("synthetic created company may backfill its HubSpot external-ID property", () => {
  const candidate = candidateFromCache("companies", companyRow({
    sync_key: "s:HUB-215904971762",
    hubspot_id: "215904971762",
    supabase_external_id: "HUB-215904971762",
    hubspot_records: [{ supabase_company_id: null }],
    unified_fields: { name: "Relume" },
    hubspot_fields: { name: "Relume" },
  }));
  check(candidate?.properties.supabase_company_id === "HUB-215904971762", "missing deterministic backfill");
  check(Object.keys(candidate.properties).length === 1, "unexpected writes for synthetic record");
});

Deno.test("contact proposals exclude CRM consent, legal basis, and contact company display name", () => {
  const candidate = candidateFromCache("contacts", {
    sync_key: "s:C012-GEN",
    hubspot_id: "281029508030",
    supabase_external_id: "C012-GEN",
    last_changed_at: "2026-10-18T12:00:00Z",
    hubspot_source_updated_at: "2026-10-18T11:59:00Z",
    hubspot_records: [{ supabase_contact_id: "C012-GEN" }],
    hubspot_fields: {
      email: null,
      company: null,
      hs_legal_basis: null,
      supabase_company_id: null,
    },
    unified_fields: {
      email: "info@example.com",
      company: "Different company name",
      hs_legal_basis: "Freely given consent from contact",
      supabase_company_id: "V01-C012",
    },
  });
  check(candidate, "missing contact candidate");
  check(candidate.properties.email === "info@example.com", "missing email fill");
  check(candidate.properties.supabase_company_id === "V01-C012", "missing custom company ID");
  check(candidate.properties.company === undefined, "must not change company display name");
  check(candidate.properties.hs_legal_basis === undefined, "must not alter legal basis");
  check(mappingProperty("contacts") === "supabase_contact_id", "invalid link property");
});

Deno.test("HubSpot already holds all intended values: skip PATCH", () => {
  const candidate = candidateFromCache("companies", companyRow());
  check(candidate, "missing candidate");
  const outcome = decideRemote(candidate, {
    id: candidate.hubspotId,
    updatedAt: "2026-10-18T12:04:00.000Z",
    properties: { phone: "+17805550001", icp_vertical: "Roofing contractors" },
  });
  check(outcome.kind === "already_aligned", "should accept independently confirmed delivery");
});

Deno.test("HubSpot source edit blocks write even if the cached field was blank", () => {
  const candidate = candidateFromCache("companies", companyRow());
  check(candidate, "missing candidate");
  const outcome = decideRemote(candidate, {
    id: candidate.hubspotId,
    updatedAt: "2026-10-18T11:59:00.000Z",
    properties: { phone: "+17805559999", icp_vertical: "" },
  });
  check(outcome.kind === "skipped" && outcome.reason.includes("remote_value_changed"), "must block overwrite");
});

Deno.test("HubSpot timestamp drift blocks an otherwise valid new write", () => {
  const candidate = candidateFromCache("companies", companyRow());
  check(candidate, "missing candidate");
  const outcome = decideRemote(candidate, {
    id: candidate.hubspotId,
    updatedAt: "2026-10-18T12:01:00.000Z",
    properties: { phone: "", icp_vertical: "" },
  });
  check(outcome.kind === "skipped" && outcome.reason === "hubspot_changed_since_cache_refresh", "must require refresh");
});

Deno.test("matching HubSpot timestamp permits blank-only patch", () => {
  const candidate = candidateFromCache("companies", companyRow());
  check(candidate, "missing candidate");
  const outcome = decideRemote(candidate, {
    id: candidate.hubspotId,
    updatedAt: "2026-10-18T11:59:00.000Z",
    properties: { phone: "", icp_vertical: "" },
  });
  check(outcome.kind === "update" &&
    outcome.properties.phone === "+17805550001" &&
    outcome.properties.icp_vertical === "Roofing contractors", "must propose exact nonblank fills");
});

Deno.test("unknown enums and malformed datetimes fail closed", () => {
  const problems = propertyProblems({
    icp_vertical: "Fictional category",
    last_prospect_scan: "not-a-date",
  });
  check(problems.includes("icp_vertical:unsupported_enum"), "enum error missing");
  check(problems.includes("last_prospect_scan:invalid_datetime"), "datetime error missing");
});

Deno.test("only approved fields are writable", () => {
  const companies = writableProperties("companies");
  const contacts = writableProperties("contacts");
  for (const field of ["lifecyclestage", "hubspot_owner_id", "hs_legal_basis", "hs_email_optout"]) {
    check(!companies.includes(field) && !contacts.includes(field), "protected HubSpot property slipped into mapping: " + field);
  }
});
