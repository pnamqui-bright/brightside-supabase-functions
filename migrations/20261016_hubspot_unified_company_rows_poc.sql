-- Read-only proof of concept: one unified row per explicit HubSpot/Supabase company identity.
-- No natural-key guesses, no sync updates, no saved plans, no association handling.
-- Remote records are fetched once with verified FDW pagination; results are limited to
-- companies selected by the two input arrays and deduplicated by canonical external ID.
CREATE OR REPLACE FUNCTION brightside.hubspot_unified_company_rows(
  p_supabase_ids text[] DEFAULT ARRAY[]::text[],
  p_hubspot_ids text[] DEFAULT ARRAY[]::text[]
)
RETURNS TABLE (
  company_external_id text,
  hubspot_ids text[],
  requested_supabase_ids text[],
  requested_hubspot_ids text[],
  identity_status text,
  display_name text,
  unified_fields jsonb,
  supabase_fields jsonb,
  hubspot_fields jsonb,
  conflicting_fields text[],
  hubspot_records jsonb
)
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
AS $unified$
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
    LEFT JOIN brightside._sql_hubspot_local_companies loc ON loc.supabase_id = ek.external_id
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
$unified$;

-- Keep the POC available only to DB roles granted explicit execution access.
REVOKE ALL ON FUNCTION brightside.hubspot_unified_company_rows(text[], text[]) FROM PUBLIC;
