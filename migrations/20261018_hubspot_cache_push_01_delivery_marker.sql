-- SOURCE-ONLY prototype migration; DO NOT APPLY until batch endpoint is reviewed and approved.
-- Store the cache version last confirmed delivered to HubSpot. No job queue or separate ledger.
-- Unchanged cache refreshes preserve last_changed_at, so version-based delivery
-- suppresses resubmission even before HubSpot data is re-seeded.
ALTER TABLE brightside.hubspot_company_sync_cache
  ADD COLUMN IF NOT EXISTS hubspot_last_applied_version timestamptz,
  ADD COLUMN IF NOT EXISTS hubspot_last_applied_at timestamptz;

ALTER TABLE brightside.hubspot_contact_sync_cache
  ADD COLUMN IF NOT EXISTS hubspot_last_applied_version timestamptz,
  ADD COLUMN IF NOT EXISTS hubspot_last_applied_at timestamptz;

COMMENT ON COLUMN brightside.hubspot_company_sync_cache.hubspot_last_applied_version IS
  'Cache last_changed_at verified applied or already present in HubSpot; not a cross-store transaction.';
COMMENT ON COLUMN brightside.hubspot_contact_sync_cache.hubspot_last_applied_version IS
  'Cache last_changed_at verified applied or already present in HubSpot; not a cross-store transaction.';
