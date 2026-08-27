/*
 *  HMAC-SHA512 and HKDF-SHA512 (RFC 5869). See hkdf_sha512.h.
 */
#include "hkdf_sha512.h"

#include <string.h>

#include "../airplay/ed25519/sha512.h"

void hmac_sha512_init(hmac_sha512_ctx *ctx, const uint8_t *key, size_t key_len) {
  uint8_t k[SHA512_BLOCK_LEN];
  uint8_t k_ipad[SHA512_BLOCK_LEN];

  memset(k, 0, sizeof(k));
  if (key_len > SHA512_BLOCK_LEN) {
    sha512(key, key_len, k); /* fills first 64 bytes, rest stay zero */
  } else if (key_len > 0) {
    memcpy(k, key, key_len);
  }

  for (size_t i = 0; i < SHA512_BLOCK_LEN; i++) {
    k_ipad[i] = k[i] ^ 0x36;
    ctx->k_opad[i] = k[i] ^ 0x5c;
  }

  sha512_init(&ctx->inner);
  sha512_update(&ctx->inner, k_ipad, SHA512_BLOCK_LEN);
}

void hmac_sha512_update(hmac_sha512_ctx *ctx, const uint8_t *data, size_t len) {
  sha512_update(&ctx->inner, data, len);
}

void hmac_sha512_final(hmac_sha512_ctx *ctx, uint8_t out[SHA512_DIGEST_LEN]) {
  uint8_t inner_digest[SHA512_DIGEST_LEN];
  sha512_context outer;

  sha512_final(&ctx->inner, inner_digest);

  sha512_init(&outer);
  sha512_update(&outer, ctx->k_opad, SHA512_BLOCK_LEN);
  sha512_update(&outer, inner_digest, SHA512_DIGEST_LEN);
  sha512_final(&outer, out);
}

void hmac_sha512(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t out[SHA512_DIGEST_LEN]) {
  hmac_sha512_ctx ctx;
  hmac_sha512_init(&ctx, key, key_len);
  hmac_sha512_update(&ctx, msg, msg_len);
  hmac_sha512_final(&ctx, out);
}

void hkdf_sha512(const uint8_t *salt, size_t salt_len,
                 const uint8_t *ikm, size_t ikm_len,
                 const uint8_t *info, size_t info_len,
                 uint8_t *okm, size_t okm_len) {
  uint8_t prk[SHA512_DIGEST_LEN];
  uint8_t zero_salt[SHA512_DIGEST_LEN];
  uint8_t t[SHA512_DIGEST_LEN];
  size_t t_len = 0;
  size_t done = 0;
  uint8_t counter = 1;

  if (salt == NULL || salt_len == 0) {
    memset(zero_salt, 0, sizeof(zero_salt));
    salt = zero_salt;
    salt_len = SHA512_DIGEST_LEN;
  }

  /* Extract: PRK = HMAC(salt, IKM) */
  hmac_sha512(salt, salt_len, ikm, ikm_len, prk);

  /* Expand: T(n) = HMAC(PRK, T(n-1) | info | n) */
  while (done < okm_len) {
    hmac_sha512_ctx ctx;
    size_t chunk;

    hmac_sha512_init(&ctx, prk, sizeof(prk));
    if (t_len > 0) hmac_sha512_update(&ctx, t, t_len);
    if (info_len > 0) hmac_sha512_update(&ctx, info, info_len);
    hmac_sha512_update(&ctx, &counter, 1);
    hmac_sha512_final(&ctx, t);
    t_len = SHA512_DIGEST_LEN;

    chunk = okm_len - done;
    if (chunk > SHA512_DIGEST_LEN) chunk = SHA512_DIGEST_LEN;
    memcpy(okm + done, t, chunk);
    done += chunk;
    counter++;
  }
}
