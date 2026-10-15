-- Manual, company-only SQL planner: prerequisites and direct Supabase field projection.
-- SOURCE MIGRATION ONLY. Do not apply to production without explicit deployment authorization.
-- The HubSpot foreign table remains read-only; no background sync or CRM data writes.

-- The foreign table exposes only explicitly declared HubSpot property names.
-- Do NOT depend on trial-only fit-scoring fields or HubSpot's marketing-consent data.
ALTER FOREIGN TABLE hubspot."Companies"
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS address2 text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS zip text,
  ADD COLUMN IF NOT EXISTS country text,
  ADD COLUMN IF NOT EXISTS website text,
  ADD COLUMN IF NOT EXISTS linkedin_company_page text,
  ADD COLUMN IF NOT EXISTS facebook_company_page text,
  ADD COLUMN IF NOT EXISTS instagram_url text,
  ADD COLUMN IF NOT EXISTS tiktok_url text,
  ADD COLUMN IF NOT EXISTS prospect_score_supabase text,
  ADD COLUMN IF NOT EXISTS marketing_maturity_supabase text,
  ADD COLUMN IF NOT EXISTS icp_vertical text,
  ADD COLUMN IF NOT EXISTS revenue_tier text,
  ADD COLUMN IF NOT EXISTS last_prospect_scan text;

CREATE OR REPLACE FUNCTION brightside._sql_hubspot_domain(p_value text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $domain$
 SELECT NULLIF(
   regexp_replace(
     split_part(
       split_part(
         regexp_replace(
           regexp_replace(lower(btrim(p_value)), '^[a-z][a-z0-9+.-]*://', ''),
           '^www\.', ''
         ),
         '/', 1
       ),
       ':', 1
     ),
     '\.$', ''
   ),
   ''
 );
$domain$;

-- Preserve the canonical primary, resolving chains and rejecting invalid links.
-- Never infer duplicates by name or domain alone.
CREATE OR REPLACE FUNCTION brightside._sql_hubspot_canonical_company(p_id text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $canonical$
DECLARE
  current_id text := nullif(btrim(p_id), '');
  next_id text;
  target_count integer;
  visited text[];
BEGIN
  IF current_id IS NULL THEN RETURN NULL; END IF;
  visited := ARRAY[current_id];
  LOOP
    SELECT count(DISTINCT to_company_external_id), min(to_company_external_id)
      INTO target_count, next_id
    FROM brightside.company_relationships
    WHERE relationship_type = 'merged_into'
      AND from_company_external_id = current_id;
    IF target_count > 1 THEN
      RAISE EXCEPTION 'conflicting_company_merge_targets for %', current_id;
    END IF;
    EXIT WHEN next_id IS NULL;
    IF next_id = ANY(visited) THEN
      RAISE EXCEPTION 'invalid_company_merge_cycle for %', current_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM brightside.companies WHERE company_external_id = next_id) THEN
      RAISE EXCEPTION 'invalid_company_merge_reference for %', next_id;
    END IF;
    current_id := next_id;
    visited := array_append(visited, current_id);
  END LOOP;
  RETURN current_id;
END;
$canonical$;

-- Comparable HubSpot datetime string; invalid observations are treated as absent.
-- A missing sync baseline is never fabricated.
CREATE OR REPLACE FUNCTION brightside._sql_hubspot_iso(p_value text)
RETURNS text
LANGUAGE plpgsql STABLE
AS $iso$
DECLARE
  v text := nullif(btrim(p_value), '');
  dt timestamptz;
BEGIN
  IF v IS NULL THEN RETURN ''; END IF;
  IF v ~ '^[0-9]{13}$' THEN
    dt := to_timestamp(v::numeric / 1000);
  ELSIF v ~ '^[0-9]{10}$' THEN
    dt := to_timestamp(v::numeric);
  ELSE
    dt := v::timestamptz;
  END IF;
  RETURN to_char(dt AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
EXCEPTION WHEN others THEN
  RETURN '';
END;
$iso$;

CREATE OR REPLACE FUNCTION brightside._sql_hubspot_valid_company_enum(p_property text, p_value text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $enum$
  SELECT CASE
    WHEN nullif(btrim(p_value), '') IS NULL THEN true
    WHEN 'marketing_maturity_supabase' THEN btrim(p_value) = ANY (ARRAY['Upper_T2', 'T2', 'Unknown', 'T3', 'Lower_T4', 'T1']::text[])
    WHEN 'revenue_tier' THEN btrim(p_value) = ANY (ARRAY['T4', 'T2', 'T3', 'T1', 'T0', 'Mega', 'Unknown']::text[])
    WHEN 'icp_vertical' THEN btrim(p_value) = ANY (ARRAY['Plumbing contractors', 'Electrical contractors', 'Landscaping companies', 'Commercial cleaning companies', 'Massage therapy clinics', 'Personal training studios', 'Acupuncture clinics', 'Chiropractic clinics', 'Roofing contractors', 'Event staging companies', 'Tent rental companies', 'Event lighting companies', 'Event production companies', 'Party rental companies', 'Event entertainment companies', 'AV production companies', 'Wedding planners', 'Counselling clinics', 'Yoga studios', 'Pilates studios', 'Medical spas', 'Aesthetic clinics', 'hvac_contractor', 'Physiotherapy clinics', 'Wedding venues', 'Banquet halls', 'Event venues', 'Event rental companies', 'Event DJ companies', 'Psychology clinics', 'Naturopathic clinics', 'Corporate event planners']::text[])
    ELSE true
  END;
$enum$;

-- This is not hubspot_companies_export. It reads authoritative parent + child
-- Supabase data directly and computes the score only for this company.
-- Multiple DISTINCT nonblank values in any mapped child field flag ambiguity.
CREATE OR REPLACE VIEW brightside._sql_hubspot_local_companies
WITH (security_invoker = true)
AS
SELECT
  c.company_external_id AS supabase_id,
  c.hubspot_export_updated_at AS local_updated_at,
  c.hubspot_last_synced_at AS last_synced_at,
  (coalesce(cardinality(d.domain_values) > 1, false)
    OR coalesce(cardinality(ph.phone_values) > 1, false)
    OR coalesce(cardinality(web.website_url_values) > 1, false)
    OR coalesce(cardinality(v.icp_vertical_values) > 1, false)
    OR coalesce(cardinality(loc.street_address_1_values) > 1, false)
    OR coalesce(cardinality(loc.street_address_2_values) > 1, false)
    OR coalesce(cardinality(loc.city_values) > 1, false)
    OR coalesce(cardinality(loc.state_province_values) > 1, false)
    OR coalesce(cardinality(loc.postal_code_values) > 1, false)
    OR coalesce(cardinality(loc.country_values) > 1, false)) AS ambiguous_mapped_values,
  jsonb_build_object(
    'name', coalesce(btrim(c.company_name), ''),
    'domain', coalesce((d.domain_values)[1], ''),
    'phone', coalesce((ph.phone_values)[1], ''),
    'address', coalesce((loc.street_address_1_values)[1], ''),
    'address2', coalesce((loc.street_address_2_values)[1], ''),
    'city', coalesce((loc.city_values)[1], ''),
    'state', coalesce((loc.state_province_values)[1], ''),
    'zip', coalesce((loc.postal_code_values)[1], ''),
    'country', coalesce((loc.country_values)[1], ''),
    'website', coalesce((web.website_url_values)[1], ''),
    'numberofemployees', CASE WHEN btrim(coalesce(c.employee_count_best, '')) ~ '^[0-9]{1,9}$' THEN btrim(c.employee_count_best)::integer::text ELSE '' END,
    'linkedin_company_page', coalesce(sp.linkedin_url, ''),
    'facebook_company_page', coalesce(sp.facebook_url, ''),
    'instagram_url', coalesce(sp.instagram_url, ''),
    'tiktok_url', coalesce(sp.tiktok_url, ''),
    'prospect_score_supabase', coalesce(score.score::text, ''),
    'marketing_maturity_supabase', coalesce(btrim(c.observed_marketing_maturity), ''),
    'icp_vertical', coalesce((v.icp_vertical_values)[1], ''),
    'revenue_tier', coalesce(btrim(c.estimated_revenue_tier), ''),
    'last_prospect_scan', brightside._sql_hubspot_iso(c.last_scanned_at)
  ) AS field_values
FROM brightside.companies c
LEFT JOIN LATERAL (
  SELECT array_agg(DISTINCT NULLIF(btrim(x.domain), '')) FILTER (WHERE NULLIF(btrim(x.domain), '') IS NOT NULL) AS domain_values
  FROM brightside.company_domains x
  WHERE x.company_external_id = c.company_external_id
) d ON true
LEFT JOIN LATERAL (
  SELECT array_agg(DISTINCT NULLIF(btrim(x.phone), '')) FILTER (WHERE NULLIF(btrim(x.phone), '') IS NOT NULL) AS phone_values
  FROM brightside.company_phone_numbers x
  WHERE x.company_external_id = c.company_external_id
) ph ON true
LEFT JOIN LATERAL (
  SELECT array_agg(DISTINCT NULLIF(btrim(x.street_address_1), '')) FILTER (WHERE NULLIF(btrim(x.street_address_1), '') IS NOT NULL) AS street_address_1_values,
         array_agg(DISTINCT NULLIF(btrim(x.street_address_2), '')) FILTER (WHERE NULLIF(btrim(x.street_address_2), '') IS NOT NULL) AS street_address_2_values,
         array_agg(DISTINCT NULLIF(btrim(x.city), '')) FILTER (WHERE NULLIF(btrim(x.city), '') IS NOT NULL) AS city_values,
         array_agg(DISTINCT NULLIF(btrim(x.state_province), '')) FILTER (WHERE NULLIF(btrim(x.state_province), '') IS NOT NULL) AS state_province_values,
         array_agg(DISTINCT NULLIF(btrim(x.postal_code), '')) FILTER (WHERE NULLIF(btrim(x.postal_code), '') IS NOT NULL) AS postal_code_values,
         array_agg(DISTINCT NULLIF(btrim(x.country), '')) FILTER (WHERE NULLIF(btrim(x.country), '') IS NOT NULL) AS country_values
  FROM brightside.company_locations x
  WHERE x.company_external_id = c.company_external_id
) loc ON true
LEFT JOIN LATERAL (
  SELECT array_agg(DISTINCT NULLIF(btrim(x.website_url), '')) FILTER (WHERE NULLIF(btrim(x.website_url), '') IS NOT NULL) AS website_url_values
  FROM brightside.company_websites x
  WHERE x.company_external_id = c.company_external_id
) web ON true
LEFT JOIN LATERAL (
  SELECT array_agg(DISTINCT NULLIF(btrim(x.icp_vertical), '')) FILTER (WHERE NULLIF(btrim(x.icp_vertical), '') IS NOT NULL) AS icp_vertical_values
  FROM brightside.company_verticals x
  WHERE x.company_external_id = c.company_external_id
) v ON true
LEFT JOIN LATERAL (
  SELECT
    max(profile_url) FILTER (WHERE platform = 'linkedin' AND rn = 1) AS linkedin_url,
    max(profile_url) FILTER (WHERE platform = 'facebook' AND rn = 1) AS facebook_url,
    max(profile_url) FILTER (WHERE platform = 'instagram' AND rn = 1) AS instagram_url,
    max(profile_url) FILTER (WHERE platform = 'tiktok' AND rn = 1) AS tiktok_url
  FROM (
    SELECT
      p.profile_url,
      CASE WHEN p.platform = 'others' AND lower(p.profile_url) LIKE '%linkedin.%'
           THEN 'linkedin' ELSE p.platform END AS platform,
      row_number() OVER (
        PARTITION BY CASE WHEN p.platform = 'others' AND lower(p.profile_url) LIKE '%linkedin.%'
                          THEN 'linkedin' ELSE p.platform END
        ORDER BY p.observed_at DESC NULLS LAST, p.profile_url
      ) AS rn
    FROM brightside.company_social_profiles p
    WHERE p.company_external_id = c.company_external_id
      AND nullif(btrim(p.profile_url), '') IS NOT NULL
  ) ranked
) sp ON true
LEFT JOIN LATERAL (
  SELECT sc.score
  FROM brightside.company_scores_current sc
  WHERE sc.company_external_id = c.company_external_id
) score ON true
WHERE NOT EXISTS (
  SELECT 1 FROM brightside.company_relationships r
  WHERE r.relationship_type = 'merged_into'
    AND r.from_company_external_id = c.company_external_id
);

-- SQL execution belongs only to admins who can read Supabase data and the FDW.
REVOKE ALL ON FUNCTION brightside._sql_hubspot_canonical_company(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION brightside._sql_hubspot_iso(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION brightside._sql_hubspot_domain(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION brightside._sql_hubspot_valid_company_enum(text,text) FROM PUBLIC;
REVOKE ALL ON brightside._sql_hubspot_local_companies FROM PUBLIC;
