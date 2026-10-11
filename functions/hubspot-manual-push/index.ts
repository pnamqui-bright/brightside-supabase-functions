// The shared library lives inside the other mounted function directory.
// Both sibling function mounts must be present in the self-hosted Docker stack.
import { serveManual } from "../hubspot-webhook/lib/sync.ts";

serveManual("push");
