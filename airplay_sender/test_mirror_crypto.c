/* Verifies mirror_crypto against golden vectors:
 *  - ChaCha20-Poly1305 AEAD: RFC 8439 §2.8.2
 *  - HMAC-SHA512: RFC 4231 Test Case 1
 *  - HKDF-SHA512 DataStream key: computed with Python hashlib/hmac
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "mirror_crypto.h"

static int fails = 0;

static int hb(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return 0;
}
static size_t unhex(const char *h, uint8_t *o) {
  size_t n = 0;
  for (size_t i = 0; h[i] && h[i + 1]; i += 2) o[n++] = (hb(h[i]) << 4) | hb(h[i + 1]);
  return n;
}
static void tohex(const uint8_t *b, size_t n, char *o) {
  const char *H = "0123456789abcdef";
  for (size_t i = 0; i < n; i++) { o[2 * i] = H[b[i] >> 4]; o[2 * i + 1] = H[b[i] & 15]; }
  o[2 * n] = 0;
}
static void check(const char *name, const uint8_t *got, size_t n, const char *want_hex) {
  char g[512];
  tohex(got, n, g);
  if (strcmp(g, want_hex) == 0) {
    printf("  [ ok ] %s\n", name);
  } else {
    printf("  [FAIL] %s\n         got  %s\n         want %s\n", name, g, want_hex);
    fails++;
  }
}

int main(void) {
  printf("mirror_crypto vector test\n");

  /* ChaCha20-Poly1305 AEAD (RFC 8439 §2.8.2) */
  {
    uint8_t key[32], nonce[12], aad[12];
    unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f", key);
    unhex("070000004041424344454647", nonce);
    unhex("50515253c0c1c2c3c4c5c6c7", aad);
    const char *pt = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    size_t pt_len = strlen(pt);
    uint8_t out[256];
    chacha20poly1305_seal(key, nonce, aad, 12, (const uint8_t *)pt, pt_len, out);
    check("chacha20poly1305 AEAD (RFC 8439)", out, pt_len + 16,
          "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
          "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
          "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
          "3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691");
  }

  /* HMAC-SHA512 (RFC 4231 TC1) */
  {
    uint8_t key[20];
    memset(key, 0x0b, 20);
    uint8_t out[64];
    hmac_sha512(key, 20, (const uint8_t *)"Hi There", 8, out);
    check("hmac-sha512 (RFC 4231 TC1)", out, 64,
          "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde"
          "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854");
  }

  /* DataStream key: HKDF-SHA512(ikm=00..0f, salt="DataStream-Salt<scid>", info=...) */
  {
    uint8_t ikm[16];
    for (int i = 0; i < 16; i++) ikm[i] = (uint8_t)i;
    uint8_t key32[32];
    mirror_derive_datastream_key(ikm, 16, 1762173453828767434ULL, key32);
    check("hkdf-sha512 DataStream key", key32, 32,
          "6e9ca96cfd5fcd536368673f43eada8c917dae8713384d3d3a4ea957d7559193");
  }

  printf("%s (%d failure%s)\n", fails ? "FAILED" : "PASSED", fails, fails == 1 ? "" : "s");
  return fails ? 1 : 0;
}
