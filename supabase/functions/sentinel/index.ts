// Sentinel: one round of the Monitor's public checks, run by pg_cron every 10 minutes while the owner's Mac is off.
//
// Only plain unauthenticated GETs to the public URLs in targets.ts; no credential, cookie or session is sent to them.
// The caller must present the shared secret (x-sentinel-secret), which the database checks against Vault; the
// round is written through sentinel_record_round(), which also turns state changes into sentinel_events.
// Deploy with JWT verification off (the secret replaces it): docs/sentinel.md.
import { type Check, evaluate, type Observation } from "./evaluate.ts";
import { type Target, targets } from "./targets.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const REQUEST_TIMEOUT_MS = 20_000;
const MAX_HEALTH_BODY = 16_384;

async function rpc(name: string, body: unknown): Promise<unknown> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${name}: HTTP ${response.status} ${text.slice(0, 300)}`);
  return text.length ? JSON.parse(text) : null;
}

async function probe(target: Target): Promise<Observation> {
  const checkedAt = new Date();
  const started = performance.now();
  try {
    const response = await fetch(target.url, {
      method: "GET",
      redirect: "follow",
      headers: { "User-Agent": "LinumicOS-Sentinel/1" },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    // Read to the end so the latency covers the whole body, as the app's probe does.
    const text = await response.text();
    const latency = (performance.now() - started) / 1000;
    return {
      checkedAt,
      statusCode: response.status,
      latency,
      body: target.kind.type === "health" ? text.slice(0, MAX_HEALTH_BODY) : null,
      failure: null,
    };
  } catch (error) {
    const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    return { checkedAt, statusCode: null, latency: null, body: null, failure: message.slice(0, 500) };
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "POST only" });
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return json(500, { error: "missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY" });

  const secret = request.headers.get("x-sentinel-secret");
  try {
    if (!secret || (await rpc("sentinel_secret_ok", { candidate: secret })) !== true) {
      return json(401, { error: "unauthorised" });
    }
  } catch (error) {
    return json(502, { error: `secret check failed: ${String(error)}` });
  }

  let source = "cron";
  try {
    const body = await request.json();
    if (body?.source === "manual") source = "manual";
  } catch {
    // An empty body is a scheduled round.
  }

  const startedAt = new Date();
  const checks: Check[] = await Promise.all(targets.map(async (t) => evaluate(await probe(t), t)));
  const finishedAt = new Date();

  try {
    const recorded = await rpc("sentinel_record_round", {
      round: { source, startedAt: startedAt.toISOString(), finishedAt: finishedAt.toISOString(), checks },
    });
    const count = (s: string) => checks.filter((c) => c.state === s).length;
    return json(200, { recorded, up: count("up"), degraded: count("degraded"), down: count("down") });
  } catch (error) {
    return json(502, { error: `recording failed: ${String(error)}` });
  }
});
