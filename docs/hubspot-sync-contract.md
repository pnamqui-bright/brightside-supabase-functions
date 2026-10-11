# HubSpot ↔ Supabase sync contract

**Status: Specification only. The two functions presently return HTTP 501 and perform no sync.**

## Operational direction
- HubSpot → Supabase: automatic once a real HubSpot webhook application, verified signatures, mapping, and processing are configured.
- Supabase → HubSpot: **only when expressly manually triggered**, after a preview and authorization. Do not create DB triggers or schedules that push to HubSpot.
- Skip contacts that have no company association. Never synthesize, stage, or guess a company association. Preserve existing legitimate associations and unrelated fields.
- For fields shared by both systems, the last **actual field update** wins. HubSpot property history and Supabase record-level `hubspot_export_updated_at` are *not* inherently equivalent per-field timestamps.
- When neither side has a reliable per-field timestamp, flag/skip the field pending reconciliation, rather than silently overwriting.
- Never automatically infer lawful marketing consent from a published email address; preserve consent and legal-basis properties unless explicitly mapped and approved.

## Credentials
- Existing token is named `HUBSPOT_ACCESS_TOKEN` in Supabase Vault on the self-hosted instance.
- Vault is encrypted storage inside Postgres, **not** a Deno environment-variable service. A narrowly scoped SQL RPC or backend database connection is needed for the function to access it; do not expose `vault.decrypted_secrets` to API callers.
- Do not return, print, or commit token values. Webhook verification secrets should also be stored securely, with independent rotation.
- Verify HubSpot webhook signatures and reject stale/replayed events. Authenticate and authorize every manual sync invocation.

## Before enabling writes
1. Inspect HubSpot object/property types, app webhook support and permissions, associations, and the existing `brightside` Postgres schema.
2. Define field mappings, deduplication keys, per-field history or conservative conflict fallback, and records eligible for synchronization.
3. Test replay, deletion policies, rate limits, idempotency, partial failures, and skipping orphan contacts.
4. Decide whether auxiliary audit/conflict tables are needed, and preview any proposed migrations before applying them.
5. Obtain explicit approval before production rollout; validate with a small controlled matched set and verify results.

## Note on the code layout
The functions are intentionally separate from the upstream `volumes/functions/main` router. This repo can be cloned on a workstation without production access.
