import { evaluate, type Pair } from "../functions/hubspot-webhook/lib/bulk_decide.ts";
const monday = "2026-10-12T00:00:00Z";
const tuesday = "2026-10-13T00:00:00Z";
const wednesday = "2026-10-14T00:00:00Z";
const phone: Pair = { property: "phone", local: "780-200", remote: "780-100" };

Deno.test("HubSpot Tuesday phone and Supabase Wednesday name conflict at record level", () => {
  const x = evaluate([phone, {property: "name", local: "New", remote: "Old"}], wednesday, tuesday, monday);
  if (x.status !== "conflict" || x.pull.length || x.push.length) throw Error(JSON.stringify(x));
});
Deno.test("NULL baseline blocks different populated values", () => {
  const x = evaluate([phone], wednesday, tuesday, "");
  if (x.status !== "conflict" || x.reason !== "no_sync_baseline_conflict") throw Error(JSON.stringify(x));
});
Deno.test("NULL baseline permits empty destination fill", () => {
  const x = evaluate([{property:"phone",local:"",remote:"123"}], "", tuesday, "");
  if (x.status !== "eligible" || x.pull.length !== 1) throw Error(JSON.stringify(x));
});
Deno.test("remote-only update is pull", () => {
  const x = evaluate([phone], monday, tuesday, monday);
  if (x.status !== "eligible" || x.pull.length !== 1 || x.push.length) throw Error(JSON.stringify(x));
});
Deno.test("local-only update is push", () => {
  const x = evaluate([phone], tuesday, monday, monday);
  if (x.status !== "eligible" || x.push.length !== 1 || x.pull.length) throw Error(JSON.stringify(x));
});
Deno.test("blank source cannot erase populated destination", () => {
  const x = evaluate([{property:"phone",local:"123",remote:""}],monday,monday,monday);
  if (x.pull.length || x.push.length) throw Error(JSON.stringify(x));
});
Deno.test("push-only mapping never pulls", () => {
  const x = evaluate([{property:"score",local:"80",remote:"50",pushOnly:true}],"","","");
  if (x.status !== "eligible" || x.pull.length || x.push.length !== 1) throw Error(JSON.stringify(x));
});
Deno.test("force override selects one direction only", () => {
  const a = evaluate([phone],wednesday,tuesday,monday,"pull");
  const b = evaluate([phone],wednesday,tuesday,monday,"push");
  if (a.status !== "eligible" || a.pull.length !== 1 || a.push.length) throw Error(JSON.stringify(a));
  if (b.status !== "eligible" || b.push.length !== 1 || b.pull.length) throw Error(JSON.stringify(b));
});
Deno.test("missing last-modified timestamps fail closed", () => {
  const x = evaluate([phone],"",tuesday,monday);
  if (x.status !== "conflict") throw Error(JSON.stringify(x));
});
