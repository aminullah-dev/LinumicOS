// EMULATOR ONLY. Creates a vendor test user (and two users for the error paths) plus sample companies in the
// local Firebase emulators, project demo-worktrack, for testing Linumic OS's WorkTrack customers screen.
// Refuses to run unless both emulator hosts are set; it never touches a real Firebase project.
// The passwords below exist only in the emulator, which forgets everything when it stops.
//
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
//     node tools/worktrack/emulator-setup.js
//
// firebase-admin is loaded from the WorkTrack repository (WORKTRACK_FUNCTIONS_DIR, default
// ~/Projects/Multiplatform/WorkTrack/backend/functions); nothing is installed here.
const path = require("path");
const os = require("os");
const fnDir = process.env.WORKTRACK_FUNCTIONS_DIR || path.join(os.homedir(), "Projects/Multiplatform/WorkTrack/backend/functions");
const req = require("module").createRequire(path.join(fnDir, "package.json"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("Refusing: FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST must point at the emulators.");
  process.exit(1);
}
const { initializeApp } = req("firebase-admin/app");
const { getAuth } = req("firebase-admin/auth");
const { getFirestore, Timestamp } = req("firebase-admin/firestore");
// demo-worktrack is a "demo-" project id, which the Firebase tools treat as emulator-only.
initializeApp({ projectId: "demo-worktrack" });
const auth = getAuth();
const db = getFirestore();

function kabulToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kabul", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}
function addDays(iso, n) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

async function user(email, password, claims, verified) {
  let u = await auth.getUserByEmail(email).catch(() => null);
  if (!u) u = await auth.createUser({ email, password, emailVerified: verified });
  else await auth.updateUser(u.uid, { password, emailVerified: verified });
  await auth.setCustomUserClaims(u.uid, claims);
  return u.uid;
}

(async () => {
  const today = kabulToday();
  const vendor = await user("vendor@linumic.test", "Emulator-Vendor-Only-1", { vendor: true }, true);
  // Error paths: no vendor claim; vendor claim but unverified email.
  await user("novendor@linumic.test", "Emulator-Vendor-Only-1", {}, true);
  await user("unverified@linumic.test", "Emulator-Vendor-Only-1", { vendor: true }, false);

  const created = Timestamp.fromDate(new Date(Date.now() - 40 * 86400000));
  const companies = {
    emu_herat: {
      name: "شرکت آزمایشی هرات",
      status: "ACTIVE",
      createdAt: created,
      license: { plan: "SILVER", deviceLimit: 30, status: "ACTIVE", expiresAt: addDays(today, 10), enforceDevices: true,
        enforcePlan: true, employeeLimit: 60, extraFeatures: ["projects"], source: "SELF_SERVE" },
    },
    emu_mazar: {
      name: "Mazar Logistics (emulator)",
      status: "ACTIVE",
      createdAt: created,
      license: { plan: "BRONZE", deviceLimit: 20, status: "ACTIVE", expiresAt: addDays(today, -20), enforceDevices: false,
        enforcePlan: false, employeeLimit: null, extraFeatures: [], source: "VENDOR" },
    },
    emu_trial: {
      name: "Trial Bakery (emulator)",
      status: "ACTIVE",
      createdAt: created,
      license: { plan: "TRIAL", deviceLimit: 50, status: "ACTIVE", expiresAt: addDays(today, 5), enforceDevices: false,
        enforcePlan: true, employeeLimit: null, extraFeatures: [], source: "VENDOR" },
    },
    emu_test: {
      name: "Test Company (emulator)",
      status: "ACTIVE",
      createdAt: created,
      license: { plan: "GOLD", deviceLimit: 500, status: "ACTIVE", expiresAt: addDays(today, 3), enforceDevices: false,
        enforcePlan: false, employeeLimit: null, extraFeatures: [], source: "VENDOR" },
      vendorFlags: { kind: "TEST", duplicateOf: null, note: "emulator sample", at: Timestamp.now(), by: "vendor@linumic.test" },
    },
    emu_perpetual: {
      name: "Perpetual Gold (emulator)",
      status: "ACTIVE",
      createdAt: created,
      license: { plan: "GOLD", deviceLimit: 100, status: "ACTIVE", expiresAt: null, enforceDevices: false,
        enforcePlan: false, employeeLimit: null, extraFeatures: [], source: "VENDOR" },
    },
  };
  for (const [id, doc] of Object.entries(companies)) await db.collection("companies").doc(id).set(doc);
  // A paid order, so orders/revenue have something real to return.
  await db.collection("billingOrders").doc("emu_order_1").set({
    companyId: "emu_herat", companyName: companies.emu_herat.name, plan: "SILVER", term: "MONTHLY", months: 1, amountAfn: 3500,
    status: "PAID", createdBy: "x", createdByEmail: null, createdAt: Timestamp.fromDate(new Date(Date.now() - 20 * 86400000)),
    hesabSessionId: null, checkoutUrl: null, paidAt: Timestamp.fromDate(new Date(Date.now() - 20 * 86400000)),
    transactionId: "emu-tx-1", senderAccount: null, licenseBefore: null, licenseAfter: null, failureReason: null,
  });
  console.log(JSON.stringify({ today, vendor, companies: Object.keys(companies) }));
})().catch((e) => { console.error(e); process.exit(1); });
