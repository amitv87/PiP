/*
 * mirror_crypto — ChaCha20-Poly1305 AEAD + HKDF-SHA512 for AirPlay 2 screen
 * mirroring, matching doubletake's video frame encryption. Apple-style
 * receivers encrypt the mirror video stream with ChaCha20-Poly1305 whose key is
 * HKDF-SHA512-derived; PiP previously only did AES-CTR (UxPlay style), which
 * such receivers can't decrypt (blank screen).
 */
#ifndef MIRROR_CRYPTO_H
#define MIRROR_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ChaCha20-Poly1305 AEAD seal (RFC 8439). out must hold pt_len + 16 bytes
 * (ciphertext followed by the 16-byte Poly1305 tag). */
void chacha20poly1305_seal(const uint8_t key[32], const uint8_t nonce[12],
                           const uint8_t *aad, size_t aad_len,
                           const uint8_t *plaintext, size_t pt_len,
                           uint8_t *out);

/* ChaCha20-Poly1305 AEAD open (decrypt + verify). ct_in is ciphertext followed
 * by the 16-byte tag (ct_len includes the tag). Writes ct_len-16 plaintext bytes
 * to out. Returns 0 if the tag verifies, non-zero otherwise. */
int chacha20poly1305_open(const uint8_t key[32], const uint8_t nonce[12],
                          const uint8_t *aad, size_t aad_len,
                          const uint8_t *ct_in, size_t ct_len,
                          uint8_t *out);

/* HMAC-SHA512 (RFC 4231). out is 64 bytes. */
void hmac_sha512(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len, uint8_t out[64]);

/* HKDF-SHA512 (RFC 5869) extract+expand. */
void hkdf_sha512(const uint8_t *ikm, size_t ikm_len,
                 const uint8_t *salt, size_t salt_len,
                 const uint8_t *info, size_t info_len,
                 uint8_t *okm, size_t okm_len);

/* Derive the 32-byte AirPlay DataStream ChaCha20-Poly1305 key:
 *   HKDF-SHA512(ikm, salt="DataStream-Salt<id>", info="DataStream-Output-Encryption-Key")
 * matching doubletake's deriveChaChaKey. ikm is the FairPlay-derived AES key
 * (raw playfair_decrypt output) or the pair-verify shared secret. */
void mirror_derive_datastream_key(const uint8_t *ikm, size_t ikm_len,
                                  uint64_t stream_connection_id,
                                  uint8_t key_out[32]);

#ifdef __cplusplus
}
#endif

#endif /* MIRROR_CRYPTO_H */
