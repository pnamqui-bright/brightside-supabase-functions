-- HubSpot -> Supabase contact sync from unified cache only.
-- Matched records: update agreed shared fields and unambiguous contact_channels.
-- HubSpot-only records: create deterministic HUB-CONTACT-<HubSpot ID> ONLY when
-- HubSpot's explicit supabase_company_id property identifies an existing company.
-- Never infer company links via name/domain/email; never edit associations or consent.
-- Preserve all unrelated Supabase fields, marketing consent, provenance and notes.
CREATE OR REPLACE FUNCTION brightside.sync_hubspot_contacts_to_supabase(
    p_dry_run boolean DEFAULT true
)
RETURNS TABLE(metric text,total integer)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $h2s_contacts$
DECLARE
 v_ready_matched integer:=0;
 v_ready_new integer:=0;
 v_missing_parent integer:=0;
 v_stale integer:=0;
 v_conflicts integer:=0;
 v_created integer:=0;
 v_parent_updated integer:=0;
 v_channels_updated integer:=0;
 v_channels_created integer:=0;
 v_rekeyed integer:=0;
BEGIN
 IF p_dry_run IS NULL THEN RAISE EXCEPTION 'p_dry_run must be explicitly true or false'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext('brightside.hubspot_sync_cache.full_seed'));

 IF NOT p_dry_run THEN
   PERFORM 1 FROM brightside.contacts c
   JOIN brightside.hubspot_contact_sync_view v ON v.supabase_external_id=c.contact_external_id
   WHERE v.status='no_conflict' AND v.identity_status='matched'
   FOR UPDATE OF c;
 END IF;

 DROP TABLE IF EXISTS pg_temp._h2s_contact_scope;
 CREATE TEMP TABLE _h2s_contact_scope ON COMMIT DROP AS
 SELECT
   v.sync_key,
   v.hubspot_id,
   coalesce(v.supabase_external_id,'HUB-CONTACT-'||v.hubspot_id) AS target_id,
   v.identity_status,
   v.hubspot_fields AS src,
   c.contact_external_id AS existing_id,
   brightside._sql_hubspot_canonical_company(
     nullif(btrim(v.hubspot_fields->>'supabase_company_id'),'')
   ) AS parent_id,
   (v.identity_status='matched' AND c.contact_external_id IS NOT NULL
      AND c.hubspot_export_updated_at IS NOT DISTINCT FROM v.supabase_source_updated_at
    OR v.identity_status='hubspot_only' AND c.contact_external_id IS NULL
       AND EXISTS(
         SELECT 1 FROM brightside.companies p
         WHERE p.company_external_id=brightside._sql_hubspot_canonical_company(
           nullif(btrim(v.hubspot_fields->>'supabase_company_id'),'')
         )
       )
   ) AS ready,
   (v.identity_status='matched' AND c.contact_external_id IS NOT NULL
      AND c.hubspot_export_updated_at IS DISTINCT FROM v.supabase_source_updated_at) AS stale
 FROM brightside.hubspot_contact_sync_view v
 LEFT JOIN brightside.contacts c ON c.contact_external_id=
   coalesce(v.supabase_external_id,'HUB-CONTACT-'||v.hubspot_id)
 WHERE v.hubspot_id IS NOT NULL AND (v.status='no_conflict' OR v.identity_status='hubspot_only');

 CREATE UNIQUE INDEX _h2s_contact_scope_key_idx ON pg_temp._h2s_contact_scope(target_id);

 SELECT count(*) FILTER(WHERE ready AND identity_status='matched')::int,
        count(*) FILTER(WHERE ready AND identity_status='hubspot_only')::int,
        count(*) FILTER(WHERE identity_status='hubspot_only' AND NOT ready AND existing_id IS NULL)::int,
        count(*) FILTER(WHERE stale)::int
 INTO v_ready_matched,v_ready_new,v_missing_parent,v_stale
 FROM pg_temp._h2s_contact_scope;

 SELECT count(*)::int INTO v_conflicts
 FROM brightside.hubspot_contact_sync_view WHERE status='conflict';

 IF p_dry_run THEN
   RETURN QUERY SELECT 'matched_eligible'::text,v_ready_matched
   UNION ALL SELECT 'contacts_to_create',v_ready_new
   UNION ALL SELECT 'missing_company_link_skipped',v_missing_parent
   UNION ALL SELECT 'stale_local_skipped',v_stale
   UNION ALL SELECT 'conflicts_skipped',v_conflicts
   UNION ALL SELECT 'matched_with_inbound_differences',
      (SELECT count(*)::int FROM pg_temp._h2s_contact_scope s
       JOIN brightside.hubspot_contact_sync_view v USING(sync_key)
       WHERE s.ready AND s.identity_status='matched'
         AND EXISTS(
           SELECT 1 FROM jsonb_each_text(s.src) field(key,val)
           WHERE field.key=ANY(ARRAY['firstname','lastname','email','phone',
             'jobtitle','seniority','hs_linkedin_url','role_category_supabase'])
             AND nullif(btrim(field.val),'') IS NOT NULL
             AND nullif(btrim(v.supabase_fields->>field.key),'')
                 IS DISTINCT FROM nullif(btrim(field.val),'')
         ));
   RETURN;
 END IF;

 INSERT INTO brightside.contacts (
   contact_external_id,company_external_id,first_name,last_name,full_name,
   job_title,seniority,role_category
 )
 SELECT s.target_id,s.parent_id,
   nullif(btrim(s.src->>'firstname'),''),
   nullif(btrim(s.src->>'lastname'),''),
   nullif(btrim(concat_ws(' ',nullif(btrim(s.src->>'firstname'),''),
                                  nullif(btrim(s.src->>'lastname'),''))),''),
   nullif(btrim(s.src->>'jobtitle'),''),
   nullif(btrim(s.src->>'seniority'),''),
   nullif(btrim(s.src->>'role_category_supabase'),'')
 FROM pg_temp._h2s_contact_scope s
 WHERE s.ready AND s.identity_status='hubspot_only'
 ON CONFLICT (contact_external_id) DO NOTHING;
 GET DIAGNOSTICS v_created=ROW_COUNT;

 UPDATE brightside.contacts c
 SET first_name=coalesce(nullif(btrim(s.src->>'firstname'),''),c.first_name),
     last_name=coalesce(nullif(btrim(s.src->>'lastname'),''),c.last_name),
     job_title=coalesce(nullif(btrim(s.src->>'jobtitle'),''),c.job_title),
     seniority=coalesce(nullif(btrim(s.src->>'seniority'),''),c.seniority),
     role_category=coalesce(nullif(btrim(s.src->>'role_category_supabase'),''),c.role_category)
 FROM pg_temp._h2s_contact_scope s
 WHERE s.ready AND s.identity_status='matched' AND c.contact_external_id=s.target_id
   AND (
      c.first_name IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'firstname'),''),c.first_name)
      OR c.last_name IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'lastname'),''),c.last_name)
      OR c.job_title IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'jobtitle'),''),c.job_title)
      OR c.seniority IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'seniority'),''),c.seniority)
      OR c.role_category IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'role_category_supabase'),''),c.role_category)
   );
 GET DIAGNOSTICS v_parent_updated=ROW_COUNT;

 -- Exactly one channel row: update only missing/agreed nonblank values.
 UPDATE brightside.contact_channels ch
 SET email=coalesce(nullif(btrim(s.src->>'email'),''),ch.email),
     phone=coalesce(nullif(btrim(s.src->>'phone'),''),ch.phone),
     linkedin_url=coalesce(nullif(btrim(s.src->>'hs_linkedin_url'),''),ch.linkedin_url)
 FROM pg_temp._h2s_contact_scope s
 WHERE s.ready
   AND ch.contact_external_id=s.target_id
   AND (SELECT count(*) FROM brightside.contact_channels other
        WHERE other.contact_external_id=s.target_id)=1
   AND (
     ch.email IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'email'),''),ch.email)
     OR ch.phone IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'phone'),''),ch.phone)
     OR ch.linkedin_url IS DISTINCT FROM coalesce(nullif(btrim(s.src->>'hs_linkedin_url'),''),ch.linkedin_url)
   );
 GET DIAGNOSTICS v_channels_updated=ROW_COUNT;

 INSERT INTO brightside.contact_channels (
     id,contact_external_id,email,phone,linkedin_url
 )
 SELECT 'HUB-CHANNEL-'||s.hubspot_id,s.target_id,
        nullif(btrim(s.src->>'email'),''),
        nullif(btrim(s.src->>'phone'),''),
        nullif(btrim(s.src->>'hs_linkedin_url'),'')
 FROM pg_temp._h2s_contact_scope s
 WHERE s.ready
   AND (nullif(btrim(s.src->>'email'),'') IS NOT NULL
     OR nullif(btrim(s.src->>'phone'),'') IS NOT NULL
     OR nullif(btrim(s.src->>'hs_linkedin_url'),'') IS NOT NULL)
   AND NOT EXISTS (
      SELECT 1 FROM brightside.contact_channels ch WHERE ch.contact_external_id=s.target_id
   )
 ON CONFLICT (id) DO NOTHING;
 GET DIAGNOSTICS v_channels_created=ROW_COUNT;

 UPDATE brightside.hubspot_contact_sync_cache cache
 SET sync_key='s:'||s.target_id,
     supabase_id=s.target_id,
     identity_status='matched'
 FROM pg_temp._h2s_contact_scope s
 WHERE cache.sync_key=s.sync_key
   AND s.identity_status='hubspot_only'
   AND s.sync_key <> 's:'||s.target_id
   AND EXISTS(SELECT 1 FROM brightside.contacts c WHERE c.contact_external_id=s.target_id)
   AND NOT EXISTS(SELECT 1 FROM brightside.hubspot_contact_sync_cache other
                  WHERE other.sync_key='s:'||s.target_id);
 GET DIAGNOSTICS v_rekeyed=ROW_COUNT;

 RETURN QUERY SELECT 'contacts_created'::text,v_created
 UNION ALL SELECT 'contact_parent_rows_updated',v_parent_updated
 UNION ALL SELECT 'contact_channels_created',v_channels_created
 UNION ALL SELECT 'contact_channels_updated',v_channels_updated
 UNION ALL SELECT 'cache_identities_promoted',v_rekeyed
 UNION ALL SELECT 'missing_company_link_skipped',v_missing_parent
 UNION ALL SELECT 'stale_local_skipped',v_stale
 UNION ALL SELECT 'conflicts_skipped',v_conflicts;
END;
$h2s_contacts$;

REVOKE ALL ON FUNCTION brightside.sync_hubspot_contacts_to_supabase(boolean)
FROM PUBLIC,anon,authenticated;