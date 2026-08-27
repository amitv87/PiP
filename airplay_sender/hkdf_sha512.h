/*
 *  HMAC-SHA512 and HKDF-SHA512 (RFC 5869) for the AirPlay 2 sender.
 *
 *  Built on the vendored SHA-512 (airplay/ed25519/sha512.h). Used for AirPlay
 *  pairing key derivation (Pair-Setup / Pair-Verify / Control / Events salts)
 *  and DataStream video/audio stream keys.
 */
#ifndef HKDF_SHA512_H
#define HKDF_SHA512_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SHA512_DIGEST_LEN 64
#define SHA512_BLOCK_LEN  128

typedef struct hmac_sha512_ctx_s hmac_sha512_ctx;

/* Incremental HMAC-SHA512. */
void hmac_sha512_init(hmac_sha512_ctx *ctx, const uint8_t *key, size_t key_len);
void hmac_sha512_update(hmac_sha512_ctx *ctx, const uint8_t *data, size_t len);
void hmac_sha512_final(hmac_sha512_ctx *ctx, uint8_t out[SHA512_DIGEST_LEN]);

/* One-shot HMAC-SHA512. */
void hmac_sha512(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t out[SHA512_DIGEST_LEN]);

/*
 * HKDF-SHA512 extract-and-expand (RFC 5869). A NULL/empty salt is treated as a
 * block of zeros, per spec. okm_len must be <= 255*64.
 */
void hkdf_sha512(const uint8_t *salt, size_t salt_len,
                 const uint8_t *ikm, size_t ikm_len,
                 const uint8_t *info, size_t info_len,
                 uint8_t *okm, size_t okm_len);

/* Expose the context layout so callers can stack-allocate it. */
#include "../airplay/ed25519/sha512.h"
struct hmac_sha512_ctx_s {
  sha512_context inner;
  uint8_t k_opad[SHA512_BLOCK_LEN];
};

#ifdef __cplusplus
}
#endif

#endif /* HKDF_SHA512_H */
