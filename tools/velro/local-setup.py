#!/usr/bin/env python3
"""LOCAL BACKEND ONLY. Adds two driver applications (approval PENDING) to a VELRO backend running on this Mac,
for testing Linumic OS's VELRO overview. Refuses any base URL that is not 127.0.0.1 or localhost, so it can never
reach https://api.velro.linumic.com. Needs the API started with VELRO_OTP_DEBUG_ECHO=true (development only;
VELRO's own config refuses it in production), because it signs the made-up numbers in with the echoed code.

    python3 tools/velro/local-setup.py                       # http://127.0.0.1:8000/api/v1
    VELRO_LOCAL_API=http://localhost:8000/api/v1 python3 tools/velro/local-setup.py

It does what a driver's handset does (backend/ui/api/routers/auth.py and documents.py):
POST /auth/otp/request, POST /auth/otp/verify, POST /driver/register. The staff account is granted separately with
VELRO's own backend/scripts/grant-admin.py against the local database (see docs/integrations.md).
"""
import json
import os
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("VELRO_LOCAL_API", "http://127.0.0.1:8000/api/v1").rstrip("/")
host = urllib.parse.urlparse(BASE).hostname
if host not in ("127.0.0.1", "localhost"):
    sys.exit(f"Refusing: {BASE} is not a local backend.")


def post(path, body, token=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["data"]


# Made-up numbers in the +93 7000000xx block the VELRO seed already uses for its sample accounts.
applicants = [("+93700000031", "Emulator Driver One"), ("+93700000032", "راننده آزمایشی")]
for phone, name in applicants:
    sent = post("/auth/otp/request", {"phone": phone, "locale": "en"})
    code = sent.get("debug_code")
    if not code:
        sys.exit("The backend did not echo the code: start it with VELRO_OTP_DEBUG_ECHO=true (local only).")
    session = post("/auth/otp/verify", {"phone": phone, "code": code, "locale": "en"})
    try:
        result = post("/driver/register", {"full_name": name}, token=session["access_token"])
        print(json.dumps({"driver": result["driver_id"], "approval_status": result["approval_status"]}))
    except urllib.error.HTTPError as e:
        # Already registered on an earlier run.
        print(json.dumps({"applicant": name, "status": e.code, "body": json.load(e).get("error", {}).get("code")}))
