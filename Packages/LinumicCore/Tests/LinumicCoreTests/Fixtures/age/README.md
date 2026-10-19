# age test vectors

From the Community Cryptography Test Vectors, `C2SP/CCTV`, folder `age/testdata`, commit
`50a8ecf2a220f4c8bdc4f085789b8e85c26829e7` (fetched 2026-10-19). Their licence allows copying them without attribution.

Kept: every `scrypt_*` vector (opened with the passphrase, as Linumic OS opens its exports) and the `stream_*`,
`hmac_*`, `stanza_*`, `header_crlf`, `version_unsupported` and `empty` vectors (opened with the file key the
vector gives, which checks the header grammar, the header MAC and STREAM). Left out: the X25519 and hybrid recipient
vectors (Linumic OS does not use those recipients), the armored ones (exports are binary), and `stream_257_chunks*` and
`stream_258_chunks` (16 MB each). The `identity:` header lines (the X25519 test identity, which these tests don't use)
are removed, so no file here carries anything shaped like a secret key; nothing else is changed. `AgeFileTests` reads
every file here except this one.
