// Stateless bounded execution transport for the manual bulk-only CLI.
import { serveBulk } from "../hubspot-webhook/lib/bulk_sync.ts";
serveBulk("execute");
