/*  HAP encrypted channel framing. See hap_channel.h. */
#include "hap_channel.h"

#include <string.h>

#include "chacha20poly1305.h"

void hap_channel_init(hap_channel_t *ch,
                      const uint8_t write_key[32], const uint8_t read_key[32]) {
  memcpy(ch->write_key, write_key, 32);
  memcpy(ch->read_key, read_key, 32);
  ch->write_counter = 0;
  ch->read_counter = 0;
}

static void nonce_from_counter(uint64_t counter, uint8_t nonce[12]) {
  nonce[0] = nonce[1] = nonce[2] = nonce[3] = 0;
  for (int i = 0; i < 8; i++) nonce[4 + i] = (uint8_t)(counter >> (8 * i));
}

int hap_channel_encrypt(hap_channel_t *ch, const uint8_t *pt, size_t pt_len,
                        uint8_t *out, size_t out_cap) {
  size_t in_off = 0, out_off = 0;

  /* An empty message still needs no frame; mirror the reference which only
   * frames actual payload chunks. */
  do {
    size_t chunk = pt_len - in_off;
    if (chunk > HAP_MAX_FRAME_PLAINTEXT) chunk = HAP_MAX_FRAME_PLAINTEXT;

    if (out_off + 2 + chunk + 16 > out_cap) return -1;

    uint8_t len_prefix[2] = {(uint8_t)(chunk & 0xff), (uint8_t)((chunk >> 8) & 0xff)};
    uint8_t nonce[12];
    nonce_from_counter(ch->write_counter, nonce);

    out[out_off + 0] = len_prefix[0];
    out[out_off + 1] = len_prefix[1];
    chacha20poly1305_seal(ch->write_key, nonce, len_prefix, 2,
                          pt + in_off, chunk,
                          out + out_off + 2, out + out_off + 2 + chunk);
    out_off += 2 + chunk + 16;
    in_off += chunk;
    ch->write_counter++;
  } while (in_off < pt_len);

  return (int)out_off;
}

int hap_channel_decrypt_frame(hap_channel_t *ch, const uint8_t *in, size_t in_len,
                              uint8_t *out, size_t out_cap, size_t *consumed) {
  if (in_len < 2) return -2;
  size_t chunk = (size_t)in[0] | ((size_t)in[1] << 8);
  size_t frame_len = 2 + chunk + 16;
  if (in_len < frame_len) return -2;
  if (chunk > out_cap) return -1;

  uint8_t nonce[12];
  nonce_from_counter(ch->read_counter, nonce);

  const uint8_t *tag = in + 2 + chunk;
  if (!chacha20poly1305_open(ch->read_key, nonce, in, 2, in + 2, chunk, tag, out)) {
    return -1;
  }
  ch->read_counter++;
  if (consumed) *consumed = frame_len;
  return (int)chunk;
}
