import { rowStamp } from "../functions/hubspot-webhook/lib/bulk_sync.ts";

Deno.test("bulk sync compares postgres.js Date to PostgreSQL timestamptz text without false changes", () => {
  // postgres.js parses timestamptz as a Date with millisecond precision.
  // The SELECT ... ::text FOR UPDATE query returns six fractional digits.
  const snapshot = new Date("2026-10-02T20:10:28.847Z");
  const locked = "2026-10-02 20:10:28.847549+00";
  if (rowStamp(snapshot) !== rowStamp(locked)) {
    throw Error(`unchanged database row was marked stale: ${rowStamp(snapshot)} vs ${rowStamp(locked)}`);
  }
});

Deno.test("bulk sync preserves meaningful millisecond changes", () => {
  const snapshot = new Date("2026-10-02T20:10:28.847Z");
  const changed = "2026-10-02 20:10:28.848000+00";
  if (rowStamp(snapshot) === rowStamp(changed)) {
    throw Error("a changed millisecond timestamp must not compare equal");
  }
});

Deno.test("bulk sync timestamp normalization preserves missing and invalid values as empty", () => {
  for (const value of [null, undefined, "", "not-a-date", new Date(NaN)]) {
    if (rowStamp(value) !== "") throw Error(`invalid timestamp accepted: ${String(value)}`);
  }
});
