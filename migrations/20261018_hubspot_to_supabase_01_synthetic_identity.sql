-- Synthetic external ID identity recognition for inbound HubSpot-created records.
-- Explicit HubSpot supabase_*_id values always win. The deterministic HUB-* fallback
-- is used ONLY when a record with that exact external ID already exists locally;
-- there is deliberately no domain/email/name deduplication or association inference.
-- Required so a later full seed does not split one logical row into h:<id> and s:HUB-<id>.
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
      coalesce(
        brightside._sql_hubspot_canonical_company(h.supabase_company_id),
        (SELECT c.company_external_id FROM brightside.companies c
         WHERE c.company_external_id='HUB-'||h.id)
      ) AS canonical_id,
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
    FROM brightside._hubspot_sync_source_companies() h
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

CREATE OR REPLACE FUNCTION brightside.refresh_hubspot_contact_sync_cache(p_supabase_ids text[] DEFAULT ARRAY[]::text[], p_hubspot_ids text[] DEFAULT ARRAY[]::text[])
 RETURNS SETOF brightside.hubspot_contact_sync_cache
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF coalesce(cardinality(p_supabase_ids),0)+coalesce(cardinality(p_hubspot_ids),0)>250 THEN
    RAISE EXCEPTION 'Contact sync refresh: limit supplied IDs to 250 per invocation';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM unnest(coalesce(p_supabase_ids,ARRAY[]::text[])||coalesce(p_hubspot_ids,ARRAY[]::text[])) t(id)
    WHERE nullif(btrim(t.id),'') IS NOT NULL
  ) THEN RAISE EXCEPTION 'Contact sync refresh: at least one ID is required'; END IF;
  RETURN QUERY
  WITH
input_supabase AS MATERIALIZED (
  SELECT DISTINCT btrim(input.id) AS id
  FROM unnest(coalesce(p_supabase_ids, ARRAY[]::text[])) AS input(id)
  WHERE nullif(btrim(input.id),'') IS NOT NULL
),
input_hubspot AS MATERIALIZED (
  SELECT DISTINCT btrim(input.id) AS id
  FROM unnest(coalesce(p_hubspot_ids, ARRAY[]::text[])) AS input(id)
  WHERE nullif(btrim(input.id),'') IS NOT NULL
),
remote_all AS MATERIALIZED (
 SELECT
   h.id AS hubspot_id,
   coalesce(
    nullif(btrim(h.supabase_contact_id), ''),
    (SELECT c.contact_external_id FROM brightside.contacts c
     WHERE c.contact_external_id='HUB-CONTACT-'||h.id)
   ) AS supabase_id,
   (h.updated_at AT TIME ZONE 'UTC') AS remote_updated_at,
   jsonb_build_object(
    'firstname',nullif(btrim(h.firstname),''),
    'lastname',nullif(btrim(h.lastname),''),
    'email',nullif(btrim(h.email),''),
    'phone',nullif(btrim(h.phone),''),
    'jobtitle',nullif(btrim(h.jobtitle),''),
    'seniority',nullif(btrim(h.seniority),''),
    'hs_linkedin_url',nullif(btrim(h.hs_linkedin_url),''),
    'role_category_supabase',nullif(btrim(h.role_category_supabase),''),
    'contact_provenance_supabase',nullif(btrim(h.contact_provenance_supabase),''),
    'email_provenance_supabase',nullif(btrim(h.email_provenance_supabase),''),
    'company',nullif(btrim(h.company),''),
    'supabase_company_id',nullif(btrim(h.supabase_company_id),'')
   ) AS field_values,
   jsonb_build_object(
    'hs_legal_basis',h.hs_legal_basis,
    'hs_email_optout',h.hs_email_optout,
    'lifecyclestage',h.lifecyclestage,
    'hubspot_owner_id',h.hubspot_owner_id,
    'mobilephone',h.mobilephone,
    'work_email',h.work_email,
    'hs_seniority',h.hs_seniority,
    'hs_role',h.hs_role,
    'hs_buying_role',h.hs_buying_role
   ) AS hubspot_metadata
 FROM brightside._hubspot_sync_source_contacts() h
),
selected_remote AS MATERIALIZED (
  SELECT r.*,
   CASE WHEN r.supabase_id IS NOT NULL THEN 's:'||r.supabase_id ELSE 'h:'||r.hubspot_id END AS entity_key
  FROM remote_all r
  WHERE EXISTS (SELECT 1 FROM input_hubspot i WHERE i.id=r.hubspot_id)
     OR EXISTS (SELECT 1 FROM input_supabase i WHERE i.id=r.supabase_id)
),
keys AS (
  SELECT DISTINCT 's:'||i.id AS entity_key,i.id AS supabase_id FROM input_supabase i
  UNION
  SELECT DISTINCT r.entity_key,r.supabase_id FROM selected_remote r
  UNION
  SELECT 'h:'||i.id,NULL::text FROM input_hubspot i
  WHERE NOT EXISTS (SELECT 1 FROM selected_remote r WHERE r.hubspot_id=i.id)
),
remote_group AS (
  SELECT
   r.entity_key,
   count(*)::int AS hubspot_count,
   array_agg(r.hubspot_id ORDER BY r.hubspot_id) AS hubspot_ids,
   (array_agg(r.field_values ORDER BY r.hubspot_id))[1] AS sole_fields,
   max(r.remote_updated_at) AS source_updated_at,
   jsonb_agg(jsonb_build_object(
     'hubspot_id',r.hubspot_id,
     'supabase_contact_id',r.supabase_id,
     'updated_at',r.remote_updated_at,
     'fields',r.field_values,
     'metadata',r.hubspot_metadata
   ) ORDER BY r.hubspot_id) AS hubspot_records
  FROM selected_remote r
  GROUP BY r.entity_key
),
requested_supabase AS (
  SELECT 's:'||i.id AS entity_key,array_agg(i.id ORDER BY i.id) AS requested_ids
  FROM input_supabase i GROUP BY i.id
),
requested_hubspot AS (
  SELECT coalesce(r.entity_key,'h:'||i.id) AS entity_key,
    array_agg(i.id ORDER BY i.id) AS requested_ids
  FROM input_hubspot i
  LEFT JOIN selected_remote r ON r.hubspot_id=i.id
  GROUP BY coalesce(r.entity_key,'h:'||i.id)
),
joined AS (
 SELECT
  k.entity_key,
  k.supabase_id,
  coalesce(g.hubspot_ids,ARRAY[]::text[]) AS hubspot_ids,
  coalesce(rs.requested_ids,ARRAY[]::text[]) AS requested_supabase_ids,
  coalesce(rh.requested_ids,ARRAY[]::text[]) AS requested_hubspot_ids,
  coalesce(g.hubspot_count,0) AS hubspot_count,
  CASE WHEN g.hubspot_count=1 THEN g.sole_fields END AS h_fields,
  local.field_values AS s_fields,
  local.supabase_id IS NOT NULL AS has_local,
  coalesce(local.ambiguous_mapped_values,false) AS local_ambiguous,
  local.local_updated_at AS supabase_source_updated_at,
  g.source_updated_at AS hubspot_source_updated_at,
  coalesce(g.hubspot_records,'[]'::jsonb) AS hubspot_records
 FROM keys k
 LEFT JOIN remote_group g ON g.entity_key=k.entity_key
 LEFT JOIN requested_supabase rs ON rs.entity_key=k.entity_key
 LEFT JOIN requested_hubspot rh ON rh.entity_key=k.entity_key
 LEFT JOIN brightside._hubspot_contact_sync_source local ON local.supabase_id=k.supabase_id
),
reconciled AS (
 SELECT j.*,
  CASE WHEN j.hubspot_count>1 OR j.local_ambiguous THEN NULL::jsonb
   ELSE (
     SELECT coalesce(jsonb_object_agg(k.key,
      CASE WHEN vals.s_value IS NOT NULL AND vals.h_value IS NOT NULL
                 AND vals.s_value<>vals.h_value
       THEN 'null'::jsonb
       ELSE to_jsonb(coalesce(vals.s_value,vals.h_value)) END
     ),'{}'::jsonb)
     FROM jsonb_object_keys(coalesce(j.s_fields,'{}'::jsonb)||coalesce(j.h_fields,'{}'::jsonb)) k(key)
     CROSS JOIN LATERAL (SELECT nullif(btrim(j.s_fields->>k.key),'') AS s_value,
       nullif(btrim(j.h_fields->>k.key),'') AS h_value) vals
   ) END AS resolved_fields,
  (
    SELECT coalesce(array_agg(k.key ORDER BY k.key),ARRAY[]::text[])
    FROM jsonb_object_keys(coalesce(j.s_fields,'{}'::jsonb)||coalesce(j.h_fields,'{}'::jsonb)) k(key)
    WHERE nullif(btrim(j.s_fields->>k.key),'') IS NOT NULL
      AND nullif(btrim(j.h_fields->>k.key),'') IS NOT NULL
      AND btrim(j.s_fields->>k.key)<>btrim(j.h_fields->>k.key)
  ) AS difference_keys
 FROM joined j
),
prepared AS MATERIALIZED (
 SELECT
  r.entity_key AS sync_key,
  r.supabase_id,
  r.hubspot_ids,
  r.requested_supabase_ids,
  r.requested_hubspot_ids,
  CASE WHEN r.hubspot_count>1 THEN 'ambiguous_multiple_hubspot_records'
       WHEN r.local_ambiguous THEN 'ambiguous_supabase_fields'
       WHEN r.has_local AND r.hubspot_count=1 THEN 'matched'
       WHEN r.has_local THEN 'supabase_only'
       WHEN r.hubspot_count=1 THEN 'hubspot_only'
       ELSE 'not_found' END AS identity_status,
  coalesce(nullif(r.s_fields->>'firstname',''),nullif(r.h_fields->>'firstname',''),
           nullif(r.s_fields->>'email',''),nullif(r.h_fields->>'email','')) AS display_name,
  coalesce(r.s_fields,'{}'::jsonb) AS supabase_fields,
  coalesce(r.h_fields,'{}'::jsonb) AS hubspot_fields,
  r.resolved_fields AS unified_fields,
  r.difference_keys AS conflicting_fields,
  r.hubspot_records,
  r.supabase_source_updated_at,
  r.hubspot_source_updated_at,
  statement_timestamp() AS generated_at
 FROM reconciled r
),
written AS (
  INSERT INTO brightside.hubspot_contact_sync_cache AS old (sync_key, supabase_id, hubspot_ids, requested_supabase_ids, requested_hubspot_ids, identity_status, display_name, supabase_fields, hubspot_fields, unified_fields, conflicting_fields, hubspot_records, supabase_source_updated_at, hubspot_source_updated_at, last_generated_at, last_changed_at)
  SELECT
    p.sync_key,p.supabase_id,p.hubspot_ids,p.requested_supabase_ids,p.requested_hubspot_ids,
    p.identity_status,p.display_name,p.supabase_fields,p.hubspot_fields,p.unified_fields,
    p.conflicting_fields,p.hubspot_records,p.supabase_source_updated_at,p.hubspot_source_updated_at,
    p.generated_at,p.generated_at
  FROM prepared p
  ON CONFLICT (sync_key) DO UPDATE SET
    supabase_id = EXCLUDED.supabase_id,
    hubspot_ids = EXCLUDED.hubspot_ids,
    requested_supabase_ids = EXCLUDED.requested_supabase_ids,
    requested_hubspot_ids = EXCLUDED.requested_hubspot_ids,
    identity_status = EXCLUDED.identity_status,
    display_name = EXCLUDED.display_name,
    supabase_fields = EXCLUDED.supabase_fields,
    hubspot_fields = EXCLUDED.hubspot_fields,
    unified_fields = EXCLUDED.unified_fields,
    conflicting_fields = EXCLUDED.conflicting_fields,
    hubspot_records = EXCLUDED.hubspot_records,
    supabase_source_updated_at = EXCLUDED.supabase_source_updated_at,
    hubspot_source_updated_at = EXCLUDED.hubspot_source_updated_at,
    last_changed_at = CASE WHEN
      ROW(old.supabase_id, old.hubspot_ids, old.identity_status, old.display_name, old.supabase_fields, old.hubspot_fields, old.unified_fields, old.conflicting_fields, old.hubspot_records)
      IS DISTINCT FROM
      ROW(EXCLUDED.supabase_id, EXCLUDED.hubspot_ids, EXCLUDED.identity_status, EXCLUDED.display_name, EXCLUDED.supabase_fields, EXCLUDED.hubspot_fields, EXCLUDED.unified_fields, EXCLUDED.conflicting_fields, EXCLUDED.hubspot_records)
      THEN EXCLUDED.last_generated_at ELSE old.last_changed_at END,
    last_generated_at = EXCLUDED.last_generated_at
  RETURNING *
)
SELECT * FROM written;
END;
$function$;

CREATE OR REPLACE FUNCTION brightside.seed_hubspot_sync_cache(p_entity text DEFAULT 'both'::text, p_batch_size integer DEFAULT 200)
 RETURNS TABLE(entity_type text, supabase_source_count integer, hubspot_source_count integer, distinct_identities integer, cached_count integer, conflicts integer, no_conflict integer, unmatched integer, stale_cached integer, elapsed_seconds numeric)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_started timestamptz := clock_timestamp();
    v_entity text := lower(btrim(coalesce(p_entity, 'both')));
    v_local integer;
    v_remote integer;
    v_identities integer;
    v_cached integer;
    v_conflicts integer;
    v_clean integer;
    v_unmatched integer;
    v_stale integer;
    v_offset integer;
    v_supabase_ids text[];
    v_hubspot_ids text[];
BEGIN
    IF v_entity NOT IN ('both','companies','contacts') THEN
      RAISE EXCEPTION 'p_entity must be both, companies, or contacts';
    END IF;
    IF p_batch_size IS NULL OR p_batch_size < 1 OR p_batch_size > 250 THEN
      RAISE EXCEPTION 'p_batch_size must be 1..250';
    END IF;

    -- Prevent two full seed sessions from overwriting each other's cache work.
    PERFORM pg_advisory_xact_lock(hashtext('brightside.hubspot_sync_cache.full_seed'));

    IF v_entity IN ('both','companies') THEN
      DROP TABLE IF EXISTS pg_temp._hubspot_sync_seed_companies;
      DROP TABLE IF EXISTS pg_temp._hubspot_sync_seed_company_keys;

      -- The existing FDW helper has a literal 10,001-row boundary check.
      CREATE TEMP TABLE _hubspot_sync_seed_companies ON COMMIT DROP AS
        SELECT * FROM brightside._sql_hubspot_fetch_companies(NULL);

      CREATE UNIQUE INDEX _hubspot_sync_seed_companies_id_idx
        ON pg_temp._hubspot_sync_seed_companies (id);

      SELECT count(*)::integer INTO v_remote FROM pg_temp._hubspot_sync_seed_companies;
      SELECT count(*)::integer INTO v_local FROM brightside.companies;
      IF v_remote=0 OR v_local=0 OR v_remote>10000 THEN
        RAISE EXCEPTION 'Unsafe company source inventory: HubSpot %, Supabase %', v_remote, v_local;
      END IF;

      CREATE TEMP TABLE _hubspot_sync_seed_company_keys ON COMMIT DROP AS
        WITH candidates AS (
          SELECT
            brightside._sql_hubspot_canonical_company(c.company_external_id) AS supabase_id,
            NULL::text AS hubspot_id
          FROM brightside.companies c
          UNION ALL
          SELECT
            coalesce(
              brightside._sql_hubspot_canonical_company(h.supabase_company_id),
              (SELECT c.company_external_id FROM brightside.companies c
               WHERE c.company_external_id='HUB-'||h.id)
            ) AS supabase_id,
            h.id AS hubspot_id
          FROM pg_temp._hubspot_sync_seed_companies h
        ),
        keys AS (
          SELECT DISTINCT
            CASE WHEN supabase_id IS NOT NULL
              THEN 's:' || supabase_id
              ELSE 'h:' || hubspot_id
            END AS sync_key,
            supabase_id,
            CASE WHEN supabase_id IS NULL THEN hubspot_id END AS hubspot_id
          FROM candidates
          WHERE supabase_id IS NOT NULL OR hubspot_id IS NOT NULL
        )
        SELECT row_number() OVER (ORDER BY sync_key)::integer AS seq,
               sync_key, supabase_id, hubspot_id
        FROM keys;

      CREATE UNIQUE INDEX _hubspot_sync_seed_company_keys_key_idx
        ON pg_temp._hubspot_sync_seed_company_keys (sync_key);

      SELECT count(*)::integer INTO v_identities
        FROM pg_temp._hubspot_sync_seed_company_keys;

      v_offset := 0;
      WHILE v_offset < v_identities LOOP
        SELECT
          coalesce(array_agg(k.supabase_id ORDER BY k.seq)
            FILTER (WHERE k.supabase_id IS NOT NULL), ARRAY[]::text[]),
          coalesce(array_agg(k.hubspot_id ORDER BY k.seq)
            FILTER (WHERE k.hubspot_id IS NOT NULL), ARRAY[]::text[])
          INTO v_supabase_ids, v_hubspot_ids
        FROM pg_temp._hubspot_sync_seed_company_keys k
        WHERE k.seq > v_offset AND k.seq <= v_offset + p_batch_size;

        PERFORM 1
          FROM brightside.refresh_hubspot_company_sync_cache(
            v_supabase_ids, v_hubspot_ids
          );
        v_offset := v_offset + p_batch_size;
      END LOOP;

      SELECT count(*)::integer,
             count(*) FILTER (WHERE v.status='conflict')::integer,
             count(*) FILTER (WHERE v.status='no_conflict')::integer,
             count(*) FILTER (WHERE v.status='unmatched')::integer
        INTO v_cached,v_conflicts,v_clean,v_unmatched
      FROM brightside.hubspot_company_sync_view v
      JOIN pg_temp._hubspot_sync_seed_company_keys k USING(sync_key);

      IF v_cached IS DISTINCT FROM v_identities THEN
        RAISE EXCEPTION 'Company seed incomplete: % expected, % found',v_identities,v_cached;
      END IF;

      SELECT count(*)::integer INTO v_stale
      FROM brightside.hubspot_company_sync_cache c
      WHERE NOT EXISTS (
        SELECT 1 FROM pg_temp._hubspot_sync_seed_company_keys k WHERE k.sync_key=c.sync_key
      );

      RETURN QUERY SELECT 'companies'::text, v_local,v_remote,v_identities,
        v_cached,v_conflicts,v_clean,v_unmatched,v_stale,
        round(extract(epoch FROM (clock_timestamp()-v_started))::numeric,2);
    END IF;

    IF v_entity IN ('both','contacts') THEN
      v_started := clock_timestamp();

      DROP TABLE IF EXISTS pg_temp._hubspot_sync_seed_contacts;
      DROP TABLE IF EXISTS pg_temp._hubspot_sync_seed_contact_keys;

      -- Exact literal FDW paging check is enforced by the source helper.
      CREATE TEMP TABLE _hubspot_sync_seed_contacts ON COMMIT DROP AS
        SELECT * FROM hubspot."Contacts" ORDER BY id LIMIT 10001;

      CREATE UNIQUE INDEX _hubspot_sync_seed_contacts_id_idx
        ON pg_temp._hubspot_sync_seed_contacts (id);

      SELECT count(*)::integer INTO v_remote FROM pg_temp._hubspot_sync_seed_contacts;
      SELECT count(*)::integer INTO v_local FROM brightside.contacts;
      IF v_remote=0 OR v_local=0 OR v_remote>10000 THEN
        RAISE EXCEPTION 'Unsafe contact source inventory: HubSpot %, Supabase %',v_remote,v_local;
      END IF;

      CREATE TEMP TABLE _hubspot_sync_seed_contact_keys ON COMMIT DROP AS
        WITH candidates AS (
          SELECT nullif(btrim(c.contact_external_id),'') AS supabase_id,
                 NULL::text AS hubspot_id
          FROM brightside.contacts c
          UNION ALL
          SELECT coalesce(
            nullif(btrim(h.supabase_contact_id),''),
            (SELECT c.contact_external_id FROM brightside.contacts c
             WHERE c.contact_external_id='HUB-CONTACT-'||h.id)
          ) AS supabase_id,
                 h.id AS hubspot_id
          FROM pg_temp._hubspot_sync_seed_contacts h
        ),
        keys AS (
          SELECT DISTINCT
            CASE WHEN supabase_id IS NOT NULL
              THEN 's:' || supabase_id
              ELSE 'h:' || hubspot_id
            END AS sync_key,
            supabase_id,
            CASE WHEN supabase_id IS NULL THEN hubspot_id END AS hubspot_id
          FROM candidates
          WHERE supabase_id IS NOT NULL OR hubspot_id IS NOT NULL
        )
        SELECT row_number() OVER (ORDER BY sync_key)::integer AS seq,
               sync_key,supabase_id,hubspot_id
        FROM keys;

      CREATE UNIQUE INDEX _hubspot_sync_seed_contact_keys_key_idx
        ON pg_temp._hubspot_sync_seed_contact_keys(sync_key);

      SELECT count(*)::integer INTO v_identities
        FROM pg_temp._hubspot_sync_seed_contact_keys;

      v_offset := 0;
      WHILE v_offset < v_identities LOOP
        SELECT
          coalesce(array_agg(k.supabase_id ORDER BY k.seq)
            FILTER (WHERE k.supabase_id IS NOT NULL),ARRAY[]::text[]),
          coalesce(array_agg(k.hubspot_id ORDER BY k.seq)
            FILTER (WHERE k.hubspot_id IS NOT NULL),ARRAY[]::text[])
          INTO v_supabase_ids,v_hubspot_ids
        FROM pg_temp._hubspot_sync_seed_contact_keys k
        WHERE k.seq > v_offset AND k.seq <= v_offset + p_batch_size;

        PERFORM 1
          FROM brightside.refresh_hubspot_contact_sync_cache(
            v_supabase_ids,v_hubspot_ids
          );
        v_offset := v_offset+p_batch_size;
      END LOOP;

      SELECT count(*)::integer,
             count(*) FILTER (WHERE v.status='conflict')::integer,
             count(*) FILTER (WHERE v.status='no_conflict')::integer,
             count(*) FILTER (WHERE v.status='unmatched')::integer
        INTO v_cached,v_conflicts,v_clean,v_unmatched
      FROM brightside.hubspot_contact_sync_view v
      JOIN pg_temp._hubspot_sync_seed_contact_keys k USING(sync_key);

      IF v_cached IS DISTINCT FROM v_identities THEN
        RAISE EXCEPTION 'Contact seed incomplete: % expected, % found',v_identities,v_cached;
      END IF;

      SELECT count(*)::integer INTO v_stale
      FROM brightside.hubspot_contact_sync_cache c
      WHERE NOT EXISTS (
        SELECT 1 FROM pg_temp._hubspot_sync_seed_contact_keys k WHERE k.sync_key=c.sync_key
      );

      RETURN QUERY SELECT 'contacts'::text,v_local,v_remote,v_identities,
        v_cached,v_conflicts,v_clean,v_unmatched,v_stale,
        round(extract(epoch FROM (clock_timestamp()-v_started))::numeric,2);
    END IF;
END;
$function$;
