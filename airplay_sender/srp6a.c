/*
 *  SRP-6a client (RFC 5054 3072-bit group, SHA-512). See srp6a.h.
 *
 *  axTLS bigint memory model: every arithmetic op frees the bigints passed to
 *  it. To keep a value V across several ops, pass bi_copy(V) each time and free
 *  the original once at the end. The group constants N and g are re-imported
 *  fresh per use (KEEP()/imp_N()/imp_g()) so no ref-counting is needed for them.
 */
#include "srp6a.h"

#include <string.h>

#include "../airplay/crypto/crypto.h"
#include "../airplay/crypto/bigint.h"
#include "../airplay/ed25519/sha512.h"

static const char *SRP_USERNAME = "Pair-Setup";

/* RFC 5054 3072-bit group modulus N (big-endian, exactly 384 bytes). */
static const char SRP_N_HEX[] =
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
    "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D"
    "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
    "83655D23DCA3AD961C62F356208552BB9ED529077096966D"
    "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9"
    "DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
    "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64"
    "ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
    "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B"
    "F12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
    "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB31"
    "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

static uint8_t N_bytes[SRP6A_MODULUS_LEN];
static uint8_t g_bytes[SRP6A_MODULUS_LEN]; /* g = 5, left-zero-padded */
static int constants_ready = 0;

static void init_constants(void) {
  if (constants_ready) return;
  for (int i = 0; i < SRP6A_MODULUS_LEN; i++) {
    char hi = SRP_N_HEX[i * 2], lo = SRP_N_HEX[i * 2 + 1];
    int h = (hi <= '9') ? hi - '0' : (hi & ~0x20) - 'A' + 10;
    int l = (lo <= '9') ? lo - '0' : (lo & ~0x20) - 'A' + 10;
    N_bytes[i] = (uint8_t)((h << 4) | l);
  }
  memset(g_bytes, 0, sizeof(g_bytes));
  g_bytes[SRP6A_MODULUS_LEN - 1] = 5;
  constants_ready = 1;
}

/* ---- small SHA-512 concatenation helpers ---- */

typedef struct { const uint8_t *p; size_t n; } chunk_t;

static void sha512_parts(const chunk_t *parts, int nparts, uint8_t out[64]) {
  sha512_context ctx;
  sha512_init(&ctx);
  for (int i = 0; i < nparts; i++) {
    if (parts[i].n) sha512_update(&ctx, parts[i].p, parts[i].n);
  }
  sha512_final(&ctx, out);
}

/* ---- bigint helpers ---- */

#ifdef SRP_DEBUG
#include <stdio.h>
static void dbgbi(BI_CTX *ctx, const char *l, bigint *b) {
  uint8_t t[SRP6A_MODULUS_LEN];
  bi_export(ctx, bi_copy(b), t, SRP6A_MODULUS_LEN);
  fprintf(stderr, "%s ", l);
  for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", t[i]);
  fprintf(stderr, "\n");
}
#else
#define dbgbi(a, b, c)
#endif

static bigint *imp_N(BI_CTX *ctx) { return bi_import(ctx, N_bytes, SRP6A_MODULUS_LEN); }
static bigint *imp_g(BI_CTX *ctx) { return bi_import(ctx, g_bytes, SRP6A_MODULUS_LEN); }

/* result = base^exp mod N; consumes base and exp. Uses the modulus installed
 * with bi_set_mod(BIGINT_M_OFFSET) by srp6a_client_compute. */
static bigint *modexpN(BI_CTX *ctx, bigint *base, bigint *exp) {
  return bi_mod_power(ctx, base, exp);
}

/* a mod N; consumes a. Uses Barrett reduction against the modulus installed by
 * bi_set_mod(BIGINT_M_OFFSET). Requires a < N^2 (holds for all uses here).
 * (The classical bi_divide is avoided: it hangs/misbehaves in this axTLS build.) */
static bigint *modN(BI_CTX *ctx, bigint *a) {
  return bi_barrett(ctx, a);
}

/* Export bi (consumed) to a 384-byte left-zero-padded buffer. */
static void export_pad(BI_CTX *ctx, bigint *bi, uint8_t out[SRP6A_MODULUS_LEN]) {
  bi_export(ctx, bi, out, SRP6A_MODULUS_LEN);
}

/* Copy pad384 into a minimal (leading-zeros-stripped) buffer. */
static void to_minimal(const uint8_t pad[SRP6A_MODULUS_LEN], uint8_t *out, size_t *outlen) {
  size_t start = 0;
  while (start < SRP6A_MODULUS_LEN - 1 && pad[start] == 0) start++;
  *outlen = SRP6A_MODULUS_LEN - start;
  memcpy(out, pad + start, *outlen);
}

int srp6a_client_compute(const uint8_t *salt, size_t salt_len,
                         const char *password,
                         const uint8_t *serverB, size_t serverB_len,
                         const uint8_t a_priv[32],
                         srp6a_client_t *out) {
  init_constants();
  memset(out, 0, sizeof(*out));

  const uint8_t *pw = (const uint8_t *)(password ? password : "");
  size_t pw_len = strlen(password ? password : "");

  BI_CTX *ctx = bi_initialize();
  bi_set_mod(ctx, imp_N(ctx), BIGINT_M_OFFSET);

  /* x = SHA512(salt || SHA512(username || ":" || password)) */
  uint8_t inner[64];
  {
    chunk_t parts[3] = {
        {(const uint8_t *)SRP_USERNAME, strlen(SRP_USERNAME)},
        {(const uint8_t *)":", 1},
        {pw, pw_len}};
    sha512_parts(parts, 3, inner);
  }
  uint8_t xhash[64];
  {
    chunk_t parts[2] = {{salt, salt_len}, {inner, 64}};
    sha512_parts(parts, 2, xhash);
  }
  bigint *x = bi_import(ctx, xhash, 64);
  bi_permanent(x);

  /* k = SHA512(pad(N,384) || pad(g,384)) */
  uint8_t khash[64];
  {
    chunk_t parts[2] = {{N_bytes, SRP6A_MODULUS_LEN}, {g_bytes, SRP6A_MODULUS_LEN}};
    sha512_parts(parts, 2, khash);
  }
  bigint *k = bi_import(ctx, khash, 64);

  /* a (secret), A = g^a mod N */
  bigint *a = bi_import(ctx, a_priv, 32);
  bi_permanent(a);
  bigint *A = modexpN(ctx, imp_g(ctx), bi_copy(a));
  bi_permanent(A);
  export_pad(ctx, bi_copy(A), out->A_pad);
  to_minimal(out->A_pad, out->A_min, &out->A_min_len);

  /* B (server public); reject B <= 0 or B >= N */
  bigint *B = bi_import(ctx, serverB, (int)serverB_len);
  bi_permanent(B);
  {
    bigint *N = imp_N(ctx);
    int cmp = bi_compare(B, N);      /* does not consume */
    bi_free(ctx, N);
    int is_zero = (B->size == 1 && B->comps[0] == 0);
    if (cmp >= 0 || is_zero) {
      bi_depermanent(x); bi_free(ctx, x);
      bi_depermanent(a); bi_free(ctx, a);
      bi_depermanent(A); bi_free(ctx, A);
      bi_depermanent(B); bi_free(ctx, B);
      bi_free(ctx, k);
      bi_free_mod(ctx, BIGINT_M_OFFSET);
      bi_terminate(ctx);
      return -1;
    }
  }
  uint8_t B_pad[SRP6A_MODULUS_LEN], B_min[SRP6A_MODULUS_LEN];
  size_t B_min_len;
  export_pad(ctx, bi_copy(B), B_pad);
  to_minimal(B_pad, B_min, &B_min_len);

  /* u = SHA512(pad(A,384) || pad(B,384)) */
  uint8_t uhash[64];
  {
    chunk_t parts[2] = {{out->A_pad, SRP6A_MODULUS_LEN}, {B_pad, SRP6A_MODULUS_LEN}};
    sha512_parts(parts, 2, uhash);
  }
  bigint *u = bi_import(ctx, uhash, 64);
  bi_permanent(u);

  /* S = (B - k*g^x mod N)^(a + u*x) mod N */
  bigint *gx = modexpN(ctx, imp_g(ctx), bi_copy(x));      /* g^x mod N */
  dbgbi(ctx, "gx  ", gx);
  dbgbi(ctx, "k   ", k);
  bigint *prod = bi_multiply(ctx, k, gx);
  dbgbi(ctx, "prod", prod);
  bigint *kgx = modN(ctx, prod);        /* (k*g^x) mod N, in [0,N) */
  dbgbi(ctx, "kgx ", kgx);
  /* diff = (B + N - k*g^x) mod N. B and kgx are both in [0,N), so B+N-kgx is
   * strictly positive; computing it this way avoids unsigned borrow/wrap. */
  int neg = 0;
  bigint *diff = bi_subtract(ctx, bi_add(ctx, bi_copy(B), imp_N(ctx)), kgx, &neg);
  diff = modN(ctx, diff);
  dbgbi(ctx, "diff", diff);
  bigint *ux = bi_multiply(ctx, bi_copy(u), bi_copy(x));   /* u*x */
  bigint *expo = bi_add(ctx, ux, bi_copy(a));              /* a + u*x */
  dbgbi(ctx, "expo", expo);
  bigint *S = modexpN(ctx, diff, expo);                    /* diff^expo mod N */
  dbgbi(ctx, "S   ", S);

  uint8_t S_pad[SRP6A_MODULUS_LEN], S_min[SRP6A_MODULUS_LEN];
  size_t S_min_len;
  export_pad(ctx, S, S_pad);
  to_minimal(S_pad, S_min, &S_min_len);

  /* K = SHA512(S) with S in natural representation */
  {
    chunk_t parts[1] = {{S_min, S_min_len}};
    sha512_parts(parts, 1, out->K);
  }

  /* M1 = SHA512( (H(N) XOR H(g)) || H(username) || salt || A || B || K ) */
  uint8_t hN[64], hg[64], hxor[64], hUser[64];
  { chunk_t p[1] = {{N_bytes, SRP6A_MODULUS_LEN}}; sha512_parts(p, 1, hN); }
  { const uint8_t g5 = 5; chunk_t p[1] = {{&g5, 1}}; sha512_parts(p, 1, hg); }
  for (int i = 0; i < 64; i++) hxor[i] = hN[i] ^ hg[i];
  { chunk_t p[1] = {{(const uint8_t *)SRP_USERNAME, strlen(SRP_USERNAME)}}; sha512_parts(p, 1, hUser); }
  {
    chunk_t parts[6] = {
        {hxor, 64}, {hUser, 64}, {salt, salt_len},
        {out->A_min, out->A_min_len}, {B_min, B_min_len}, {out->K, 64}};
    sha512_parts(parts, 6, out->M1);
  }

  bi_depermanent(x); bi_free(ctx, x);
  bi_depermanent(a); bi_free(ctx, a);
  bi_depermanent(A); bi_free(ctx, A);
  bi_depermanent(B); bi_free(ctx, B);
  bi_depermanent(u); bi_free(ctx, u);
  bi_free_mod(ctx, BIGINT_M_OFFSET);
  bi_terminate(ctx);
  return 0;
}

int srp6a_verify_server_proof(const srp6a_client_t *c,
                              const uint8_t *server_proof, size_t len) {
  if (len != 64) return 0;
  uint8_t expected[64];
  chunk_t parts[3] = {{c->A_min, c->A_min_len}, {c->M1, 64}, {c->K, 64}};
  sha512_parts(parts, 3, expected);
  uint8_t diff = 0;
  for (int i = 0; i < 64; i++) diff |= expected[i] ^ server_proof[i];
  return diff == 0;
}
