#!/usr/bin/env python3
"""Builds Packages/LinumicCore/Sources/LinumicCore/Resources/seed-inventory.json.

Every value below comes from evidence gathered read-only on 2026-09-23 and is
recorded with its source. Nothing is inferred from folder names. Where no
evidence exists the field is left unknown.

Evidence:
  - evidence/github-2026-09-23.json   GitHub REST API (read-only GETs via `gh api`)
  - local working copies under ~/Projects (git log/branch/remote, build files, READMEs)
  - public pages: linumic.com, App Store lookup API, Google Play listing pages

Run from the repository root:  python3 tools/inventory/build_seed.py
"""
import json
import pathlib
import uuid
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
EVIDENCE = json.loads((ROOT / "tools/inventory/evidence/github-2026-09-23.json").read_text())
OUT = ROOT / "Packages/LinumicCore/Sources/LinumicCore/Resources/seed-inventory.json"

OBS = "2026-09-23T07:00:00Z"  # when this evidence was gathered
NS = uuid.UUID("6f1c2d3e-0000-4000-8000-000000000001")


def uid(*parts):
    return str(uuid.uuid5(NS, "|".join(parts))).upper()


def iso(ts):
    """Normalizes an ISO-8601 timestamp (possibly with an offset) to UTC 'Z' form."""
    if ts is None:
        return None
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- sources

def src(kind, reference, detail=None):
    s = {"kind": kind, "reference": reference, "observedAt": OBS}
    if detail:
        s["detail"] = detail
    return s


OWNER_LIST = src("ownerStatement", "Product list provided by the Linumic owner when the Command Center project started (2026-09-23)")


ASC_SHOT = "App Store Connect app list, screenshot shared by the owner at 03:01 on 2026-09-23 (tools/inventory/evidence/app-store-connect-apps-2026-09-23.png)"


def asc(detail):
    return src("ownerStatement", ASC_SHOT, detail)


ASC_ABSENT = ("Not present in the owner's App Store Connect app list (screenshot 2026-09-23), which shows 7 apps: SafeBeauty, VELRO Driver, VELRO Ride, "
              "Linumic WorkTrack, VELRO Ops, Nerkh Times, Afghan Prayer Times.")


OWNER_ANSWERS = "Owner's answers in the Command Center working session, 2026-09-23"


def owner(detail):
    return src("ownerStatement", OWNER_ANSWERS, detail)


LEGAL_OWNER = None  # set below, once fact() exists


PLAY_CONSOLE = "Google Play Console, owner's developer account (read-only view, 2026-09-23)"


def console(detail):
    return src("googlePlay", PLAY_CONSOLE, detail)


def gh(repo, detail=None):
    return src("gitHub", f"https://api.github.com/repos/aminullah-dev/{repo}", detail)


def local(path, detail=None):
    return src("localRepository", f"~/Projects/{path}", detail)


def web(url, detail=None):
    return src("website", url, detail)


def appstore(url, detail=None):
    return src("appStore", url, detail)


def play(app_id, detail=None):
    return src("googlePlay", f"https://play.google.com/store/apps/details?id={app_id}", detail)


def ver(status, sources=(), notes=""):
    v = {"status": status, "sources": list(sources), "notes": notes}
    if status in ("verified", "partiallyVerified", "conflicting") and sources:
        v["verifiedAt"] = OBS
    return v


def fact(value, status, sources=(), notes=""):
    f = {"verification": ver(status, sources, notes)}
    if value is not None:
        f["value"] = value
    return f


def unknown(notes=""):
    return fact(None, "unknown", (), notes)


# ---------------------------------------------------------------- repositories

def snapshot(repo):
    e = EVIDENCE[repo]
    langs = list(e["languages"].keys())
    s = {
        "slug": f"{e['owner']}/{e['name']}",
        "visibility": e["visibility"],
        "defaultBranch": e["defaultBranch"],
        "releaseCount": e["releaseCount"],
        "openPullRequests": e["openPRs"],
        "openIssues": e["openIssues"],
        "languages": langs,
        "fetchedAt": OBS,
    }
    if e["description"]:
        s["description"] = e["description"]
    if e["homepage"]:
        s["homepage"] = e["homepage"]
    if e["latestCommit"]:
        c = e["latestCommit"]
        s["latestCommit"] = {"sha": c["sha"], "message": c["message"], "date": iso(c["date"])}
    if e["latestRelease"]:
        r = e["latestRelease"]
        s["latestRelease"] = {"tag": r["tag"], "name": r["name"], "publishedAt": iso(r["published"]), "assets": r["assets"]}
    return s


def checkout(path, branch, sha, date, message, notes=""):
    c = {"path": f"~/Projects/{path}", "observedAt": OBS, "notes": notes}
    if branch:
        c["branch"] = branch
    if sha:
        c["lastCommit"] = {"sha": sha, "message": message, "date": iso(date), "author": "Aminullah Hashemi"}
    return c


def repo(name, rtype, link, checkouts=(), notes=""):
    return {
        "id": uid("repo", name),
        "name": name,
        "owner": EVIDENCE[name]["owner"],
        "url": EVIDENCE[name]["url"],
        "host": "github",
        "type": rtype,
        "link": link,
        "gitHub": snapshot(name),
        "localCheckouts": list(checkouts),
        "notes": notes,
    }


def local_folder(key, name, rtype, link, notes):
    return {
        "id": uid("folder", key),
        "name": name,
        "host": "other",
        "type": rtype,
        "link": link,
        "localCheckouts": [],
        "notes": notes,
    }


# ---------------------------------------------------------------- platforms & stores

def platform(pid, plat, component, identifier, version, status, sources, notes=""):
    p = {"id": uid("platform", pid), "platform": plat, "verification": ver(status, sources, notes)}
    if component:
        p["component"] = component
    if identifier:
        p["identifier"] = identifier
    if version:
        p["sourceVersion"] = version
    return p


def listing(lid, store, name, identifier, url, version, sources, storefront=None, seller=None, notes="", submitted=None, review=None, status="verified"):
    item = {"id": uid("listing", lid), "store": store, "appName": name, "appIdentifier": identifier,
            "verification": ver(status, sources, notes)}
    if url:
        item["url"] = url
    if submitted:
        item["latestSubmittedVersion"] = submitted
    if review:
        item["reviewStatus"] = review
    if version:
        item["productionVersion"] = version
    if storefront:
        item["storefront"] = storefront
    if seller:
        item["seller"] = seller
    return item


SELLER_NOTE = "The App Store lists the seller as the individual account \"AMINULLAH HASHEMI\", not \"Linumic\"."


def product(pid, name, **fields):
    fields.setdefault("legalOwner", fact("Aminullah Hashemi", "verified",
                                         [owner("\"The owner is me; Linumic is only the mother (umbrella) of the projects.\"")],
                                         "Linumic is the umbrella brand for the projects, not the legal owner."))
    p = {"id": pid, "name": name,
         "provenance": {"source": "Command Center verified inventory, built by tools/inventory/build_seed.py", "recordedAt": OBS}}
    p.update(fields)
    return p


def owner_listed(extra=(), notes=""):
    return fact(True, "verified", [OWNER_LIST, *extra], notes)


# ================================================================= products

products = []

# --- Safe Beauty ------------------------------------------------------------
SB = "Multiplatform/Safe beauty"
products.append(product(
    "safe-beauty", "Safe Beauty",
    isLinumicProduct=owner_listed([web("https://linumic.com/what-we-do/safebeauty/", "Product page on linumic.com (HTTP 200)")]),
    alsoKnownAs=fact(["SafeBeauty"], "verified", [gh("stealth-service-vault-", "Description begins \"SafeBeauty —\""),
                                                  appstore("https://apps.apple.com/af/app/safebeauty/id6810050614", "App name SafeBeauty")]),
    summary=fact(EVIDENCE["stealth-service-vault-"]["description"], "verified", [gh("stealth-service-vault-", "Repository description")]),
    category=fact("Marketplace: beauty-salon booking", "partiallyVerified", [gh("stealth-service-vault-")], "Category wording derived from the repository description."),
    projectType=fact("Monorepo: Android app, iOS app, Firebase Cloud Functions, web admin/provider consoles, Electron desktop wrappers",
                     "verified", [local(f"{SB}/README.md", "\"What's inside\" table"), local(f"{SB}/app/build.gradle.kts"), local(f"{SB}/ios/project.yml")]),
    status=fact("active", "partiallyVerified", [appstore("https://apps.apple.com/af/app/safebeauty/id6810050614", "Live, v1.0.1 released 2026-09-23"), play("com.security.stealthapp", "Listing page live")],
                "Live store listings show a public release. Whether the product counts as \"active\" is inferred from them. Please confirm."),
    currentVersion=unknown("Versions differ by platform: iOS 1.0.1 on the App Store, Android versionName 2.1.5 in the build config. The Google Play production version is not readable from the public page. See Platforms and Stores."),
    backend=fact("Firebase: Cloud Functions (Node 22), Firestore and Storage rules. Firebase projects safebeauty (prod) and safebeauty-staging.", "verified",
                 [local(f"{SB}/.firebaserc"), local(f"{SB}/functions/package.json", "name safebeauty-functions"), local(f"{SB}/README.md")]),
    website=fact("https://linumic.com/what-we-do/safebeauty/", "verified",
                 [gh("stealth-service-vault-", "Repository homepage field"), web("https://linumic.com/what-we-do/safebeauty/", "Title: SafeBeauty — Verified Salon Booking Marketplace")],
                 "The page links Google Play for customers, the salon panel for macOS/Windows, and safebeauty.web.app/get (HTTP 200). It doesn't mention the live iOS app."),
    repositories=[
        repo("stealth-service-vault-", "monorepo",
             ver("verified", [gh("stealth-service-vault-", "Description and homepage identify SafeBeauty"), local(f"{SB}/README.md", "# SafeBeauty")],
                 "Canonical Safe Beauty repository. The name differs from the product name."),
             [checkout(SB, "claude/stealth-android-vault-4zr1d3", "93866a5f7b9b3ab82d2ec0875cc4bff0bcd2b1f7", "2026-09-23T00:25:38-04:00",
                       "Android 22 (2.1.5): the robust Update button, staged as a draft on Play"),
              checkout("_Archive/home/stealth-service-vault-", None, "6753b44", "2026-09-04T00:00:00Z", "v2.1.0 (17) — the release that makes registration work",
                       "Older copy in _Archive. Commit date only (no time) recorded."),
              checkout("_Archive/StudioProjects/stealth-service-vault-", None, "8004489", "2026-08-23T00:00:00Z", "The dialogs the first sweep could not see",
                       "Older copy in _Archive. Commit date only (no time) recorded.")]),
        repo("safebeauty-privacy", "website",
             ver("verified", [gh("safebeauty-privacy", "Description: Privacy policy pages for the SafeBeauty app.")])),
        local_folder("marketing-pipeline", "Marketing/pipeline (local folder, not a Git repository)", "marketing",
                     ver("partiallyVerified", [local("Marketing/pipeline/README.md", "Install steps run from ~/Documents/\"SafeBeauty Marketing\"")]),
                     "Image generator for marketing. It refers to a SafeBeauty Marketing folder, so the link to Safe Beauty is indirect."),
    ],
    platforms=[
        platform("sb-android", "android", "Customer / provider / admin app", "com.security.stealthapp", "2.1.5", "verified",
                 [local(f"{SB}/app/build.gradle.kts", "com.android.application, applicationId com.security.stealthapp, versionName 2.1.5, versionCode 22"),
                  play("com.security.stealthapp", "Listed as SafeBeauty")]),
        platform("sb-ios", "iOS", "iOS app", "com.safebeauty.app", "1.0.1", "verified",
                 [local(f"{SB}/ios/SafeBeauty.xcodeproj", "SDKROOT iphoneos, MARKETING_VERSION 1.0.1"),
                  appstore("https://apps.apple.com/af/app/safebeauty/id6810050614")]),
        platform("sb-backend", "backend", "Firebase Cloud Functions", None, None, "verified", [local(f"{SB}/functions/package.json"), local(f"{SB}/firebase.json")]),
        platform("sb-web", "web", "Admin and provider consoles (Firebase Hosting)", None, None, "verified",
                 [local(f"{SB}/.firebaserc", "Hosting targets safebeauty, safebeauty-admin, safebeauty-salon"), local(f"{SB}/README.md")]),
        platform("sb-macos", "macOS", "Salon desktop app (Electron)", None, "1.0.0", "verified",
                 [local(f"{SB}/desktop-provider/package.json", "safebeauty-salon 1.0.0"), gh("stealth-service-vault-", "Release salon-desktop has SafeBeauty-Salon-mac-arm64.dmg and mac-x64.dmg")]),
        platform("sb-windows", "windows", "Salon desktop app (Electron)", None, "1.0.0", "verified",
                 [gh("stealth-service-vault-", "Release salon-desktop has SafeBeauty-Salon-win-x64.exe")]),
    ],
    storeListings=[
        listing("sb-appstore", "appStore", "SafeBeauty", "com.safebeauty.app", "https://apps.apple.com/af/app/safebeauty/id6810050614", "1.0.1",
                [appstore("https://itunes.apple.com/lookup?bundleId=com.safebeauty.app&country=af", "v1.0.1, current version released 2026-09-23, first released 2026-09-21"),
                 asc("SafeBeauty — iOS 1.0.1, green check")],
                storefront="Afghanistan", review="Green check in App Store Connect (live)", seller="AMINULLAH HASHEMI", notes=SELLER_NOTE + " No US storefront listing was found."),
        listing("sb-play", "googlePlay", "SafeBeauty", "com.security.stealthapp", "https://play.google.com/store/apps/details?id=com.security.stealthapp", "2.1.5",
                [play("com.security.stealthapp", "og:title \"SafeBeauty - Apps on Google Play\"; developer Aminullah Hashemi"),
                 console("Production: 2.1.5 (version code 22), Available on Google Play, full rollout, 177/177 countries, updated Sep 23, 2026; 12 installed audience")],
                seller="Aminullah Hashemi", review="Available on Google Play (production)",
                notes="Also: closed testing 1.9 (code 14) in 1 country; internal testing 1.0 (code 3); an open-testing draft."),
    ],
    documentation=[{"id": uid("doc", "sb-privacy"), "title": "SafeBeauty privacy policy", "url": "https://linumic.com/safebeauty-privacy-policy/"}],
))

# --- Velro ------------------------------------------------------------------
VL = "Multiplatform/Velro"
products.append(product(
    "velro", "Velro",
    isLinumicProduct=owner_listed([web("https://linumic.com/what-we-do/velro/", "Product page on linumic.com (HTTP 200)")]),
    alsoKnownAs=fact(["VELRO", "VELRO Ride", "VELRO Driver"], "verified", [appstore("https://apps.apple.com/us/app/velro-ride/id6810899663"), appstore("https://apps.apple.com/us/app/velro-driver/id6811925434")]),
    summary=fact(EVIDENCE["velro"]["description"], "verified", [gh("velro", "Repository description")]),
    category=fact("Transport: intercity ride booking", "partiallyVerified", [gh("velro")], "Category wording derived from the repository description."),
    projectType=fact("Monorepo: FastAPI backend, React staff web panel, Android passenger and driver apps, iOS passenger/driver/ops apps, watchOS companion", "verified",
                     [local(f"{VL}/README.md", "\"one backend and four clients\""), local(f"{VL}/ios/project.yml"), local(f"{VL}/mobile/app-passenger/build.gradle.kts")]),
    status=fact("active", "partiallyVerified", [appstore("https://apps.apple.com/us/app/velro-ride/id6810899663", "Live, v1.0.0 released 2026-09-13")],
                "Live App Store listings show a public release. Whether the product counts as \"active\" is inferred from them. Please confirm."),
    currentVersion=fact("1.0.0", "partiallyVerified", [appstore("https://apps.apple.com/us/app/velro-ride/id6810899663", "VELRO Ride v1.0.0"), appstore("https://apps.apple.com/us/app/velro-driver/id6811925434", "VELRO Driver v1.0.0")],
                        "This is the iOS App Store version. Android versions come from Gradle properties and no Google Play listing was found."),
    backend=fact("FastAPI + SQLAlchemy + PostgreSQL, deployed on one VPS with docker-compose and Caddy", "verified",
                 [local(f"{VL}/README.md", "Repository table: backend/, deploy/"), local(f"{VL}/backend/pyproject.toml", "velro-backend 0.1.0")]),
    website=fact("https://linumic.com/what-we-do/velro/", "verified", [gh("velro", "Repository homepage field"), web("https://linumic.com/what-we-do/velro/", "Title: VELRO — Intercity Ride Booking for Afghanistan")],
                 "The linumic.com page offers only the Android APK downloads and doesn't mention the live iOS apps."),
    repositories=[repo("velro", "monorepo", ver("verified", [gh("velro", "Description and homepage identify VELRO")]),
                       [checkout(VL, "feat/gps-origin-places", "f4cd957fabde752fac17196c251ea89d3e7ec3ef", "2026-09-22T11:30:41-04:00",
                                 "Marketing: App Store posters, QR codes, Instagram posts, NowOnAppStore video")])],
    platforms=[
        platform("vl-android-p", "android", "Passenger app", "af.velro.passenger", None, "verified", [local(f"{VL}/mobile/app-passenger/build.gradle.kts", "applicationId af.velro.passenger"),
                  web("https://api.velro.linumic.com/app", "Download page (HTTP 200) links /app/velro-passenger.apk"), web("https://linumic.com/what-we-do/velro/", "\"Download the passenger app\" → api.velro.linumic.com/app")],
                 "Distributed as an APK from api.velro.linumic.com/app, and in Google Play closed testing (1.2.3, code 6). There is no public Play listing yet."),
        platform("vl-android-d", "android", "Driver app", "af.velro.driver", None, "verified", [local(f"{VL}/mobile/app-driver/build.gradle.kts", "applicationId af.velro.driver"),
                  web("https://api.velro.linumic.com/app", "Download page (HTTP 200) links /app/velro-driver.apk"), web("https://linumic.com/what-we-do/velro/", "\"Download the driver app\" → api.velro.linumic.com/app")],
                 "Distributed as an APK from api.velro.linumic.com/app, and in Google Play closed testing (1.2.3, code 6). There is no public Play listing yet."),
        platform("vl-ios-p", "iOS", "VELRO Ride (passenger)", "af.velro.passenger", "1.0.0", "verified", [appstore("https://apps.apple.com/us/app/velro-ride/id6810899663"), local(f"{VL}/ios/project.yml")]),
        platform("vl-ios-d", "iOS", "VELRO Driver", "af.velro.driver", "1.0.0", "verified", [appstore("https://apps.apple.com/us/app/velro-driver/id6811925434"), local(f"{VL}/ios/project.yml")]),
        platform("vl-ios-ops", "iOS", "VELRO Ops", "af.velro.ops", "1.0", "verified",
                 [local(f"{VL}/ios/project.yml", "VelroOps supportedDestinations [iOS, macOS]"), asc("VELRO Ops — iOS 1.0, macOS 1.0, yellow clock")], "Submitted, not yet public."),
        platform("vl-macos", "macOS", "VELRO Ops", "af.velro.ops", "1.0", "verified",
                 [local(f"{VL}/ios/project.yml", "VelroOps supportedDestinations [iOS, macOS]"), asc("VELRO Ops — iOS 1.0, macOS 1.0, yellow clock")], "Submitted, not yet public."),
        platform("vl-watch", "watchOS", "VELRO Ops watch app", "af.velro.ops.watchkitapp", None, "verified", [local(f"{VL}/ios/project.yml", "platform: watchOS targets")]),
        platform("vl-web", "web", "Staff admin panel (React)", None, "0.1.0", "verified", [local(f"{VL}/admin/package.json", "velro-admin 0.1.0")]),
        platform("vl-backend", "backend", "FastAPI API", None, "0.1.0", "verified", [local(f"{VL}/backend/pyproject.toml")]),
    ],
    storeListings=[
        listing("vl-play-ride", "googlePlay", "VELRO Ride", "af.velro.passenger", None, None,
                [console("Closed testing (Alpha) and internal testing: 1.2.3 (version code 6), Sep 14, 2026. No production release. 13 installed audience.")],
                seller="Aminullah Hashemi", submitted="1.2.3", review="Closed testing only (no production release)"),
        listing("vl-play-driver", "googlePlay", "VELRO Driver", "af.velro.driver", None, None,
                [console("Closed testing (Alpha) and internal testing: 1.2.3 (version code 6), Sep 14, 2026. No production release. 13 installed audience.")],
                seller="Aminullah Hashemi", submitted="1.2.3", review="Closed testing only (no production release)"),
        listing("vl-as-ride", "appStore", "VELRO Ride", "af.velro.passenger", "https://apps.apple.com/us/app/velro-ride/id6810899663", "1.0.0",
                [appstore("https://itunes.apple.com/lookup?bundleId=af.velro.passenger", "v1.0.0, released 2026-09-13"), asc("VELRO Ride — iOS 1.0.1, yellow clock")],
                storefront="United States", seller="AMINULLAH HASHEMI", submitted="1.0.1",
                review="Pending: yellow clock in App Store Connect (the screenshot doesn't say which state)", notes=SELLER_NOTE + " 1.0.0 is live publicly and 1.0.1 is pending in App Store Connect."),
        listing("vl-as-driver", "appStore", "VELRO Driver", "af.velro.driver", "https://apps.apple.com/us/app/velro-driver/id6811925434", "1.0.0",
                [appstore("https://itunes.apple.com/lookup?bundleId=af.velro.driver", "v1.0.0, released 2026-09-18"), asc("VELRO Driver — iOS 1.0.1, yellow clock")],
                storefront="United States", seller="AMINULLAH HASHEMI", submitted="1.0.1",
                review="Pending: yellow clock in App Store Connect (the screenshot doesn't say which state)", notes=SELLER_NOTE + " 1.0.0 is live publicly and 1.0.1 is pending in App Store Connect."),
        listing("vl-as-ops", "appStore", "VELRO Ops", "af.velro.ops", None, None,
                [asc("VELRO Ops — iOS 1.0, macOS 1.0, yellow clock"), appstore("https://itunes.apple.com/lookup?bundleId=af.velro.ops", "No public listing (US)")],
                seller="AMINULLAH HASHEMI", submitted="iOS 1.0, macOS 1.0",
                review="Pending: yellow clock in App Store Connect (the screenshot doesn't say which state)", notes="An App Store Connect record exists but isn't public yet."),
    ],
))

# --- WorkTrack --------------------------------------------------------------
WT = "Multiplatform/WorkTrack"
products.append(product(
    "worktrack", "WorkTrack",
    isLinumicProduct=owner_listed([web("https://linumic.com/what-we-do/worktrack/", "Product page on linumic.com (HTTP 200)"),
                                   appstore("https://apps.apple.com/us/app/linumic-worktrack/id6810004398", "App name \"Linumic WorkTrack\"")]),
    alsoKnownAs=fact(["Linumic WorkTrack"], "verified", [appstore("https://apps.apple.com/us/app/linumic-worktrack/id6810004398")]),
    summary=fact(EVIDENCE["WorkTrack"]["description"], "verified", [gh("WorkTrack", "Repository description")]),
    category=fact("HR and workforce management (HRMS)", "partiallyVerified", [local(f"{WT}/README.md", "\"multi-tenant Workforce Management Platform (HRMS)\"")]),
    projectType=fact("Monorepo: web company console, Android and iOS employee apps, Firebase Cloud Functions backend, Electron desktop shell", "verified",
                     [local(f"{WT}/README.md", "\"Two products, one backend\""), local(f"{WT}/app/build.gradle.kts"), local(f"{WT}/desktop/package.json")]),
    status=fact("active", "partiallyVerified", [appstore("https://apps.apple.com/us/app/linumic-worktrack/id6810004398", "Live, v1.0 released 2026-09-21")],
                "A live App Store listing shows a public release. Whether the product counts as \"active\" is inferred from it. Please confirm."),
    currentVersion=unknown("Versions differ by platform: iOS 1.0 on the App Store, Android versionName 1.2.0 in the build config (no Google Play listing found)."),
    backend=fact("Firebase: Cloud Functions in backend/functions. Firebase projects worktrack-prod and worktrack-demo-af.", "verified",
                 [local(f"{WT}/.firebaserc"), local(f"{WT}/backend/functions/package.json", "worktrack-functions")]),
    website=fact("https://linumic.com/what-we-do/worktrack/", "verified", [gh("WorkTrack", "Repository homepage field"), web("https://linumic.com/what-we-do/worktrack/", "Title: WorkTrack — Attendance, Shifts, Leave & Payroll")],
                 "The page describes \"an Android app for staff, a web portal for managers\" and a live demo at /what-we-do/worktrack/demo/ (HTTP 200). It doesn't mention the live iOS app."),
    repositories=[repo("WorkTrack", "monorepo", ver("verified", [gh("WorkTrack", "Description and homepage identify WorkTrack")]),
                       [checkout(WT, "claude/worktrack-hrms-platform-tlar35", "e698c12a51e5b329e38bcf7ede4fae91a4690fbf", "2026-09-16T09:34:44-04:00",
                                 "Fix login button visibility across language switch",
                                 "The local branch isn't main. GitHub PR #1 \"Bring the WorkTrack platform onto main\" is open.")],
                       notes="~/Projects/_Archive/Downloads has a downloaded zip and an extracted copy of this branch (not a Git working copy).")],
    platforms=[
        platform("wt-android", "android", "Employee app", "app.worktrack", "1.2.0", "verified", [local(f"{WT}/app/build.gradle.kts", "applicationId app.worktrack, versionName 1.2.0")],
                 "Google Play closed testing 1.2.0 (code 4). There is no production release, so no public listing."),
        platform("wt-ios", "iOS", "Employee app", "app.worktrack", "1.0", "verified", [appstore("https://apps.apple.com/us/app/linumic-worktrack/id6810004398"), local(f"{WT}/ios/project.yml")]),
        platform("wt-web", "web", "Company console", None, "1.0.0", "verified", [local(f"{WT}/web/package.json", "worktrack-admin"), web("https://worktrack-prod.web.app/", "Live: WorkTrack — پورتال مدیر")]),
        platform("wt-backend", "backend", "Firebase Cloud Functions", None, None, "verified", [local(f"{WT}/backend/functions/package.json")]),
        platform("wt-desktop", "desktop", "Electron shell for the company console", None, "1.0.0", "partiallyVerified",
                 [local(f"{WT}/desktop/package.json", "\"desktop shell for the manager web portal\", electron ^33")], "No desktop release was found, and the target operating systems aren't confirmed."),
    ],
    storeListings=[listing("wt-play", "googlePlay", "Linumic WorkTrack", "app.worktrack", None, None,
                           [console("Closed testing (Alpha): 1.2.0 (version code 4), available to testers, 177 countries, Sep 16, 2026. No production release. 13 installed audience.")],
                           seller="Aminullah Hashemi", submitted="1.2.0", review="Closed testing only (no production release)"),
                   listing("wt-as", "appStore", "Linumic WorkTrack", "app.worktrack", "https://apps.apple.com/us/app/linumic-worktrack/id6810004398", "1.0",
                           [appstore("https://itunes.apple.com/lookup?bundleId=app.worktrack", "v1.0, released 2026-09-21"), asc("Linumic WorkTrack — iOS 1.0, green check")], storefront="United States", review="Green check in App Store Connect (live)", seller="AMINULLAH HASHEMI", notes=SELLER_NOTE)],
))

# --- DukanPro ---------------------------------------------------------------
DP = "Multiplatform/DukanPro"
products.append(product(
    "dukanpro", "DukanPro",
    isLinumicProduct=owner_listed([local(f"{DP}/README.md", "Default sync server https://api.linumic.com")],
                                  "No product page on linumic.com: /what-we-do/dukanpro/ returned 404, and DukanPro isn't on the products index."),
    summary=fact("Offline-first, cross-platform retail point-of-sale for the Afghan market (Dari / Pashto / English, AFN, Hijri Shamsi).", "verified",
                 [local(f"{DP}/README.md", "Opening paragraph")], "GitHub has no repository description."),
    category=fact("Retail point of sale", "partiallyVerified", [local(f"{DP}/README.md")]),
    projectType=fact("Monorepo: Flutter client (Android, iOS, macOS), Dart packages, Python FastAPI sync server", "verified",
                     [local(f"{DP}/app/pubspec.yaml"), local(f"{DP}/melos.yaml"), local(f"{DP}/server/pyproject.toml")]),
    status=fact("development", "partiallyVerified", [local(f"{DP}/README.md", "\"all ten phases… are built\"; lists what is \"still missing before a real shop uses it\"")]),
    currentVersion=unknown("pubspec declares 1.0.0+1. No GitHub release or store listing was found."),
    backend=fact("Optional Python FastAPI + SQLAlchemy + PostgreSQL sync server. A shop can also run on one device with no server.", "verified",
                 [local(f"{DP}/README.md", "Stack section"), local(f"{DP}/server/pyproject.toml", "dukanpro-server 0.1.0")]),
    website=unknown("https://linumic.com/what-we-do/dukanpro/ returned 404 on 2026-09-23."),
    repositories=[repo("DukanPro", "monorepo", ver("verified", [OWNER_LIST, local(f"{DP}/README.md", "# DukanPro")], "GitHub has no description or homepage."),
                       [checkout(DP, "main", "41a3a4108be2756874ff7ca20ef8c4cfebba2dce", "2026-09-20T03:35:55-04:00",
                                 "The repository says what stays out of it, and keeps the editor's own state out")])],
    platforms=[
        platform("dp-android", "android", "Flutter app", "com.dukanpro.dukanpro", "1.0.0", "verified", [local(f"{DP}/app/android/app/build.gradle.kts", "applicationId com.dukanpro.dukanpro")]),
        platform("dp-ios", "iOS", "Flutter app", "com.dukanpro.dukanpro", "1.0.0", "verified", [local(f"{DP}/app/ios/Runner.xcodeproj", "SDKROOT iphoneos")]),
        platform("dp-macos", "macOS", "Flutter app", "com.dukanpro.dukanpro", "1.0.0", "verified", [local(f"{DP}/app/macos/Runner.xcodeproj", "SDKROOT macosx")]),
        platform("dp-backend", "backend", "Sync server", None, "0.1.0", "verified", [local(f"{DP}/server/pyproject.toml")]),
        platform("dp-windows", "windows", "Planned", None, None, "unknown", [], "The README says \"Windows next\", so it's planned, not built."),
    ],
))

# --- Talar ------------------------------------------------------------------
TL = "Multiplatform/Talar"
products.append(product(
    "talar", "Talar",
    isLinumicProduct=owner_listed([local(f"{TL}/README.md", "\"Built by Linumic, Kabul.\""), web("https://linumic.com/what-we-do/talar/", "Product page on linumic.com (HTTP 200)")]),
    alsoKnownAs=fact(["تالار"], "verified", [gh("talar", "Description: Talar (تالار)")]),
    summary=fact(EVIDENCE["talar"]["description"], "verified", [gh("talar", "Repository description")]),
    category=fact("Wedding-hall booking marketplace and hall ERP", "partiallyVerified", [gh("talar")]),
    projectType=fact("Monorepo: Android app, web app, Electron hall-management panel, Firebase Cloud Functions", "verified",
                     [local(f"{TL}/android/app/build.gradle.kts"), local(f"{TL}/web/package.json"), local(f"{TL}/desktop/package.json"), local(f"{TL}/backend/functions/package.json")]),
    status=fact("active", "partiallyVerified", [gh("talar-releases", "Public release v1.0.0 (Talar-1.0.0.apk), 2026-08-27"), local(f"{TL}/README.md", "Public sandbox demo at linumic.com/what-we-do/talar/demo")],
                "A public installer release and demo show it's available. Whether it counts as \"active\" is inferred from them. Please confirm."),
    currentVersion=fact("1.0.0", "verified", [gh("talar-releases", "Latest release v1.0.0"), local(f"{TL}/android/app/build.gradle.kts", "versionName 1.0.0")]),
    backend=fact("Firebase: Cloud Functions (backend/functions). The docs link to Firebase project talar-af-prod.", "verified",
                 [local(f"{TL}/backend/functions/package.json", "talar-functions"), local(f"{TL}/README.md", "Firebase console links for talar-af-prod")]),
    website=fact("https://linumic.com/what-we-do/talar/", "verified", [gh("talar", "Repository homepage field"), web("https://linumic.com/what-we-do/talar/", "Title: Talar — Wedding Hall & Event Venue ERP")]),
    repositories=[
        repo("talar", "monorepo", ver("verified", [gh("talar", "Description and homepage identify Talar")]),
             [checkout(TL, "main", "4dae3a022e1dfc6ff7294f6b62fc3e586daf9f36", "2026-09-20T03:52:42-04:00", "Merge pull request #4 from aminullah-dev/demo/sandbox-project")]),
        repo("talar-releases", "releases",
             ver("verified", [gh("talar-releases", "Description: Installer downloads for Talar (تالار) … by Linumic. Release files only; source is private.")])),
    ],
    platforms=[
        platform("tl-android", "android", "Android app", "af.talar", "1.0.0", "verified",
                 [local(f"{TL}/android/app/build.gradle.kts", "applicationId af.talar, versionName 1.0.0"), gh("talar-releases", "Release asset Talar-1.0.0.apk")],
                 "Distributed as an APK. No public Google Play listing was found (HTTP 404)."),
        platform("tl-web", "web", "Web app", None, "1.0.0", "verified", [local(f"{TL}/web/package.json", "talar-web 1.0.0")]),
        platform("tl-desktop", "desktop", "Hall-management panel (Electron)", None, None, "partiallyVerified",
                 [local(f"{TL}/desktop/package.json", "talar-panel, electron ^31")], "No desktop release was found, and the target operating systems aren't confirmed."),
        platform("tl-backend", "backend", "Firebase Cloud Functions", None, None, "verified", [local(f"{TL}/backend/functions/package.json")]),
    ],
))

# --- NerkhTimes -------------------------------------------------------------
NT = "Android/NerkhTimes"
products.append(product(
    "nerkhtimes", "NerkhTimes",
    isLinumicProduct=owner_listed([web("https://linumic.com/what-we-do/", "Listed on the linumic.com products index (\"Daily market prices — NerkhTimes\")"),
                                   web("https://linumic.com/nerkhtimes-privacy-policy/", "NerkhTimes Privacy Policy & Support — Linumic")]),
    alsoKnownAs=fact(["نرخ تایمز", "Nerkh Times"], "verified", [appstore("https://apps.apple.com/us/app/%D9%86%D8%B1%D8%AE-%D8%AA%D8%A7%DB%8C%D9%85%D8%B2-nerkh-times/id6810293641")]),
    summary=fact(EVIDENCE["NerkhTimes"]["description"], "verified", [gh("NerkhTimes", "Repository description")]),
    category=fact("Market price information", "partiallyVerified", [gh("NerkhTimes")]),
    projectType=fact("Android app, iOS app, and a Google Apps Script admin dashboard", "verified",
                     [local(f"{NT}/app/build.gradle.kts"), local(f"{NT}/ios/project.yml"), local(f"{NT}/admin/README.md")]),
    status=fact("active", "partiallyVerified", [appstore("https://apps.apple.com/us/app/%D9%86%D8%B1%D8%AE-%D8%AA%D8%A7%DB%8C%D9%85%D8%B2-nerkh-times/id6810293641", "Live, v1.0"), play("af.market.nerkhtimes", "Listing page live")],
                "Live store listings show a public release. Whether the product counts as \"active\" is inferred from them. Please confirm."),
    currentVersion=unknown("Versions differ by platform: iOS 1.0 on the App Store, Android versionName 1.0.11 in the build config. The Google Play production version is not readable from the public page."),
    backend=fact("Google Apps Script web app over a Google Sheet (serves ?action=markets and ?action=candles)", "partiallyVerified",
                 [local(f"{NT}/admin/README.md", "Admin dashboard merged into the existing Apps Script")], "Inferred from the admin README. Please confirm the production data source."),
    website=fact("https://aminullah-dev.github.io/nerkhtimes.github.io/", "verified",
                 [gh("nerkhtimes.github.io", "Landing and privacy-policy pages for the NerkhTimes app"), web("https://aminullah-dev.github.io/nerkhtimes.github.io/", "Title: NerkhTimes (HTTP 200)")],
                 "The GitHub homepage field of the NerkhTimes repo points to the Google Play listing. linumic.com also hosts a NerkhTimes privacy/support page."),
    repositories=[
        repo("NerkhTimes", "application", ver("verified", [gh("NerkhTimes", "Description identifies NerkhTimes")]),
             [checkout(NT, "main", "df977c9438e50c858fb02ea048475696237a6719", "2026-09-20T03:39:03-04:00", "Add README, harden .gitignore, untrack IDE/local/generated files"),
              checkout("_Archive/StudioProjects/NerkhTimes", None, "93eb471", "2026-07-22T00:00:00Z", "feat: sanitize sheet text + support new assets (GBP/SAR/AED/silver/crypto)",
                       "Older copy in _Archive. Commit date only (no time) recorded.")]),
        repo("nerkhtimes.github.io", "website", ver("verified", [gh("nerkhtimes.github.io", "Description: Landing and privacy-policy pages for the NerkhTimes app.")])),
    ],
    platforms=[
        platform("nt-android", "android", "Android app", "af.market.nerkhtimes", "1.0.11", "verified",
                 [local(f"{NT}/app/build.gradle.kts", "applicationId af.market.nerkhtimes, versionName 1.0.11, versionCode 11"), play("af.market.nerkhtimes")]),
        platform("nt-ios", "iOS", "iOS app", "af.market.nerkhtimes", "1.0.0", "verified",
                 [local(f"{NT}/ios/NerkhTimes.xcodeproj", "MARKETING_VERSION 1.0.0"), appstore("https://itunes.apple.com/lookup?bundleId=af.market.nerkhtimes", "Store version 1.0")]),
        platform("nt-backend", "backend", "Apps Script admin/API", None, None, "partiallyVerified", [local(f"{NT}/admin/README.md")]),
    ],
    storeListings=[
        listing("nt-as", "appStore", "نرخ تایمز - Nerkh Times", "af.market.nerkhtimes",
                "https://apps.apple.com/us/app/%D9%86%D8%B1%D8%AE-%D8%AA%D8%A7%DB%8C%D9%85%D8%B2-nerkh-times/id6810293641", "1.0",
                [appstore("https://itunes.apple.com/lookup?bundleId=af.market.nerkhtimes", "v1.0, current version released 2026-09-15, first released 2026-09-14"),
                 asc("Nerkh Times - نرخ تایمز — iOS 1.0, green check")],
                storefront="United States", review="Green check in App Store Connect (live)", seller="AMINULLAH HASHEMI", notes=SELLER_NOTE),
        listing("nt-play", "googlePlay", "NerkhTimes", "af.market.nerkhtimes", "https://play.google.com/store/apps/details?id=af.market.nerkhtimes", "1.0.10",
                [play("af.market.nerkhtimes", "og:title \"NerkhTimes - Apps on Google Play\"; developer Aminullah Hashemi"),
                 console("Production: 1.0.10 (version code 10), Available on Google Play, full rollout, 177/177 countries, updated Aug 27, 2026; 14 installed audience")],
                seller="Aminullah Hashemi", review="Available on Google Play (production)",
                notes="The local build config is already at 1.0.11 (code 11), which isn't uploaded. There's also a closed-testing draft."),
    ],
    documentation=[{"id": uid("doc", "nt-privacy"), "title": "NerkhTimes privacy policy & support (linumic.com)", "url": "https://linumic.com/nerkhtimes-privacy-policy/"}],
))

# --- Namazia ----------------------------------------------------------------
NZ = "Android/-Namazia"
products.append(product(
    "namazia", "Namazia",
    isLinumicProduct=owner_listed(notes="No Linumic reference found in the repository or on linumic.com (/what-we-do/namazia/ returned 404)."),
    alsoKnownAs=fact(["Afghan Prayer Times"], "verified", [appstore("https://apps.apple.com/us/app/afghan-prayer-times/id6810537640", "Bundle af.namazia.app is listed as \"Afghan Prayer Times\"")]),
    summary=unknown("The README contains only a title, and GitHub has no description."),
    category=fact("Prayer times", "partiallyVerified",
                  [appstore("https://apps.apple.com/us/app/afghan-prayer-times/id6810537640", "App name Afghan Prayer Times"), local(NZ, "Branch claude/android-prayer-times-app-yiqx6y")]),
    projectType=fact("Android app and iOS app (with widget extension)", "verified", [local(f"{NZ}/app/build.gradle"), local(f"{NZ}/ios/Namazia.xcodeproj")]),
    status=fact("active", "partiallyVerified", [appstore("https://apps.apple.com/us/app/afghan-prayer-times/id6810537640", "Live, v1.0 released 2026-09-14")],
                "A live App Store listing shows a public release. Whether the product counts as \"active\" is inferred from it. Please confirm."),
    currentVersion=unknown("Versions differ by platform: iOS 1.0 on the App Store, Android versionName 1.1.0 in the build config (no Google Play listing found)."),
    backend=unknown(),
    website=unknown("https://linumic.com/what-we-do/namazia/ returned 404. The repository contains a privacy-policy.html."),
    repositories=[repo("-Namazia", "application", ver("verified", [OWNER_LIST, local(f"{NZ}/app/build.gradle", "applicationId af.namazia.app")], "GitHub has no description."),
                       [checkout(NZ, "claude/android-prayer-times-app-yiqx6y", "95aa3fc120b604cd5ec4212f1c330b9d2dc3859c", "2026-09-22T11:37:56-04:00",
                                 "chore: harden .gitignore (ignore app/build, keystores, .env, firebase config)",
                                 "The app code is on this branch. GitHub main has only \"Initial commit\" and PR #1 is open.")])],
    platforms=[
        platform("nz-android", "android", "Android app", "af.namazia.app", "1.1.0", "verified", [local(f"{NZ}/app/build.gradle", "applicationId af.namazia.app, versionName 1.1.0, versionCode 4"),
                  console("Production 1.1.0 (code 4) in review")],
                 "1.1.0 is in Google Play production review. Closed testing has 1.0.1."),
        platform("nz-ios", "iOS", "iOS app + widget", "af.namazia.app", "1.0", "verified",
                 [local(f"{NZ}/ios/Namazia.xcodeproj", "SDKROOT iphoneos"), appstore("https://apps.apple.com/us/app/afghan-prayer-times/id6810537640")]),
    ],
    storeListings=[listing("nz-play", "googlePlay", "Afghan Prayer Times", "af.namazia.app", None, None,
                           [console("Production: 1.1.0 (version code 4) In review since Sep 16, 2026, full rollout to 177 countries. Closed testing (Alpha): 1.0.1 (code 2), available to testers. 15 installed audience.")],
                           seller="Aminullah Hashemi", submitted="1.1.0", review="In review (production)",
                           notes="Not public yet. The public listing page returned 404 on 2026-09-23, which is consistent with the review."),
                   listing("nz-as", "appStore", "Afghan Prayer Times", "af.namazia.app", "https://apps.apple.com/us/app/afghan-prayer-times/id6810537640", "1.0",
                           [appstore("https://itunes.apple.com/lookup?bundleId=af.namazia.app", "v1.0, released 2026-09-14"), asc("Afghan Prayer Times — iOS 1.0, green check")], storefront="United States", review="Green check in App Store Connect (live)", seller="AMINULLAH HASHEMI", notes=SELLER_NOTE)],
))

# --- AfghanJama (KhayatYar) -------------------------------------------------
AJ = "Android/AfghanJama"
products.append(product(
    "afghanjama", "AfghanJama",
    isLinumicProduct=owner_listed([web("https://linumic.com/what-we-do/tailor-erp/", "Tailor ERP page download links point to github.com/aminullah-dev/AfghanJama/releases/download/v1.8.0/KhayatYar-1.8.0.{apk,msi,dmg}")]),
    alsoKnownAs=fact(["KhayatYar", "خیاط‌یار", "Tailor ERP"], "verified",
                     [gh("AfghanJama", "Description: KhayatYar / خیاط‌یار — Tailor ERP"), web("https://linumic.com/what-we-do/tailor-erp/", "Title: Tailor ERP — Orders, Production & Accounts"),
                      owner("\"KhayatYar is the same as AfghanJama.\"")],
                     "The repository, the app and the website call this product KhayatYar / Tailor ERP. \"AfghanJama\" appears only as the repository and package name."),
    # The owner confirmed: KhayatYar is AfghanJama.
    summary=fact(EVIDENCE["AfghanJama"]["description"], "verified", [gh("AfghanJama", "Repository description")]),
    category=fact("Tailoring workshop management (ERP)", "verified",
                  [gh("AfghanJama", "KhayatYar — Tailor ERP"), web("https://linumic.com/what-we-do/tailor-erp/", "Category \"Manufacturing\": Workshop management for tailoring businesses")],
                  "This is the product linumic.com sells as \"Tailor ERP\". The separate Tailoring-Workshop-ERP repository (Darzi) is a different codebase. See that product."),
    projectType=fact("Kotlin Android app + Compose Desktop app (macOS/Windows), with an iOS app on a separate branch", "verified",
                     [local(f"{AJ}/app/build.gradle.kts"), local(f"{AJ}/desktop/build.gradle.kts", "org.jetbrains.compose desktop"), local("Android/AfghanJama-ios/iosApp/project.yml")]),
    status=fact("active", "partiallyVerified", [gh("AfghanJama", "Release v1.8.0 on 2026-09-20 (apk, dmg, msi)"),
                                                  web("https://linumic.com/what-we-do/tailor-erp/", "Offers downloads and per-workshop licensing")],
                "Public GitHub releases show it's available. Whether it counts as \"active\" is inferred from them. Please confirm."),
    currentVersion=fact("1.8.0", "verified", [gh("AfghanJama", "Latest release v1.8.0"), local(f"{AJ}/gradle.properties", "appVersion=1.8.0, appVersionCode=13")]),
    backend=fact("None: offline-first, all data stays on the device", "verified", [local(f"{AJ}/README.md", "\"بی‌اینترنت کار می‌کند. همهٔ داده روی خودِ دستگاه می‌مانَد.\"")]),
    website=fact("https://linumic.com/what-we-do/tailor-erp/", "verified", [gh("AfghanJama", "Repository homepage field"), web("https://linumic.com/what-we-do/tailor-erp/", "Page mentions AfghanJama and KhayatYar")]),
    repositories=[repo("AfghanJama", "application", ver("verified", [gh("AfghanJama"), OWNER_LIST]),
                       [checkout(AJ, "main", "f71c233574c24b89c991b2bad8618ce12eae5905", "2026-09-20T03:32:44-04:00", "هشدار روی publish.py — فایل‌های مخزن دیگر آینهٔ سایت نیستند"),
                        checkout("Android/AfghanJama-ios", "claude/ios-app", "a1e27f85b949078d6f23c33699b77344085acdc9", "2026-09-19T23:26:10-04:00",
                                 "هم‌گام با main — و پنج فیچرِ تازه روی آیفون هم نشستند", "Second working copy of the same repository, on the iOS branch."),
                        checkout("_Archive/StudioProjects/AfghanJama", None, "f71c233", "2026-09-20T00:00:00Z", "هشدار روی publish.py — فایل‌های مخزن دیگر آینهٔ سایت نیستند",
                                 "Older copy in _Archive. Commit date only (no time) recorded.")])],
    platforms=[
        platform("aj-android", "android", "KhayatYar Android", "com.afghanjama", "1.8.0", "verified",
                 [local(f"{AJ}/app/build.gradle.kts", "applicationId com.afghanjama"), gh("AfghanJama", "Release asset KhayatYar-1.8.0.apk")],
                 "Distributed through GitHub releases. No public Google Play listing was found (HTTP 404)."),
        platform("aj-macos", "macOS", "KhayatYar desktop", None, "1.8.0", "verified", [gh("AfghanJama", "Release asset KhayatYar-1.8.0.dmg"), local(f"{AJ}/desktop/build.gradle.kts")]),
        platform("aj-windows", "windows", "KhayatYar desktop", None, "1.8.0", "verified", [gh("AfghanJama", "Release asset KhayatYar-1.8.0.msi"), local(f"{AJ}/desktop/build.gradle.kts")]),
        platform("aj-ios", "iOS", "KhayatYar iOS", "com.afghanjama.khayatyar", None, "partiallyVerified",
                 [local("Android/AfghanJama-ios/iosApp/KhayatYar.xcodeproj", "SDKROOT iphoneos, bundle com.afghanjama.khayatyar")],
                 "Only on branch claude/ios-app, not on main. linumic.com says \"iPhone — App Store · in preparation\". " + ASC_ABSENT),
    ],
))

# --- SODER-HAKEM ------------------------------------------------------------
SH = "Android/SODER-HAKEM"
products.append(product(
    "soder-hakem", "SODER-HAKEM",
    isLinumicProduct=owner_listed(notes="No Linumic reference found in the repository or on linumic.com."),
    alsoKnownAs=fact(["سوډر حاکم", "SoderHakim"], "verified", [local(f"{SH}/README.md", "# سوډر حاکم — Android reader; dist/SoderHakim-1.0.apk")]),
    summary=fact("Offline Android reading app for the book «سوډر حاکم — د بې‌واکه حاکمیت فلسفه» by امین‌الله هاشمي, with the full text bundled.", "verified",
                 [local(f"{SH}/README.md", "Opening paragraph")]),
    category=fact("Book: reader app for the owner's Pashto book", "verified", [local(f"{SH}/README.md"), owner("\"SODER-HAKEM is a book.\"")]),
    projectType=fact("Android app (Kotlin + Jetpack Compose)", "verified", [local(f"{SH}/app/build.gradle.kts"), local(f"{SH}/README.md")]),
    status=unknown("The first commit to GitHub was on 2026-09-22. The README describes sideloading an APK from dist/."),
    currentVersion=fact("1.0", "partiallyVerified", [local(f"{SH}/app/build.gradle.kts", "versionName 1.0"), local(f"{SH}/README.md", "dist/SoderHakim-1.0.apk")],
                        "Version from the build config and README. No GitHub release or store listing was found."),
    backend=fact("None: no network access", "verified", [local(f"{SH}/README.md", "\"no network access and no user-facing permissions\"")]),
    website=unknown(),
    repositories=[repo("SODER-HAKEM", "application", ver("verified", [OWNER_LIST, local(f"{SH}/README.md")]),
                       [checkout(SH, "main", "aed081c5ccb24bdbc268452dbe977aec7cb4863f", "2026-09-22T10:59:17-04:00", "Initial commit: SODER-HAKEM Android app source")])],
    platforms=[platform("sh-android", "android", "Reader app", "com.hashemi.soderhakim", "1.0", "verified", [local(f"{SH}/app/build.gradle.kts", "applicationId com.hashemi.soderhakim")],
                        "Sideloaded APK. No public Google Play listing was found (HTTP 404).")],
))

# --- MediFlow ---------------------------------------------------------------
MF = "Desktop/MediFlow"
products.append(product(
    "mediflow", "MediFlow",
    isLinumicProduct=owner_listed([web("https://linumic.com/what-we-do/mediflow/", "Product page on linumic.com (HTTP 200); listed first on the products index under Healthcare")],
                                  "The LICENSE names \"Copyright (c) 2026 Aminullah Hashemi\" as a proprietary licence, not Linumic."),
    summary=fact(EVIDENCE["MediFlow"]["description"], "verified", [gh("MediFlow", "Repository description")]),
    category=fact("Medical: clinic and hospital management", "verified", [gh("MediFlow"), owner("\"MediFlow is a medical system.\"")]),
    priority=fact("high", "verified", [owner("\"MediFlow is a medical system; it matters.\"")]),
    projectType=fact("Offline desktop application (Python 3.13, PySide6, SQLite) with a local web UI; 16 modules", "verified",
                     [local(f"{MF}/README.md", "Module table (16 modules), start.command / start.bat web UI launchers"), local(f"{MF}/pyproject.toml")]),
    status=fact("development", "partiallyVerified",
                [local(f"{MF}/README.md", "All 16 modules implemented (Phases 1–6). Phase 7 (printing & packaging) in progress: A4/thermal printing and receipt/prescription/report templates still open."),
                 gh("MediFlow", "Release v0.2.0 on 2026-08-27 (MediFlow-0.2.0-windows.zip)"),
                 web("https://linumic.com/what-we-do/mediflow/", "Offers the Windows ZIP download; \"a double-click installer is coming in the next release\"")],
                "Publicly downloadable, but still in development according to the README roadmap. Whether any clinic runs it in production is unknown."),
    currentVersion=fact("0.2.0", "verified", [gh("MediFlow", "Latest release v0.2.0"), local(f"{MF}/pyproject.toml", "version 0.2.0")]),
    backend=fact("None: fully offline on one machine (SQLite in a per-user folder)", "verified", [local(f"{MF}/README.md", "\"runs entirely on one machine with no internet, cloud, or subscription\"")]),
    website=fact("https://linumic.com/what-we-do/mediflow/", "verified", [gh("MediFlow", "Repository homepage field"), web("https://linumic.com/what-we-do/mediflow/", "Title: MediFlow — Clinic & Hospital Management System")]),
    repositories=[
        repo("MediFlow", "application", ver("verified", [gh("MediFlow", "Description and homepage identify MediFlow")]),
             [checkout(MF, "main", "3f932672b47e3518f873656693da5d253734f928", "2026-09-22T11:49:20-04:00", "chore: remove marketing/ from the code repo (moved to ~/Projects/Marketing)",
                       "26 commits since 2026-07-23. Tag v0.2.0. GitHub Actions CI (.github/workflows/ci.yml) passed on main on 2026-09-22. The README reports 117 passing tests; a local grep finds about 145 test functions in 8 files.")],
             notes="Proprietary licence (LICENSE). The README notes that PySide6 is LGPL v3, which attaches conditions to how a closed-source product is sold."),
        local_folder("marketing-mediflow", "Marketing/marketing (local folder, not a Git repository)", "marketing",
                     ver("verified", [local("Marketing/marketing/README.md", "# MediFlow — Marketing"), local(MF, "Commit 3f93267 moved marketing/ to ~/Projects/Marketing")]),
                     "Dari/Pashto social posts, cards and screenshots for MediFlow."),
    ],
    platforms=[
        platform("mf-windows", "windows", "Desktop app", None, "0.2.0", "verified", [gh("MediFlow", "Release asset MediFlow-0.2.0-windows.zip"), local(f"{MF}/README.md", "Windows 10/11 installer")]),
        platform("mf-macos", "macOS", "Desktop app", None, None, "partiallyVerified",
                 [local(f"{MF}/README.md", "macOS 11+ .dmg, Developer ID + notarised"), local(f"{MF}/packaging/build-macos.sh"), local(MF, "Commit 2080819 (2026-09-18): Make macOS a real target: sealed secrets, signed and notarised builds")],
                 "macOS packaging exists in the source, but the v0.2.0 release and linumic.com offer only Windows. " + ASC_ABSENT),
    ],
))

# --- Tailoring Workshop ERP (Darzi) -----------------------------------------
TW = "Web/Tailoring Workshop ERP"
products.append(product(
    "tailoring-workshop-erp", "Tailoring Workshop ERP",
    isLinumicProduct=owner_listed(notes="No Linumic reference found in this repository."),
    alsoKnownAs=fact(["Darzi", "درزی"], "verified", [local(f"{TW}/README.md", "# Darzi — درزی"), local(f"{TW}/package.json", "darzi-erp")]),
    summary=fact("Tailoring workshop ERP: a production management platform for garment manufacturing, from the customer's measurements to the delivered, invoiced and costed order.", "verified",
                 [local(f"{TW}/README.md", "Opening paragraph")]),
    category=fact("Garment production ERP", "partiallyVerified", [local(f"{TW}/README.md", "\"A production management platform for garment manufacturing\"")]),
    priority=fact("sidelined", "verified", [owner("\"Move Darzi to the sidelines for now.\"")]),
    projectType=fact("Web application: React web client + Express/Drizzle/PostgreSQL API", "verified", [local(f"{TW}/README.md", "Layout table")]),
    status=fact("development", "partiallyVerified", [local(f"{TW}/README.md", "\"Increment 1 — foundation and the order-intake slice\"")]),
    currentVersion=unknown("package.json declares 0.1.0. No release was found."),
    backend=fact("Express 5 + Drizzle + PostgreSQL (api/)", "verified", [local(f"{TW}/README.md", "Layout table")]),
    website=unknown("No website. The owner confirmed that linumic.com's Tailor ERP page is KhayatYar (the AfghanJama repository), not this codebase."),
    repositories=[repo("Tailoring-Workshop-ERP", "application",
                       ver("verified", [gh("Tailoring-Workshop-ERP", "Description: Tailoring Workshop ERP"), OWNER_LIST]),
                       [checkout(TW, "feat/finished-goods-warehouse", "6321d175af3d4e5ae5a1421f4c6a91b74a3cee5c", "2026-08-02T21:28:41-04:00",
                                 "refactor(web): give the app a shell and a page frame it did not have")],
                       notes="The GitHub repository was created on 2026-09-22, but its commits date from 2026-08. The history was pushed after it was written.")],
    platforms=[
        platform("tw-web", "web", "Web client (React + Vite)", None, None, "verified", [local(f"{TW}/web/package.json", "@darzi/web")]),
        platform("tw-backend", "backend", "API (Express + PostgreSQL)", None, None, "verified", [local(f"{TW}/api/package.json", "@darzi/api")]),
    ],
))

# --- The Digital Infrastructure of the Pashto Language ----------------------
PS = "Research/The-Digital-Infrastructure-of-the-Pashto-Language"
products.append(product(
    "the-digital-infrastructure-of-the-pashto-language", "The Digital Infrastructure of the Pashto Language",
    isLinumicProduct=owner_listed(notes="No Linumic reference found in this repository."),
    alsoKnownAs=fact(["pashto-text"], "verified", [local(f"{PS}/pyproject.toml", "name pashto-text")]),
    summary=fact("Orthographic normalization, tokenization and stemming for Pashto. Pure Python standard library, MIT licensed.", "verified", [local(f"{PS}/README.md", "Opening lines")]),
    category=fact("Language technology research", "partiallyVerified", [local(f"{PS}/README.md")]),
    projectType=fact("Python library, with a local web viewer (app/)", "verified", [local(f"{PS}/pyproject.toml"), local(f"{PS}/app/server.py")]),
    status=unknown(),
    currentVersion=fact("0.1.0", "partiallyVerified", [local(f"{PS}/pyproject.toml", "version 0.1.0")], "No release was found."),
    backend=fact("None: a library. app/ is a local viewer server.", "partiallyVerified", [local(f"{PS}/README.md"), local(f"{PS}/app/server.py")]),
    website=unknown(),
    repositories=[repo("The-Digital-Infrastructure-of-the-Pashto-Language", "research",
                       ver("verified", [OWNER_LIST, local(f"{PS}/README.md", "*The Digital Infrastructure of the Pashto Language*")]),
                       [checkout(PS, "claude/new-session-cktx6n", "bfd7bf60b0375f107a864447f60069711c9623fa", "2026-07-27T06:54:17Z", "Add app/: a local web viewer over the library",
                                 "The code is on this branch. GitHub main has only \"Initial commit\".")])],
    platforms=[platform("ps-research", "research", "Python library", "pashto-text", "0.1.0", "verified", [local(f"{PS}/pyproject.toml")])],
))

# ================================================================= unresolved

# Gul-E-Lala: removed at the owner's instruction (2026-09-23).
# Kabul Signal (kabulsignal.com and aminullah-dev/kabul-signal-android) is deliberately excluded:
# it is a separate organization, and the owner asked on 2026-09-23 for it to be removed from the Command Center.
unresolved = [
    {"id": "radar-system", "kind": "sidelined", "name": "Radar-system", "location": "https://github.com/aminullah-dev/Radar-system",
     "findings": "Private repository created 2026-07-28 with a single \"Initial commit\" containing only README.md (\"# Radar-system\"). No local working copy.",
     "verification": ver("verified", [gh("Radar-system", "Contents: README.md only"), owner("\"Radar-system: sideline.\"")], "Sidelined by the owner.")},
    {"id": "explore-afghanistan", "kind": "sidelined", "name": "Explore_Afghanistan / Explore-Afghanistan", "location": "https://github.com/aminullah-dev/Explore_Afghanistan",
     "findings": "Explore_Afghanistan (private, 2025-08-03) holds a static website (index.html, js, stylesheet, images). Explore-Afghanistan (public, same day) is empty. Both predate every known product repository. No Linumic reference found (contents not read in depth).",
     "verification": ver("verified", [gh("Explore_Afghanistan", "Contents: .gitignore, images, index.html, js, stylesheet"), gh("Explore-Afghanistan", "Empty repository"),
                         owner("\"Explore Afghanistan: sideline.\"")], "Sidelined by the owner.")},
]

inventory = {"schemaVersion": 2, "seedRevision": 3, "products": products, "unresolved": unresolved}
OUT.write_text(json.dumps(inventory, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
print(f"wrote {OUT.relative_to(ROOT)}: {len(products)} products, {len(unresolved)} unresolved items")
