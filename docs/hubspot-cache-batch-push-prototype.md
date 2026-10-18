# HubSpot cache batch-push prototype

**Review only: not deployed, not invoked; database migration unapplied.**

## Contract

New manually invoked Edge Function: `hubspot-cache-batch-push`.
POST preview defaults to no external network access and no writes:

```json
{"entity":"companies","limit":50,"action":"preview"}
```

Explicit apply, when separately approved and deployed:

```json
{"entity":"companies","limit":50,"after":"","action":"apply","previewHash":"<hash returned by preview>","confirm":"APPLY"}
```

Use the same schema for `contacts`. Batch size 1–100. `after` is an optional sync-key cursor; reuse the exact cursor and limit between a preview and its apply. Success receipts allow successive calls to select the next pending batch without resending the previous successful batch. A returned `nextCursor` lets the operator advance past blocked candidates.

Calls require an opaque Supabase `sb_secret_` key in the `apikey` request header. The runtime obtains the HubSpot token from Supabase Vault. Apply is disabled unless the server-side `HUBSPOT_CACHE_PUSH_ENABLE_WRITES=true` flag is explicitly configured; the default is disabled.

## Field and record boundaries

- Reads `brightside.hubspot_company_sync_view` or `brightside.hubspot_contact_sync_view`. Only `status='no_conflict'` and `identity_status='matched'` can be selected.
- Candidate properties must have a populated unified value and a blank cached HubSpot value. Never overwrite a nonblank differing HubSpot value.
- Company mapped fields: name, domain, phone, address, address2, city, state, zip, country, website, employee count, founded year, LinkedIn/Facebook/Instagram/TikTok/X/Pinterest URLs, Supabase score, maturity, ICP vertical, revenue tier, last prospect scan.
- Contact mapped fields: first/last name, email, phone, job title, seniority, LinkedIn URL, role category, contact/email provenance, Supabase company-ID property (custom property, not an association).
- Fills missing HubSpot custom `supabase_company_id` and `supabase_contact_id` properties from exact matched external IDs; includes the deterministic HUB-IDs created during the completed inbound sync.
- Does not create HubSpot records, infer matches from domains/emails, create company associations, alter contact `company` display text, or edit consent, legal basis, lifecycle, owners, deals, and unrelated CRM fields.
- Live HubSpot enum options were inspected 2026-10-18; the prototype uses a fixed allowlist and fails closed on unsupported values. Revalidate before first apply.

## Verification and idempotency

1. Preview returns ordered record/property changes, snapshot versions, problem flags, a SHA-256 previewHash and optional nextCursor. Preview does not contact HubSpot.
2. Apply recomputes the same previewHash from current cache, and requires `confirm=APPLY` plus the separately enabled write flag.
3. Check the operational Supabase parent timestamp equals the cached source timestamp; also recheck just before any HubSpot write.
4. Batch-read existing HubSpot records to compare live values and `updatedAt` against the cache version. Reject newer nonblank values and unknown/changed timestamps; mark already-aligned values without patching.
5. Use HubSpot v3 batch/update (maximum 100 inputs). Do not automatically retry an ambiguous POST failure.
6. Only an exact, complete HubSpot success response may advance the new `hubspot_last_applied_version` and `hubspot_last_applied_at` columns in the cache. A partial response does not create a delivery receipt.
7. The cache's `last_changed_at` is the applied version, so unchanged refreshes do not repeat sends. The batch cursor also permits advancing past skipped records.

HubSpot remote writes and Postgres receipts cannot commit atomically. If HubSpot succeeds and receipt storage fails, do a fresh read/reconciliation before attempting another apply. There is also a race between the final preflight and a remote HubSpot update; no remote compare-and-swap is available.

## Source-only files

- `migrations/20261018_hubspot_cache_push_01_delivery_marker.sql` — NOT applied.
- `functions/hubspot-cache-batch-push/index.ts` — NOT deployed or invoked.
- `functions/hubspot-cache-batch-push/lib.ts` — pure planning/validation.
- `tests/hubspot_cache_batch_push_test.ts` — isolated unit tests (no live API calls).
- `deno.json` — static check includes this endpoint.
- `deploy/docker-compose.override.example.yml` — prototype mount example is commented out.

**Before approving live use:** run Deno static checks/unit tests in a development environment; review known-company and known-contact preview; verify portal enum options and HubSpot API scopes; separately approve the migration, bind mount, function deployment, write-enable flag, and first manual apply. Do not schedule anything as part of this prototype.