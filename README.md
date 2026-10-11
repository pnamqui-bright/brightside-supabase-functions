# Brightside Supabase Edge Functions

Custom TypeScript/Deno Edge Functions for Brightside's **self-hosted** Supabase deployment.

This repository is portable development source code, **not** a copy of the production Supabase installation. A checkout on a workstation is never assumed to be running in production.

## Current status

The repository starts with **disabled scaffolds**:
- `functions/hubspot-webhook/index.ts` — intended for automatic HubSpot → Supabase updates.
- `functions/hubspot-manual-push/index.ts` — intended for explicitly triggered Supabase → HubSpot updates.

Both currently return HTTP **501 Not Implemented** and **do not read or write CRM data**. Creating or mounting these files does not activate synchronization.

See [the sync contract](docs/hubspot-sync-contract.md) for requirements that must be implemented and tested before activation.

## Layout

```text
brightside-supabase-functions/     # This Git repository
├── AGENTS.md                      # Development instructions for Codex
├── deno.json
├── functions/
│   ├── hubspot-webhook/index.ts
│   └── hubspot-manual-push/index.ts
├── deploy/
│   └── docker-compose.override.example.yml
└── docs/
    └── hubspot-sync-contract.md
```

## Install alongside the self-hosted Docker stack

The example below assumes these sibling directories on your server:

```text
parent/
├── AGENTS.md                      # Server-specific production instructions
├── supabase/                      # Upstream self-hosted Docker deployment
│   ├── docker-compose.yml
│   └── volumes/functions/main/    # Keep Supabase's built-in router
└── brightside-supabase-functions/  # Checkout of this repo
```

1. Clone this repo **beside**, not inside, the `supabase/` deployment directory.
2. Review `deploy/docker-compose.override.example.yml`. Merge its service mounts into `supabase/docker-compose.override.yml`; **do not overwrite an existing override**. Paths are relative to the directory containing the base Compose file.
3. Verify the Compose service names and container paths against your installed Supabase version. The example uses `functions` and `studio`, with current upstream paths `/home/deno/functions` and `/app/edge-functions` respectively.
4. From the `supabase/` deployment directory, validate and apply the new mounts:

```sh
docker compose config --quiet
docker compose up -d --no-deps --force-recreate functions studio
```

The override bind-mounts each custom function into the existing functions tree and, optionally, the Studio UI. It **does not replace** `volumes/functions/main/` or the upstream function router.

After a future, **authorized** production rollout, update the server checkout to an approved revision and reload the functions service:

```sh
git -C ../brightside-supabase-functions pull --ff-only
docker compose restart functions --no-deps
```

These commands are documentation, not an automatic deployment pipeline. No repository change should be treated as permission to run them against production.

## Development

Use Deno and run `deno task check` to type-check the functions. Do not store production credentials or test against live CRM data by default.

## Secrets and security

The HubSpot token is already stored as `HUBSPOT_ACCESS_TOKEN` in the self-hosted database's Supabase Vault. Keep Vault as the source of truth; do not copy tokens into Git, files, or chat. The future functions will require **restricted server-side Vault access**, webhook signature verification, and authenticated manual execution. The scaffolds deliberately implement none of these yet.

## Reference

[Supabase's self-hosted Edge Functions guide](https://supabase.com/docs/guides/self-hosting/self-hosted-functions).
