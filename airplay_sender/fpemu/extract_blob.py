#!/usr/bin/env python3
"""Extract the FairPlay snapshot blob from doubletake's fpexchange_data.go.

This mirrors airfry's rust/fpemu/build.rs: it parses the `snapshotData`
`[]byte{ ... }` array out of the (research-only) doubletake source and writes it
to fp_blob.bin. The blob is Apple's proprietary FairPlay code, so it is NEVER
committed to this repo — it is regenerated at build time on the machine doing
the build. See fpemu/README.md.

Usage:
    extract_blob.py <path/to/fpexchange_data.go> <out/fp_blob.bin>
"""
import re
import sys

MARKER = "var snapshotData = []byte{"


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: extract_blob.py <fpexchange_data.go> <fp_blob.bin>\n")
        return 2
    src_path, out_path = sys.argv[1], sys.argv[2]

    with open(src_path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()

    start = src.find(MARKER)
    if start < 0:
        sys.stderr.write("error: 'snapshotData' array not found in %s\n" % src_path)
        return 1
    start += len(MARKER)
    end = src.find("\n}", start)
    if end < 0:
        sys.stderr.write("error: end of snapshotData array not found\n")
        return 1
    body = src[start:end]

    # Greedily parse 0xNN (1-2 hex digit) tokens, exactly like build.rs.
    data = bytes(int(tok, 16) & 0xFF for tok in re.findall(r"0x([0-9a-fA-F]{1,2})", body))

    with open(out_path, "wb") as f:
        f.write(data)
    sys.stderr.write("fp_blob.bin: extracted %d bytes from %s\n" % (len(data), src_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
