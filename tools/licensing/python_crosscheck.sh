#!/bin/sh
# Dev check, not a CI dependency: Swift signs with the TEST key, Python `cryptography` verifies.
# Needs the issuing tool's venv (override with LINUMIC_LICENSING_PYTHON).
set -eu
cd "$(dirname "$0")/../.."
PY="${LINUMIC_LICENSING_PYTHON:-$HOME/Projects/Multiplatform/Linumic/licensing/.venv/bin/python}"
OUT="$(mktemp -t lnm1-crosscheck)"
trap 'rm -f "$OUT"' EXIT
LNM1_PYTHON_CHECK_OUT="$OUT" swift test --package-path Packages/LinumicCore --filter writesKeysForThePythonCrossCheck >/dev/null
"$PY" tools/licensing/python_crosscheck.py "$OUT"
