# Agent instructions — development repository

This repository contains source code for self-hosted Supabase Edge Functions. **Never assume this checkout is on the production server.** The default is an isolated development workspace.

- The authoritative production infrastructure instructions live in the server's separate parent-level AGENTS.md. Do not copy that file into this repository or infer deployment access from this repository.
- Never deploy, restart containers, modify production Compose files, update database schemas, or write live HubSpot/Supabase CRM records without explicit user authorization and verified environment context.
- Production target, when explicitly approved: self-hosted Supabase at https://supbase.brightsidebrandstudio.com. Treat this as a **target identifier**, not as evidence you're running there.
- Keep Supabase's installed `volumes/functions/main/index.ts` and its original directory mount intact. This repo owns custom function subdirectories only.
- Secrets belong in Supabase Vault. Never commit, print, or transmit decrypted secrets to logs or examples. Use restricted server-side access.
- Any functions implementing CRM synchronization must be safe by default, authenticated, idempotent, tested with fixtures, and explicitly enabled.
- HubSpot → Supabase synchronization is automatic once deliberately configured; Supabase → HubSpot is **manual only**. No automatic outbound syncing or hidden scheduled jobs.
- Skip contacts without a company association **in both directions**. Do not invent associations or stage orphan records.
- For shared writable properties, use latest-per-field-update-wins only where reliable field-level timestamps are known; otherwise report conflicts or skip instead of claiming precision.
- Never automatically overwrite legal consent, source provenance, computed prospect scores, IDs, or unmapped properties.
- Keep PRs and commits narrowly scoped. Document behavior and production prerequisites honestly.

## Initial state
The initial `hubspot-webhook` and `hubspot-manual-push` entrypoints intentionally return 501. Implementing these is future work, not an implicit part of repository setup.
