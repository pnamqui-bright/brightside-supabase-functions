-- Repair HubSpot FDW pagination for the SQL company planner.
-- Without a literal LIMIT pushed into the wrapper, a scan silently returns
-- only its default first page (100 rows). A parameterized LIMIT in the
-- SQL-language preview was NOT pushed down.
-- Query the read-only foreign table via dynamically constructed, integer-only
-- LIMIT so the wrapper enumerates its pages. The cap and +1 row guard fail
-- closed rather than create a misleading "unmatched" plan.

CREATE OR REPLACE FUNCTION brightside._sql_hubspot_fetch_companies(p_limit integer DEFAULT NULL)
RETURNS SETOF hubspot."Companies"
LANGUAGE plpgsql VOLATILE
AS $fetch$
DECLARE
  v_limit integer := coalesce(p_limit, 10000);
  v_rows bigint;
BEGIN
  IF v_limit < 1 OR v_limit > 10000 THEN
    RAISE EXCEPTION 'hubspot_company_preview_limit_must_be_1_to_10000';
  END IF;

  -- Fixed trusted identifier + validated integer literal. No user SQL input.
  RETURN QUERY EXECUTE format(
    'SELECT * FROM hubspot."Companies" ORDER BY id LIMIT %s',
    CASE WHEN p_limit IS NULL THEN 10001 ELSE v_limit END
  );
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF p_limit IS NULL AND v_rows > 10000 THEN
    RAISE EXCEPTION 'hubspot_company_full_scan_cap_reached; refusing partial plan';
  END IF;
END;
$fetch$;

-- Replace only the source of the existing preview function, leaving matching,
-- conflict detection, field rules and output schema exactly as in migration 02.
-- If the expected source SQL differs, abort instead of silently changing logic.
DO $upgrade$
DECLARE
  old_ddl text;
  new_ddl text;
  expected_snippet text := 'FROM hubspot."Companies" h';
BEGIN
  SELECT pg_get_functiondef('brightside.hubspot_sql_company_preview(integer)'::regprocedure)
    INTO old_ddl;
  IF old_ddl IS NULL
     OR length(old_ddl) - length(replace(old_ddl, expected_snippet, ''))
       <> length(expected_snippet)
  THEN
    RAISE EXCEPTION 'preview SQL changed; cannot apply guarded FDW pagination patch';
  END IF;
  new_ddl := replace(
    old_ddl,
    expected_snippet,
    'FROM brightside._sql_hubspot_fetch_companies(p_hubspot_limit) h'
  );
  EXECUTE new_ddl;
END;
$upgrade$;

REVOKE ALL ON FUNCTION brightside._sql_hubspot_fetch_companies(integer) FROM PUBLIC;
