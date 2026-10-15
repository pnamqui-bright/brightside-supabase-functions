# Supabase company deduplication and primary-record maintenance

**Status:** Interim operating guidelines for humans and agents. This file can later move into a Supabase maintenance skill or the prospecting skill.

**Scope:** Supabase company data and its related records. This is **not** a HubSpot deduplication procedure, a HubSpot write authorization, or a change to bidirectional sync behavior.

## Core rule

**Linking duplicate companies is not the same as reconciling their data. A deduplication is complete only when all relevant differences have been resolved and the chosen primary Supabase company contains the resolved values.**

The bidirectional HubSpot sync treats the **primary/canonical company** as the sync target. It resolves confirmed duplicate IDs for identity matching; it does **not** examine the latest values or modification timestamps on secondary companies, choose the best data among them, or copy their fields into the primary.

Consequently, **any update discovered on an already-merged secondary company must be reconciled against the primary**, even if the secondary was updated more recently. Do not leave important changes exclusively on a merged record and assume HubSpot sync will pick them up.

## Terms and existing relationships

- **Primary / canonical company:** The Supabase company ID whose reconciled information is maintained and synchronized.
- **Merged duplicate / secondary company:** A separate Supabase company representing the same business and linked to the primary through `brightside.company_relationships` with `relationship_type = 'merged_into'`.
- **Relationship direction:** `from_company_external_id` (secondary) -> `to_company_external_id` (primary). If links form a chain, resolve to the final primary; do not create cycles or conflicting targets.
- **`linked` is not `merged_into`:** Related organizations, facilities, or legitimately distinct branches may be linked without being duplicate records. Do not consolidate them merely because they share a website or domain.

A shared normalized domain is a strong duplicate *candidate* signal, not automatic proof that separate physical locations or business entities are one record. Check enough identity evidence (such as company name, location, and operating identity) to distinguish repeated imports from real branches.

## Select and preserve the established primary

1. **Check for an existing `merged_into` mapping first.** If one exists, keep its final target as the primary; do not select a new primary because another record is newer or more complete.
2. **If the original HubSpot import already selected a Supabase company ID for the domain, respect that established ID** (`supabase_company_id`) when it corresponds to the same business. This is an identity reference only; do not modify HubSpot as part of this workflow.
3. If multiple incompatible primary candidates exist, the relationship is invalid, or the business identity is ambiguous, **stop and flag the case for a decision**. Do not choose arbitrarily or turn distinct branches into one record.

## Required reconciliation workflow

Perform this **before marking a new duplicate as merged**, and for any previously merged record whose information may not yet have been reconciled.

1. **Collect the complete Supabase record set:** Read the primary and all secondary company rows and their relevant child data (domains, websites, phone numbers, addresses/locations, social profiles, company verticals, service areas, research/scores, and linked contacts where relevant). Preserve source record IDs and provenance.
2. **Compare information field by field:** Separate equal values, complementary values (for example, a nonempty field missing on the primary), and true disagreements. Compare collections rather than blindly overwriting one collection with another.
3. **Resolve each relevant disagreement using evidence:** Consider the underlying source, observation time, accuracy, and business identity. A more recent *record-level* update does not establish that every field in that record is newer or correct. Prefer a defensible value; retain legitimate multi-valued information in the appropriate child table when the schema permits it.
4. **Record unresolved questions:** If competing populated values cannot be resolved confidently, do not silently overwrite either value or mark reconciliation complete. Record which fields are unresolved, their sources, and the next action. Escalate for human judgment as needed.
5. **Write the resolved information to the primary Supabase company:** Update its parent fields and appropriate child rows as necessary. Preserve unrelated values, existing IDs, provenance, and legitimate company/contact relationships. Do not delete secondary records as a shortcut. If a contact's association must change, verify it is the correct business before altering it.
6. **Record or verify the relationship:** Once the identity and data reconciliation are settled, record `merged_into` from each secondary ID to the established primary (or verify an existing link). Do not convert `linked` relationships into merges without confirming they are duplicates.
7. **Verify the result:** Read back the primary, relevant child records, and merge links. Confirm each resolved fact is available from the primary, no unrelated data was lost, and no unresolved issue has been silently dismissed.

Keep a concise reconciliation note or work log identifying the secondary and primary IDs, fields changed, supporting sources, material decisions, outstanding conflicts (if any), and the verification result. The storage location for this log can be defined when these guidelines become a skill.

## Mandatory rule for subsequent updates

Before an agent or human writes *new* company information into Supabase:

1. Look up whether the destination company ID is a `merged_into` secondary; if so, resolve its final primary.
2. Compare the incoming data with the **current primary** and reconcile any differences using the same field-level evidence rules.
3. **Write the resolved company information to the primary**, not solely to the secondary. Preserve independent raw observations/provenance when required, but never treat storing them on a secondary as completing the primary update.
4. Verify the primary reflects the resolved information and document any unresolved conflict.

This applies to prospect scans, imports, manual edits, enrichments, and maintenance jobs. If a workflow cannot safely reconcile and update the primary, **stop or flag the update** rather than silently changing only the secondary.

## Interaction with HubSpot synchronization

- The sync planner/executor are responsible for matching the **canonical identity**, not for consolidating source data from secondary Supabase records.
- After the primary is updated, normal bidirectional conflict rules still apply. A newer secondary record is not itself a reason to push; the primary's mapped data and modification/baseline timestamps determine the sync decision.
- **Do not manipulate `hubspot_last_synced_at` or the Supabase export-update timestamp to force a direction.** Let the existing sync and database timestamp machinery operate normally.
- A data reconciliation can legitimately lead to a push, an already-equal outcome, or a sync conflict. Do not force a sync merely because deduplication was completed.
- The existing `brightside.hubspot_companies_export` and `brightside.hubspot_contacts_export` views have **not yet** been updated to honor `merged_into` relationships; that limitation is tracked separately and is not solved by these guidelines.

## Existing merged relationships: one-time caveat

**An existing `merged_into` link is proof of an identity relationship, not proof that data was reconciled.** Previously linked groups (including the recently created bulk links) should be audited for secondary-only or conflicting values before they are considered fully reconciled. Do not unlink or change their chosen primary IDs merely to avoid that audit.

## Completion checklist

- [ ] The primary company ID is established and respected.
- [ ] The records truly represent the same business; distinct branches are preserved.
- [ ] Relevant parent and child data from all secondaries was compared.
- [ ] Conflicts were resolved with evidence, or explicitly flagged as outstanding.
- [ ] Resolved data is saved on the primary and verified by reading it back.
- [ ] `merged_into` links point from secondary IDs to the primary without ambiguity.
- [ ] Related contacts and provenance remain correct.
- [ ] Future writes will resolve the primary rather than update only a secondary.
- [ ] No HubSpot record, sync baseline, or export view was modified as part of deduplication unless separately authorized.
