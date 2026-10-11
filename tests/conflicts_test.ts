import { decide } from "../functions/hubspot-webhook/lib/decide.ts";

const older = "2026-10-08T00:00:00Z";
const newer = "2026-10-10T00:00:00Z";

Deno.test("pull picks a genuinely newer HubSpot property", () => {
  const result = decide("pull", "old", "new", older, newer);
  if (result.action !== "update") throw new Error(JSON.stringify(result));
});
Deno.test("pull does not overwrite a possibly newer Supabase record", () => {
  const result = decide("pull", "new", "old", newer, older);
  if (result.action !== "skip") throw new Error(JSON.stringify(result));
});
Deno.test("push picks newer Supabase record timestamp", () => {
  const result = decide("push", "new", "old", newer, older);
  if (result.action !== "update") throw new Error(JSON.stringify(result));
});
Deno.test("push blocks a possibly newer HubSpot property", () => {
  const result = decide("push", "old", "new", older, newer);
  if (result.action !== "skip") throw new Error(JSON.stringify(result));
});
Deno.test("empty destination can be populated in either direction", () => {
  if (decide("pull", "", "remote", "", "").action !== "update") {
    throw new Error("pull should fill blank");
  }
  if (decide("push", "local", "", "", "").action !== "update") {
    throw new Error("push should fill blank");
  }
});
Deno.test("empty source never deletes destination", () => {
  if (decide("pull", "local", "", older, newer).action !== "skip") {
    throw new Error("pull must not clear data");
  }
  if (decide("push", "", "remote", newer, older).action !== "skip") {
    throw new Error("push must not clear data");
  }
});
Deno.test("no history, equality and ties are conservative", () => {
  if (decide("pull", "local", "remote", "", older).action !== "skip") {
    throw new Error("missing timestamp must skip");
  }
  if (decide("push", "local", "remote", newer, newer).action !== "skip") {
    throw new Error("tied timestamp must skip");
  }
  if (decide("push", "same", "same", newer, older).action !== "skip") {
    throw new Error("equal value must skip");
  }
});
