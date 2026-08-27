/*
 *  HAP (HomeKit Accessory Protocol) encrypted channel framing used by the
 *  AirPlay 2 control and event channels after pair-verify.
 *
 *  Each frame: [LE16 plaintext_len] || ChaCha20-Poly1305 seal of up to 1024
 *  plaintext bytes, with the 2 length bytes as AAD and a nonce of
 *  4 zero bytes || LE64(counter). Read and write directions use independent
 *  keys and independent monotonic counters.
 */
#ifndef HAP_CHANNEL_H
#define HAP_CHANNEL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HAP_MAX_FRAME_PLAINTEXT 1024
#define HAP_FRAME_OVERHEAD      (2 + 16) /* length prefix + Poly1305 tag */

typedef struct {
  uint8_t write_key[32];
  uint8_t read_key[32];
  uint64_t write_counter;
  uint64_t read_counter;
} hap_channel_t;

void hap_channel_init(hap_channel_t *ch,
                      const uint8_t write_key[32], const uint8_t read_key[32]);

/*
 * Encrypt plaintext into one or more HAP frames. Returns total bytes written to
 * out, or -1 if out_cap is insufficient. Advances the write counter by one per
 * 1024-byte chunk.
 */
int hap_channel_encrypt(hap_channel_t *ch, const uint8_t *pt, size_t pt_len,
                        uint8_t *out, size_t out_cap);

/*
 * Decrypt a single HAP frame at the front of in. On success writes plaintext to
 * out, sets *consumed to the number of input bytes used, and returns the
 * plaintext length. Returns -1 on auth failure/short buffer, or -2 if in holds
 * an incomplete frame (need more bytes). Advances the read counter on success.
 */
int hap_channel_decrypt_frame(hap_channel_t *ch, const uint8_t *in, size_t in_len,
                              uint8_t *out, size_t out_cap, size_t *consumed);

#ifdef __cplusplus
}
#endif

#endif /* HAP_CHANNEL_H */
