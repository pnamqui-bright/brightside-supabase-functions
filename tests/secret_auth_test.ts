import {
  configuredSecretKeys,
  isAuthorizedSecretRequest,
} from "../functions/hubspot-webhook/lib/auth.ts";

const VALID = "sb_secret_test_configuration_a1234567";
const OTHER = "sb_secret_unrelated_secret_b1234567";
const req = (key: string | null, bearer?: string): Request => {
  const headers = new Headers();
  if (key !== null) headers.set("apikey", key);
  if (bearer) headers.set("Authorization", bearer);
  return new Request("https://localhost/functions/v1/hubspot-webhook", {
    method: "POST",
    headers,
  });
};

Deno.test("accepts opaque secret in apikey with self-hosted JSON environment", async () => {
  const config = { SUPABASE_SECRET_KEYS: JSON.stringify({ default: VALID }) };
  if (!await isAuthorizedSecretRequest(req(VALID), config)) {
    throw new Error("valid apikey was rejected");
  }
});

Deno.test("accepts SUPABASE_SECRET_KEY fallback when named key dictionary is absent", async () => {
  if (!await isAuthorizedSecretRequest(req(VALID), { SUPABASE_SECRET_KEY: VALID })) {
    throw new Error("direct secret key was rejected");
  }
});

Deno.test("rejects legacy bearer-based invocation", async () => {
  const env = { SUPABASE_SECRET_KEYS: JSON.stringify({ default: VALID }) };
  if (await isAuthorizedSecretRequest(req(null, "Bearer " + VALID), env)) {
    throw new Error("secret-key bearer header unexpectedly accepted");
  }
});

Deno.test("rejects missing/wrong/publishable API keys", async () => {
  const env = { SUPABASE_SECRET_KEYS: JSON.stringify({ default: VALID }) };
  for (const key of [null, "", OTHER, "sb_publishable_test12345678"]) {
    if (await isAuthorizedSecretRequest(req(key), env)) {
      throw new Error("invalid API key unexpectedly accepted");
    }
  }
});

Deno.test("malformed named-key configuration fails closed", async () => {
  const env = { SUPABASE_SECRET_KEYS: "{malformed", SUPABASE_SECRET_KEY: VALID };
  if (await isAuthorizedSecretRequest(req(VALID), env)) {
    throw new Error("malformed named-key config fell back to direct key");
  }
});

Deno.test("named keys take precedence over fallback", async () => {
  const env = {
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: OTHER }),
    SUPABASE_SECRET_KEY: VALID,
  };
  if (await isAuthorizedSecretRequest(req(VALID), env)) {
    throw new Error("unexpectedly accepted outdated fallback key");
  }
  if (!await isAuthorizedSecretRequest(req(OTHER), env)) {
    throw new Error("named key unexpectedly rejected");
  }
});

Deno.test("empty/missing secret key configuration fails closed", async () => {
  if (configuredSecretKeys({}).length !== 0) throw new Error("no env should yield no keys");
  if (await isAuthorizedSecretRequest(req(VALID), {})) {
    throw new Error("unconfigured authentication accepted a key");
  }
  if (await isAuthorizedSecretRequest(
    req(VALID),
    { SUPABASE_SECRET_KEYS: JSON.stringify({ default: "" }) },
  )) throw new Error("empty named key unexpectedly accepted");
});
