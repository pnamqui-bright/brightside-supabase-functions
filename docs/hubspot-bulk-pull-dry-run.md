# HubSpot bulk pull — hardcoded dry run

This is a **separate manual Edge Function** at `functions/hubspot-bulk-pull/index.ts`.
It does not change either existing manual pull/push endpoint.

**The current source contains `const DRY_RUN: boolean = true`.**
It does not write to HubSpot or Supabase. Do not disable this until you have
reviewed the report and explicitly decided to run the real pull.

## What it checks

- Reads **all** non-archived HubSpot companies and contacts via paginated CRM API calls.
- Matches companies by existing `supabase_company_id`, otherwise website domain;
  matches contacts by existing `supabase_contact_id`, otherwise email.
- Estimates Supabase parent records that would be **created** or **updated**,
  plus unchanged records. Existing company/contact associations are not repaired.
- A new contact requires an existing or pull-eligible Supabase company linked by
  explicit company ID or the HubSpot contact's existing company association.
  Unresolved contacts are reported and skipped. No dummy records are fabricated.
- Empty HubSpot values do not overwrite populated Supabase fields.
- For distinct populated values, uses HubSpot property history timestamps and
  Supabase record-level `hubspot_export_updated_at`. Only HubSpot values strictly
  newer than the Supabase record are considered safe updates. Older, tied, unknown,
  or ambiguous differences go into `conflicts`.
- Returns all conflict details (both values, IDs, property, timestamps, reason),
  plus a `skipped` list for unmatched/invalid records and an `errors` list.

The `summary` contains `wouldCreate`, `wouldUpdate`, `unchanged`,
`conflicts` (number of **records** with at least one conflicting field),
`conflictingFields`, `skipped`, and `scanned` for both companies and contacts.
`complete: true` indicates full pagination completed; a failed scan is not a
valid final total. The response itself contains `generatedAt` in UTC.

## Deploy to the self-hosted Edge Runtime

1. Pull this repository on the server. This does **not** deploy it automatically.
2. Add the new `hubspot-bulk-pull` volume mount from
   `deploy/docker-compose.override.example.yml` to the existing
   `functions` service in your deployment's `docker-compose.override.yml`.
   Keep the existing `hubspot-webhook` mount because the new function imports
   its authorization/conflict modules. Preserve the upstream function mounts.
3. From the deployment directory, check the merged configuration and recreate
   only the functions service when ready:

```sh
docker compose config --quiet
docker compose up -d --no-deps --force-recreate functions
```

The function needs `SUPABASE_DB_URL`, the existing Vault
`HUBSPOT_ACCESS_TOKEN`, and `SUPABASE_SECRET_KEYS` (or the configured
`SUPABASE_SECRET_KEY`). As with the existing manually authenticated
functions, self-hosted router JWT verification must allow the opaque-key
request through; the handler validates `apikey` itself.

## Invoke the dry run

Run from a trusted shell with `SUPABASE_SECRET_KEY` loaded in its environment:

```sh
curl --fail-with-body --silent --show-error --request POST \
  --header "apikey: $SUPABASE_SECRET_KEY" \
  --output "hubspot-bulk-pull-dry-run-$(date -u +%Y%m%dT%H%M%SZ).json" \
  "https://supabase.brightsidebrandstudio.com/functions/v1/hubspot-bulk-pull"
```

There is **no JSON body, query parameter, preview/apply step, ID list, or date
filter**. Dry run is hardcoded in the source; the endpoint ignores request bodies
and query parameters. The response JSON is the report: save it locally as shown.

A complete thousands-of-records scan can take time and is subject to HubSpot
rate limits and self-hosted Edge Runtime request/wall-time limits. If it times
out or fails, it has written **nothing** in the current dry-run configuration.
No claim is made that this has been live integration-tested.

## Later: enable actual writes

Only when separately requested, change `DRY_RUN` to `false` and redeploy
the same function. The write path creates parents/necessary child rows, updates
only safely mapped values, and skips/reports conflicts. It does not modify
HubSpot or alter contact-company associations.
