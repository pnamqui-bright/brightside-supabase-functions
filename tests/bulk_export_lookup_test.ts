import { exportViewLookup } from "../functions/hubspot-webhook/lib/bulk_sync.ts";

Deno.test("single-company export lookup uses indexed equality, not ANY(text[])", () => {
  const id = "company-123";
  const result = exportViewLookup("companies", [id]);
  if (result.sql !== 'select * from brightside.hubspot_companies_export where "Supabase Company ID" = $1') {
    throw Error("single-company export query must use scalar equality: " + result.sql);
  }
  if (JSON.stringify(result.params) !== JSON.stringify([id])) {
    throw Error("single ID must be bound as a scalar parameter");
  }
});

Deno.test("single-contact export lookup also uses scalar equality", () => {
  const id = "contact-456";
  const result = exportViewLookup("contacts", [id]);
  if (result.sql !== 'select * from brightside.hubspot_contacts_export where "Supabase Contact ID" = $1') {
    throw Error("single-contact export query must use scalar equality: " + result.sql);
  }
  if (JSON.stringify(result.params) !== JSON.stringify([id])) {
    throw Error("single contact ID must be bound as a scalar parameter");
  }
});

Deno.test("planner multi-ID export lookup keeps array matching", () => {
  const ids = ["company-123", "company-456"];
  const result = exportViewLookup("companies", ids);
  if (result.sql !== 'select * from brightside.hubspot_companies_export where "Supabase Company ID" = any($1::text[])') {
    throw Error("multi-ID export query must preserve existing ANY behavior: " + result.sql);
  }
  if (JSON.stringify(result.params) !== JSON.stringify([ids])) {
    throw Error("multi-ID export query must bind the ID array as one parameter");
  }
});

Deno.test("export lookup binds untrusted identifiers rather than interpolating them", () => {
  const id = "x' OR true --";
  const result = exportViewLookup("companies", [id]);
  if (result.sql.includes(id) || result.params[0] !== id) {
    throw Error("record IDs must be bound only as SQL parameters");
  }
});
