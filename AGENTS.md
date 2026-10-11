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
