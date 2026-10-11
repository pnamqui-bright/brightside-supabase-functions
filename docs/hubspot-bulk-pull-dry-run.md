# HubSpot bulk pull — live execution

This manual Edge Function lives at `functions/hubspot-bulk-pull/index.ts`. The
existing `hubspot-webhook` and `hubspot-manual-push` functions are unchanged.

**Current setting: `const DRY_RUN: boolean = false`.**
An authenticated POST starts the full HubSpot → Supabase pull immediately.
It **does write** to Supabase. No body, CLI arguments, preview/apply steps, or
date filter are required.

## Behavior

- Pages through all non-archived HubSpot companies and contacts.
- Matches existing Supabase records by explicit linked IDs first, then by
  company website domain or contact email.
- Creates missing records when required information exists. Updates mapped
  fields when HubSpot is newer or Supabase has no value.
- Never clears populated Supabase values from empty HubSpot fields.
- Uses HubSpot property history against Supabase's parent-record timestamp to
  detect conflicts; conflicting fields are skipped and reported.
- Reports ambiguous matches and records missing required information; it
  does not invent company associations or repair existing relationships.
- Writes mapped changes into Supabase only. HubSpot is never modified.

Each JSON response includes a UTC `generatedAt`, an object-type summary,
`conflicts`, `skipped`, and `errors`. Summary keys named `wouldCreate` and
`wouldUpdate` refer to planned record counts; `applied` counts records whose
write method finished. `complete: true` means pagination reached the end.

If the function is interrupted or times out while live mode is on, **some
records may already have been committed** even without a complete report.
Re-running the function reconciles values again; no cross-record transaction
or checkpoint is implemented.

## Update the server and redeploy

Pull the repo in your existing checkout:

```sh
git pull --ff-only
```

The `hubspot-bulk-pull` bind mount must already exist under
`services.functions.volumes` in the deployment's
`docker-compose.override.yml`, as in
`deploy/docker-compose.override.example.yml`. The existing
`hubspot-webhook` mount is also required for imported helpers.

From the Supabase deployment directory, restart the runtime to load the
new source (no mount change is needed if the prior dry run appeared and ran):

```sh
docker compose restart functions
```

## Invoke the live pull

From a trusted shell with `SUPABASE_SECRET_KEY` available:

```sh
curl --fail-with-body --silent --show-error --request POST \
  --header "apikey: $SUPABASE_SECRET_KEY" \
  --output "hubspot-bulk-pull-live-$(date -u +%Y%m%dT%H%M%SZ).json" \
  "https://supabase.brightsidebrandstudio.com/functions/v1/hubspot-bulk-pull"
```

The function uses the existing Vault `HUBSPOT_ACCESS_TOKEN`,
`SUPABASE_DB_URL`, and Supabase's secret-key authentication. Its code has
been statically checked, but live database writes have not yet been
end-to-end verified in this environment.
