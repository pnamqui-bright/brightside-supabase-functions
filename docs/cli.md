# hubspot-sync: command-line reference

A standalone **Python 3.9+** CLI for the two **manual** self-hosted Supabase Edge Functions. Uses only the Python standard library; no pip install and no new Supabase migration.

## Start here

Clone/pull the `pnamqui-bright/brightside-supabase-functions` repository. In the repository root:

```sh
./bin/hubspot-sync --help
./bin/hubspot-sync --version
```

On the self-hosted server where the existing Supabase installation is in a sibling `supabase/` folder:

```sh
# From the brightside-supabase-functions/ repo directory:
./bin/hubspot-sync pull companies --limit 1 --env-file ../supabase/.env
./bin/hubspot-sync push companies --limit 1 --env-file ../supabase/.env
```

If you prefer to run it from your Supabase deployment directory, use:

```sh
python3 ../brightside-supabase-functions/scripts/hubspot_sync.py \
  pull companies --limit 1 --env-file .env
```

You can also export `SUPABASE_SECRET_KEY` into the environment and omit `--env-file`. Explicit `--env-file` overrides the environment variable. It must contain your opaque `sb_secret_...` key, not a service-role JWT.

The CLI sends it exclusively in the HTTPS `apikey` header; it never prints the key or puts it in a URL. Don't pass credentials as CLI arguments, and don't use the privileged key from a browser frontend.

## Syntax

```text
hubspot-sync {pull|push} {companies|contacts}
  [--id RECORD_ID ... | --cursor OPAQUE_CURSOR]
  [--limit 1..5] [--show-skipped] [--json]
  [--apply] [--yes]
  [--env-file PATH] [--url HTTPS_BASE_URL] [--timeout SECONDS]
```

| Parameter | Meaning |
| --- | --- |
| `pull` | Invoke `hubspot-webhook` manually: HubSpot → Supabase |
| `push` | Invoke `hubspot-manual-push` manually: Supabase → HubSpot |
| `companies` / `contacts` | Sync entity type |
| `--id RECORD_ID` | Explicit record; repeat for up to 5 IDs. `pull` takes **HubSpot numeric IDs**, `push` takes **Supabase external IDs** |
| `--cursor TOKEN` | Preview the next page using a returned `nextCursor` (cannot combine with `--id`) |
| `--limit 1..5` | Page size when no IDs supplied (default 5); the function caps requests to 5 |
| `--show-skipped` | Show excluded fields and skip reasons in human-readable previews |
| `--json` | Print the full JSON response; may contain CRM contact data |
| `--apply` | Make a **fresh preview**, review it, and apply it using the returned `previewHash` (requires explicit IDs) |
| `--yes` | Skip the interactive confirmation for automation. **Requires `--apply` with explicit IDs** |
| `--env-file PATH` | Read `SUPABASE_SECRET_KEY` from an existing local .env file |
| `--url URL` | Supabase base URL (default: `https://supabase.brightsidebrandstudio.com`) |
| `--timeout SECONDS` | Per-request timeout; default 120 seconds |
| `--allow-http` | Permit `http://localhost` for **local testing only**, not public hosts |
| `--help` / `--version` | Print syntax and version without requiring credentials |

## Examples

Preview one HubSpot company by its HubSpot record ID:

```sh
./bin/hubspot-sync pull companies --id 123456789 --env-file ../supabase/.env
```

Preview two Supabase contacts before a possible HubSpot update:

```sh
./bin/hubspot-sync push contacts --id abc123 --id def456 \
  --show-skipped --env-file ../supabase/.env
```

Preview a page and obtain a cursor:

```sh
./bin/hubspot-sync pull contacts --limit 5 --json \
  --env-file ../supabase/.env
./bin/hubspot-sync pull contacts --cursor 'NEXT_CURSOR' \
  --limit 5 --env-file ../supabase/.env
```

Apply a **specific reviewed** Supabase company to HubSpot. This fetches a fresh preview, prints proposed changes, and prompts you to type `APPLY` before making the second HTTP request:

```sh
./bin/hubspot-sync push companies --id abc123 --apply \
  --env-file ../supabase/.env
```

In a trusted, automated admin workflow you can add `--yes` to bypass the prompt. It will still request a new preview and send `confirm: APPLY` plus the calculated `previewHash`. For noninteractive JSON output, use both `--apply --yes --json`.

## Operational limits and safeguards

- **Preview is always the default**; there is no scheduled sync.
- **Apply always needs explicit IDs**, max five per call. A paged preview is intentionally not a mass-apply operation.
- Updates are limited to records already matched by Supabase external IDs. Neither endpoint creates new contacts or companies.
- Contacts without matching verified company associations are skipped; no orphan records are staged or assigned.
- This implementation uses HubSpot per-property history with Supabase record-level timestamps as a conservative conflict fallback. It is **not** exact per-field latest-update-wins until Supabase-side field history exists.
- HTTP 409 indicates a stale preview; run the command again. HTTP 401 usually indicates an incorrect key or server auth configuration. HTTP 503 often indicates a boot or runtime error.
- Standard self-hosted Supabase should have `FUNCTIONS_VERIFY_JWT=false` for opaque `apikey` requests. Verify before changing it, because that setting affects all functions; the handlers independently validate secret keys.
- Human-readable previews show changed values. JSON output includes CRM data. Treat terminal output and redirected files accordingly.

See [the underlying synchronization runbook](manual-sync.md). CI tests invoke a local fake HTTP server, **not** production Supabase or HubSpot.
