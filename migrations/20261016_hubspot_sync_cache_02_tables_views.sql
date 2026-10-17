-- Persisted reconciled SOURCE snapshots. No changes to CRM or operational company/contact tables.
-- Each row preserves both source values, all shared mapped fields, unresolved conflicts,
-- source modification stamps, and its last generation/change time.
CREATE TABLE IF NOT EXISTS brightside.hubspot_company_sync_cache (
  sync_key text PRIMARY KEY,
  supabase_id text,
  hubspot_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  requested_supabase_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  requested_hubspot_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  identity_status text NOT NULL,
  display_name text,
  supabase_fields jsonb NOT NULL DEFAULT '{}'::jsonb,
  hubspot_fields jsonb NOT NULL DEFAULT '{}'::jsonb,
  unified_fields jsonb,
  conflicting_fields text[] NOT NULL DEFAULT ARRAY[]::text[],
  hubspot_records jsonb NOT NULL DEFAULT '[]'::jsonb,
  supabase_source_updated_at timestamptz,
  hubspot_source_updated_at timestamptz,
  last_generated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS hubspot_company_sync_cache_changed_idx ON brightside.hubspot_company_sync_cache (last_changed_at);

CREATE TABLE IF NOT EXISTS brightside.hubspot_contact_sync_cache (
  sync_key text PRIMARY KEY,
  supabase_id text,
  hubspot_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  requested_supabase_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  requested_hubspot_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  identity_status text NOT NULL,
  display_name text,
  supabase_fields jsonb NOT NULL DEFAULT '{}'::jsonb,
  hubspot_fields jsonb NOT NULL DEFAULT '{}'::jsonb,
  unified_fields jsonb,
  conflicting_fields text[] NOT NULL DEFAULT ARRAY[]::text[],
  hubspot_records jsonb NOT NULL DEFAULT '[]'::jsonb,
  supabase_source_updated_at timestamptz,
  hubspot_source_updated_at timestamptz,
  last_generated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS hubspot_contact_sync_cache_changed_idx ON brightside.hubspot_contact_sync_cache (last_changed_at);

-- Views expose EVERY agreed shared mapped property as an explicit selectable column.
CREATE OR REPLACE VIEW brightside.hubspot_company_sync_view
WITH (security_invoker=true) AS
SELECT
  cache.sync_key,
  cache.supabase_id AS supabase_external_id,
  CASE WHEN cardinality(cache.hubspot_ids)=1 THEN cache.hubspot_ids[1] END AS hubspot_id,
  cache.hubspot_ids,
  cache.identity_status,
  cache.display_name,
  cache.conflicting_fields,
  cache.supabase_source_updated_at,
  cache.hubspot_source_updated_at,
  cache.last_generated_at,
  cache.last_changed_at,
  cache.unified_fields ->> 'name' AS "name",
  cache.unified_fields ->> 'domain' AS "domain",
  cache.unified_fields ->> 'phone' AS "phone",
  cache.unified_fields ->> 'address' AS "address",
  cache.unified_fields ->> 'address2' AS "address2",
  cache.unified_fields ->> 'city' AS "city",
  cache.unified_fields ->> 'state' AS "state",
  cache.unified_fields ->> 'zip' AS "zip",
  cache.unified_fields ->> 'country' AS "country",
  cache.unified_fields ->> 'website' AS "website",
  cache.unified_fields ->> 'numberofemployees' AS "numberofemployees",
  cache.unified_fields ->> 'linkedin_company_page' AS "linkedin_company_page",
  cache.unified_fields ->> 'facebook_company_page' AS "facebook_company_page",
  cache.unified_fields ->> 'instagram_url' AS "instagram_url",
  cache.unified_fields ->> 'tiktok_url' AS "tiktok_url",
  cache.unified_fields ->> 'prospect_score_supabase' AS "prospect_score_supabase",
  cache.unified_fields ->> 'marketing_maturity_supabase' AS "marketing_maturity_supabase",
  cache.unified_fields ->> 'icp_vertical' AS "icp_vertical",
  cache.unified_fields ->> 'revenue_tier' AS "revenue_tier",
  cache.unified_fields ->> 'last_prospect_scan' AS "last_prospect_scan",
  cache.unified_fields ->> 'founded_year' AS "founded_year",
  cache.unified_fields ->> 'x___twitter_url' AS "x___twitter_url",
  cache.unified_fields ->> 'pinterest_url' AS "pinterest_url",
  cache.supabase_fields,
  cache.hubspot_fields,
  cache.unified_fields,
  cache.hubspot_records
FROM brightside.hubspot_company_sync_cache cache;

CREATE OR REPLACE VIEW brightside.hubspot_contact_sync_view
WITH (security_invoker=true) AS
SELECT
  cache.sync_key,
  cache.supabase_id AS supabase_external_id,
  CASE WHEN cardinality(cache.hubspot_ids)=1 THEN cache.hubspot_ids[1] END AS hubspot_id,
  cache.hubspot_ids,
  cache.identity_status,
  cache.display_name,
  cache.conflicting_fields,
  cache.supabase_source_updated_at,
  cache.hubspot_source_updated_at,
  cache.last_generated_at,
  cache.last_changed_at,
  cache.unified_fields ->> 'firstname' AS "firstname",
  cache.unified_fields ->> 'lastname' AS "lastname",
  cache.unified_fields ->> 'email' AS "email",
  cache.unified_fields ->> 'phone' AS "phone",
  cache.unified_fields ->> 'jobtitle' AS "jobtitle",
  cache.unified_fields ->> 'seniority' AS "seniority",
  cache.unified_fields ->> 'hs_linkedin_url' AS "hs_linkedin_url",
  cache.unified_fields ->> 'role_category_supabase' AS "role_category_supabase",
  cache.unified_fields ->> 'contact_provenance_supabase' AS "contact_provenance_supabase",
  cache.unified_fields ->> 'email_provenance_supabase' AS "email_provenance_supabase",
  cache.unified_fields ->> 'company' AS "company",
  cache.unified_fields ->> 'supabase_company_id' AS "supabase_company_id",
  cache.supabase_fields,
  cache.hubspot_fields,
  cache.unified_fields,
  cache.hubspot_records
FROM brightside.hubspot_contact_sync_cache cache;

REVOKE ALL ON brightside.hubspot_company_sync_cache, brightside.hubspot_contact_sync_cache
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON brightside.hubspot_company_sync_view, brightside.hubspot_contact_sync_view
  FROM PUBLIC, anon, authenticated;
