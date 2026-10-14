-- REVIEW-ONLY migration. Do not run against production without deployment approval.
-- Record-level sync baselines; NULL means no established successful sync.
ALTER TABLE brightside.companies
  ADD COLUMN IF NOT EXISTS hubspot_last_synced_at timestamptz;
ALTER TABLE brightside.contacts
  ADD COLUMN IF NOT EXISTS hubspot_last_synced_at timestamptz;

COMMENT ON COLUMN brightside.companies.hubspot_last_synced_at IS
  'Last successful verified bidirectional bulk reconciliation. NULL = not established; not a per-field timestamp.';
COMMENT ON COLUMN brightside.contacts.hubspot_last_synced_at IS
  'Last successful verified bidirectional bulk reconciliation. NULL = not established; not a per-field timestamp.';

-- Preserve the existing source-change trigger's behavior while ensuring a
-- baseline-only UPDATE is not falsely recorded as a Supabase source edit.
CREATE OR REPLACE FUNCTION brightside._hubspot_export_stamp_record()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, brightside
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.hubspot_export_created_at := coalesce(NEW.hubspot_export_created_at, clock_timestamp());
    NEW.hubspot_export_updated_at := coalesce(NEW.hubspot_export_updated_at, NEW.hubspot_export_created_at);
  ELSE
    NEW.hubspot_export_created_at := OLD.hubspot_export_created_at;
    IF (to_jsonb(NEW) - 'hubspot_export_created_at' - 'hubspot_export_updated_at' - 'hubspot_last_synced_at')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'hubspot_export_created_at' - 'hubspot_export_updated_at' - 'hubspot_last_synced_at') THEN
      NEW.hubspot_export_updated_at := clock_timestamp();
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
