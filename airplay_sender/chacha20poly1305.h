/*
 *  ChaCha20-Poly1305 AEAD (RFC 8439, IETF construction: 96-bit nonce,
 *  32-bit block counter) for the AirPlay 2 sender.
 *
 *  Used for the HAP control/event channel framing and the DataStream video
 *  encryption. AirPlay layers its own nonce/AAD conventions on top; those live
 *  in the pairing/mirror code, not here.
 */
#ifndef CHACHA20POLY1305_H
#define CHACHA20POLY1305_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CHACHA20POLY1305_KEY_LEN   32
#define CHACHA20POLY1305_NONCE_LEN 12
#define CHACHA20POLY1305_TAG_LEN   16

/* Raw ChaCha20 keystream cipher (RFC 8439 §2.4). Encrypt == decrypt. */
void chacha20_xor(const uint8_t key[CHACHA20POLY1305_KEY_LEN],
                  const uint8_t nonce[CHACHA20POLY1305_NONCE_LEN],
                  uint32_t initial_counter,
                  const uint8_t *in, uint8_t *out, size_t len);

/* Poly1305 one-shot MAC (RFC 8439 §2.5). */
void poly1305_mac(const uint8_t key[32], const uint8_t *msg, size_t len,
                  uint8_t tag[16]);

/*
 * AEAD seal: writes len bytes of ciphertext to out and a 16-byte tag to tag.
 * out may alias in. aad may be NULL when aad_len is 0.
 */
void chacha20poly1305_seal(const uint8_t key[CHACHA20POLY1305_KEY_LEN],
                           const uint8_t nonce[CHACHA20POLY1305_NONCE_LEN],
                           const uint8_t *aad, size_t aad_len,
                           const uint8_t *in, size_t len,
                           uint8_t *out, uint8_t tag[CHACHA20POLY1305_TAG_LEN]);

/*
 * AEAD open: verifies tag, and on success writes len bytes of plaintext to out.
 * Returns 1 on success (tag valid), 0 on authentication failure (out untouched
 * on failure). out may alias in.
 */
int chacha20poly1305_open(const uint8_t key[CHACHA20POLY1305_KEY_LEN],
                          const uint8_t nonce[CHACHA20POLY1305_NONCE_LEN],
                          const uint8_t *aad, size_t aad_len,
                          const uint8_t *in, size_t len,
                          const uint8_t tag[CHACHA20POLY1305_TAG_LEN],
                          uint8_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CHACHA20POLY1305_H */
