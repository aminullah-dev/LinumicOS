// EMULATOR ONLY. Adds what Linumic OS's Talar overview reads, on top of Talar's own seed, in the local Firebase
// emulators (project demo-talar): a dedicated admin account, a non-admin account for the error path, two halls
// awaiting review, a pending review and two payouts. Refuses to run unless both emulator hosts are set; it never
// touches a real Firebase project. The password below exists only in the emulator, which forgets everything when
// it stops.
//
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
//     node tools/talar/emulator-setup.js
//
// firebase-admin is loaded from the Talar repository (TALAR_FUNCTIONS_DIR, default
// ~/Projects/Multiplatform/Talar/backend/functions); nothing is installed here.
const path = require("path");
const os = require("os");
const fnDir = process.env.TALAR_FUNCTIONS_DIR || path.join(os.homedir(), "Projects/Multiplatform/Talar/backend/functions");
const req = require("module").createRequire(path.join(fnDir, "package.json"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("Refusing: FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST must point at the emulators.");
  process.exit(1);
}
const { initializeApp } = req("firebase-admin/app");
const { getAuth } = req("firebase-admin/auth");
const { getFirestore, Timestamp } = req("firebase-admin/firestore");
// demo-talar is a "demo-" project id, which the Firebase tools treat as emulator-only.
initializeApp({ projectId: "demo-talar" });
const auth = getAuth();
const db = getFirestore();
const PASSWORD = "Emulator-Admin-Only-1";

async function user(email, claims) {
  let u = await auth.getUserByEmail(email).catch(() => null);
  if (!u) u = await auth.createUser({ email, password: PASSWORD, emailVerified: true });
  else await auth.updateUser(u.uid, { password: PASSWORD, emailVerified: true });
  // The same claim shape Talar's /v1/admin/bootstrap writes (`role: "admin"`, lib/auth.ts requireRole).
  await auth.setCustomUserClaims(u.uid, claims);
  return u.uid;
}

(async () => {
  const admin = await user("admin@linumic.test", { role: "admin" });
  const customer = await user("customer@linumic.test", { role: "customer" });
  const ago = (days) => Timestamp.fromDate(new Date(Date.now() - days * 86400000));

  // Halls awaiting review: the fields halls/routes.ts hallSchema accepts, status pending_review.
  const pending = {
    "emu-hall-pending-1": {
      name: { fa: "تالار آزمایشی بهار", ps: "د پسرلي ازمایښتي تالار", en: "Bahar Test Hall (emulator)" },
      cityId: "kabul", district: "district-5", geo: { lat: 34.53, lng: 69.17 }, hallType: "luxury",
      capacity: { total: 800, mens: 400, womens: 400 }, amenities: ["parking", "generator"],
      shifts: ["EVENING", "FULL_DAY"], hallFeeMinor: 25000000, currency: "AFN", depositPct: 30, instantBooking: false,
      refundRules: [{ minDaysBefore: 30, refundPct: 80 }], orgId: "org-demo", createdBy: "owner-demo", createdAt: ago(2),
    },
    "emu-hall-pending-2": {
      name: { fa: "باغ آزمایشی", en: "Garden Test Venue (emulator)" },
      cityId: "herat", geo: { lat: 34.35, lng: 62.2 }, hallType: "garden",
      capacity: { total: 300, mens: 150, womens: 150 }, amenities: [], shifts: ["MORNING"],
      hallFeeMinor: 0, currency: "AFN", depositPct: 20, instantBooking: true, refundRules: [],
      orgId: "org-demo", createdBy: "owner-demo", createdAt: ago(1),
    },
  };
  for (const [id, hall] of Object.entries(pending)) {
    await db.collection("halls").doc(id).set({
      ...hall, status: "pending_review", priceRange: { minPerGuestMinor: 0, maxPerGuestMinor: 0, currency: hall.currency },
      rating: { avg: 0, count: 0 }, searchTokens: [],
    });
  }

  // A review awaiting moderation (reviews/routes.ts creates them with status pending).
  await db.doc("halls/hall-aryana/reviews/emu-review-pending").set({
    customerUid: customer, bookingId: "booking-demo", rating: 4, aspects: { food: 5, service: 4 },
    text: "Emulator sample review awaiting moderation.", status: "pending", reply: null, createdAt: ago(0.5),
  });

  // Two payouts of org-demo, in the shape payments/payouts.ts runSettlementForOrg writes.
  const payouts = db.collection("organizations").doc("org-demo").collection("payouts");
  await payouts.doc("emu-payout-pending").set({
    periodTo: "2026-10-08", grossMinor: 10000000, commissionMinor: 500000, commissionPct: 5, netMinor: 9500000,
    currency: "AFN", paymentIds: ["emu-pay-1", "emu-pay-2"], status: "pending", createdBy: admin, createdAt: ago(1), paidAt: null,
  });
  await payouts.doc("emu-payout-paid").set({
    periodTo: "2026-09-30", grossMinor: 4000000, commissionMinor: 200000, commissionPct: 5, netMinor: 3800000,
    currency: "AFN", paymentIds: ["emu-pay-0"], status: "paid", createdBy: admin, createdAt: ago(9), paidAt: ago(8), paidBy: admin,
  });
  console.log(JSON.stringify({ admin, customer, pendingHalls: Object.keys(pending), review: "emu-review-pending", payouts: 2 }));
})().catch((e) => { console.error(e); process.exit(1); });
