/* ChaCha20-Poly1305 (RFC 8439) + HMAC/HKDF-SHA512. See mirror_crypto.h. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mirror_crypto.h"
#include "../airplay/ed25519/sha512.h"

/* ---- little-endian helpers ---- */
static uint32_t load32_le(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void store32_le(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
  p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static void store64_le(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

/* ---- ChaCha20 (RFC 8439) ---- */
#define ROTL32(v, n) (((v) << (n)) | ((v) >> (32 - (n))))
#define QR(x, a, b, c, d)                    \
  x[a] += x[b]; x[d] ^= x[a]; x[d] = ROTL32(x[d], 16); \
  x[c] += x[d]; x[b] ^= x[c]; x[b] = ROTL32(x[b], 12); \
  x[a] += x[b]; x[d] ^= x[a]; x[d] = ROTL32(x[d], 8);  \
  x[c] += x[d]; x[b] ^= x[c]; x[b] = ROTL32(x[b], 7)

static void chacha20_block(const uint32_t key[8], uint32_t counter,
                           const uint32_t nonce[3], uint8_t out[64]) {
  uint32_t st[16];
  st[0] = 0x61707865; st[1] = 0x3320646e; st[2] = 0x79622d32; st[3] = 0x6b206574;
  for (int i = 0; i < 8; i++) st[4 + i] = key[i];
  st[12] = counter; st[13] = nonce[0]; st[14] = nonce[1]; st[15] = nonce[2];

  uint32_t x[16];
  memcpy(x, st, sizeof(x));
  for (int i = 0; i < 10; i++) {
    QR(x, 0, 4, 8, 12); QR(x, 1, 5, 9, 13);
    QR(x, 2, 6, 10, 14); QR(x, 3, 7, 11, 15);
    QR(x, 0, 5, 10, 15); QR(x, 1, 6, 11, 12);
    QR(x, 2, 7, 8, 13); QR(x, 3, 4, 9, 14);
  }
  for (int i = 0; i < 16; i++) store32_le(out + 4 * i, x[i] + st[i]);
}

static void chacha20_xor(const uint8_t key[32], uint32_t counter,
                         const uint8_t nonce[12], const uint8_t *in,
                         uint8_t *out, size_t len) {
  uint32_t k[8], n[3];
  for (int i = 0; i < 8; i++) k[i] = load32_le(key + 4 * i);
  for (int i = 0; i < 3; i++) n[i] = load32_le(nonce + 4 * i);

  uint8_t block[64];
  size_t off = 0;
  while (off < len) {
    chacha20_block(k, counter, n, block);
    counter++;
    size_t chunk = len - off;
    if (chunk > 64) chunk = 64;
    for (size_t i = 0; i < chunk; i++) out[off + i] = in[off + i] ^ block[i];
    off += chunk;
  }
}

/* ---- Poly1305 (RFC 8439), poly1305-donna 32-bit ---- */
typedef struct {
  uint32_t r[5];
  uint32_t h[5];
  uint32_t pad[4];
  size_t leftover;
  uint8_t buffer[16];
  uint8_t final;
} poly1305_ctx;

static void poly1305_init(poly1305_ctx *st, const uint8_t key[32]) {
  uint32_t t0 = load32_le(key + 0);
  uint32_t t1 = load32_le(key + 4);
  uint32_t t2 = load32_le(key + 8);
  uint32_t t3 = load32_le(key + 12);

  st->r[0] = (t0) & 0x3ffffff;
  st->r[1] = ((t0 >> 26) | (t1 << 6)) & 0x3ffff03;
  st->r[2] = ((t1 >> 20) | (t2 << 12)) & 0x3ffc0ff;
  st->r[3] = ((t2 >> 14) | (t3 << 18)) & 0x3f03fff;
  st->r[4] = ((t3 >> 8)) & 0x00fffff;

  st->h[0] = st->h[1] = st->h[2] = st->h[3] = st->h[4] = 0;
  st->pad[0] = load32_le(key + 16);
  st->pad[1] = load32_le(key + 20);
  st->pad[2] = load32_le(key + 24);
  st->pad[3] = load32_le(key + 28);
  st->leftover = 0;
  st->final = 0;
}

static void poly1305_blocks(poly1305_ctx *st, const uint8_t *m, size_t bytes) {
  const uint32_t hibit = st->final ? 0 : (1UL << 24);
  uint32_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2], r3 = st->r[3], r4 = st->r[4];
  uint32_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
  uint32_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4];

  while (bytes >= 16) {
    h0 += (load32_le(m + 0)) & 0x3ffffff;
    h1 += (load32_le(m + 3) >> 2) & 0x3ffffff;
    h2 += (load32_le(m + 6) >> 4) & 0x3ffffff;
    h3 += (load32_le(m + 9) >> 6) & 0x3ffffff;
    h4 += (load32_le(m + 12) >> 8) | hibit;

    uint64_t d0 = (uint64_t)h0 * r0 + (uint64_t)h1 * s4 + (uint64_t)h2 * s3 + (uint64_t)h3 * s2 + (uint64_t)h4 * s1;
    uint64_t d1 = (uint64_t)h0 * r1 + (uint64_t)h1 * r0 + (uint64_t)h2 * s4 + (uint64_t)h3 * s3 + (uint64_t)h4 * s2;
    uint64_t d2 = (uint64_t)h0 * r2 + (uint64_t)h1 * r1 + (uint64_t)h2 * r0 + (uint64_t)h3 * s4 + (uint64_t)h4 * s3;
    uint64_t d3 = (uint64_t)h0 * r3 + (uint64_t)h1 * r2 + (uint64_t)h2 * r1 + (uint64_t)h3 * r0 + (uint64_t)h4 * s4;
    uint64_t d4 = (uint64_t)h0 * r4 + (uint64_t)h1 * r3 + (uint64_t)h2 * r2 + (uint64_t)h3 * r1 + (uint64_t)h4 * r0;

    uint32_t c = (uint32_t)(d0 >> 26); h0 = (uint32_t)d0 & 0x3ffffff;
    d1 += c; c = (uint32_t)(d1 >> 26); h1 = (uint32_t)d1 & 0x3ffffff;
    d2 += c; c = (uint32_t)(d2 >> 26); h2 = (uint32_t)d2 & 0x3ffffff;
    d3 += c; c = (uint32_t)(d3 >> 26); h3 = (uint32_t)d3 & 0x3ffffff;
    d4 += c; c = (uint32_t)(d4 >> 26); h4 = (uint32_t)d4 & 0x3ffffff;
    h0 += c * 5; c = (h0 >> 26); h0 = h0 & 0x3ffffff;
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
    for (size_t i = 0; i < want; i++) st->buffer[st->leftover + i] = m[i];
    bytes -= want;
    m += want;
    st->leftover += want;
    if (st->leftover < 16) return;
    poly1305_blocks(st, st->buffer, 16);
    st->leftover = 0;
  }
  if (bytes >= 16) {
    size_t want = bytes & ~((size_t)15);
    poly1305_blocks(st, m, want);
    m += want;
    bytes -= want;
  }
  if (bytes) {
    for (size_t i = 0; i < bytes; i++) st->buffer[st->leftover + i] = m[i];
    st->leftover += bytes;
  }
}

static void poly1305_finish(poly1305_ctx *st, uint8_t mac[16]) {
  if (st->leftover) {
    size_t i = st->leftover;
    st->buffer[i++] = 1;
    for (; i < 16; i++) st->buffer[i] = 0;
    st->final = 1;
    poly1305_blocks(st, st->buffer, 16);
  }

  uint32_t h0 = st->h[0], h1 = st->h[1], h2 = st->h[2], h3 = st->h[3], h4 = st->h[4];
  uint32_t c = h1 >> 26; h1 = h1 & 0x3ffffff;
  h2 += c; c = h2 >> 26; h2 = h2 & 0x3ffffff;
  h3 += c; c = h3 >> 26; h3 = h3 & 0x3ffffff;
  h4 += c; c = h4 >> 26; h4 = h4 & 0x3ffffff;
  h0 += c * 5; c = h0 >> 26; h0 = h0 & 0x3ffffff;
  h1 += c;

  uint32_t g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff;
  uint32_t g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff;
  uint32_t g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff;
  uint32_t g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff;
  uint32_t g4 = h4 + c - (1UL << 26);

  uint32_t mask = (g4 >> ((sizeof(uint32_t) * 8) - 1)) - 1;
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

  uint64_t f;
  f = (uint64_t)h0 + st->pad[0]; h0 = (uint32_t)f;
  f = (uint64_t)h1 + st->pad[1] + (f >> 32); h1 = (uint32_t)f;
  f = (uint64_t)h2 + st->pad[2] + (f >> 32); h2 = (uint32_t)f;
  f = (uint64_t)h3 + st->pad[3] + (f >> 32); h3 = (uint32_t)f;

  store32_le(mac + 0, h0);
  store32_le(mac + 4, h1);
  store32_le(mac + 8, h2);
  store32_le(mac + 12, h3);
}

/* ---- ChaCha20-Poly1305 AEAD seal (RFC 8439 §2.8) ---- */
void chacha20poly1305_seal(const uint8_t key[32], const uint8_t nonce[12],
                           const uint8_t *aad, size_t aad_len,
                           const uint8_t *plaintext, size_t pt_len,
                           uint8_t *out) {
  /* One-time Poly1305 key = ChaCha20 block 0. */
  uint32_t k[8], n[3];
  for (int i = 0; i < 8; i++) k[i] = load32_le(key + 4 * i);
  for (int i = 0; i < 3; i++) n[i] = load32_le(nonce + 4 * i);
  uint8_t poly_block[64];
  chacha20_block(k, 0, n, poly_block);

  /* Encrypt plaintext with counter starting at 1. */
  chacha20_xor(key, 1, nonce, plaintext, out, pt_len);

  /* MAC over aad || pad16 || ciphertext || pad16 || len(aad) || len(ct). */
  static const uint8_t zeros[16] = {0};
  poly1305_ctx st;
  poly1305_init(&st, poly_block);
  poly1305_update(&st, aad, aad_len);
  if (aad_len % 16) poly1305_update(&st, zeros, 16 - (aad_len % 16));
  poly1305_update(&st, out, pt_len);
  if (pt_len % 16) poly1305_update(&st, zeros, 16 - (pt_len % 16));
  uint8_t lengths[16];
  store64_le(lengths, (uint64_t)aad_len);
  store64_le(lengths + 8, (uint64_t)pt_len);
  poly1305_update(&st, lengths, 16);
  poly1305_finish(&st, out + pt_len);
}

int chacha20poly1305_open(const uint8_t key[32], const uint8_t nonce[12],
                          const uint8_t *aad, size_t aad_len,
                          const uint8_t *ct_in, size_t ct_len,
                          uint8_t *out) {
  if (ct_len < 16) return -1;
  size_t pt_len = ct_len - 16;

  uint32_t k[8], n[3];
  for (int i = 0; i < 8; i++) k[i] = load32_le(key + 4 * i);
  for (int i = 0; i < 3; i++) n[i] = load32_le(nonce + 4 * i);
  uint8_t poly_block[64];
  chacha20_block(k, 0, n, poly_block);

  /* Recompute the tag over aad || pad || ciphertext || pad || lengths. */
  static const uint8_t zeros[16] = {0};
  poly1305_ctx st;
  poly1305_init(&st, poly_block);
  poly1305_update(&st, aad, aad_len);
  if (aad_len % 16) poly1305_update(&st, zeros, 16 - (aad_len % 16));
  poly1305_update(&st, ct_in, pt_len);
  if (pt_len % 16) poly1305_update(&st, zeros, 16 - (pt_len % 16));
  uint8_t lengths[16];
  store64_le(lengths, (uint64_t)aad_len);
  store64_le(lengths + 8, (uint64_t)pt_len);
  poly1305_update(&st, lengths, 16);
  uint8_t tag[16];
  poly1305_finish(&st, tag);

  /* Constant-time compare against the received tag. */
  uint8_t diff = 0;
  const uint8_t *rx_tag = ct_in + pt_len;
  for (int i = 0; i < 16; i++) diff |= tag[i] ^ rx_tag[i];
  if (diff != 0) return -1;

  chacha20_xor(key, 1, nonce, ct_in, out, pt_len);
  return 0;
}

/* ---- HMAC-SHA512 ---- */
#define SHA512_BLOCK 128
#define SHA512_DIGEST 64

void hmac_sha512(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len, uint8_t out[64]) {
  uint8_t k[SHA512_BLOCK];
  memset(k, 0, sizeof(k));
  if (key_len > SHA512_BLOCK) {
    sha512(key, key_len, k); /* writes 64 bytes; rest stays zero */
  } else {
    memcpy(k, key, key_len);
  }

  uint8_t ipad[SHA512_BLOCK], opad[SHA512_BLOCK];
  for (int i = 0; i < SHA512_BLOCK; i++) {
    ipad[i] = k[i] ^ 0x36;
    opad[i] = k[i] ^ 0x5c;
  }

  uint8_t inner[SHA512_DIGEST];
  sha512_context c;
  sha512_init(&c);
  sha512_update(&c, ipad, SHA512_BLOCK);
  sha512_update(&c, msg, msg_len);
  sha512_final(&c, inner);

  sha512_init(&c);
  sha512_update(&c, opad, SHA512_BLOCK);
  sha512_update(&c, inner, SHA512_DIGEST);
  sha512_final(&c, out);
}

/* ---- HKDF-SHA512 (RFC 5869) ---- */
void hkdf_sha512(const uint8_t *ikm, size_t ikm_len,
                 const uint8_t *salt, size_t salt_len,
                 const uint8_t *info, size_t info_len,
                 uint8_t *okm, size_t okm_len) {
  /* Extract: PRK = HMAC(salt, IKM). */
  uint8_t prk[SHA512_DIGEST];
  uint8_t zero_salt[SHA512_DIGEST];
  if (salt == NULL || salt_len == 0) {
    memset(zero_salt, 0, sizeof(zero_salt));
    salt = zero_salt;
    salt_len = sizeof(zero_salt);
  }
  hmac_sha512(salt, salt_len, ikm, ikm_len, prk);

  /* Expand. */
  uint8_t t[SHA512_DIGEST];
  size_t t_len = 0;
  size_t done = 0;
  uint8_t counter = 1;
  uint8_t *buf = NULL;
  size_t buf_cap = SHA512_DIGEST + info_len + 1;
  buf = (uint8_t *)malloc(buf_cap);
  while (done < okm_len) {
    size_t p = 0;
    if (t_len) { memcpy(buf, t, t_len); p += t_len; }
    if (info_len) { memcpy(buf + p, info, info_len); p += info_len; }
    buf[p++] = counter;
    hmac_sha512(prk, SHA512_DIGEST, buf, p, t);
    t_len = SHA512_DIGEST;
    size_t chunk = okm_len - done;
    if (chunk > SHA512_DIGEST) chunk = SHA512_DIGEST;
    memcpy(okm + done, t, chunk);
    done += chunk;
    counter++;
  }
  free(buf);
}

void mirror_derive_datastream_key(const uint8_t *ikm, size_t ikm_len,
                                  uint64_t stream_connection_id,
                                  uint8_t key_out[32]) {
  char salt[64];
  int salt_len = snprintf(salt, sizeof(salt), "DataStream-Salt%llu",
                          (unsigned long long)stream_connection_id);
  static const char info[] = "DataStream-Output-Encryption-Key";
  hkdf_sha512(ikm, ikm_len, (const uint8_t *)salt, (size_t)salt_len,
              (const uint8_t *)info, sizeof(info) - 1, key_out, 32);
}
