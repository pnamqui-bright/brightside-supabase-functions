# Brightside Supabase Edge Functions

> **New on the Issue #1 feature branch:** manual **BULK-ONLY** bidirectional HubSpot ↔ Supabase synchronization. The supported CLI is now `hubspot-sync plan`, `hubspot-sync apply`, and `hubspot-sync resume`. There is no single-record/`--id` user workflow. Default bulk runs skip and report whole-record conflicts; `--force=pull` or `--force=push` is an explicit directional override. See **[the bulk sync guide](docs/bulk-sync.md)** for diagrams, limits, CLI usage, migration, and prerequisites. **Nothing in this branch is deployed and its migration is not applied.**

**Before using the bulk sync**, separately review and approve `migrations/20261013_bulk_sync_baseline.sql` (two nullable baseline columns and one trigger adjustment). The existing manual endpoints below remain for compatibility; the following original README sections describe their legacy five-record interface.

---

# Brightside Supabase Edge Functions

Manually operated HubSpot ↔ Supabase synchronization for Brightside's **self-hosted** Supabase instance.

The source code lives here, independently of the production Supabase Docker deployment. Cloning this repository onto a workstation **does not** mean Codex is working on the deployed server.

## Command-line client

A standalone, standard-library Python CLI is included for invoking either manual endpoint. The `bin/hubspot-sync` wrapper works after checkout on Linux with Python 3.9+:

```sh
./bin/hubspot-sync --help
./bin/hubspot-sync pull companies --limit 1 --env-file ../supabase/.env
./bin/hubspot-sync push companies --id YOUR_SUPABASE_COMPANY_ID --apply --env-file ../supabase/.env
```

Preview is the default. `--apply` requires explicit IDs, shows a fresh preview and prompts for confirmation; see the [full CLI reference](docs/cli.md). The script reads `SUPABASE_SECRET_KEY`, never requires a legacy service-role key, and sends credentials on the `apikey` header.


## Current behavior

| Function | Direction | Trigger |
| --- | --- | --- |
| [hubspot-webhook](functions/hubspot-webhook/index.ts) | HubSpot → Supabase | Authenticated manual HTTP POST only |
| [hubspot-manual-push](functions/hubspot-manual-push/index.ts) | Supabase → HubSpot | Authenticated manual HTTP POST only |

Despite its historical name, **hubspot-webhook is not an active webhook receiver**. Both functions default to read-only preview mode; updates require explicit action, confirmation and an unchanged preview hash. There is no cron, database trigger, or outbound scheduler.

**Only existing records linked through HubSpot `supabase_company_id`/`supabase_contact_id` are synced.** Contacts need a real HubSpot contact→company association matching the existing Supabase company; unmatched contacts are skipped without staging or creating associations. No records are created in either system.

See **[Manual operation and deployment](docs/manual-sync.md)** for payloads, examples, authorization, limits and troubleshooting. See **[Sync contract](docs/hubspot-sync-contract.md)** for mappings and conflict policy.

## Repository layout

```text
brightside-supabase-functions/
├── AGENTS.md                            # Portable Codex development instructions
├── deno.json
├── functions/
│   ├── hubspot-webhook/
│   │   ├── index.ts                     # Manual HubSpot → Supabase
│   │   └── lib/
│   │       ├── sync.ts                  # Shared sync engine and Vault access
│   │       └── decide.ts                # Conservative conflict decisions
│   └── hubspot-manual-push/
│       └── index.ts                     # Manual Supabase → HubSpot
├── tests/
│   └── conflicts_test.ts
├── deploy/
│   └── docker-compose.override.example.yml
└── docs/
    ├── hubspot-sync-contract.md
    └── manual-sync.md
```

## Install on the self-hosted server

```text
parent/
├── AGENTS.md                            # Server-specific production instructions
├── supabase/                            # Upstream self-hosted Docker deployment
│   ├── docker-compose.yml
│   └── volumes/functions/main/          # Required upstream router; keep it
└── brightside-supabase-functions/        # Git checkout of this repository
```

Clone the repo as a sibling of `supabase/`. Review [the Compose override example](deploy/docker-compose.override.example.yml) and merge the service mounts into your deployment's `docker-compose.override.yml`; **never overwrite existing overrides**. The example mounts both functions in the functions runtime and optionally Studio. The outbound function imports its shared library from the inbound function's directory, so **both function mounts must remain present**.

Validate and apply mounts **once**, from the Supabase deployment directory:

```sh
docker compose config --quiet
docker compose up -d --no-deps --force-recreate functions studio
```

If Docker cannot mount into Studio's pre-existing read-only functions directory, create the two corresponding placeholder directories inside `volumes/functions/`, or omit the optional `studio` overrides. Do not remove Supabase's original `./volumes/functions:/home/deno/functions` mount or built-in `main/index.ts` router.

For subsequent, explicitly approved updates of these two function sources:

```sh
git -C ../brightside-supabase-functions pull --ff-only
docker compose restart functions --no-deps
```

These commands are documentation. Git changes are not permission to deploy to production.

## Requirements

- Self-hosted Supabase function runtime with `SUPABASE_DB_URL` and `SUPABASE_SECRET_KEYS`, populated from Docker Compose `.env` variable `SUPABASE_SECRET_KEY`. Requests use the `apikey` header, **not** an `Authorization` Bearer token. If the runtime has `VERIFY_JWT=true`, this cannot work until the instance's JWT verification policy is adjusted; standard self-hosted Compose sets `FUNCTIONS_VERIFY_JWT=false` and the handler validates `apikey` itself.
- A valid HubSpot credential already present in database Vault as `HUBSPOT_ACCESS_TOKEN`.
- HubSpot CRM company/contact read/write and association-read permissions.
- A trusted backend or administrator capable of calling authenticated endpoints; **never** expose the Supabase secret API key to frontend code.
- Approval of each write through the preview/apply protocol.

The integration reads existing `brightside` base tables and HubSpot export views. **No database migration** is part of this repository version.

## Conflict-policy limitation

The current Supabase schema tracks the modified timestamp of each *record*, not each property. HubSpot exposes property history. When both sides have nonempty, different values, the functions compare a HubSpot property timestamp to the Supabase **record** timestamp and skip ambiguous or tied cases. This is a conservative approximation, **not exact per-field latest-update-wins**. Empty destinations can be filled, but populated fields are never cleared automatically. Protected consent, marketing-subscription and unrelated HubSpot fields are untouched.

## Tests

```sh
deno task check
deno test tests/
```

GitHub Actions runs the same static checks and unit tests on pushes. They do **not** test live credentials, networking or database writes. Always preview a known matched company and contact in your own deployment before approving changes.

[Official Supabase self-hosted Functions guide](https://supabase.com/docs/guides/self-hosting/self-hosted-functions).
