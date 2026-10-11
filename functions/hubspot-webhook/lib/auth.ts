/**
 * Authenticate trusted server-to-server requests with opaque Supabase secret
 * API keys (sb_secret_...). These are not JWTs; clients must send "apikey".
 *
 * On self-hosted Supabase, docker-compose reads SUPABASE_SECRET_KEY from .env
 * and exports SUPABASE_SECRET_KEYS='{"default":"sb_secret_..."}' to Edge Runtime.
 * The optional single-key fallback is useful only for custom/local deployments.
 */
const SECRET_PATTERN = /^sb_secret_[A-Za-z0-9_-]{8,240}$/;

export type SecretKeyEnvironment = {
  SUPABASE_SECRET_KEYS?: string;
  SUPABASE_SECRET_KEY?: string;
};

export function configuredSecretKeys(env: SecretKeyEnvironment): string[] {
  const plural = env.SUPABASE_SECRET_KEYS?.trim();
  if (plural) {
    // If the named key dictionary is present but malformed, fail closed.
    let parsed: unknown;
    try {
      parsed = JSON.parse(plural);
    } catch {
      return [];
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return [];
    return [...new Set(Object.values(parsed).filter(
      (v): v is string => typeof v === "string" && SECRET_PATTERN.test(v),
    ))];
  }
  const fallback = env.SUPABASE_SECRET_KEY?.trim() ?? "";
  return SECRET_PATTERN.test(fallback) ? [fallback] : [];
}

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  ));
}

async function equalsHashed(a: string, b: string): Promise<boolean> {
  const [left, right] = await Promise.all([sha256(a), sha256(b)]);
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  return difference === 0;
}

export async function isAuthorizedSecretRequest(
  request: Request,
  env: SecretKeyEnvironment,
): Promise<boolean> {
  // Never accept Authorization: Bearer sb_secret_... or legacy service-role JWT.
  const supplied = request.headers.get("apikey")?.trim() ?? "";
  if (!SECRET_PATTERN.test(supplied)) return false;
  const allowed = configuredSecretKeys(env);
  if (allowed.length === 0) return false;
  let match = false;
  for (const expected of allowed) {
    // Do not short-circuit; scan every configured key on each request.
    match = await equalsHashed(supplied, expected) || match;
  }
  return match;
}
