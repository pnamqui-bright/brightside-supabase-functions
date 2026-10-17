-- MANUAL-ONLY sync cache refresh. Both functions update ONLY sync-cache rows.
-- Matching uses explicit Supabase external IDs; NO guessed email/domain matches.
-- Every reconciled value is sourced from the 23 company / 12 contact shared-property columns.
-- Conflicting populated values remain NULL in unified_fields but are retained in source JSON.
-- Neither function writes brightside.companies/contacts, HubSpot, or associations.
CREATE OR REPLACE FUNCTION brightside.refresh_hubspot_company_sync_cache(
  p_supabase_ids text[] DEFAULT ARRAY[]::text[],
  p_hubspot_ids text[] DEFAULT ARRAY[]::text[]
)
RETURNS SETOF brightside.hubspot_company_sync_cache
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
AS $refresh_companies$
BEGIN
  -- Explicit IDs only; the separate first-time full seed can call this in bounded batches.
  RETURN QUERY
  WITH prepared AS MATERIALIZED (
  SELECT
    CASE WHEN r.company_external_id IS NOT NULL
      THEN 's:' || r.company_external_id
      ELSE 'h:' || coalesce(r.hubspot_ids[1], r.requested_hubspot_ids[1])
    END AS sync_key,
    r.company_external_id AS supabase_id,
    r.hubspot_ids,
    r.requested_supabase_ids,
    r.requested_hubspot_ids,
    r.identity_status,
    r.display_name,
    coalesce(r.supabase_fields, '{}'::jsonb) AS supabase_fields,
    coalesce(r.hubspot_fields, '{}'::jsonb) AS hubspot_fields,
    r.unified_fields,
    coalesce(r.conflicting_fields, ARRAY[]::text[]) AS conflicting_fields,
    coalesce(r.hubspot_records, '[]'::jsonb) AS hubspot_records,
    local.local_updated_at AS supabase_source_updated_at,
    (SELECT max(nullif(rec.value->>'updated_at','')::timestamptz)
       FROM jsonb_array_elements(coalesce(r.hubspot_records, '[]'::jsonb)) rec(value)
    ) AS hubspot_source_updated_at,
    statement_timestamp() AS generated_at
  FROM brightside.hubspot_unified_company_rows(p_supabase_ids,p_hubspot_ids) r
  LEFT JOIN brightside._hubspot_company_sync_source local
    ON local.supabase_id = r.company_external_id
),
written AS (
  INSERT INTO brightside.hubspot_company_sync_cache AS old (sync_key, supabase_id, hubspot_ids, requested_supabase_ids, requested_hubspot_ids, identity_status, display_name, supabase_fields, hubspot_fields, unified_fields, conflicting_fields, hubspot_records, supabase_source_updated_at, hubspot_source_updated_at, last_generated_at, last_changed_at)
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
$refresh_companies$;

CREATE OR REPLACE FUNCTION brightside.refresh_hubspot_contact_sync_cache(
  p_supabase_ids text[] DEFAULT ARRAY[]::text[],
  p_hubspot_ids text[] DEFAULT ARRAY[]::text[]
)
RETURNS SETOF brightside.hubspot_contact_sync_cache
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
AS $refresh_contacts$
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
   nullif(btrim(h.supabase_contact_id), '') AS supabase_id,
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
 FROM (SELECT * FROM hubspot."Contacts" ORDER BY id LIMIT 10000) h
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
$refresh_contacts$;

REVOKE ALL ON FUNCTION brightside.refresh_hubspot_company_sync_cache(text[],text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION brightside.refresh_hubspot_contact_sync_cache(text[],text[]) FROM PUBLIC;
