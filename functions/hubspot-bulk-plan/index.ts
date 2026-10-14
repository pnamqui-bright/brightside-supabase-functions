// Read-only Edge Function for the manual bulk-only CLI.
import { serveBulk } from "../hubspot-webhook/lib/bulk_sync.ts";
serveBulk("plan");
