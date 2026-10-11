# Manual HubSpot / Supabase sync — operator runbook

**Both functions are manual only.** Neither endpoint accepts unauthenticated HubSpot webhooks, runs on a schedule, or initiates synchronization on deployment.

## Endpoints

| Direction | Endpoint | IDs in request |
| --- | --- | --- |
| HubSpot → Supabase | `/functions/v1/hubspot-webhook` | HubSpot numeric company/contact IDs |
| Supabase → HubSpot | `/functions/v1/hubspot-manual-push` | Supabase external company/contact IDs |

For a self-hosted installation whose public URL is `https://supbase.brightsidebrandstudio.com`, prepend that address to the paths.

Each endpoint requires a POST request with a **server-side Supabase service-role JWT** as `Authorization: Bearer ...`. Never put this credential in client-side web applications or source control. The installed self-hosted function service provides `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_DB_URL`. The HubSpot credential is read at invocation time from Supabase Vault under `HUBSPOT_ACCESS_TOKEN`. Function requests are reauthenticated inside the handler even if the API gateway also validates JWTs.

## Safe preview first

On a trusted server with the service-role token already held in an environment variable called `SERVICE_ROLE_KEY`:

```sh
curl -sS 'https://supbase.brightsidebrandstudio.com/functions/v1/hubspot-webhook' \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"action":"preview","objectType":"companies","ids":["HUBSPOT_COMPANY_ID"]}'
```

The response contains `records`, a full proposed per-property diff, skip reasons, and a `previewHash`. For example, each property indicates `before`, `after`, `action`, and `reason`. **Review these values before applying.**

To preview a small page without explicit IDs, omit `ids` and optionally specify `limit` (1–5) and `cursor`:

```json
{"action":"preview","objectType":"contacts","limit":5}
```

The response includes the selected `records[].id` values and possibly a `nextCursor`. **An apply request always requires explicit IDs**, even after a paged preview.

## Apply an approved preview

Use the **same endpoint and exact IDs**, with the hash returned by the preview:

```json
{
  "action": "apply",
  "objectType": "companies",
  "ids": ["HUBSPOT_COMPANY_ID"],
  "previewHash": "64_character_hash_from_preview",
  "confirm": "APPLY"
}
```

If the proposed changes have changed between preview and apply, the endpoint rejects the batch with HTTP 409. A preview does not write anything. An apply writes only properties marked `action: "update"`. Partial errors may return HTTP 207 with individual outcomes. Re-preview any batch with errors.

For Supabase → HubSpot, use `hubspot-manual-push` and supply **Supabase external IDs** instead.

## Matching and safety rules

- Only update records **already linked by exact `supabase_company_id` or `supabase_contact_id`** in HubSpot. Neither direction creates companies or contacts.
- A contact requires its existing Supabase company FK **and** a verifiable actual HubSpot contact→company association pointing to a HubSpot company with the same Supabase company ID. Otherwise it is skipped. There is **no orphan staging** or association creation.
- Only mapped properties are touched. Empty source properties **never erase** populated destinations; unmatched and ambiguous multiple child records are skipped.
- The existing Supabase export views supply the fields; child-row updates require exactly one existing child row (no guessed new IDs). Computed scores, maturity, revenue tier, ICP vertical, social URLs, and provenance can be pushed to HubSpot but are **not pulled into Supabase** in this first version. Legal basis, consent, lifecycle, ownership and unrelated CRM fields are never changed.
- The existing Supabase `hubspot_export_updated_at` is a **record-level** timestamp. HubSpot exposes property history. Nonempty-vs-nonempty conflicts use the HubSpot property timestamp against the Supabase whole-record timestamp, so this is a conservative **approximation**, *not* precise per-property latest-update-wins. Missing/tied timestamps are skipped. No migration is installed.
- HubSpot enum/dropdown values are checked against the configured option sets. Unsupported Supabase values are marked `unsupported_hubspot_dropdown_value` and skipped individually rather than aborting the entire HubSpot PATCH. Re-check those option sets if you change your CRM properties.
- Company/contact update batches are intentionally capped at **5 records per invocation** to fit self-hosted Edge Runtime time limits.
- This code has no automated webhook subscription or automatic outbound push. Later automation would require separate authorization, verification and design.

## Self-hosted deployment

In the server's Supabase deployment directory, with the sibling checkout `../brightside-supabase-functions` already bind-mounted for both functions:

```sh
git -C ../brightside-supabase-functions pull --ff-only
docker compose restart functions --no-deps
```

The manual push imports the shared library from the sibling `hubspot-webhook/lib` directory; **both mounts are necessary**.

## Operational checks

1. Run the GitHub validation workflow or `deno task check && deno test tests/` on a development machine.
2. Confirm the existing Vault `HUBSPOT_ACCESS_TOKEN` is current and has HubSpot CRM read/write scopes and association-read access.
3. Confirm your self-hosted function runtime has `SUPABASE_DB_URL` and `SUPABASE_SERVICE_ROLE_KEY` (do **not** reveal their values).
4. Preview a single known matched company; inspect mapped property differences and skip reasons.
5. Apply only after reviewing, then confirm the changed property in both systems. Repeat with a known associated contact before larger batches.
6. Do not enable automatic webhooks, cron jobs or the HubSpot subscription manager for these endpoints.

Any future per-field accuracy work would require adding Supabase-side per-property tracking, after review and approval.
