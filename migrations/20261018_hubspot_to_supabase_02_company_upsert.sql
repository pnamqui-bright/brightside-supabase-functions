-- HubSpot -> Supabase company sync, using ONLY the reconciled cache snapshot.
-- Deliberately does not deduplicate by domain/name, and does not change Supabase-owned
-- prospect scores, marketing maturity, social profiles, ICP, or marketing evidence.
-- Conflicted records and sources modified since last refresh are skipped wholesale.
-- New company IDs are 'HUB-'||hubspot_id; no HubSpot API calls.
CREATE OR REPLACE FUNCTION brightside.sync_hubspot_companies_to_supabase(
    p_dry_run boolean DEFAULT true
)
RETURNS TABLE(metric text, total integer)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $h2s_companies$
DECLARE
 v_ready_matched integer:=0;
 v_ready_new integer:=0;
 v_stale integer:=0;
 v_conflict integer:=0;
 v_created integer:=0;
 v_parent_updated integer:=0;
 v_domains_updated integer:=0;
 v_domains_created integer:=0;
 v_phones_updated integer:=0;
 v_phones_created integer:=0;
 v_locations_updated integer:=0;
 v_locations_created integer:=0;
 v_websites_updated integer:=0;
 v_websites_created integer:=0;
 v_rekeyed integer:=0;
BEGIN
 IF p_dry_run IS NULL THEN RAISE EXCEPTION 'p_dry_run must be explicitly true or false'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext('brightside.hubspot_sync_cache.full_seed'));

 IF NOT p_dry_run THEN
   -- Lock matched parents before evaluating cache freshness, to protect against
   -- concurrent local writes while applying all normalized child updates.
   PERFORM 1
   FROM brightside.companies c
   JOIN brightside.hubspot_company_sync_view v ON v.supabase_external_id=c.company_external_id
   WHERE v.status='no_conflict' AND v.identity_status='matched'
   FOR UPDATE OF c;
 END IF;

 DROP TABLE IF EXISTS pg_temp._h2s_company_scope;
 CREATE TEMP TABLE _h2s_company_scope ON COMMIT DROP AS
 SELECT
   v.sync_key,
   v.hubspot_id,
   coalesce(v.supabase_external_id, 'HUB-'||v.hubspot_id) AS target_id,
   v.identity_status,
   v.hubspot_fields AS src,
   c.company_external_id AS existing_id,
   (
     (v.identity_status='matched'
      AND c.company_external_id IS NOT NULL
      AND c.hubspot_export_updated_at IS NOT DISTINCT FROM v.supabase_source_updated_at)
     OR (v.identity_status='hubspot_only' AND c.company_external_id IS NULL)
   ) AS ready,
   (v.identity_status='matched' AND c.company_external_id IS NOT NULL
      AND c.hubspot_export_updated_at IS DISTINCT FROM v.supabase_source_updated_at) AS stale
 FROM brightside.hubspot_company_sync_view v
 LEFT JOIN brightside.companies c ON c.company_external_id=
    coalesce(v.supabase_external_id,'HUB-'||v.hubspot_id)
 WHERE v.hubspot_id IS NOT NULL
   AND (v.status='no_conflict' OR v.identity_status='hubspot_only');

 CREATE UNIQUE INDEX _h2s_company_scope_id_idx ON pg_temp._h2s_company_scope(target_id);
 SELECT count(*) FILTER (WHERE ready AND identity_status='matched')::int,
        count(*) FILTER (WHERE ready AND identity_status='hubspot_only')::int,
        count(*) FILTER (WHERE stale)::int
 INTO v_ready_matched,v_ready_new,v_stale
 FROM pg_temp._h2s_company_scope;

 SELECT count(*)::int INTO v_conflict
 FROM brightside.hubspot_company_sync_view
 WHERE status='conflict';

 IF p_dry_run THEN
   RETURN QUERY SELECT 'matched_eligible'::text,v_ready_matched
   UNION ALL SELECT 'companies_to_create',v_ready_new
   UNION ALL SELECT 'stale_local_skipped',v_stale
   UNION ALL SELECT 'conflicts_skipped',v_conflict
   UNION ALL SELECT 'matched_with_inbound_differences',
     (SELECT count(*)::int FROM pg_temp._h2s_company_scope s
      JOIN brightside.hubspot_company_sync_view v USING(sync_key)
      WHERE s.ready AND s.identity_status='matched'
        AND EXISTS (
          SELECT 1 FROM jsonb_each_text(s.src) f(key,val)
          WHERE f.key=ANY(ARRAY['name','numberofemployees','founded_year',
            'domain','phone','address','address2','city','state','zip','country','website'])
          AND nullif(btrim(f.val),'') IS NOT NULL
          AND nullif(btrim(v.supabase_fields->>f.key),'') IS DISTINCT FROM nullif(btrim(f.val),'')
        ));
   RETURN;
 END IF;

 -- Parent creation: deterministic external ID; never match by name/domain.
 INSERT INTO brightside.companies (
   company_external_id, company_name,employee_count_best,founded_year
 )
 SELECT s.target_id,
        nullif(btrim(s.src->>'name'),''),
        nullif(btrim(s.src->>'numberofemployees'),''),
        nullif(btrim(s.src->>'founded_year'),'')
 FROM pg_temp._h2s_company_scope s
 WHERE s.ready AND s.identity_status='hubspot_only'
 ON CONFLICT (company_external_id) DO NOTHING;
 GET DIAGNOSTICS v_created=ROW_COUNT;

 -- Existing matched records: nonblank HubSpot values may fill/agree with local,
 -- but any divergent populated field was excluded by status='no_conflict'.
 UPDATE brightside.companies c
 SET company_name=coalesce(nullif(btrim(s.src->>'name'),''),c.company_name),
     employee_count_best=coalesce(nullif(btrim(s.src->>'numberofemployees'),''),c.employee_count_best),
     founded_year=coalesce(nullif(btrim(s.src->>'founded_year'),''),c.founded_year)
 FROM pg_temp._h2s_company_scope s
 WHERE s.ready AND s.identity_status='matched'
   AND c.company_external_id=s.target_id
   AND (
     c.company_name IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'name'),''),c.company_name)
     OR c.employee_count_best IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'numberofemployees'),''),c.employee_count_best)
     OR c.founded_year IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'founded_year'),''),c.founded_year)
   );
 GET DIAGNOSTICS v_parent_updated=ROW_COUNT;

 -- Existing child rows updated only when exactly one row belongs to the company.
 -- Missing child rows receive a deterministic child key. Multiple rows are untouched.
   UPDATE brightside.company_domains d
  SET domain=coalesce(nullif(btrim(s.src->>'domain'),''),d.domain)
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready AND d.company_external_id=s.target_id
    AND (SELECT count(*) FROM brightside.company_domains chk WHERE chk.company_external_id=s.target_id)=1
    AND (d.domain IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'domain'),''),d.domain));
  GET DIAGNOSTICS v_domains_updated=ROW_COUNT;

  INSERT INTO brightside.company_domains (
      id,company_external_id,domain
  )
  SELECT 'HUB-DOMAIN-'||s.hubspot_id, s.target_id,
      nullif(btrim(s.src->>'domain'),'')
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready
    AND (nullif(btrim(s.src->>'domain'),'') IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM brightside.company_domains d WHERE d.company_external_id=s.target_id)
  ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_domains_created=ROW_COUNT;

  UPDATE brightside.company_phone_numbers d
  SET phone=coalesce(nullif(btrim(s.src->>'phone'),''),d.phone)
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready AND d.company_external_id=s.target_id
    AND (SELECT count(*) FROM brightside.company_phone_numbers chk WHERE chk.company_external_id=s.target_id)=1
    AND (d.phone IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'phone'),''),d.phone));
  GET DIAGNOSTICS v_phones_updated=ROW_COUNT;

  INSERT INTO brightside.company_phone_numbers (
      id,company_external_id,phone
  )
  SELECT 'HUB-PHONE-'||s.hubspot_id, s.target_id,
      nullif(btrim(s.src->>'phone'),'')
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready
    AND (nullif(btrim(s.src->>'phone'),'') IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM brightside.company_phone_numbers d WHERE d.company_external_id=s.target_id)
  ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_phones_created=ROW_COUNT;

  UPDATE brightside.company_locations d
  SET street_address_1=coalesce(nullif(btrim(s.src->>'address'),''),d.street_address_1),
      street_address_2=coalesce(nullif(btrim(s.src->>'address2'),''),d.street_address_2),
      city=coalesce(nullif(btrim(s.src->>'city'),''),d.city),
      state_province=coalesce(nullif(btrim(s.src->>'state'),''),d.state_province),
      postal_code=coalesce(nullif(btrim(s.src->>'zip'),''),d.postal_code),
      country=coalesce(nullif(btrim(s.src->>'country'),''),d.country)
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready AND d.company_external_id=s.target_id
    AND (SELECT count(*) FROM brightside.company_locations chk WHERE chk.company_external_id=s.target_id)=1
    AND (d.street_address_1 IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'address'),''),d.street_address_1)
      OR d.street_address_2 IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'address2'),''),d.street_address_2)
      OR d.city IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'city'),''),d.city)
      OR d.state_province IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'state'),''),d.state_province)
      OR d.postal_code IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'zip'),''),d.postal_code)
      OR d.country IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'country'),''),d.country));
  GET DIAGNOSTICS v_locations_updated=ROW_COUNT;

  INSERT INTO brightside.company_locations (
      id,company_external_id,street_address_1,street_address_2,city,state_province,postal_code,country
  )
  SELECT 'HUB-LOCATION-'||s.hubspot_id, s.target_id,
      nullif(btrim(s.src->>'address'),''),
      nullif(btrim(s.src->>'address2'),''),
      nullif(btrim(s.src->>'city'),''),
      nullif(btrim(s.src->>'state'),''),
      nullif(btrim(s.src->>'zip'),''),
      nullif(btrim(s.src->>'country'),'')
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready
    AND (nullif(btrim(s.src->>'address'),'') IS NOT NULL OR nullif(btrim(s.src->>'address2'),'') IS NOT NULL OR nullif(btrim(s.src->>'city'),'') IS NOT NULL OR nullif(btrim(s.src->>'state'),'') IS NOT NULL OR nullif(btrim(s.src->>'zip'),'') IS NOT NULL OR nullif(btrim(s.src->>'country'),'') IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM brightside.company_locations d WHERE d.company_external_id=s.target_id)
  ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_locations_created=ROW_COUNT;

  UPDATE brightside.company_websites d
  SET website_url=coalesce(nullif(btrim(s.src->>'website'),''),d.website_url)
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready AND d.company_external_id=s.target_id
    AND (SELECT count(*) FROM brightside.company_websites chk WHERE chk.company_external_id=s.target_id)=1
    AND (d.website_url IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'website'),''),d.website_url));
  GET DIAGNOSTICS v_websites_updated=ROW_COUNT;

  INSERT INTO brightside.company_websites (
      id,company_external_id,website_url
  )
  SELECT 'HUB-WEBSITE-'||s.hubspot_id, s.target_id,
      nullif(btrim(s.src->>'website'),'')
  FROM pg_temp._h2s_company_scope s
  WHERE s.ready
    AND (nullif(btrim(s.src->>'website'),'') IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM brightside.company_websites d WHERE d.company_external_id=s.target_id)
  ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_websites_created=ROW_COUNT;

 -- Promote created HubSpot-only cache identities to their new deterministic local ID.
 -- The next seed refreshes both source versions without generating duplicate h: rows.
 UPDATE brightside.hubspot_company_sync_cache cache
 SET sync_key='s:'||s.target_id,
     supabase_id=s.target_id,
     identity_status='matched'
 FROM pg_temp._h2s_company_scope s
 WHERE cache.sync_key=s.sync_key
   AND s.identity_status='hubspot_only'
   AND s.sync_key <> 's:'||s.target_id
   AND EXISTS(SELECT 1 FROM brightside.companies c WHERE c.company_external_id=s.target_id)
   AND NOT EXISTS(SELECT 1 FROM brightside.hubspot_company_sync_cache other
                  WHERE other.sync_key='s:'||s.target_id);
 GET DIAGNOSTICS v_rekeyed=ROW_COUNT;

 RETURN QUERY SELECT 'companies_created'::text,v_created
 UNION ALL SELECT 'existing_parent_rows_updated',v_parent_updated
 UNION ALL SELECT 'domains_created',v_domains_created
 UNION ALL SELECT 'domains_updated',v_domains_updated
 UNION ALL SELECT 'phones_created',v_phones_created
 UNION ALL SELECT 'phones_updated',v_phones_updated
 UNION ALL SELECT 'locations_created',v_locations_created
 UNION ALL SELECT 'locations_updated',v_locations_updated
 UNION ALL SELECT 'websites_created',v_websites_created
 UNION ALL SELECT 'websites_updated',v_websites_updated
 UNION ALL SELECT 'cache_identities_promoted',v_rekeyed
 UNION ALL SELECT 'stale_local_skipped',v_stale
 UNION ALL SELECT 'conflicts_skipped',v_conflict;
END;
$h2s_companies$;

REVOKE ALL ON FUNCTION brightside.sync_hubspot_companies_to_supabase(boolean)
FROM PUBLIC,anon,authenticated;
