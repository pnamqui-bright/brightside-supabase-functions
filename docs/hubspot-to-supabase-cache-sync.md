# Cache-based HubSpot -> Supabase propagation

## Deployed stored functions

```sql
-- Read-only previews are the default:
SELECT * FROM brightside.sync_hubspot_companies_to_supabase();
SELECT * FROM brightside.sync_hubspot_contacts_to_supabase();

-- Apply all eligible inbound updates from the LAST GENERATED CACHE:
SELECT * FROM brightside.sync_hubspot_companies_to_supabase(false);
SELECT * FROM brightside.sync_hubspot_contacts_to_supabase(false);

-- Refresh reconciled source snapshots after applying:
SELECT * FROM brightside.seed_hubspot_sync_cache('companies',250);
SELECT * FROM brightside.seed_hubspot_sync_cache('contacts',250);
```

**The sync writes to Supabase operational tables only.** No HubSpot API calls, scheduling, auto triggers, domain or email deduplication, company/contact association lookup, or cross-source conflict resolution.

Both functions use `brightside.hubspot_company_sync_view` or `brightside.hubspot_contact_sync_view`, and accept only `status='no_conflict'` matched rows plus `identity_status='hubspot_only'` rows eligible for creation. Rows marked `conflict` are excluded wholesale for agent review.

A matched row is skipped if its Supabase parent modification timestamp differs from `supabase_source_updated_at` stored in the snapshot. Nonblank inbound values fill or agree with local values; empty values never delete or overwrite local data. Existing normalized children are updated only when exactly one child row belongs to the parent; if no child exists it receives an ID derived from the HubSpot ID, without matching by domain/email. Multiple child rows are preserved and not guessed between.

## Deterministic IDs and identity mapping

- New company external ID: `HUB-<hubspot company id>` (example `HUB-215904971762`).
- New contact external ID: `HUB-CONTACT-<hubspot contact id>` **only** when HubSpot's explicit `supabase_company_id` references an existing Supabase company.
- Children use `HUB-DOMAIN-<id>`, `HUB-PHONE-<id>`, `HUB-LOCATION-<id>`, `HUB-WEBSITE-<id>`, `HUB-CHANNEL-<id>`.
- There is NO domain/name/email deduplication or inference of contact-company relationships.
- Targeted reconciliation functions and full seed recognize the synthetic external IDs when that exact ID exists in Supabase, even if HubSpot's `supabase_company_id` / `supabase_contact_id` custom property has not been populated yet.
- New cache rows are promoted from `h:<id>` to `s:HUB-<id>`; subsequent full seeds preserve one identity per record.

## Writable mappings

Company parent: `company_name` from `name`, `employee_count_best` from `numberofemployees`, `founded_year` from `founded_year`.

Company normalized children:
- `company_domains.domain` from `domain`;
- `company_phone_numbers.phone` from `phone`;
- `company_locations.street_address_1`, `street_address_2`, `city`, `state_province`, `postal_code`, `country` from `address`, `address2`, `city`, `state`, `zip`, `country`;
- `company_websites.website_url` from `website`.

Contact parent: `first_name`, `last_name`, `job_title`, `seniority`, `role_category` from HubSpot's corresponding properties. For **new contacts only**, `full_name` is formed from first and last names and `company_external_id` is taken from the validated explicit `supabase_company_id`.

Contact child: `contact_channels.email`, `phone`, `linkedin_url` from `email`, `phone`, `hs_linkedin_url`.

Supabase-owned research, marketing maturity, ICP, prospect scores, social profiles and contact provenance fields are NOT overwritten from HubSpot. CRM lifecycle, owner, legal basis, consent, unrelated data, and associations remain untouched.

## Initial authorized full run (2026-10-18)

Dry run:
- 2,872 existing matched companies eligible, including 1,325 with inbound differences; 352 new HubSpot-only companies eligible for creation; 89 company conflicts skipped; no locally stale company rows.
- 1,459 existing matched contacts eligible, including 5 with inbound differences; **0 HubSpot-only contacts eligible for creation**: all 172 HubSpot-only contacts lacked an explicit `supabase_company_id`. 66 conflicts skipped; no locally stale contact rows.

Applied results:
- 352 companies created, 1,324 existing company parent rows updated.
- Of the new companies, 65 have a blank HubSpot company name and were created with NULL `company_name` (per Supabase's nullable schema); these may need later CRM data quality review.
- Child rows: 239 domains created; 259 phones created, 1 updated; 197 locations created, 2 updated; 239 websites created.
- 5 existing contact channels updated; 0 contacts created.
- 352 HubSpot-only company cache identities promoted to canonical Supabase IDs.
- No HubSpot records were modified.

After re-seeding both entity caches, a new dry run returned **0 companies to create**, **0 matched companies with inbound differences**, **0 contacts to create**, **0 matched contacts with inbound differences**, and **0 stale Supabase source rows**.

Post-run inventories:
- `brightside.companies`: 4,280 rows (352 with `HUB-` external IDs).
- `brightside.contacts`: 5,033 rows.
- Company cache: 3,707 distinct identities (3,224 no conflict, 89 conflict, 394 Supabase-only).
- Contact cache: 5,205 distinct identities (1,459 no conflict, 66 conflict, 172 HubSpot-only, 3,508 Supabase-only).

HubSpot's custom external-ID properties still need the separate Supabase -> HubSpot propagation implementation if they are to be filled. The cache's deterministic fallback does not require those properties for its next seed.

## Migrations

1. `20261018_hubspot_to_supabase_01_synthetic_identity.sql`
2. `20261018_hubspot_to_supabase_02_company_upsert.sql`
3. `20261018_hubspot_to_supabase_03_contact_upsert.sql`
