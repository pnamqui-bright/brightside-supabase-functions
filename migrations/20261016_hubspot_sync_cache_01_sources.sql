-- Shared-field sources for the company and contact sync cache proof of concept.
-- The HubSpot FDW column names below have been confirmed against live HubSpot properties.
-- Deliberately excludes consent/legal basis, contact associations and unrelated CRM metadata.
DO $ddl$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='hubspot' AND table_name='Companies' AND column_name='x___twitter_url') THEN
   ALTER FOREIGN TABLE hubspot."Companies" ADD COLUMN x___twitter_url text;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='hubspot' AND table_name='Companies' AND column_name='pinterest_url') THEN
   ALTER FOREIGN TABLE hubspot."Companies" ADD COLUMN pinterest_url text;
 END IF;
END $ddl$;

CREATE OR REPLACE VIEW brightside._hubspot_company_sync_source
WITH (security_invoker=true) AS
SELECT
  s.supabase_id,
  s.local_updated_at,
  s.last_synced_at,
  s.ambiguous_mapped_values,
  s.field_values || jsonb_build_object(
    'founded_year', nullif(btrim(c.founded_year), ''),
    'x___twitter_url', (
      SELECT NULLIF(btrim(sp.profile_url), '')
      FROM brightside.company_social_profiles sp
      WHERE sp.company_external_id = s.supabase_id
        AND sp.platform = 'x/twitter'
        AND nullif(btrim(sp.profile_url), '') IS NOT NULL
      ORDER BY sp.observed_at DESC NULLS LAST, sp.profile_url
      LIMIT 1
    ),
    'pinterest_url', (
      SELECT NULLIF(btrim(sp.profile_url), '')
      FROM brightside.company_social_profiles sp
      WHERE sp.company_external_id = s.supabase_id
        AND sp.platform = 'pinterest'
        AND nullif(btrim(sp.profile_url), '') IS NOT NULL
      ORDER BY sp.observed_at DESC NULLS LAST, sp.profile_url
      LIMIT 1
    )
  ) AS field_values
FROM brightside._sql_hubspot_local_companies s
JOIN brightside.companies c ON c.company_external_id = s.supabase_id;

CREATE OR REPLACE VIEW brightside._hubspot_contact_sync_source
WITH (security_invoker=true) AS
SELECT
  c.contact_external_id AS supabase_id,
  c.hubspot_export_updated_at AS local_updated_at,
  c.hubspot_last_synced_at AS last_synced_at,
  coalesce(cardinality(ch.email_values) > 1, false)
    OR coalesce(cardinality(ch.phone_values) > 1, false)
    OR coalesce(cardinality(ch.linkedin_values) > 1, false)
    OR coalesce(cardinality(ch.provenance_values) > 1, false) AS ambiguous_mapped_values,
  jsonb_build_object(
    'firstname', nullif(btrim(c.first_name), ''),
    'lastname', nullif(btrim(c.last_name), ''),
    'email', ch.email_values[1],
    'phone', ch.phone_values[1],
    'jobtitle', nullif(btrim(c.job_title), ''),
    'seniority', nullif(btrim(c.seniority), ''),
    'hs_linkedin_url', ch.linkedin_values[1],
    'role_category_supabase', nullif(btrim(c.role_category), ''),
    'contact_provenance_supabase', nullif(btrim(c.contact_provenance_status), ''),
    'email_provenance_supabase', ch.provenance_values[1],
    'company', nullif(btrim(co.company_name), ''),
    'supabase_company_id', nullif(btrim(c.company_external_id), '')
  ) AS field_values
FROM brightside.contacts c
LEFT JOIN brightside.companies co
  ON co.company_external_id = brightside._sql_hubspot_canonical_company(c.company_external_id)
LEFT JOIN LATERAL (
  SELECT
    array_agg(DISTINCT nullif(btrim(x.email), '')) FILTER (WHERE nullif(btrim(x.email), '') IS NOT NULL) AS email_values,
    array_agg(DISTINCT nullif(btrim(x.phone), '')) FILTER (WHERE nullif(btrim(x.phone), '') IS NOT NULL) AS phone_values,
    array_agg(DISTINCT nullif(btrim(x.linkedin_url), '')) FILTER (WHERE nullif(btrim(x.linkedin_url), '') IS NOT NULL) AS linkedin_values,
    array_agg(DISTINCT nullif(btrim(x.email_provenance_status), '')) FILTER (WHERE nullif(btrim(x.email_provenance_status), '') IS NOT NULL) AS provenance_values
  FROM brightside.contact_channels x
  WHERE x.contact_external_id = c.contact_external_id
) ch ON true;

-- Retain the existing unified company POC's arguments and result schema.
-- Its shared-field JSON now includes 23 rather than 20 truly mapped properties.
CREATE OR REPLACE FUNCTION brightside.hubspot_unified_company_rows(p_supabase_ids text[] DEFAULT ARRAY[]::text[], p_hubspot_ids text[] DEFAULT ARRAY[]::text[])
 RETURNS TABLE(company_external_id text, hubspot_ids text[], requested_supabase_ids text[], requested_hubspot_ids text[], identity_status text, display_name text, unified_fields jsonb, supabase_fields jsonb, hubspot_fields jsonb, conflicting_fields text[], hubspot_records jsonb)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
BEGIN
  IF coalesce(cardinality(p_supabase_ids), 0) + coalesce(cardinality(p_hubspot_ids), 0) > 250 THEN
    RAISE EXCEPTION 'hubspot_unified_company_rows: limit inputs to 250 IDs per call';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM unnest(coalesce(p_supabase_ids, ARRAY[]::text[]) || coalesce(p_hubspot_ids, ARRAY[]::text[])) AS r(id)
    WHERE nullif(btrim(r.id), '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'hubspot_unified_company_rows: at least one ID is required';
  END IF;

  RETURN QUERY
  WITH
  supabase_requested AS MATERIALIZED (
    SELECT DISTINCT
      btrim(input.id) AS requested_id,
      brightside._sql_hubspot_canonical_company(input.id) AS canonical_id
    FROM unnest(coalesce(p_supabase_ids, ARRAY[]::text[])) AS input(id)
    WHERE nullif(btrim(input.id), '') IS NOT NULL
  ),
  hubspot_requested AS MATERIALIZED (
    SELECT DISTINCT btrim(input.id) AS requested_id
    FROM unnest(coalesce(p_hubspot_ids, ARRAY[]::text[])) AS input(id)
    WHERE nullif(btrim(input.id), '') IS NOT NULL
  ),
  remote_all AS MATERIALIZED (
    SELECT
      h.id AS hubspot_id,
      nullif(btrim(h.supabase_company_id), '') AS raw_company_external_id,
      brightside._sql_hubspot_canonical_company(h.supabase_company_id) AS canonical_id,
      (h.updated_at AT TIME ZONE 'UTC') AS remote_updated_at,
      jsonb_build_object(
        'name', nullif(btrim(h.name), ''),
        'domain', nullif(btrim(h.domain), ''),
        'phone', nullif(btrim(h.phone), ''),
        'address', nullif(btrim(h.address), ''),
        'address2', nullif(btrim(h.address2), ''),
        'city', nullif(btrim(h.city), ''),
        'state', nullif(btrim(h.state), ''),
        'zip', nullif(btrim(h.zip), ''),
        'country', nullif(btrim(h.country), ''),
        'website', nullif(btrim(h.website), ''),
        'numberofemployees', nullif(btrim(h.numberofemployees), ''),
        'linkedin_company_page', nullif(btrim(h.linkedin_company_page), ''),
        'facebook_company_page', nullif(btrim(h.facebook_company_page), ''),
        'instagram_url', nullif(btrim(h.instagram_url), ''),
        'tiktok_url', nullif(btrim(h.tiktok_url), ''),
        'founded_year', nullif(btrim(h.founded_year), ''),
        'x___twitter_url', nullif(btrim(h.x___twitter_url), ''),
        'pinterest_url', nullif(btrim(h.pinterest_url), ''),
        'prospect_score_supabase', nullif(btrim(h.prospect_score_supabase), ''),
        'marketing_maturity_supabase', nullif(btrim(h.marketing_maturity_supabase), ''),
        'icp_vertical', nullif(btrim(h.icp_vertical), ''),
        'revenue_tier', nullif(btrim(h.revenue_tier), ''),
        'last_prospect_scan', nullif(brightside._sql_hubspot_iso(h.last_prospect_scan), '')
      ) AS field_values
    FROM brightside._sql_hubspot_fetch_companies(NULL) h
  ),
  selected_remote AS MATERIALIZED (
    SELECT r.*,
      CASE WHEN r.canonical_id IS NOT NULL
        THEN 's:' || r.canonical_id ELSE 'h:' || r.hubspot_id END AS entity_key
    FROM remote_all r
    WHERE EXISTS (SELECT 1 FROM hubspot_requested hi WHERE hi.requested_id = r.hubspot_id)
       OR EXISTS (SELECT 1 FROM supabase_requested si WHERE si.canonical_id = r.canonical_id)
  ),
  entity_keys AS (
    SELECT DISTINCT 's:' || si.canonical_id AS entity_key, si.canonical_id AS external_id
    FROM supabase_requested si
    UNION
    SELECT DISTINCT sr.entity_key, sr.canonical_id AS external_id
    FROM selected_remote sr
    UNION
    SELECT 'h:' || hi.requested_id, NULL::text
    FROM hubspot_requested hi
    WHERE NOT EXISTS (SELECT 1 FROM selected_remote sr WHERE sr.hubspot_id = hi.requested_id)
  ),
  grouped_remote AS (
    SELECT sr.entity_key,
      count(*)::integer AS record_count,
      array_agg(sr.hubspot_id ORDER BY sr.hubspot_id) AS matched_hubspot_ids,
      (array_agg(sr.field_values ORDER BY sr.hubspot_id))[1] AS sole_fields,
      jsonb_agg(jsonb_build_object(
        'hubspot_id', sr.hubspot_id,
        'supabase_company_id', sr.raw_company_external_id,
        'updated_at', sr.remote_updated_at,
        'fields', sr.field_values
      ) ORDER BY sr.hubspot_id) AS all_hubspot_records
    FROM selected_remote sr
    GROUP BY sr.entity_key
  ),
  supabase_request_groups AS (
    SELECT 's:' || si.canonical_id AS entity_key,
      array_agg(si.requested_id ORDER BY si.requested_id) AS requested_ids
    FROM supabase_requested si
    GROUP BY si.canonical_id
  ),
  hubspot_request_groups AS (
    SELECT coalesce(sr.entity_key, 'h:' || hi.requested_id) AS entity_key,
      array_agg(hi.requested_id ORDER BY hi.requested_id) AS requested_ids
    FROM hubspot_requested hi
    LEFT JOIN selected_remote sr ON sr.hubspot_id = hi.requested_id
    GROUP BY coalesce(sr.entity_key, 'h:' || hi.requested_id)
  ),
  joined AS (
    SELECT ek.entity_key,
      ek.external_id,
      srq.requested_ids AS input_supabase_ids,
      hrq.requested_ids AS input_hubspot_ids,
      gr.matched_hubspot_ids,
      gr.all_hubspot_records,
      coalesce(gr.record_count, 0) AS hubspot_count,
      CASE WHEN gr.record_count = 1 THEN gr.sole_fields END AS h_fields,
      loc.field_values AS s_fields,
      loc.supabase_id IS NOT NULL AS has_local,
      coalesce(loc.ambiguous_mapped_values, false) AS local_ambiguous
    FROM entity_keys ek
    LEFT JOIN grouped_remote gr ON gr.entity_key = ek.entity_key
    LEFT JOIN supabase_request_groups srq ON srq.entity_key = ek.entity_key
    LEFT JOIN hubspot_request_groups hrq ON hrq.entity_key = ek.entity_key
    LEFT JOIN brightside._hubspot_company_sync_source loc ON loc.supabase_id = ek.external_id
  ),
  reconciled AS (
    SELECT j.*,
      CASE WHEN j.hubspot_count > 1 OR j.local_ambiguous THEN NULL::jsonb
      ELSE (
        SELECT coalesce(jsonb_object_agg(k.key,
          CASE WHEN v.s_value IS NOT NULL AND v.h_value IS NOT NULL
                 AND v.s_value <> v.h_value
            THEN 'null'::jsonb
            ELSE to_jsonb(coalesce(v.s_value, v.h_value))
          END), '{}'::jsonb)
        FROM jsonb_object_keys(coalesce(j.s_fields, '{}'::jsonb)
             || coalesce(j.h_fields, '{}'::jsonb)) AS k(key)
        CROSS JOIN LATERAL (
          SELECT nullif(btrim(j.s_fields ->> k.key), '') AS s_value,
                 nullif(btrim(j.h_fields ->> k.key), '') AS h_value
        ) v
      ) END AS resolved_fields,
      (
        SELECT coalesce(array_agg(k.key ORDER BY k.key), ARRAY[]::text[])
        FROM jsonb_object_keys(coalesce(j.s_fields, '{}'::jsonb)
             || coalesce(j.h_fields, '{}'::jsonb)) AS k(key)
        WHERE nullif(btrim(j.s_fields ->> k.key), '') IS NOT NULL
          AND nullif(btrim(j.h_fields ->> k.key), '') IS NOT NULL
          AND btrim(j.s_fields ->> k.key) <> btrim(j.h_fields ->> k.key)
      ) AS difference_keys
    FROM joined j
  )
  SELECT
    r.external_id AS company_external_id,
    coalesce(r.matched_hubspot_ids, ARRAY[]::text[]) AS hubspot_ids,
    coalesce(r.input_supabase_ids, ARRAY[]::text[]) AS requested_supabase_ids,
    coalesce(r.input_hubspot_ids, ARRAY[]::text[]) AS requested_hubspot_ids,
    CASE
      WHEN r.hubspot_count > 1 THEN 'ambiguous_multiple_hubspot_records'
      WHEN r.local_ambiguous THEN 'ambiguous_supabase_fields'
      WHEN r.has_local AND r.hubspot_count = 1 THEN 'matched'
      WHEN r.has_local THEN 'supabase_only'
      WHEN r.hubspot_count = 1 THEN 'hubspot_only'
      ELSE 'not_found'
    END AS identity_status,
    coalesce(nullif(r.s_fields ->> 'name', ''), nullif(r.h_fields ->> 'name', '')) AS display_name,
    r.resolved_fields AS unified_fields,
    r.s_fields AS supabase_fields,
    r.h_fields AS hubspot_fields,
    r.difference_keys AS conflicting_fields,
    coalesce(r.all_hubspot_records, '[]'::jsonb) AS hubspot_records
  FROM reconciled r
  ORDER BY r.external_id NULLS LAST, r.entity_key;
END;
$function$;

REVOKE ALL ON FUNCTION brightside.hubspot_unified_company_rows(text[],text[]) FROM PUBLIC;
REVOKE ALL ON brightside._hubspot_company_sync_source, brightside._hubspot_contact_sync_source FROM PUBLIC, anon, authenticated;
