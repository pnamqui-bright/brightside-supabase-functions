-- Applied to the previously installed version of migration 05.
-- The source version of migration 05 includes this directive for fresh deployments.
DO $upgrade$
DECLARE old_ddl text;
BEGIN
 SELECT pg_get_functiondef('brightside.hubspot_sql_top_scored_company_preview(integer,integer)'::regprocedure) INTO old_ddl;
 IF old_ddl IS NULL
   OR position(E'AS $function$\nDECLARE' IN old_ddl)=0
   OR position('GET DIAGNOSTICS v_selected = ROW_COUNT' IN old_ddl)=0
 THEN RAISE EXCEPTION 'top-scored preview function changed; refuse repair'; END IF;
 EXECUTE replace(old_ddl,E'AS $function$\nDECLARE',E'AS $function$\n#variable_conflict use_column\nDECLARE');
END $upgrade$;