# Manual HubSpot ↔ Supabase sync contract

**Implemented and committed as TypeScript Edge Functions; NOT deployed or integration-tested on the production server by this repository.** Both directions are manually triggered via authenticated HTTP POST. They do not run on a schedule, accept unsolicited HubSpot webhook events, or push changes on a database trigger.

## Directions and matching

- \`hubspot-webhook\`: HubSpot → Supabase (manual pull).
- \`hubspot-manual-push\`: Supabase → HubSpot (manual push).
- Explicitly select 1–5 record IDs or preview a small page; follow a preview with an apply call using the returned hash. Apply requires \`confirm: "APPLY"\`.
- Match records only via HubSpot's existing \`supabase_company_id\` and \`supabase_contact_id\`. No creation or fuzzy matching in either direction.
- For contacts, check a real HubSpot contact→company association, then verify that the associated company has the exact same \`supabase_company_id\` as the Supabase contact's parent company. Skip otherwise; **no staging or association synthesis**.
- A pull updates the existing \`brightside.companies\`, \`brightside.contacts\` or exactly-one existing related child row; no child-row creation.

## Writable field groups

**Bidirectional for matched existing records**:
- Company: company name; domain, phone, address, city, province/state, postal code, country and website (when each related table has one unambiguous existing row); employee count.
- Contact: first/last name, job title, seniority, email, phone, LinkedIn URL, role category.

**Supabase → HubSpot only**:
- Company: LinkedIn/Facebook/Instagram/TikTok URLs, computed prospect score, observed marketing maturity, ICP vertical, estimated revenue tier, last scan.
- Contact: contact and email provenance metadata.
- Company website/social records remain owned by existing normalized Supabase tables.

**Never automatically changed**:
- HubSpot legal basis, marketing consent/subscription, lifecycle, ownership, list membership, deals, unrelated CRM properties or existing company associations.
- Identifiers and external IDs after initial matching.
- HubSpot contacts without a verified company association.

## Conflict fallback

HubSpot CRM history supports per-property timestamps, but \`brightside.companies.hubspot_export_updated_at\` and \`brightside.contacts.hubspot_export_updated_at\` are **record-level** modification stamps, not per-field history.

For two distinct, populated values, compare HubSpot's property change time to Supabase's **whole record change time**. Update only if the requested direction is strictly newer by those data, otherwise skip. Without valid timestamps or for ties, skip. Fill an empty destination from a non-empty source regardless of timestamps; never clear a populated destination from an empty source. Ambiguous export-view source values or missing target child rows are also skipped.

**This is not exact per-property latest-update-wins**. Doing that accurately needs new Supabase per-field change tracking and a separately approved database change. The current version introduces **no migration**.

## Security and operations

- The HubSpot API token is already stored in database Vault as \`HUBSPOT_ACCESS_TOKEN\`. The Edge Functions query it through a direct Postgres connection using \`SUPABASE_DB_URL\`. The actual token is never returned.
- A valid \`Authorization: Bearer <service-role-JWT>\` is required on each request and verified in the handler against \`SUPABASE_SERVICE_ROLE_KEY\`. Never invoke from a web browser or ship that token to clients.
- Reads are scoped to fixed \`brightside\` tables/views and HubSpot CRM endpoints. Inbound Postgres changes use one transaction per record and check the local modification stamp before writing. Outbound HubSpot PATCH is idempotent for repeated property assignments but is not a cross-system atomic transaction.
- The functions do not make any call or change anything until a **manual** authorized invocation.
- Max 5 records per invocation for bounded execution time. A partial apply response can include per-record failures requiring a fresh preview/reconciliation.

Review \`docs/manual-sync.md\` before running on your server. Validate with one known matching company and one contact and verify both systems afterward.
