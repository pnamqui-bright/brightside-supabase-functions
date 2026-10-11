import { serveManual } from "./lib/sync.ts";

// For now, this endpoint is strictly manually invoked, NOT a HubSpot webhook.
// A signed HubSpot event will NOT authenticate here. No automatic subscriptions.
serveManual("pull");
