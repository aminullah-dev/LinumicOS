// EMULATOR ONLY. Creates a SafeBeauty admin account (and a customer for the error path) plus sample queues in the
// local Firebase emulators, project demo-safebeauty, for testing Linumic OS's SafeBeauty overview. Refuses to run
// unless both emulator hosts are set; it never touches a real Firebase project. Every name, number and password
// below is made up and exists only in the emulator, which forgets everything when it stops.
//
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
//     node tools/safebeauty/emulator-setup.js
//
// Accounts are written the way SafeBeauty's registration writes them: users/{appUid} with pinHash =
// PBKDF2(password, salt) (functions/shared.js pbkdf2Hash) and a Firebase Auth user whose password is
// PBKDF2("AUTH:" + password, salt) (public/admin/index.html deriveAuthPassword, ios PinHasher.deriveAuthPassword).
// firebase-admin is loaded from the SafeBeauty repository (SAFEBEAUTY_FUNCTIONS_DIR, default
// ~/Projects/Multiplatform/Safe beauty/functions); nothing is installed here.
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const fnDir = process.env.SAFEBEAUTY_FUNCTIONS_DIR || path.join(os.homedir(), "Projects/Multiplatform/Safe beauty/functions");
const req = require("module").createRequire(path.join(fnDir, "package.json"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("Refusing: FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST must point at the emulators.");
  process.exit(1);
}
const { initializeApp } = req("firebase-admin/app");
const { getAuth } = req("firebase-admin/auth");
const { getFirestore } = req("firebase-admin/firestore");
initializeApp({ projectId: "demo-safebeauty" });
const auth = getAuth();
const db = getFirestore();
const PASSWORD = "Emulator-Admin-Only-1";

const pbkdf2 = (text, saltB64) => crypto.pbkdf2Sync(String(text), Buffer.from(saltB64, "base64"), 65536, 32, "sha256").toString("base64");

async function account(appUid, phone, name, role, extra = {}) {
  const salt = crypto.randomBytes(16).toString("base64");
  const firebaseEmail = `${appUid}@sb.app`;
  const authPassword = pbkdf2("AUTH:" + PASSWORD, salt);
  const existing = await auth.getUserByEmail(firebaseEmail).catch(() => null);
  if (existing) await auth.updateUser(existing.uid, { password: authPassword });
  else await auth.createUser({ email: firebaseEmail, password: authPassword });
  await db.doc(`users/${appUid}`).set({
    name, phone, role, status: "APPROVED", kycStatus: "NONE", firebaseEmail, salt, pinHash: pbkdf2(PASSWORD, salt),
    createdAt: Date.now() - 30 * 86400000, ...extra,
  });
}

function kabulMidnight(offsetDays = 0) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kabul", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  // Kabul is UTC+4:30 all year.
  return Date.parse(`${parts}T00:00:00+04:30`) + offsetDays * 86400000;
}

(async () => {
  await account("emu-admin", "+93700000099", "Emulator Admin", "ADMIN");
  await account("emu-customer", "+93700000098", "Emulator Customer", "CUSTOMER");
  // KYC queue: identity fields present so the test can prove Linumic OS never downloads them.
  await account("emu-kyc-1", "+93700000011", "مریم آزمایشی", "CUSTOMER", {
    kycStatus: "PENDING", tazkiraNumber: "EMU-0000-0001", tazkiraPhotoPath: "kyc/emu-kyc-1/tazkira.jpg",
    selfiePhotoPath: "kyc/emu-kyc-1/selfie.jpg", birthYear: 1999, addressProvince: "Kabul",
  });
  await account("emu-kyc-2", "+93700000012", "Salon Owner KYC (emulator)", "PROVIDER", {
    kycStatus: "PENDING", status: "PENDING", tazkiraNumber: "EMU-0000-0002", tazkiraPhotoPath: "kyc/emu-kyc-2/tazkira.jpg",
  });
  // Provider approval queue (users status PENDING, public/admin/index.html renderApprovals).
  await account("emu-provider-1", "+93700000013", "Herat Beauty (emulator)", "PROVIDER", { status: "PENDING" });

  const salons = {
    "emu-salon-1": { name: "Emulator Salon One", providerId: "emu-provider-1", isVerified: true },
    "emu-salon-2": { name: "Emulator Salon Two", providerId: "emu-kyc-2", isVerified: false },
    "emu-salon-3": { name: "Emulator Salon Three", providerId: "emu-provider-1" },
  };
  for (const [id, s] of Object.entries(salons)) await db.doc(`salons/${id}`).set({ ...s, createdAt: Date.now() });

  // Appointments: appointmentDate is epoch milliseconds (functions/domains/bookings.js).
  const appts = {
    "emu-appt-today-1": kabulMidnight(0) + 10 * 3600000,
    "emu-appt-today-2": kabulMidnight(0) + 15 * 3600000,
    "emu-appt-tomorrow": kabulMidnight(1) + 11 * 3600000,
    "emu-appt-last-month": kabulMidnight(-30) + 11 * 3600000,
  };
  for (const [id, at] of Object.entries(appts)) {
    await db.doc(`appointments/${id}`).set({ appointmentDate: at, status: "CONFIRMED", salonId: "emu-salon-1", customerId: "emu-customer", serviceName: "Emulator service" });
  }

  // Money: positive = the platform owes the salon (payout due); negative = the salon owes the platform.
  await db.doc("provider_balances/emu-provider-1").set({ providerId: "emu-provider-1", owedAmount: 4200, updatedAt: Date.now() });
  await db.doc("provider_balances/emu-kyc-2").set({ providerId: "emu-kyc-2", owedAmount: -300, updatedAt: Date.now() });
  await db.doc("refund_requests/emu-refund-1").set({ customerId: "emu-customer", providerId: "emu-provider-1", amount: 500, status: "PENDING", createdAt: Date.now() });
  await db.doc("refund_requests/emu-refund-2").set({ customerId: "emu-customer", providerId: "emu-provider-1", amount: 200, status: "PROCESSED", createdAt: Date.now() });
  await db.doc("platform_config/general").set({ commissionPercent: 12, maxDiscountFraction: 0.5 });

  console.log(JSON.stringify({ admin: "+93700000099", customer: "+93700000098", kyc: 2, providersPending: 2, salons: 3, appointments: 4 }));
})().catch((e) => { console.error(e); process.exit(1); });
