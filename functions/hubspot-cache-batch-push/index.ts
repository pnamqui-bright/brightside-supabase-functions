/**
 * PROTOTYPE ONLY: manual cache -> HubSpot batch push.
 * Not deployed. No cron, no webhook subscription, no implicit writes.
 *
 * POST preview (default): { "entity": "companies", "limit": 50 }
 * POST apply: { "action": "apply", "entity": "companies", "limit": 50,
 *               "previewHash": "<preview hash>", "confirm": "APPLY" }
 *
 * A separate reviewed migration adds the two cache delivery marker columns.
 */
import postgres from "npm:postgres@3.4.7";
import { isAuthorizedSecretRequest } from "../hubspot-webhook/lib/auth.ts";
import {
  candidateFromCache, decideRemote, droppedAfterRefresh, mappingProperty, writableProperties,
  type CacheRow, type Candidate, type Entity, type Json,
} from "./lib.ts";

type Pg = ReturnType<typeof postgres>;
type RequestBody = {
  action?: "preview" | "apply";
  entity?: Entity;
  limit?: number;
  after?: string;
  previewHash?: string;
  confirm?: string;
  selectedKeys?: string[];
};

const HUBSPOT_API = "https://api.hubapi.com";
const MAX_BATCH = 100;

function value(v: unknown): string {
  return v === null || v === undefined ? "" : String(v).trim();
}
function respond(body: unknown, code = 200): Response {
  return Response.json(body, {
    status: code,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}
function fail(message: string): never {
  throw new Error("invalid_request: " + message);
}
function parseInput(raw: unknown): Required<Pick<RequestBody, "action" | "entity" | "limit" | "after">> &
  Pick<RequestBody, "previewHash" | "confirm" | "selectedKeys"> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) fail("expected object");
  const input = raw as Record<string, unknown>;
  const action = input.action === undefined ? "preview" : input.action;
  const entity = input.entity;
  const limit = input.limit === undefined ? 50 : input.limit;
  const after = input.after === undefined ? "" : input.after;
  if (action !== "preview" && action !== "apply") fail("action must be preview or apply");
  if (entity !== "companies" && entity !== "contacts") fail("entity must be companies or contacts");
  if (typeof limit !== "number" || !Number.isInteger(limit) || limit < 1 || limit > MAX_BATCH) {
    fail("limit must be an integer from 1 to 100");
  }
  if (typeof after !== "string" || after.length > 255 || /[\r\n]/.test(after)) {
    fail("after must be a sync_key cursor no longer than 255 characters");
  }
  if (input.previewHash !== undefined &&
      (typeof input.previewHash !== "string" || !/^[a-f0-9]{64}$/.test(input.previewHash))) {
    fail("previewHash must be a SHA-256 hex string");
  }
  if (input.confirm !== undefined && typeof input.confirm !== "string") fail("invalid confirm");
  if (input.selectedKeys !== undefined && (
      !Array.isArray(input.selectedKeys) ||
      input.selectedKeys.length < 1 || input.selectedKeys.length > limit ||
      input.selectedKeys.some((key: unknown) => typeof key !== "string" ||
        key.length > 255 || !/^s:[^\r\n]+$/.test(key)) ||
      new Set(input.selectedKeys).size !== input.selectedKeys.length ||
      [...input.selectedKeys].sort().some((key, index) => key !== (input.selectedKeys as string[])[index])
  )) fail("selectedKeys must be 1..limit distinct, ordered Supabase sync keys");
  if (action === "apply" && input.selectedKeys === undefined) {
    fail("apply requires selectedKeys from the reviewed preview");
  }
  return {
    action, entity, limit, after,
    previewHash: input.previewHash as string | undefined,
    confirm: input.confirm as string | undefined,
    selectedKeys: input.selectedKeys as string[] | undefined,
  };
}

async function digest(data: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(data));
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}

const SOURCE = {
  companies: {
    view: "hubspot_company_sync_view",
    cache: "hubspot_company_sync_cache",
    table: "companies",
    primary: "company_external_id",
    refresh: "refresh_hubspot_company_sync_cache",
  },
  contacts: {
    view: "hubspot_contact_sync_view",
    cache: "hubspot_contact_sync_cache",
    table: "contacts",
    primary: "contact_external_id",
    refresh: "refresh_hubspot_contact_sync_cache",
  },
} as const;

/**
 * First selection comes from the existing cache, not another full seed.
 * Intentionally omit the parent-timestamp test at selection time, because
 * refreshing this batch is how locally changed records can become eligible.
 * After refresh, re-apply ALL gates and never top-up with different keys.
 */
async function pendingBatch(
  db: Pg, entity: Entity, after: string, limit: number,
  onlyKeys?: string[], refreshed = false,
): Promise<Candidate[]> {
  const source = SOURCE[entity]; // Fixed allowlist: no client SQL identifiers.
  const mapping = mappingProperty(entity);
  const sql =
    "SELECT v.sync_key, v.hubspot_id, v.supabase_external_id," +
    " v.last_changed_at::text AS last_changed_at," +
    " v.hubspot_source_updated_at::text AS hubspot_source_updated_at," +
    " v.unified_fields, v.hubspot_fields, v.hubspot_records" +
    " FROM brightside." + source.view + " v" +
    " JOIN brightside." + source.cache + " cache USING(sync_key)" +
    " JOIN brightside." + source.table + " p ON p." + source.primary + " = v.supabase_external_id" +
    " WHERE v.sync_key > $1" +
    " AND v.status='no_conflict' AND v.identity_status='matched'" +
    " AND v.hubspot_id ~ '^[0-9]+$'" +
    " AND cache.hubspot_last_applied_version IS DISTINCT FROM cache.last_changed_at" +
    " AND ($5::text[] IS NULL OR v.sync_key=any($5::text[]))" +
    (refreshed
      ? " AND p.hubspot_export_updated_at IS NOT DISTINCT FROM v.supabase_source_updated_at"
      : "") +
    " AND (EXISTS (" +
    "   SELECT 1 FROM jsonb_each_text(coalesce(v.unified_fields,'{}'::jsonb)) f(key,val)" +
    "   WHERE f.key = any($3::text[]) AND nullif(btrim(f.val),'') IS NOT NULL" +
    "     AND nullif(btrim(v.hubspot_fields->>f.key),'') IS NULL" +
    " ) OR nullif(btrim(v.hubspot_records->0->>$4::text),'') IS NULL)" +
    " ORDER BY v.sync_key LIMIT $2";

  const rows = await db.unsafe(sql, [
    after, limit, [...writableProperties(entity)], mapping, onlyKeys ?? null,
  ]);
  const candidates: Candidate[] = [];
  for (const row of rows) {
    const item = candidateFromCache(entity, row as unknown as CacheRow);
    if (!item) throw new Error("Invalid candidate in cache; refresh required");
    candidates.push(item);
  }
  return candidates;
}

/**
 * Single transaction-local refresh for just the SELECTED identities. The
 * existing SQL refresh function updates those cache rows, reads both current
 * Supabase local fields and the HubSpot foreign table and recalculates conflict
 * status. IMPORTANT: in the current FDW implementation it scans HubSpot's
 * inventory once per targeted invocation, not only the requested remote IDs.
 */
async function refreshSelectedBatch(
  db: Pg, entity: Entity, selectedKeys: string[],
): Promise<void> {
  if (!selectedKeys.length) return;
  if (selectedKeys.length > MAX_BATCH) fail("too many selected keys");
  const source = SOURCE[entity];
  const snapshots = await db.unsafe(
    "SELECT sync_key,supabase_id,hubspot_ids FROM brightside." + source.cache +
    " WHERE sync_key=any($1::text[])", [selectedKeys],
  );
  const byKey = new Map(snapshots.map((r) => [value(r.sync_key), r]));
  const localIds: string[] = [];
  const hubspotIds: string[] = [];
  for (const key of selectedKeys) {
    const row = byKey.get(key);
    const remote = row?.hubspot_ids as unknown;
    const remoteId = Array.isArray(remote) && remote.length === 1 ? value(remote[0]) : "";
    const localId = value(row?.supabase_id);
    if (!row || key !== "s:" + localId || !remoteId || !/^\d+$/.test(remoteId)) {
      throw new Error("stale_preview: selected identity changed; refresh/re-preview");
    }
    localIds.push(localId);
    hubspotIds.push(remoteId);
  }
  // 100 IDs per side = 200 supplied IDs, below the SQL helper's 250-ID cap.
  const refreshed = await db.unsafe(
    "SELECT sync_key FROM brightside." + source.refresh +
      "($1::text[],$2::text[])", [localIds,hubspotIds],
  );
  const found = new Set(refreshed.map((r) => value(r.sync_key)));
  if (selectedKeys.some((key) => !found.has(key))) {
    throw new Error("stale_preview: identity remapped during refresh");
  }
}

async function hubspotRequest(token: string, path: string, input: Json): Promise<Json> {
  // No automatic retry of writes: a lost response must be reconciled through
  // a fresh batch read before another attempt.
  const response = await fetch(HUBSPOT_API + path, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(input),
    signal: AbortSignal.timeout(15000),
    redirect: "error",
  });
  if (!response.ok) throw new Error("HubSpot HTTP " + response.status);
  return await response.json() as Json;
}
async function tokenFromVault(db: Pg): Promise<string> {
  const rows = await db.unsafe(
    "select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1",
    ["HUBSPOT_ACCESS_TOKEN"],
  );
  const token = value(rows[0]?.decrypted_secret);
  if (!token) throw new Error("HubSpot token unavailable in Vault");
  return token;
}

function readResults(remote: Json, expected: Candidate[]): Map<string, Json> {
  if (remote.status !== "COMPLETE" ||
      (value(remote.numErrors) !== "" && Number(remote.numErrors) !== 0) ||
      (Array.isArray(remote.errors) && remote.errors.length > 0) ||
      !Array.isArray(remote.results)) {
    throw new Error("HubSpot batch read incomplete; cache unchanged");
  }
  const result = new Map<string, Json>();
  for (const record of remote.results) {
    if (!record || typeof record !== "object" || Array.isArray(record)) continue;
    const r = record as Json;
    const id = value(r.id);
    if (result.has(id)) throw new Error("HubSpot batch read returned duplicate IDs");
    result.set(id, r);
  }
  if (result.size !== expected.length ||
      expected.some((item) => !result.has(item.hubspotId))) {
    throw new Error("HubSpot batch read missing requested IDs");
  }
  return result;
}

async function assertLocalStillFresh(db: Pg, entity: Entity, candidates: Candidate[]): Promise<void> {
  if (!candidates.length) return;
  const source = SOURCE[entity];
  const keys = candidates.map((c) => c.syncKey);
  const rows = await db.unsafe(
    "SELECT v.sync_key, v.last_changed_at::text AS version FROM brightside." + source.view +
    " v JOIN brightside." + source.table +
    " p ON p." + source.primary + " = v.supabase_external_id" +
    " WHERE v.sync_key=any($1::text[]) AND v.status='no_conflict'" +
    " AND v.identity_status='matched'" +
    " AND p.hubspot_export_updated_at IS NOT DISTINCT FROM v.supabase_source_updated_at",
    [keys],
  );
  const found = new Map(rows.map((r) => [value(r.sync_key), value(r.version)]));
  if (found.size !== candidates.length ||
      candidates.some((c) => found.get(c.syncKey) !== c.cacheVersion)) {
    throw new Error("Supabase cache changed since preview; refresh/re-preview");
  }
}

async function markDelivered(db: Pg, entity: Entity, candidates: Candidate[]): Promise<void> {
  if (!candidates.length) return;
  const table = SOURCE[entity].cache;
  await db.begin(async (tx) => {
    for (const candidate of candidates) {
      const changed = await tx.unsafe(
        "UPDATE brightside." + table +
        " SET hubspot_last_applied_version=$2::timestamptz," +
        " hubspot_last_applied_at=clock_timestamp()" +
        " WHERE sync_key=$1 AND last_changed_at=$2::timestamptz" +
        " AND hubspot_last_applied_version IS DISTINCT FROM $2::timestamptz" +
        " RETURNING sync_key",
        [candidate.syncKey, candidate.cacheVersion],
      );
      if (changed.length !== 1) throw new Error("Failed to mark delivered cache version; refresh required");
    }
  });
}

function errorStatus(message: string): number {
  if (message.startsWith("invalid_request:")) return 400;
  if (message.startsWith("stale_preview:")) return 409;
  if (message.startsWith("HubSpot")) return 502;
  return 500;
}

function publicError(e: unknown): string {
  // Do not expose the Vault secret, request headers, SQL args, or HubSpot bodies.
  if (e instanceof Error) {
    const s = e.message;
    if (s.startsWith("invalid_request:") || s.startsWith("stale_preview:") ||
        s.startsWith("HubSpot HTTP ") || s.startsWith("HubSpot batch ")) return s.slice(0, 180);
  }
  return "Batch could not be completed; review logs and refresh the cache before retrying";
}

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method !== "POST") return respond({ error: "POST only" }, 405);
  if (!await isAuthorizedSecretRequest(request, {
    SUPABASE_SECRET_KEYS: Deno.env.get("SUPABASE_SECRET_KEYS"),
    SUPABASE_SECRET_KEY: Deno.env.get("SUPABASE_SECRET_KEY"),
  })) return respond({ error: "Unauthorized" }, 401);

  let db: Pg | undefined;
  try {
    const body = await request.text();
    if (body.length > 35000) fail("request too large");
    const input = parseInput(JSON.parse(body));
    const url = Deno.env.get("SUPABASE_DB_URL");
    if (!url) throw new Error("SUPABASE_DB_URL not configured");
    db = postgres(url, {
      max: 1, prepare: false, connect_timeout: 5, idle_timeout: 5,
    });

    // An apply request must be explicitly approved and enabled before it can
    // even refresh/cache selected identities.
    if (input.action === "apply" && (input.confirm !== "APPLY" || !input.previewHash)) {
      fail("apply requires confirm=APPLY and previewHash");
    }
    if (input.action === "apply" &&
        Deno.env.get("HUBSPOT_CACHE_PUSH_ENABLE_WRITES") !== "true") {
      return respond({ error: "Apply disabled until deployment is explicitly approved" }, 403);
    }

    // Preview: pick the next N cached candidate keys once.
    // Apply: refresh exactly the reviewed selectedKeys from the preview.
    // Neither path refills the batch from later keys if any become ineligible.
    const initial = input.selectedKeys === undefined
      ? await pendingBatch(db, input.entity, input.after, input.limit)
      : [];
    const selectedKeys = input.selectedKeys ?? initial.map((c) => c.syncKey);
    await refreshSelectedBatch(db, input.entity, selectedKeys);
    const candidates = selectedKeys.length
      ? await pendingBatch(
        db, input.entity, input.after, selectedKeys.length, selectedKeys, true,
      )
      : [];
    const noLongerEligible = droppedAfterRefresh(selectedKeys, candidates);
    const nextCursor = selectedKeys.length === input.limit
      ? selectedKeys[selectedKeys.length - 1]
      : undefined;

    // The reviewed hash binds the originally selected IDs to the refreshed
    // candidate payload, including the identities excluded after refresh.
    const previewHash = await digest({
      entity: input.entity, limit: input.limit, after: input.after,
      selectedKeys, candidates, noLongerEligible,
    });
    const preview = {
      entity: input.entity,
      limit: input.limit,
      after: input.after || null,
      nextCursor,
      selectedKeys,
      refreshedCount: selectedKeys.length,
      eligibleCount: candidates.length,
      noLongerEligible,
      count: candidates.length,
      previewHash,
      records: candidates,
    };
    if (input.action === "preview") return respond({ action: "preview", ...preview });

    if (input.previewHash !== previewHash) {
      throw new Error("stale_preview: batch eligibility or values changed after refresh");
    }
    if (!candidates.length) return respond({ action: "apply", ...preview, applied: 0 });

    const token = await tokenFromVault(db);
    const properties = [...new Set(candidates.flatMap((c) => Object.keys(c.properties)))];
    const ids = candidates.map((c) => ({ id: c.hubspotId }));
    const remote = await hubspotRequest(
      token, "/crm/v3/objects/" + input.entity + "/batch/read",
      { inputs: ids, properties },
    );
    const actualRecords = readResults(remote, candidates);
    const ready: { item: Candidate; properties: Record<string, string> }[] = [];
    const aligned: Candidate[] = [];
    const skipped: { hubspotId: string; reason: string }[] = [];
    for (const item of candidates) {
      const choice = decideRemote(item, actualRecords.get(item.hubspotId) ?? null);
      if (choice.kind === "update") ready.push({ item, properties: choice.properties });
      else if (choice.kind === "already_aligned") aligned.push(item);
      else skipped.push({ hubspotId: item.hubspotId, reason: choice.reason });
    }

    // A second local check guards source modifications during HubSpot preflight.
    await assertLocalStillFresh(db, input.entity, [...ready.map((x) => x.item), ...aligned]);

    if (ready.length) {
      const updated = await hubspotRequest(
        token, "/crm/v3/objects/" + input.entity + "/batch/update",
        { inputs: ready.map(({ item, properties: props }) => ({
          id: item.hubspotId, properties: props,
        })) },
      );
      // HubSpot may return status=PENDING/PROCESSING or HTTP 207 with partial
      // failures. Never record delivered markers without a complete, exact response.
      if (updated.status !== "COMPLETE" ||
          Number(updated.numErrors ?? 0) !== 0 ||
          (Array.isArray(updated.errors) && updated.errors.length > 0) ||
          !Array.isArray(updated.results)) {
        throw new Error("HubSpot batch update incomplete; refresh before retry");
      }
      const successful = new Set(
        (updated.results as Json[]).map((r) => value(r?.id)),
      );
      if (successful.size !== ready.length ||
          ready.some(({ item }) => !successful.has(item.hubspotId))) {
        throw new Error("HubSpot batch update results incomplete; refresh before retry");
      }
    }

    // A batch update is not a two-system transaction. If marker persistence
    // fails after HubSpot succeeded, the next preflight must verify HubSpot and
    // may mark values already aligned rather than resending them.
    await markDelivered(db, input.entity, [...ready.map((x) => x.item), ...aligned]);
    return respond({
      action: "apply", entity: input.entity, previewHash,
      selected: candidates.length, updated: ready.length,
      alreadyAligned: aligned.length, skipped,
      markedDelivered: ready.length + aligned.length,
      nextCursor,
    }, skipped.length ? 207 : 200);
  } catch (e) {
    const error = publicError(e);
    return respond({ error }, errorStatus(error));
  } finally {
    if (db) await db.end({ timeout: 2 }).catch(() => {});
  }
});
