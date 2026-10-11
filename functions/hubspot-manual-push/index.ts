/**
 * Planned, explicitly invoked Supabase -> HubSpot sync endpoint.
 *
 * DISABLED: Must implement authenticated authorization, dry-run preview,
 * explicit manual execution, field-level conflicts, and idempotent writes.
 */
Deno.serve((_request: Request): Response => {
  return Response.json(
    { error: "Not implemented", function: "hubspot-manual-push" },
    { status: 501, headers: { "Cache-Control": "no-store" } },
  );
});
