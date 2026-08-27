/*
 *  ChaCha20-Poly1305 AEAD (RFC 8439). See chacha20poly1305.h.
 *
 *  Portable, constant-structure implementation (no table lookups keyed on
 *  secret data). Not performance-tuned; the mirror data path encrypts a few
 *  MB/s which this handles comfortably.
 */
#include "chacha20poly1305.h"

#include <string.h>

/* ---- little-endian helpers ---- */

static inline uint32_t load32_le(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void store32_le(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16);
  p[3] = (uint8_t)(v >> 24);
}

static inline uint32_t rotl32(uint32_t x, int n) {
  return (x << n) | (x >> (32 - n));
}

/* ---- ChaCha20 ---- */

#define QR(a, b, c, d)          \
  a += b; d ^= a; d = rotl32(d, 16); \
  c += d; b ^= c; b = rotl32(b, 12); \
  a += b; d ^= a; d = rotl32(d, 8);  \
  c += d; b ^= c; b = rotl32(b, 7)

static void chacha20_block(const uint32_t in[16], uint8_t out[64]) {
  uint32_t x[16];
  for (int i = 0; i < 16; i++) x[i] = in[i];

  for (int i = 0; i < 10; i++) {
    /* column rounds */
    QR(x[0], x[4], x[8], x[12]);
    QR(x[1], x[5], x[9], x[13]);
    QR(x[2], x[6], x[10], x[14]);
    QR(x[3], x[7], x[11], x[15]);
    /* diagonal rounds */
    QR(x[0], x[5], x[10], x[15]);
    QR(x[1], x[6], x[11], x[12]);
    QR(x[2], x[7], x[8], x[13]);
    QR(x[3], x[4], x[9], x[14]);
  }

  for (int i = 0; i < 16; i++) {
    store32_le(out + 4 * i, x[i] + in[i]);
  }
}

static void chacha20_init_state(uint32_t state[16],
                                const uint8_t key[32],
                                const uint8_t nonce[12],
                                uint32_t counter) {
  state[0] = 0x61707865;
  state[1] = 0x3320646e;
  state[2] = 0x79622d32;
  state[3] = 0x6b206574;
  for (int i = 0; i < 8; i++) state[4 + i] = load32_le(key + 4 * i);
  state[12] = counter;
  state[13] = load32_le(nonce + 0);
  state[14] = load32_le(nonce + 4);
  state[15] = load32_le(nonce + 8);
}

void chacha20_xor(const uint8_t key[32], const uint8_t nonce[12],
                  uint32_t initial_counter,
                  const uint8_t *in, uint8_t *out, size_t len) {
  uint32_t state[16];
  uint8_t block[64];
  size_t off = 0;

  chacha20_init_state(state, key, nonce, initial_counter);

  while (off < len) {
    size_t n = len - off;
    if (n > 64) n = 64;
    chacha20_block(state, block);
    for (size_t i = 0; i < n; i++) out[off + i] = in[off + i] ^ block[i];
    off += n;
    state[12]++; /* next block counter */
  }
}

/* ---- Poly1305 (RFC 8439 §2.5) ---- */

typedef struct {
  uint32_t r[5];
  uint32_t h[5];
  uint32_t pad[4];
  size_t leftover;
  uint8_t buffer[16];
  uint8_t final;
} poly1305_ctx;

static void poly1305_init(poly1305_ctx *st, const uint8_t key[32]) {
  st->r[0] = (load32_le(&key[0])) & 0x3ffffff;
  st->r[1] = (load32_le(&key[3]) >> 2) & 0x3ffff03;
  st->r[2] = (load32_le(&key[6]) >> 4) & 0x3ffc0ff;
  st->r[3] = (load32_le(&key[9]) >> 6) & 0x3f03fff;
  st->r[4] = (load32_le(&key[12]) >> 8) & 0x00fffff;

  st->h[0] = st->h[1] = st->h[2] = st->h[3] = st->h[4] = 0;

  st->pad[0] = load32_le(&key[16]);
  st->pad[1] = load32_le(&key[20]);
  st->pad[2] = load32_le(&key[24]);
  st->pad[3] = load32_le(&key[28]);

  st->leftover = 0;
  st->final = 0;
}

static void poly1305_blocks(poly1305_ctx *st, const uint8_t *m, size_t bytes) {
  const uint32_t hibit = st->final ? 0 : (1 << 24);
  uint32_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2], r3 = st->r[3], r4 = st->r[4];
  uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
  uint32_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4];

  while (bytes >= 16) {
    uint64_t d0, d1, d2, d3, d4;
    uint32_t c;

    h0 += (load32_le(m + 0)) & 0x3ffffff;
    h1 += (load32_le(m + 3) >> 2) & 0x3ffffff;
    h2 += (load32_le(m + 6) >> 4) & 0x3ffffff;
    h3 += (load32_le(m + 9) >> 6) & 0x3ffffff;
    h4 += (load32_le(m + 12) >> 8) | hibit;

    d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 + (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
    d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 + (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
    d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 + (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
    d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 + (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
    d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 + (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

    c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffff;
    d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffff;
    d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffff;
    d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffff;
    d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffff;
    h0 += c * 5; c = h0 >> 26; h0 = h0 & 0x3ffffff;
    h1 += c;

    m += 16;
    bytes -= 16;
  }

  st->h[0] = h0; st->h[1] = h1; st->h[2] = h2; st->h[3] = h3; st->h[4] = h4;
}

static void poly1305_update(poly1305_ctx *st, const uint8_t *m, size_t bytes) {
  if (st->leftover) {
    size_t want = 16 - st->leftover;
    if (want > bytes) want = bytes;
    memcpy(st->buffer + st->leftover, m, want);
    bytes -= want;
    m += want;
    st->leftover += want;
    if (st->leftover < 16) return;
    poly1305_blocks(st, st->buffer, 16);
    st->leftover = 0;
  }

  if (bytes >= 16) {
    size_t want = bytes & ~(size_t)15;
    poly1305_blocks(st, m, want);
    m += want;
    bytes -= want;
  }

  if (bytes) {
    memcpy(st->buffer + st->leftover, m, bytes);
    st->leftover += bytes;
  }
}

static void poly1305_finish(poly1305_ctx *st, uint8_t mac[16]) {
  uint32_t h0, h1, h2, h3, h4, c;
  uint32_t g0, g1, g2, g3, g4;
  uint64_t f;
  uint32_t mask;

  if (st->leftover) {
    size_t i = st->leftover;
    st->buffer[i++] = 1;
    for (; i < 16; i++) st->buffer[i] = 0;
    st->final = 1;
    poly1305_blocks(st, st->buffer, 16);
  }

  h0 = st->h[0]; h1 = st->h[1]; h2 = st->h[2]; h3 = st->h[3]; h4 = st->h[4];

  c = h1 >> 26; h1 &= 0x3ffffff;
  h2 += c; c = h2 >> 26; h2 &= 0x3ffffff;
  h3 += c; c = h3 >> 26; h3 &= 0x3ffffff;
  h4 += c; c = h4 >> 26; h4 &= 0x3ffffff;
  h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff;
  h1 += c;

  g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
  g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
  g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
  g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
  g4 = h4 + c - (1 << 26);

  mask = (g4 >> ((sizeof(uint32_t) * 8) - 1)) - 1;
  g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
  mask = ~mask;
  h0 = (h0 & mask) | g0;
  h1 = (h1 & mask) | g1;
  h2 = (h2 & mask) | g2;
  h3 = (h3 & mask) | g3;
  h4 = (h4 & mask) | g4;

  h0 = (h0) | (h1 << 26);
  h1 = (h1 >> 6) | (h2 << 20);
  h2 = (h2 >> 12) | (h3 << 14);
  h3 = (h3 >> 18) | (h4 << 8);

  f = (uint64_t)h0 + st->pad[0]; h0 = (uint32_t)f;
  f = (uint64_t)h1 + st->pad[1] + (f >> 32); h1 = (uint32_t)f;
  f = (uint64_t)h2 + st->pad[2] + (f >> 32); h2 = (uint32_t)f;
  f = (uint64_t)h3 + st->pad[3] + (f >> 32); h3 = (uint32_t)f;

  store32_le(mac + 0, h0);
  store32_le(mac + 4, h1);
  store32_le(mac + 8, h2);
  store32_le(mac + 12, h3);
}

void poly1305_mac(const uint8_t key[32], const uint8_t *msg, size_t len,
                  uint8_t tag[16]) {
  poly1305_ctx st;
  poly1305_init(&st, key);
  poly1305_update(&st, msg, len);
  poly1305_finish(&st, tag);
}

/* ---- AEAD (RFC 8439 §2.8) ---- */

static const uint8_t zero_pad[16] = {0};

static void poly1305_update_padded(poly1305_ctx *st, const uint8_t *data, size_t len) {
  poly1305_update(st, data, len);
  size_t rem = len % 16;
  if (rem) poly1305_update(st, zero_pad, 16 - rem);
}

static void aead_tag(const uint8_t key[32], const uint8_t nonce[12],
                     const uint8_t *aad, size_t aad_len,
                     const uint8_t *ciphertext, size_t ct_len,
                     uint8_t tag[16]) {
  uint8_t poly_key[64];
  poly1305_ctx st;
  uint8_t lengths[16];

  /* Poly1305 one-time key = ChaCha20 block 0 (first 32 bytes). */
  memset(poly_key, 0, sizeof(poly_key));
  chacha20_xor(key, nonce, 0, poly_key, poly_key, 32);

  poly1305_init(&st, poly_key);
  poly1305_update_padded(&st, aad, aad_len);
  poly1305_update_padded(&st, ciphertext, ct_len);

  store32_le(lengths + 0, (uint32_t)aad_len);
  store32_le(lengths + 4, (uint32_t)((uint64_t)aad_len >> 32));
  store32_le(lengths + 8, (uint32_t)ct_len);
  store32_le(lengths + 12, (uint32_t)((uint64_t)ct_len >> 32));
  poly1305_update(&st, lengths, 16);

  poly1305_finish(&st, tag);
}

void chacha20poly1305_seal(const uint8_t key[32], const uint8_t nonce[12],
                           const uint8_t *aad, size_t aad_len,
                           const uint8_t *in, size_t len,
                           uint8_t *out, uint8_t tag[16]) {
  /* Ciphertext uses block counter starting at 1 (block 0 is the poly key). */
  chacha20_xor(key, nonce, 1, in, out, len);
  aead_tag(key, nonce, aad, aad_len, out, len, tag);
}

int chacha20poly1305_open(const uint8_t key[32], const uint8_t nonce[12],
                          const uint8_t *aad, size_t aad_len,
                          const uint8_t *in, size_t len,
                          const uint8_t tag[16], uint8_t *out) {
  uint8_t computed[16];
  uint8_t diff = 0;

  aead_tag(key, nonce, aad, aad_len, in, len, computed);
  for (int i = 0; i < 16; i++) diff |= computed[i] ^ tag[i];
  if (diff != 0) return 0;

  chacha20_xor(key, nonce, 1, in, out, len);
  return 1;
}
