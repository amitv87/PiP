/*
 * fpemu — FairPlay SAP exchange for the AirPlay sender.
 *
 * A self-contained ARM64 interpreter that executes Apple's embedded FairPlay
 * code to answer a receiver's FairPlay SAP challenge (m2) with a valid response
 * (m3). This is a faithful C port of airfry's Rust `fpemu`, which is itself a
 * byte-for-byte-validated port of doubletake's Go `fpemu`.
 *
 * The Apple FairPlay snapshot (fp_blob.bin) is Apple's proprietary code and is
 * NEVER committed to this repository — it is regenerated at build time from the
 * doubletake submodule. See fpemu/README.md.
 */
#ifndef FPEMU_H
#define FPEMU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Given a receiver's FairPlay m2 response (>= 142 bytes, the full FPLY-framed
 * blob), compute the 164-byte m3 response to POST back to /fp-setup.
 *
 * m3_out must point to at least 164 bytes. On success returns 0 and fills
 * m3_out with 164 bytes. On failure returns non-zero and leaves m3_out
 * untouched. Thread-safe: no shared mutable state.
 */
int fpsap_exchange_m3(const uint8_t *m2, size_t m2_len, uint8_t m3_out[164]);

/*
 * Core primitive: 128-byte challenge payload (m2[14..142]) -> 20-byte WB-AES
 * hash. m3 = 144-byte constant FPLY prefix followed by this hash. Returns 0 on
 * success, non-zero on interpreter failure.
 */
int fpsap_exchange_standalone(const uint8_t payload[128], uint8_t hash_out[20]);

#ifdef __cplusplus
}
#endif

#endif /* FPEMU_H */
