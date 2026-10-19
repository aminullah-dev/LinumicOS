// The same judgement as LinumicCore's MonitorEvaluator
// (Packages/LinumicCore/Sources/LinumicCore/Monitor/MonitorEvaluation.swift).
import type { HealthFormat, Target } from "./targets.ts";

export interface Observation {
  checkedAt: Date;
  statusCode: number | null;
  /** Seconds from sending the request to the end of the body. */
  latency: number | null;
  /** Kept only for health endpoints. */
  body: string | null;
  /** The transport error, when there was no response. */
  failure: string | null;
}

export type State = "up" | "degraded" | "down";
export type Reason = "transport" | "httpStatus" | "unhealthy" | "unreadableHealth" | "slow";

/** One check, in the JSON shape sentinel_record_round() reads. */
export interface Check {
  targetID: string;
  product: string;
  checkedAt: string;
  state: State;
  statusCode: number | null;
  latencyMS: number | null;
  healthStatus: string | null;
  reason: Reason | null;
  failure: string | null;
}

export interface Health {
  status: string;
  database: string | null;
}

/** Reads the body in the given product format; null when it is not that JSON shape. */
export function parseHealth(body: string, format: HealthFormat): Health | null {
  let object: unknown;
  try {
    object = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof object !== "object" || object === null || Array.isArray(object)) return null;
  const o = object as Record<string, unknown>;
  switch (format) {
    case "velroEnvelope":
    case "dataStatus": {
      const inner = o["data"];
      if (typeof inner !== "object" || inner === null) return null;
      const d = inner as Record<string, unknown>;
      const status = d["status"];
      if (typeof status !== "string") return null;
      const database = d["database"];
      return { status, database: typeof database === "string" ? database : null };
    }
    case "okFlag": {
      const ok = o["ok"];
      if (typeof ok !== "boolean") return null;
      return { status: ok ? "ok" : "not ok", database: null };
    }
  }
}

/** Healthy when the status matches and, where a database is reported, it is "ok". */
export function isHealthy(health: Health, expected: string): boolean {
  return health.status === expected && (health.database === null || health.database === "ok");
}

export function evaluate(observation: Observation, target: Target): Check {
  const latencyMS = observation.latency === null ? null : Math.round(observation.latency * 1000);
  const result = (state: State, reason: Reason | null, healthStatus: string | null = null): Check => ({
    targetID: target.id,
    product: target.product,
    checkedAt: observation.checkedAt.toISOString(),
    state,
    statusCode: observation.statusCode,
    latencyMS,
    healthStatus,
    reason,
    failure: observation.failure,
  });
  const code = observation.statusCode;
  if (observation.failure !== null || code === null) return result("down", "transport");
  if (code < 200 || code >= 400) return result("down", "httpStatus");
  let healthStatus: string | null = null;
  if (target.kind.type === "health") {
    const parsed = observation.body === null ? null : parseHealth(observation.body, target.kind.format);
    if (parsed === null) return result("down", "unreadableHealth");
    healthStatus = parsed.status;
    if (!isHealthy(parsed, target.kind.expected)) return result("down", "unhealthy", healthStatus);
  }
  if (observation.latency !== null && observation.latency > target.slowAfter) return result("degraded", "slow", healthStatus);
  return result("up", null, healthStatus);
}
