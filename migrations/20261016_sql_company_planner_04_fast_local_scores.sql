-- Make SQL company comparison compute only the requested company's score.
-- This view is read-only and uses the exact existing scoring model.
-- Tested with SELECT EXCEPT ALL: source and candidate field values identical.
CREATE OR REPLACE VIEW brightside._sql_hubspot_local_companies
WITH (security_invoker = true) AS
SELECT c.company_external_id AS supabase_id,
    c.hubspot_export_updated_at AS local_updated_at,
    c.hubspot_last_synced_at AS last_synced_at,
    COALESCE(cardinality(d.domain_values) > 1, false) OR COALESCE(cardinality(ph.phone_values) > 1, false) OR COALESCE(cardinality(web.website_url_values) > 1, false) OR COALESCE(cardinality(v.icp_vertical_values) > 1, false) OR COALESCE(cardinality(loc.street_address_1_values) > 1, false) OR COALESCE(cardinality(loc.street_address_2_values) > 1, false) OR COALESCE(cardinality(loc.city_values) > 1, false) OR COALESCE(cardinality(loc.state_province_values) > 1, false) OR COALESCE(cardinality(loc.postal_code_values) > 1, false) OR COALESCE(cardinality(loc.country_values) > 1, false) AS ambiguous_mapped_values,
    jsonb_build_object('name', COALESCE(btrim(c.company_name), ''::text), 'domain', COALESCE(d.domain_values[1], ''::text), 'phone', COALESCE(ph.phone_values[1], ''::text), 'address', COALESCE(loc.street_address_1_values[1], ''::text), 'address2', COALESCE(loc.street_address_2_values[1], ''::text), 'city', COALESCE(loc.city_values[1], ''::text), 'state', COALESCE(loc.state_province_values[1], ''::text), 'zip', COALESCE(loc.postal_code_values[1], ''::text), 'country', COALESCE(loc.country_values[1], ''::text), 'website', COALESCE(web.website_url_values[1], ''::text), 'numberofemployees',
        CASE
            WHEN btrim(COALESCE(c.employee_count_best, ''::text)) ~ '^[0-9]{1,9}$'::text THEN btrim(c.employee_count_best)::integer::text
            ELSE ''::text
        END, 'linkedin_company_page', COALESCE(sp.linkedin_url, ''::text), 'facebook_company_page', COALESCE(sp.facebook_url, ''::text), 'instagram_url', COALESCE(sp.instagram_url, ''::text), 'tiktok_url', COALESCE(sp.tiktok_url, ''::text), 'prospect_score_supabase', COALESCE((SELECT sc.score::text FROM brightside.company_scores_current sc WHERE sc.company_external_id = c.company_external_id), ''::text), 'marketing_maturity_supabase', COALESCE(btrim(c.observed_marketing_maturity), ''::text), 'icp_vertical', COALESCE(v.icp_vertical_values[1], ''::text), 'revenue_tier', COALESCE(btrim(c.estimated_revenue_tier), ''::text), 'last_prospect_scan', brightside._sql_hubspot_iso(c.last_scanned_at)) AS field_values
   FROM brightside.companies c
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT NULLIF(btrim(x.domain), ''::text)) FILTER (WHERE NULLIF(btrim(x.domain), ''::text) IS NOT NULL) AS domain_values
           FROM brightside.company_domains x
          WHERE x.company_external_id = c.company_external_id) d ON true
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT NULLIF(btrim(x.phone), ''::text)) FILTER (WHERE NULLIF(btrim(x.phone), ''::text) IS NOT NULL) AS phone_values
           FROM brightside.company_phone_numbers x
          WHERE x.company_external_id = c.company_external_id) ph ON true
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT NULLIF(btrim(x.street_address_1), ''::text)) FILTER (WHERE NULLIF(btrim(x.street_address_1), ''::text) IS NOT NULL) AS street_address_1_values,
            array_agg(DISTINCT NULLIF(btrim(x.street_address_2), ''::text)) FILTER (WHERE NULLIF(btrim(x.street_address_2), ''::text) IS NOT NULL) AS street_address_2_values,
            array_agg(DISTINCT NULLIF(btrim(x.city), ''::text)) FILTER (WHERE NULLIF(btrim(x.city), ''::text) IS NOT NULL) AS city_values,
            array_agg(DISTINCT NULLIF(btrim(x.state_province), ''::text)) FILTER (WHERE NULLIF(btrim(x.state_province), ''::text) IS NOT NULL) AS state_province_values,
            array_agg(DISTINCT NULLIF(btrim(x.postal_code), ''::text)) FILTER (WHERE NULLIF(btrim(x.postal_code), ''::text) IS NOT NULL) AS postal_code_values,
            array_agg(DISTINCT NULLIF(btrim(x.country), ''::text)) FILTER (WHERE NULLIF(btrim(x.country), ''::text) IS NOT NULL) AS country_values
           FROM brightside.company_locations x
          WHERE x.company_external_id = c.company_external_id) loc ON true
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT NULLIF(btrim(x.website_url), ''::text)) FILTER (WHERE NULLIF(btrim(x.website_url), ''::text) IS NOT NULL) AS website_url_values
           FROM brightside.company_websites x
          WHERE x.company_external_id = c.company_external_id) web ON true
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT NULLIF(btrim(x.icp_vertical), ''::text)) FILTER (WHERE NULLIF(btrim(x.icp_vertical), ''::text) IS NOT NULL) AS icp_vertical_values
           FROM brightside.company_verticals x
          WHERE x.company_external_id = c.company_external_id) v ON true
     LEFT JOIN LATERAL ( SELECT max(ranked.profile_url) FILTER (WHERE ranked.platform = 'linkedin'::text AND ranked.rn = 1) AS linkedin_url,
            max(ranked.profile_url) FILTER (WHERE ranked.platform = 'facebook'::text AND ranked.rn = 1) AS facebook_url,
            max(ranked.profile_url) FILTER (WHERE ranked.platform = 'instagram'::text AND ranked.rn = 1) AS instagram_url,
            max(ranked.profile_url) FILTER (WHERE ranked.platform = 'tiktok'::text AND ranked.rn = 1) AS tiktok_url
           FROM ( SELECT p.profile_url,
                        CASE
                            WHEN p.platform = 'others'::text AND lower(p.profile_url) ~~ '%linkedin.%'::text THEN 'linkedin'::text
                            ELSE p.platform
                        END AS platform,
                    row_number() OVER (PARTITION BY (
                        CASE
                            WHEN p.platform = 'others'::text AND lower(p.profile_url) ~~ '%linkedin.%'::text THEN 'linkedin'::text
                            ELSE p.platform
                        END) ORDER BY p.observed_at DESC NULLS LAST, p.profile_url) AS rn
                   FROM brightside.company_social_profiles p
                  WHERE p.company_external_id = c.company_external_id AND NULLIF(btrim(p.profile_url), ''::text) IS NOT NULL) ranked) sp ON true
     
  WHERE NOT (EXISTS ( SELECT 1
           FROM brightside.company_relationships r
          WHERE r.relationship_type = 'merged_into'::text AND r.from_company_external_id = c.company_external_id));

DO $check$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid='brightside._sql_hubspot_local_companies'::regclass AND 'security_invoker=true'=ANY(c.reloptions) AND position('( SELECT sc.score::text' IN pg_get_viewdef(c.oid,true))>0) THEN
    RAISE EXCEPTION 'SQL company scoring preview view verification failed';
  END IF;
END $check$;
