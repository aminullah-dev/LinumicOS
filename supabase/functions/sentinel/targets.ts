// The Monitor's public targets, copied from LinumicCore so the server checks exactly what the app checks:
// Packages/LinumicCore/Sources/LinumicCore/Monitor/MonitorTargets.swift (MonitorCatalog.targets, 2026-10-09).
// Keep the two lists in step; SentinelTests checks that every Swift target id and URL appears in this file.

export type HealthFormat = "velroEnvelope" | "dataStatus" | "okFlag";

export type CheckKind = { type: "page" } | { type: "health"; format: HealthFormat; expected: string };

export interface Target {
  id: string;
  product: "velro" | "safeBeauty" | "workTrack" | "talar" | "website";
  url: string;
  kind: CheckKind;
  /** Slower than this (seconds) is "degraded". */
  slowAfter: number;
}

const page: CheckKind = { type: "page" };
const health = (format: HealthFormat, expected: string): CheckKind => ({ type: "health", format, expected });

export const targets: Target[] = [
  // VELRO
  { id: "velro.api.live", product: "velro", url: "https://api.velro.linumic.com/healthz", kind: health("velroEnvelope", "alive"), slowAfter: 3 },
  { id: "velro.api.ready", product: "velro", url: "https://api.velro.linumic.com/readyz", kind: health("velroEnvelope", "ready"), slowAfter: 3 },
  { id: "velro.admin", product: "velro", url: "https://admin.velro.linumic.com/", kind: page, slowAfter: 3 },
  // SafeBeauty
  { id: "safebeauty.app", product: "safeBeauty", url: "https://safebeauty.web.app/get", kind: page, slowAfter: 3 },
  { id: "safebeauty.admin", product: "safeBeauty", url: "https://safebeauty-admin.web.app/", kind: page, slowAfter: 3 },
  { id: "safebeauty.admin.domain", product: "safeBeauty", url: "https://9sg9ceuj.linumic.com/", kind: page, slowAfter: 3 },
  { id: "safebeauty.salon", product: "safeBeauty", url: "https://safebeauty-salon.web.app/", kind: page, slowAfter: 3 },
  { id: "safebeauty.salon.domain", product: "safeBeauty", url: "https://salon.linumic.com/", kind: page, slowAfter: 3 },
  // WorkTrack
  { id: "worktrack.api", product: "workTrack", url: "https://worktrack-prod.web.app/v1/health", kind: health("dataStatus", "ok"), slowAfter: 8 },
  { id: "worktrack.portal", product: "workTrack", url: "https://worktrack-prod.web.app/", kind: page, slowAfter: 3 },
  { id: "worktrack.console", product: "workTrack", url: "https://console.linumic.com/", kind: page, slowAfter: 3 },
  { id: "worktrack.demo", product: "workTrack", url: "https://demo.linumic.com/v1/health", kind: health("dataStatus", "ok"), slowAfter: 10 },
  // Talar
  { id: "talar.web", product: "talar", url: "https://talar-af-prod.web.app/", kind: page, slowAfter: 3 },
  {
    id: "talar.api",
    product: "talar",
    url: "https://asia-south1-talar-af-prod.cloudfunctions.net/api/v1/health",
    kind: health("okFlag", "ok"),
    slowAfter: 10,
  },
  // linumic.com
  { id: "website.home", product: "website", url: "https://linumic.com/", kind: page, slowAfter: 3 },
];
