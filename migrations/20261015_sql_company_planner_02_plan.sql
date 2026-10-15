-- Manual SQL planner for HubSpot companies. Companies only; contacts need
-- a separate HubSpot contacts FDW and verified company-association source.
-- No HubSpot PATCH, Supabase CRM writes, cron, or automatic apply.
-- SOURCE MIGRATION ONLY; review before deployment.

CREATE OR REPLACE FUNCTION brightside.hubspot_sql_company_preview(p_hubspot_limit integer DEFAULT NULL)
RETURNS TABLE (
  hubspot_id text,
  supabase_id text,
  status text,
  reason text,
  directions text[],
  pull_fields text[],
  push_fields text[],
  blocked_push_fields text[],
  local_updated_at timestamptz,
  hubspot_updated_at timestamptz,
  last_synced_at timestamptz,
  details jsonb
)
LANGUAGE sql VOLATILE
AS $preview$
WITH
-- HubSpot is contacted ONCE per preview. Use only a small LIMIT for diagnostics.
-- A limited preview must NEVER become an executable full plan.
remote AS MATERIALIZED (
  SELECT
    h.id AS hubspot_id,
    nullif(btrim(h.supabase_company_id), '') AS raw_link,
    brightside._sql_hubspot_canonical_company(h.supabase_company_id) AS canonical_link,
    brightside._sql_hubspot_domain(h.domain) AS domain_key,
    brightside._sql_hubspot_domain(h.website) AS website_key,
    (h.updated_at AT TIME ZONE 'UTC') AS remote_stamp,
    jsonb_build_object(
      'name', coalesce(btrim(h.name), ''),
      'domain', coalesce(btrim(h.domain), ''),
      'phone', coalesce(btrim(h.phone), ''),
      'address', coalesce(btrim(h.address), ''),
      'address2', coalesce(btrim(h.address2), ''),
      'city', coalesce(btrim(h.city), ''),
      'state', coalesce(btrim(h.state), ''),
      'zip', coalesce(btrim(h.zip), ''),
      'country', coalesce(btrim(h.country), ''),
      'website', coalesce(btrim(h.website), ''),
      'numberofemployees', coalesce(btrim(h.numberofemployees), ''),
      'linkedin_company_page', coalesce(btrim(h.linkedin_company_page), ''),
      'facebook_company_page', coalesce(btrim(h.facebook_company_page), ''),
      'instagram_url', coalesce(btrim(h.instagram_url), ''),
      'tiktok_url', coalesce(btrim(h.tiktok_url), ''),
      'prospect_score_supabase', coalesce(btrim(h.prospect_score_supabase), ''),
      'marketing_maturity_supabase', coalesce(btrim(h.marketing_maturity_supabase), ''),
      'icp_vertical', coalesce(btrim(h.icp_vertical), ''),
      'revenue_tier', coalesce(btrim(h.revenue_tier), ''),
      'last_prospect_scan', coalesce(btrim(h.last_prospect_scan), '')
    ) AS remote_fields
  FROM hubspot."Companies" h
  WHERE h.id IS NOT NULL
  ORDER BY h.id
  LIMIT coalesce(p_hubspot_limit, 2147483647)
),
-- Explicitly declared merged_into links only. Local search keys from secondary
-- records are indexed under the established primary; data is never reconciled.
local_keys AS MATERIALIZED (
  SELECT DISTINCT
    brightside._sql_hubspot_domain(source.value) AS domain_key,
    brightside._sql_hubspot_canonical_company(source.company_external_id) AS supabase_id
  FROM (
    SELECT company_external_id, domain AS value FROM brightside.company_domains
    UNION ALL
    SELECT company_external_id, website_url AS value FROM brightside.company_websites
  ) source
  WHERE brightside._sql_hubspot_domain(source.value) IS NOT NULL
),
remote_keys AS (
  SELECT hubspot_id, domain_key FROM remote WHERE domain_key IS NOT NULL
  UNION
  SELECT hubspot_id, website_key FROM remote WHERE website_key IS NOT NULL
),
natural_candidates AS (
  SELECT DISTINCT rk.hubspot_id, lk.supabase_id
  FROM remote_keys rk
  JOIN local_keys lk ON lk.domain_key = rk.domain_key
),
natural_match AS (
  SELECT hubspot_id, count(DISTINCT supabase_id) AS candidate_count,
         min(supabase_id) AS candidate_id
  FROM natural_candidates
  GROUP BY hubspot_id
),
identity AS (
  SELECT
    r.*,
    coalesce(n.candidate_count, 0) AS natural_count,
    n.candidate_id AS natural_id,
    coalesce(r.canonical_link, n.candidate_id, 'hubspot-company-' || r.hubspot_id) AS resolved_id,
    CASE
      WHEN coalesce(n.candidate_count, 0) > 1 THEN 'ambiguous_domain_or_email_match'
      WHEN r.canonical_link IS NOT NULL AND n.candidate_id IS NOT NULL
        AND r.canonical_link <> n.candidate_id
        THEN 'external_id_conflicts_with_natural_match'
      ELSE NULL
    END AS identity_error
  FROM remote r
  LEFT JOIN natural_match n ON n.hubspot_id = r.hubspot_id
),
matched AS (
  SELECT
    i.*,
    local.field_values AS local_fields,
    local.local_updated_at,
    local.last_synced_at,
    coalesce(local.ambiguous_mapped_values, false) AS ambiguous_mapped_values,
    local.supabase_id IS NOT NULL AS existing_local,
    count(*) OVER (PARTITION BY i.resolved_id) AS hubspot_records_for_local,
    coalesce(local.local_updated_at > local.last_synced_at, false) AS local_changed,
    coalesce(i.remote_stamp > local.last_synced_at, false) AS hubspot_changed
  FROM identity i
  LEFT JOIN brightside._sql_hubspot_local_companies local ON local.supabase_id = i.resolved_id
),
compared AS (
  SELECT
    m.*,
    diffs.pull_fields,
    diffs.proposed_push_fields,
    diffs.invalid_enum_fields,
    diffs.divergent_fields,
    coalesce(cardinality(diffs.divergent_fields), 0) > 0 AS has_divergence
  FROM matched m
  CROSS JOIN LATERAL (
    SELECT
      coalesce(array_agg(e.key ORDER BY e.key) FILTER (WHERE action = 'pull'), ARRAY[]::text[]) AS pull_fields,
      coalesce(array_agg(e.key ORDER BY e.key) FILTER (WHERE action = 'push'), ARRAY[]::text[]) AS proposed_push_fields,
      coalesce(array_agg(e.key ORDER BY e.key) FILTER (WHERE NOT enum_valid), ARRAY[]::text[]) AS invalid_enum_fields,
      coalesce(array_agg(e.key ORDER BY e.key) FILTER (
        WHERE enum_valid AND NOT push_only AND local_value <> '' AND remote_value <> '' AND local_value <> remote_value
      ), ARRAY[]::text[]) AS divergent_fields
    FROM jsonb_each_text(m.remote_fields) AS e(key, val)
    CROSS JOIN LATERAL (
      SELECT btrim(coalesce(m.local_fields ->> e.key, '')) AS local_value,
             btrim(coalesce(e.val, '')) AS remote_value,
             e.key = ANY(ARRAY['linkedin_company_page', 'facebook_company_page', 'instagram_url', 'tiktok_url', 'prospect_score_supabase', 'marketing_maturity_supabase', 'icp_vertical', 'revenue_tier', 'last_prospect_scan']::text[]) AS push_only,
             brightside._sql_hubspot_valid_company_enum(e.key, coalesce(m.local_fields ->> e.key, '')) AS enum_valid
    ) values_for_field
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN NOT enum_valid OR local_value = remote_value THEN NULL
        WHEN push_only THEN CASE WHEN local_value <> '' THEN 'push' END
        WHEN local_value = '' AND remote_value <> '' THEN 'pull'
        WHEN remote_value = '' AND local_value <> '' THEN 'push'
        WHEN m.last_synced_at IS NOT NULL AND m.hubspot_changed AND NOT m.local_changed THEN 'pull'
        WHEN m.last_synced_at IS NOT NULL AND m.local_changed AND NOT m.hubspot_changed THEN 'push'
        ELSE NULL
      END AS action
    ) decision
  ) diffs
),
classified AS (
  SELECT
    c.*,
    CASE
      WHEN c.identity_error IS NOT NULL THEN 'skipped'
      WHEN c.hubspot_records_for_local > 1 THEN 'conflict'
      WHEN c.ambiguous_mapped_values THEN 'skipped'
      WHEN NOT c.existing_local AND c.raw_link IS NOT NULL THEN 'skipped'
      WHEN c.existing_local AND c.last_synced_at IS NULL AND c.has_divergence THEN 'conflict'
      WHEN c.existing_local AND c.last_synced_at IS NOT NULL
        AND (c.local_updated_at IS NULL OR c.remote_stamp IS NULL) THEN 'conflict'
      WHEN c.existing_local AND c.last_synced_at IS NOT NULL
        AND c.local_changed AND c.hubspot_changed THEN 'conflict'
      WHEN c.existing_local AND c.last_synced_at IS NOT NULL
        AND NOT c.local_changed AND NOT c.hubspot_changed AND c.has_divergence THEN 'conflict'
      WHEN NOT c.existing_local AND cardinality(c.pull_fields) = 0 THEN 'skipped'
      WHEN cardinality(c.pull_fields) > 0
        OR (c.existing_local AND c.last_synced_at IS NULL)
        OR (cardinality(c.proposed_push_fields) > 0 AND c.raw_link = c.resolved_id)
        THEN 'work'
      WHEN cardinality(c.proposed_push_fields) > 0 AND c.raw_link IS DISTINCT FROM c.resolved_id
        THEN 'skipped'
      ELSE 'equal'
    END AS classification,
    CASE
      WHEN c.identity_error IS NOT NULL THEN c.identity_error
      WHEN c.hubspot_records_for_local > 1 THEN 'duplicate_hubspot_match'
      WHEN c.ambiguous_mapped_values THEN 'ambiguous_supabase_export_values'
      WHEN NOT c.existing_local AND c.raw_link IS NOT NULL THEN 'unknown_supabase_external_id'
      WHEN c.existing_local AND c.last_synced_at IS NULL AND c.has_divergence THEN 'no_sync_baseline_conflict'
      WHEN c.existing_local AND c.last_synced_at IS NOT NULL
        AND (c.local_updated_at IS NULL OR c.remote_stamp IS NULL) THEN 'missing_modification_timestamp'
      WHEN c.existing_local AND c.last_synced_at IS NOT NULL
        AND c.local_changed AND c.hubspot_changed THEN 'both_sides_changed_since_last_sync'
      WHEN c.existing_local AND c.last_synced_at IS NOT NULL
        AND NOT c.local_changed AND NOT c.hubspot_changed AND c.has_divergence
        THEN 'unexplained_divergence_since_last_sync'
      WHEN NOT c.existing_local AND cardinality(c.pull_fields) = 0 THEN 'new_record_has_no_mapped_values'
      WHEN c.existing_local AND c.last_synced_at IS NULL AND NOT c.has_divergence THEN 'bootstrap_sync_baseline'
      WHEN cardinality(c.pull_fields) > 0
        OR (cardinality(c.proposed_push_fields) > 0 AND c.raw_link = c.resolved_id)
        THEN 'safe_bulk_changes'
      WHEN cardinality(c.proposed_push_fields) > 0 AND c.raw_link IS DISTINCT FROM c.resolved_id
        THEN 'outbound_requires_external_id_link'
      ELSE 'already_equal'
    END AS classification_reason
  FROM compared c
),
results AS (
  SELECT
    c.hubspot_id,
    c.resolved_id AS supabase_id,
    c.classification AS status,
    c.classification_reason AS reason,
    CASE WHEN c.classification = 'work' THEN
      array_remove(ARRAY[
        CASE WHEN cardinality(c.pull_fields) > 0
          OR (c.existing_local AND c.last_synced_at IS NULL) THEN 'pull'::text END,
        CASE WHEN cardinality(c.proposed_push_fields) > 0
          AND c.raw_link = c.resolved_id THEN 'push'::text END
      ], NULL)
      ELSE ARRAY[]::text[] END AS directions,
    c.pull_fields,
    CASE WHEN c.raw_link = c.resolved_id THEN c.proposed_push_fields
         ELSE ARRAY[]::text[] END AS push_fields,
    CASE WHEN c.raw_link IS DISTINCT FROM c.resolved_id THEN c.proposed_push_fields
         ELSE ARRAY[]::text[] END AS blocked_push_fields,
    c.local_updated_at,
    c.remote_stamp AS hubspot_updated_at,
    c.last_synced_at,
    jsonb_build_object(
      'existing_local', c.existing_local,
      'raw_external_id', c.raw_link,
      'natural_match_count', c.natural_count,
      'hubspot_matches_for_local', c.hubspot_records_for_local,
      'divergent_fields', c.divergent_fields,
      'invalid_enum_fields', c.invalid_enum_fields,
      'local_changed', c.local_changed,
      'hubspot_changed', c.hubspot_changed
    ) AS details
  FROM classified c
)
SELECT * FROM results
UNION ALL
SELECT
  NULL::text AS hubspot_id,
  local.supabase_id,
  'skipped'::text AS status,
  'unmatched_outbound_no_creation'::text AS reason,
  ARRAY[]::text[] AS directions,
  ARRAY[]::text[] AS pull_fields,
  ARRAY[]::text[] AS push_fields,
  ARRAY[]::text[] AS blocked_push_fields,
  local.local_updated_at,
  NULL::timestamptz AS hubspot_updated_at,
  local.last_synced_at,
  jsonb_build_object('existing_local', true) AS details
FROM brightside._sql_hubspot_local_companies local
WHERE p_hubspot_limit IS NULL
  AND NOT EXISTS (SELECT 1 FROM matched m WHERE m.resolved_id = local.supabase_id);
$preview$;

-- Persist immutable plan decisions; not CRM data, not an apply queue.
CREATE TABLE IF NOT EXISTS brightside.hubspot_sql_company_plan_runs (
  run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  status text NOT NULL DEFAULT 'planning' CHECK (status IN ('planning','ready')),
  source text NOT NULL DEFAULT 'hubspot_fdw_and_supabase',
  object_type text NOT NULL DEFAULT 'companies' CHECK (object_type = 'companies'),
  summary jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS brightside.hubspot_sql_company_plan_items (
  run_id uuid NOT NULL REFERENCES brightside.hubspot_sql_company_plan_runs(run_id) ON DELETE CASCADE,
  record_key text NOT NULL,
  hubspot_id text,
  supabase_id text,
  status text NOT NULL,
  reason text NOT NULL,
  directions text[] NOT NULL DEFAULT ARRAY[]::text[],
  pull_fields text[] NOT NULL DEFAULT ARRAY[]::text[],
  push_fields text[] NOT NULL DEFAULT ARRAY[]::text[],
  blocked_push_fields text[] NOT NULL DEFAULT ARRAY[]::text[],
  local_updated_at timestamptz,
  hubspot_updated_at timestamptz,
  last_synced_at timestamptz,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (run_id,record_key),
  CONSTRAINT manual_sql_company_plan_ids CHECK (hubspot_id IS NOT NULL OR supabase_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS hubspot_sql_company_plan_items_status_idx
  ON brightside.hubspot_sql_company_plan_items (run_id, status);

-- Manual invocation only. A committed plan is a snapshot for human review.
-- Future Apply MUST fetch current values and revalidate timestamps/conflicts.
CREATE OR REPLACE FUNCTION brightside.hubspot_sql_create_company_plan()
RETURNS uuid LANGUAGE plpgsql VOLATILE
AS $create$
DECLARE
  new_run uuid;
BEGIN
  INSERT INTO brightside.hubspot_sql_company_plan_runs DEFAULT VALUES
    RETURNING run_id INTO new_run;

  INSERT INTO brightside.hubspot_sql_company_plan_items (
    run_id, record_key, hubspot_id, supabase_id, status, reason, directions,
    pull_fields, push_fields, blocked_push_fields,
    local_updated_at, hubspot_updated_at, last_synced_at, details
  )
  SELECT
    new_run,
    CASE WHEN p.hubspot_id IS NOT NULL THEN 'hubspot:' || p.hubspot_id
         ELSE 'supabase:' || p.supabase_id END,
    p.hubspot_id, p.supabase_id, p.status, p.reason, p.directions,
    p.pull_fields, p.push_fields, p.blocked_push_fields,
    p.local_updated_at, p.hubspot_updated_at, p.last_synced_at, p.details
  FROM brightside.hubspot_sql_company_preview(NULL) p;

  UPDATE brightside.hubspot_sql_company_plan_runs r
  SET status = 'ready', completed_at = clock_timestamp(),
      summary = (
        SELECT jsonb_build_object(
          'rows', count(*),
          'work', count(*) FILTER (WHERE status = 'work'),
          'conflict', count(*) FILTER (WHERE status = 'conflict'),
          'skipped', count(*) FILTER (WHERE status = 'skipped'),
          'equal', count(*) FILTER (WHERE status = 'equal'),
          'pull', count(*) FILTER (WHERE 'pull' = ANY(directions)),
          'push', count(*) FILTER (WHERE 'push' = ANY(directions))
        )
        FROM brightside.hubspot_sql_company_plan_items i
        WHERE i.run_id = new_run
      )
  WHERE r.run_id = new_run;
  RETURN new_run;
END;
$create$;

-- The executable worklist is IDs + directions only.
CREATE OR REPLACE VIEW brightside.hubspot_sql_company_plan_worklist
WITH (security_invoker = true) AS
SELECT i.run_id, i.hubspot_id, i.supabase_id, direction
FROM brightside.hubspot_sql_company_plan_items i
CROSS JOIN LATERAL unnest(i.directions) AS direction
WHERE i.status = 'work';

REVOKE ALL ON FUNCTION brightside.hubspot_sql_company_preview(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION brightside.hubspot_sql_create_company_plan() FROM PUBLIC;
REVOKE ALL ON brightside.hubspot_sql_company_plan_runs FROM PUBLIC;
REVOKE ALL ON brightside.hubspot_sql_company_plan_items FROM PUBLIC;
REVOKE ALL ON brightside.hubspot_sql_company_plan_worklist FROM PUBLIC;
