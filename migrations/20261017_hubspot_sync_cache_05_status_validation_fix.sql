-- Repair ambiguity status expression in the installed sync views.
-- Read-only schema correction; cached data unchanged.
CREATE OR REPLACE VIEW brightside.hubspot_company_sync_view
WITH (security_invoker = true) AS
SELECT sync_key,
    supabase_id AS supabase_external_id,
        CASE
            WHEN cardinality(hubspot_ids) = 1 THEN hubspot_ids[1]
            ELSE NULL::text
        END AS hubspot_id,
    hubspot_ids,
    identity_status,
    display_name,
    conflicting_fields,
    supabase_source_updated_at,
    hubspot_source_updated_at,
    last_generated_at,
    last_changed_at,
    unified_fields ->> 'name'::text AS name,
    unified_fields ->> 'domain'::text AS domain,
    unified_fields ->> 'phone'::text AS phone,
    unified_fields ->> 'address'::text AS address,
    unified_fields ->> 'address2'::text AS address2,
    unified_fields ->> 'city'::text AS city,
    unified_fields ->> 'state'::text AS state,
    unified_fields ->> 'zip'::text AS zip,
    unified_fields ->> 'country'::text AS country,
    unified_fields ->> 'website'::text AS website,
    unified_fields ->> 'numberofemployees'::text AS numberofemployees,
    unified_fields ->> 'linkedin_company_page'::text AS linkedin_company_page,
    unified_fields ->> 'facebook_company_page'::text AS facebook_company_page,
    unified_fields ->> 'instagram_url'::text AS instagram_url,
    unified_fields ->> 'tiktok_url'::text AS tiktok_url,
    unified_fields ->> 'prospect_score_supabase'::text AS prospect_score_supabase,
    unified_fields ->> 'marketing_maturity_supabase'::text AS marketing_maturity_supabase,
    unified_fields ->> 'icp_vertical'::text AS icp_vertical,
    unified_fields ->> 'revenue_tier'::text AS revenue_tier,
    unified_fields ->> 'last_prospect_scan'::text AS last_prospect_scan,
    unified_fields ->> 'founded_year'::text AS founded_year,
    unified_fields ->> 'x___twitter_url'::text AS x___twitter_url,
    unified_fields ->> 'pinterest_url'::text AS pinterest_url,
    supabase_fields,
    hubspot_fields,
    unified_fields,
    hubspot_records
,
    CASE
        WHEN left(cache.identity_status, 10) = 'ambiguous_'
          OR coalesce(cardinality(cache.conflicting_fields), 0) > 0
          OR cache.unified_fields IS NULL
          THEN 'conflict'::text
        WHEN cache.identity_status = 'not_found' THEN 'not_found'::text
        WHEN cache.identity_status IN ('hubspot_only', 'supabase_only') THEN 'unmatched'::text
        WHEN cache.identity_status = 'matched' THEN 'no_conflict'::text
        ELSE 'conflict'::text
    END AS status
   FROM brightside.hubspot_company_sync_cache cache;



CREATE OR REPLACE VIEW brightside.hubspot_contact_sync_view
WITH (security_invoker = true) AS
SELECT sync_key,
    supabase_id AS supabase_external_id,
        CASE
            WHEN cardinality(hubspot_ids) = 1 THEN hubspot_ids[1]
            ELSE NULL::text
        END AS hubspot_id,
    hubspot_ids,
    identity_status,
    display_name,
    conflicting_fields,
    supabase_source_updated_at,
    hubspot_source_updated_at,
    last_generated_at,
    last_changed_at,
    unified_fields ->> 'firstname'::text AS firstname,
    unified_fields ->> 'lastname'::text AS lastname,
    unified_fields ->> 'email'::text AS email,
    unified_fields ->> 'phone'::text AS phone,
    unified_fields ->> 'jobtitle'::text AS jobtitle,
    unified_fields ->> 'seniority'::text AS seniority,
    unified_fields ->> 'hs_linkedin_url'::text AS hs_linkedin_url,
    unified_fields ->> 'role_category_supabase'::text AS role_category_supabase,
    unified_fields ->> 'contact_provenance_supabase'::text AS contact_provenance_supabase,
    unified_fields ->> 'email_provenance_supabase'::text AS email_provenance_supabase,
    unified_fields ->> 'company'::text AS company,
    unified_fields ->> 'supabase_company_id'::text AS supabase_company_id,
    supabase_fields,
    hubspot_fields,
    unified_fields,
    hubspot_records
,
    CASE
        WHEN left(cache.identity_status, 10) = 'ambiguous_'
          OR coalesce(cardinality(cache.conflicting_fields), 0) > 0
          OR cache.unified_fields IS NULL
          THEN 'conflict'::text
        WHEN cache.identity_status = 'not_found' THEN 'not_found'::text
        WHEN cache.identity_status IN ('hubspot_only', 'supabase_only') THEN 'unmatched'::text
        WHEN cache.identity_status = 'matched' THEN 'no_conflict'::text
        ELSE 'conflict'::text
    END AS status
   FROM brightside.hubspot_contact_sync_cache cache;

REVOKE ALL ON brightside.hubspot_company_sync_view, brightside.hubspot_contact_sync_view
  FROM PUBLIC, anon, authenticated;
