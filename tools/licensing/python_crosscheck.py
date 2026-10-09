#!/usr/bin/env python3
"""Dev check (not CI): verifies licence keys signed by LinumicCore (Swift) with Python `cryptography`,
the library the Linumic issuing tool uses, and checks the signed bytes equal Python's canonical JSON.

Uses only the TEST key pair from Packages/LinumicCore/Tests/LinumicCoreTests/Fixtures. Run through
python_crosscheck.sh, which produces the input file with `swift test`.
"""
import base64, json, sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[2]
VECTORS = ROOT / "Packages/LinumicCore/Tests/LinumicCoreTests/Fixtures/licensing-test-vectors.json"


def unb64u(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def main(path: str) -> int:
    pub = serialization.load_pem_public_key(json.loads(VECTORS.read_text())["test_public_key_pem"].encode())
    samples = json.loads(Path(path).read_text())
    failures = 0
    for s in samples:
        prefix, body_b64, sig_b64 = s["key"].split(".")
        body, sig = unb64u(body_b64), unb64u(sig_b64)
        ok = prefix == "LNM1"
        try:
            pub.verify(sig, body, ec.ECDSA(hashes.SHA256()))
        except InvalidSignature:
            ok = False
            print(f"FAIL {s['product']}: signature does not verify in Python")
        canonical = json.dumps(s["payload"], ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
        if body != canonical or base64.b64decode(s["canonical_b64"]) != canonical:
            ok = False
            print(f"FAIL {s['product']}: signed bytes differ from Python canonical JSON")
        print(("OK  " if ok else "BAD ") + f"{s['product']} {json.loads(body)['id']} {json.loads(body)['c']}")
        failures += not ok
    print(f"{len(samples) - failures}/{len(samples)} Swift-signed keys verified by Python cryptography")
    return 1 if failures or not samples else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
