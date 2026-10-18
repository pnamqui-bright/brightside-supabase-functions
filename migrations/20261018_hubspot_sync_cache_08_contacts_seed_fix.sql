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
            brightside._sql_hubspot_canonical_company(h.supabase_company_id) AS supabase_id,
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
          SELECT nullif(btrim(h.supabase_contact_id),'') AS supabase_id,
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
