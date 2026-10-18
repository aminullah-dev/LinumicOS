// deno test supabase/functions/sentinel/ — the same cases as MonitorTests' evaluator tests.
import { assertEquals } from "jsr:@std/assert@1";
import { evaluate, parseHealth } from "./evaluate.ts";
import { targets } from "./targets.ts";

const at = new Date("2026-10-18T09:00:00Z");
const byID = (id: string) => targets.find((t) => t.id === id)!;

Deno.test("catalog has the 15 Monitor targets with unique ids", () => {
  assertEquals(targets.length, 15);
  assertEquals(new Set(targets.map((t) => t.id)).size, 15);
});

Deno.test("healthy VELRO readiness is up", () => {
  const body = '{"success":true,"data":{"status":"ready","database":"ok"}}';
  const c = evaluate({ checkedAt: at, statusCode: 200, latency: 0.2, body, failure: null }, byID("velro.api.ready"));
  assertEquals([c.state, c.reason, c.healthStatus, c.latencyMS], ["up", null, "ready", 200]);
});

Deno.test("database not ok is unhealthy", () => {
  const body = '{"data":{"status":"ready","database":"down"}}';
  const c = evaluate({ checkedAt: at, statusCode: 200, latency: 0.2, body, failure: null }, byID("velro.api.ready"));
  assertEquals([c.state, c.reason], ["down", "unhealthy"]);
});

Deno.test("HTML in place of health JSON is unreadable", () => {
  const c = evaluate({ checkedAt: at, statusCode: 200, latency: 0.1, body: "<html></html>", failure: null }, byID("worktrack.api"));
  assertEquals([c.state, c.reason], ["down", "unreadableHealth"]);
});

Deno.test("Talar ok flag", () => {
  assertEquals(parseHealth('{"ok":true,"service":"talar-api"}', "okFlag"), { status: "ok", database: null });
  assertEquals(parseHealth('{"ok":false}', "okFlag")?.status, "not ok");
  assertEquals(parseHealth("[]", "okFlag"), null);
});

Deno.test("HTTP 503 and transport errors are down", () => {
  const t = byID("website.home");
  assertEquals(evaluate({ checkedAt: at, statusCode: 503, latency: 0.1, body: null, failure: null }, t).reason, "httpStatus");
  const e = evaluate({ checkedAt: at, statusCode: null, latency: null, body: null, failure: "TimeoutError: timed out" }, t);
  assertEquals([e.state, e.reason, e.failure], ["down", "transport", "TimeoutError: timed out"]);
});

Deno.test("slow but correct is degraded; redirects count as up", () => {
  const t = byID("website.home");
  assertEquals(evaluate({ checkedAt: at, statusCode: 200, latency: 3.5, body: null, failure: null }, t).state, "degraded");
  assertEquals(evaluate({ checkedAt: at, statusCode: 302, latency: 0.1, body: null, failure: null }, t).state, "up");
  // WorkTrack's API gets 8 s for a cold start.
  const body = '{"data":{"status":"ok"}}';
  assertEquals(evaluate({ checkedAt: at, statusCode: 200, latency: 6, body, failure: null }, byID("worktrack.api")).state, "up");
});
