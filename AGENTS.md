# Codex instructions — Edge Functions SOURCE repository

This repository is portable development source for Brightside's self-hosted Supabase Edge Functions. **Never assume a checkout is running on the deployed server.** Development/test is the default. The server's parent-level AGENTS.md separately governs its production Supabase deployment; do not duplicate or override it.

## Deployment rules
- Never push code to a running server, restart Docker, change Docker Compose, modify production tables, execute a manual sync in "apply" mode, or write CRM records without explicit user authorization and a verified production context.
- Production, if explicitly authorized, is the self-hosted service identified as https://supabase.brightsidebrandstudio.com. Its address does not mean this checkout has access to production.
- Preserve Supabase's original `volumes/functions/main/index.ts` router and base bind mounts. Only custom function subdirectories are owned by this repo.
- The manual outbound endpoint imports shared code from `hubspot-webhook/lib`; keep both sibling bind mounts deployed.
- Before shipping, run `deno task check` and `deno test tests/`. These are unit/static checks and do not establish live compatibility.

## Integration contract
- **Both directions are MANUAL ONLY for now.** `hubspot-webhook` is a historical name; it is not configured as an automatic webhook.
- The only authorized caller is a trusted backend/admin with the opaque Supabase `sb_secret_...` API key on the `apikey` header, never `Authorization: Bearer`. In self-hosted Docker Compose, `SUPABASE_SECRET_KEY` becomes `SUPABASE_SECRET_KEYS` for Edge Runtime. Auth is verified in the handler. Default operation is preview; apply requires exact IDs, `previewHash`, and `confirm: "APPLY"`.
- Never log, commit, return or duplicate decrypted secrets. HubSpot credentials belong in database Vault under `HUBSPOT_ACCESS_TOKEN`.
- Only sync records with exact HubSpot Supabase external ID links. Do not create companies or contacts; do not match by guesswork.
- **Skip contacts without a verified company association in both systems.** No orphan staging, arbitrary association creation, or inferred associations.
- Never modify HubSpot marketing consent/legal basis, unrelated associations or properties, or other unmapped fields.
- HubSpot property timestamps are available, but Supabase currently has record-level timestamps only. Apply conservative conflict rules and skip uncertain overwrites; do not claim exact per-field latest-update-wins.
- Preserve existing related records and IDs. Inbound child-field updates need one existing unambiguous child row. Empty source fields never delete destination values.
- No automatic inbound webhook subscriptions, no triggers, no cron, and no background data push.

See `docs/manual-sync.md` for request contracts and `docs/hubspot-sync-contract.md` for field mappings/limitations.

## New bulk-only workflow (Issue #1)

The primary CLI interface is `hubspot-sync plan | apply | resume` for **full dataset** reconciliation; there is no new targeted/single-ID user interface. The `hubspot-bulk-plan` endpoint is read-only, and `hubspot-bulk-execute` accepts bounded ID batches exclusively as an internal CLI transport. Keep the legacy five-ID endpoints working; their preview/hash contract above is legacy-only.

The new inbound **bulk** path may create unmatched HubSpot objects in Supabase, reusing deterministic IDs and requiring verified contact-company links. It **never** creates outbound HubSpot objects. The original integration contract's no-creation rule applies to the legacy targeted endpoints, not this approved bulk feature.

Record conflicts are **whole-record**: if both sides changed since that record's successful sync, skip and report it, even when different fields changed. When the baseline is NULL, differing populated bidirectional values are also conflicts; equal values and safe blank fills may bootstrap. No column-level timestamps/merges. `--force=pull` or `--force=push` is an explicit directional override, not conflict resolution.

The proposed `migrations/20261013_bulk_sync_baseline.sql` adds one nullable `hubspot_last_synced_at` to each parent and updates the existing timestamp trigger. **Do not apply this migration or deploy the Edge Functions to production without separate explicit approval.** See `docs/bulk-sync.md` for diagrams and operational details.
