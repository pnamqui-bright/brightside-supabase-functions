/**
 * Planned inbound HubSpot webhook endpoint.
 *
 * DISABLED: Never acknowledge HubSpot events as processed before signature
 * verification, durable processing, and conflict-safe writes are implemented.
 */
Deno.serve((_request: Request): Response => {
  return Response.json(
    { error: "Not implemented", function: "hubspot-webhook" },
    { status: 501, headers: { "Cache-Control": "no-store" } },
  );
});
