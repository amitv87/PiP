# fpemu — FairPlay SAP exchange (C port)

A self-contained ARM64 interpreter that executes Apple's embedded FairPlay code
to answer a receiver's FairPlay SAP challenge. This is what lets the AirPlay
sender mirror to **any** real Apple TV / HomePod, instead of only the
project's own reverse-engineered receiver.

Given a receiver's `m2` (the response to `POST /fp-setup` with `m1`), it computes
the correct `m3` to POST back, and the wrapped stream key follows from the same
exchange. Because it runs Apple's real algorithm against whatever challenge the
receiver sends, it generalizes to arbitrary receivers — unlike the previous
byte-echo handshake in `fairplay_client.c`.

## Provenance & licensing

- The interpreter is a faithful C port of **airfry**'s `rust/fpemu`
  (MIT-licensed), which is itself a byte-for-byte-validated port of
  **doubletake**'s Go `fpemu`.
- The crypto primitives the Rust version pulls from crates.io (`aes`, `ctr`,
  `sha1`, `sha2`) are provided here by macOS **CommonCrypto** — no external
  dependency.
- **`fp_blob.bin` is Apple's proprietary FairPlay code and is NEVER committed.**
  It is regenerated at build time by `extract_blob.py` from the doubletake
  source (`internal/fpemu/fpexchange_data.go`). The compiled binary embeds it
  via `.incbin` (see `fp_blob.S`), so the extraction happens on the machine
  doing the build — Apple's code is not redistributed by this repo.

## Files

| File | Role |
|---|---|
| `fpemu.h` | Public API: `fpsap_exchange_m3`, `fpsap_exchange_standalone` |
| `fpemu_priv.h` | CPU / memory / state model + helper declarations |
| `fpemu_map.c` | `u64`-keyed hash map (pages, stubs, crypto contexts) |
| `fpemu_helpers.c` | ARM64 arithmetic helpers + condition codes |
| `fpemu_mem.c` | Paged guest memory |
| `fpemu_stubs.c` | libc / CommonCrypto stubs + interpreter state lifecycle |
| `fpemu_decode.c` | The ARM64 fetch-decode-execute interpreter |
| `fpemu_loader.c` | Snapshot loader + `m3` prefix + dedup fixups + entry points |
| `fp_blob.S` | `.incbin` of `fp_blob.bin` |
| `extract_blob.py` | Build-time blob extractor (from doubletake) |
| `test_fpemu.c` | Golden-vector test (values from doubletake) |

## Build the blob (once, or via the build system)

```sh
python3 extract_blob.py \
    /path/to/doubletake/internal/fpemu/fpexchange_data.go \
    fp_blob.bin
```

`fp_blob.bin` must be 165,575 bytes.

## Run the self-test

```sh
clang -O2 -std=c11 -I. -o test_fpemu \
    test_fpemu.c fpemu_map.c fpemu_helpers.c fpemu_mem.c \
    fpemu_stubs.c fpemu_decode.c fpemu_loader.c fp_blob.S
./test_fpemu
```

Expect `PASSED (0 failures)` — all vectors match doubletake/airfry byte-for-byte.
CommonCrypto links automatically via libSystem (no `-framework` needed). The
assembler resolves `.incbin "fp_blob.bin"` via the `-I.` include path.
