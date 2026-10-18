# HubSpot / Supabase unified sync cache

This is the **manual, reconciliation-first** cache path, separate from the legacy directional CLI sync. It does not send HubSpot updates or update normalized operational Supabase records.

## Seed / refresh entire inventories

Run in Supabase SQL editor as a privileged database role:

```sql
SELECT * FROM brightside.seed_hubspot_sync_cache();
```

For smaller transactions or clients with restrictive timeouts, run one entity at a time:

```sql
SELECT * FROM brightside.seed_hubspot_sync_cache('companies', 250);
SELECT * FROM brightside.seed_hubspot_sync_cache('contacts', 250);
```

* The function reads each HubSpot entity **once per invocation** through the foreign wrapper, validating the 10,000-row source cap and rejecting duplicate remote IDs.
* Company and contact IDs from **both** systems become a single deduplicated inventory, based on explicit `supabase_company_id` / `supabase_contact_id`. Company merge relationships canonicalize the Supabase company ID.
* The operation processes temporary ID batches using existing targeted refresh functions and writes only `brightside.hubspot_company_sync_cache` and `brightside.hubspot_contact_sync_cache`.
* Each cache row records source values, unresolved unified values, conflicting fields, canonical identifiers, source timestamps, `last_generated_at`, and `last_changed_at`. The generation time advances on refresh; the change time advances only when the cached values change.
* Cache records no longer present in either source are reported as `stale_cached` and **not deleted automatically**. A complete seed does not create, change, or delete operational company/contact records.
* The default argument `both` runs companies and contacts in one transaction. Running separately makes it easier to retry a single entity type.
* A client-side timeout does not necessarily mean PostgreSQL rolled back. **Check cached row counts and generation timestamps before rerunning.**

## Read the snapshot

```sql
SELECT * FROM brightside.hubspot_company_sync_view;
SELECT * FROM brightside.hubspot_contact_sync_view;
```

Both expose all currently agreed shared mapped fields as columns (23 company properties, 12 contact properties), plus source-value JSON and identity metadata.

Review unresolved conflicts, including original source values:

```sql
SELECT 'company' AS entity_type, sync_key, display_name, conflicting_fields,
       supabase_fields, hubspot_fields
FROM brightside.hubspot_company_sync_view WHERE status='conflict'
UNION ALL
SELECT 'contact', sync_key, display_name, conflicting_fields,
       supabase_fields, hubspot_fields
FROM brightside.hubspot_contact_sync_view WHERE status='conflict';
```

`status` values are:
* `conflict`: differing populated shared fields, ambiguous identity, or ambiguous source values; **requires manual agent review**.
* `no_conflict`: matched identity without unresolved disagreements; not a receipt or evidence of applied updates.
* `unmatched`: currently in only one store. Creation policy not yet defined.
* `not_found`: supplied ID did not exist during a targeted refresh.

Do **not** treat `status='no_conflict'` as proof of a needed write or confirmed delivery. No propagation to Supabase, HubSpot API update, CSV export, scheduling, or automatic conflict resolution is part of this seed.

## Initial full-seed verification (2026-10-18)

| Entity | Supabase source | HubSpot source | Cached identities | Conflict | No conflict | Unmatched |
|---|---:|---:|---:|---:|---:|---:|
| Companies | 3,928 | 3,313 | 3,707 | 89 | 2,872 | 746 |
| Contacts | 5,033 | 1,697 | 5,205 | 66 | 1,459 | 3,680 |

All Supabase company and contact identities were accounted for. The caches represent 3,313 distinct HubSpot company IDs and 1,697 distinct HubSpot contact IDs. Existing local merged company identities collapse into canonical rows.

Relevant migrations:
- `20261018_hubspot_sync_cache_06_seed_sources.sql`
- `20261018_hubspot_sync_cache_07_full_seed.sql`
- `20261018_hubspot_sync_cache_08_contacts_seed_fix.sql`
