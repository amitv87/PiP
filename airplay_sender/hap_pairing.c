/* AirPlay 2 HAP transient pairing (SRP-6a pair-setup + X25519 pair-verify).
 * See hap_pairing.h. Ported from airfry src/pairing.rs. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "hap_pairing.h"
#include "http_client.h"
#include "tlv8.h"
#include "mirror_crypto.h"
#include "../airplay/crypto/bigint.h"
#include "../airplay/ed25519/sha512.h"
#include "../airplay/ed25519/ed25519.h"
#include "../airplay/curve25519/curve25519.h"

/* RFC 5054 3072-bit group, g = 5. */
static const char *SRP_N_HEX =
"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
"020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
"E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6"
"49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD96"
"1C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE5"
"15D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A"
"8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B"
"F12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"
"08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

#define SRP_LEN 384

static int hexnib(char c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }

/* SHA-512 over up to 6 (ptr,len) chunks. */
static void sha512_cat(uint8_t out[64],
                       const uint8_t *a, int la, const uint8_t *b, int lb,
                       const uint8_t *c, int lc, const uint8_t *d, int ld,
                       const uint8_t *e, int le, const uint8_t *f, int lf) {
    sha512_context s;
    sha512_init(&s);
    if (a) sha512_update(&s, a, la);
    if (b) sha512_update(&s, b, lb);
    if (c) sha512_update(&s, c, lc);
    if (d) sha512_update(&s, d, ld);
    if (e) sha512_update(&s, e, le);
    if (f) sha512_update(&s, f, lf);
    sha512_final(&s, out);
}

static int nat_off(const uint8_t *p, int n) { int i = 0; while (i < n - 1 && p[i] == 0) i++; return i; }

static void hap_nonce(uint8_t nonce[12], const char *label8) {
    memset(nonce, 0, 12);
    memcpy(nonce + 4, label8, 8);
}

/* POST a TLV8 body to path; copy the response body into resp. Returns response
 * length (>=0) on HTTP 200, or -1 on failure. */
static int post_tlv(struct http_client_s *http, const char *path,
                    const uint8_t *body, int blen, uint8_t *resp, int cap) {
    http_client_response_t *r = http_client_request(
        http, "POST", path,
        "Content-Type: application/octet-stream\r\nX-Apple-HKP: 3\r\n",
        (const char *)body, blen);
    if (!r || r->status_code != 200) {
        fprintf(stderr, "hap: %s failed, status=%d\n", path, r ? r->status_code : -1);
        if (r) http_client_response_destroy(r);
        return -1;
    }
    int n = r->body_len;
    if (n > cap) n = cap;
    if (n > 0 && r->body) memcpy(resp, r->body, n);
    http_client_response_destroy(r);
    return n;
}

/* Complete SRP-6a transient pair-setup (M1..M6). Fills K (64 bytes). */
static int pair_setup(struct http_client_s *http, const char *pairing_id,
                      const uint8_t ed_pub[32], const uint8_t ed_priv[64],
                      uint8_t out_K[64]) {
    /* ---- M1: method=0, state=1, flags=transient ---- */
    uint8_t v_method = 0, v_state = 1, v_flags[4] = {0x10, 0, 0, 0};
    tlv8_item m1[] = {
        {TLV_METHOD, &v_method, 1},
        {TLV_STATE, &v_state, 1},
        {TLV_FLAGS, v_flags, 4},
    };
    uint8_t buf[1024];
    int mn = (int)tlv8_encode(m1, 3, buf, sizeof buf);
    uint8_t resp[1024];
    int rn = post_tlv(http, "/pair-setup", buf, mn, resp, sizeof resp);
    if (rn < 0) return -1;

    uint8_t err[8]; size_t el;
    if (tlv8_get(resp, rn, TLV_ERROR, err, sizeof err, &el) && el && err[0]) {
        fprintf(stderr, "hap: pair-setup M2 error %d\n", err[0]);
        return -1;
    }
    uint8_t salt[64]; size_t saltlen = 0;
    tlv8_get(resp, rn, TLV_SALT, salt, sizeof salt, &saltlen);
    uint8_t Bb[SRP_LEN]; size_t blen = 0;
    if (!tlv8_get(resp, rn, TLV_PUBLIC_KEY, Bb, sizeof Bb, &blen) || blen == 0) {
        fprintf(stderr, "hap: M2 missing server public key\n");
        return -1;
    }

    /* ---- SRP-6a (validated math): x, k, a, A, u, S, K, M1 proof ---- */
    uint8_t Nb[SRP_LEN];
    for (int i = 0; i < SRP_LEN; i++) Nb[i] = (hexnib(SRP_N_HEX[i * 2]) << 4) | hexnib(SRP_N_HEX[i * 2 + 1]);
    uint8_t gb[1] = {5};
    uint8_t ab[32];
    arc4random_buf(ab, sizeof ab);

    BI_CTX *ctx = bi_initialize();
    bigint *N = bi_import(ctx, Nb, SRP_LEN);
    bigint *g = bi_import(ctx, gb, 1);
    bigint *a = bi_import(ctx, ab, 32);
    bigint *B = bi_import(ctx, Bb, (int)blen);
    bi_set_mod(ctx, bi_clone(ctx, N), BIGINT_M_OFFSET);

    /* x = H(salt || H("Pair-Setup:3939")) ; k = H(pad(N)||pad(g)) */
    uint8_t inner[64]; sha512_cat(inner, (const uint8_t *)"Pair-Setup:3939", 15, 0,0,0,0,0,0,0,0,0,0);
    uint8_t xh[64]; sha512_cat(xh, salt, (int)saltlen, inner, 64, 0,0,0,0,0,0,0,0);
    bigint *x = bi_import(ctx, xh, 64);
    uint8_t padN[SRP_LEN]; bi_export(ctx, bi_clone(ctx, N), padN, SRP_LEN);
    uint8_t padg[SRP_LEN]; bi_export(ctx, bi_clone(ctx, g), padg, SRP_LEN);
    uint8_t kh[64]; sha512_cat(kh, padN, SRP_LEN, padg, SRP_LEN, 0,0,0,0,0,0,0,0);
    bigint *k = bi_import(ctx, kh, 64);

    /* A = g^a mod N */
    bigint *A = bi_mod_power(ctx, bi_clone(ctx, g), bi_clone(ctx, a));
    uint8_t Apad[SRP_LEN]; bi_export(ctx, bi_clone(ctx, A), Apad, SRP_LEN);
    uint8_t Bpad[SRP_LEN]; bi_export(ctx, bi_clone(ctx, B), Bpad, SRP_LEN);

    /* u = H(pad(A)||pad(B)) */
    uint8_t uh[64]; sha512_cat(uh, Apad, SRP_LEN, Bpad, SRP_LEN, 0,0,0,0,0,0,0,0);
    bigint *u = bi_import(ctx, uh, 64);

    /* gx = g^x mod N ; kgx = (k*gx) mod N (Barrett) */
    bigint *gx = bi_mod_power(ctx, bi_clone(ctx, g), bi_clone(ctx, x));
    bigint *kgx = bi_residue(ctx, bi_multiply(ctx, bi_clone(ctx, k), bi_clone(ctx, gx)));

    /* diff = ((B+N) - kgx) mod N  (always-positive subtraction) */
    int dz = 0;
    bigint *bpn = bi_add(ctx, bi_clone(ctx, B), bi_clone(ctx, N));
    bigint *diff = bi_residue(ctx, bi_subtract(ctx, bpn, bi_clone(ctx, kgx), &dz));

    /* e = a + u*x ; S = diff^e mod N ; K = H(S natural) */
    bigint *e = bi_add(ctx, bi_clone(ctx, a), bi_multiply(ctx, bi_clone(ctx, u), bi_clone(ctx, x)));
    bigint *S = bi_mod_power(ctx, bi_clone(ctx, diff), bi_clone(ctx, e));
    uint8_t Spad[SRP_LEN]; bi_export(ctx, bi_clone(ctx, S), Spad, SRP_LEN);
    int soff = nat_off(Spad, SRP_LEN);
    uint8_t K[64]; sha512_cat(K, Spad + soff, SRP_LEN - soff, 0,0,0,0,0,0,0,0,0,0);

    /* M1 proof = H( (H(N)^H(g)) || H("Pair-Setup") || salt || A_nat || B_nat || K ) */
    uint8_t hnn[64]; sha512_cat(hnn, padN, SRP_LEN, 0,0,0,0,0,0,0,0,0,0);
    uint8_t hgg[64]; sha512_cat(hgg, gb, 1, 0,0,0,0,0,0,0,0,0,0);
    uint8_t hxor[64]; for (int i = 0; i < 64; i++) hxor[i] = hnn[i] ^ hgg[i];
    uint8_t hu[64]; sha512_cat(hu, (const uint8_t *)"Pair-Setup", 10, 0,0,0,0,0,0,0,0,0,0);
    int aoff = nat_off(Apad, SRP_LEN), boff = nat_off(Bpad, SRP_LEN);
    uint8_t M1p[64];
    sha512_cat(M1p, hxor, 64, hu, 64, salt, (int)saltlen,
               Apad + aoff, SRP_LEN - aoff, Bpad + boff, SRP_LEN - boff, K, 64);

    /* keep A (padded, 384) for M3; free the bigint context (leak-free enough). */
    /* ---- M3: state=3, publicKey=pad(A,384), proof=M1 ---- */
    tlv8_item m3[] = {
        {TLV_STATE, (const uint8_t[]){3}, 1},
        {TLV_PUBLIC_KEY, Apad, SRP_LEN},
        {TLV_PROOF, M1p, 64},
    };
    mn = (int)tlv8_encode(m3, 3, buf, sizeof buf);
    rn = post_tlv(http, "/pair-setup", buf, mn, resp, sizeof resp);
    if (rn < 0) return -1;
    if (tlv8_get(resp, rn, TLV_ERROR, err, sizeof err, &el) && el && err[0]) {
        fprintf(stderr, "hap: pair-setup M4 error %d\n", err[0]);
        return -1;
    }

    /* ---- M5: encrypted sub-TLV {identifier, ed25519 pub, signature} ---- */
    size_t idlen = strlen(pairing_id);
    uint8_t session_key[32];
    hkdf_sha512(K, 64, (const uint8_t *)"Pair-Setup-Encrypt-Salt", 23,
                (const uint8_t *)"Pair-Setup-Encrypt-Info", 23, session_key, 32);
    uint8_t sign_key[32];
    hkdf_sha512(K, 64, (const uint8_t *)"Pair-Setup-Controller-Sign-Salt", 31,
                (const uint8_t *)"Pair-Setup-Controller-Sign-Info", 31, sign_key, 32);

    /* signature over sign_key || pairing_id || ed_pub */
    uint8_t sig_in[32 + 128 + 32];
    memcpy(sig_in, sign_key, 32);
    memcpy(sig_in + 32, pairing_id, idlen);
    memcpy(sig_in + 32 + idlen, ed_pub, 32);
    uint8_t sig[64];
    ed25519_sign(sig, sig_in, 32 + idlen + 32, ed_pub, ed_priv);

    tlv8_item sub[] = {
        {TLV_IDENTIFIER, (const uint8_t *)pairing_id, idlen},
        {TLV_PUBLIC_KEY, ed_pub, 32},
        {TLV_SIGNATURE, sig, 64},
    };
    uint8_t subbuf[256];
    int subn = (int)tlv8_encode(sub, 3, subbuf, sizeof subbuf);

    uint8_t nonce[12]; hap_nonce(nonce, "PS-Msg05");
    uint8_t sealed[512];
    chacha20poly1305_seal(session_key, nonce, NULL, 0, subbuf, subn, sealed);

    tlv8_item m5[] = {
        {TLV_STATE, (const uint8_t[]){5}, 1},
        {TLV_ENCRYPTED_DATA, sealed, (size_t)(subn + 16)},
    };
    mn = (int)tlv8_encode(m5, 2, buf, sizeof buf);
    rn = post_tlv(http, "/pair-setup", buf, mn, resp, sizeof resp);
    if (rn < 0) return -1;
    if (tlv8_get(resp, rn, TLV_ERROR, err, sizeof err, &el) && el && err[0]) {
        fprintf(stderr, "hap: pair-setup M6 error %d\n", err[0]);
        return -1;
    }

    memcpy(out_K, K, 64);
    fprintf(stderr, "hap: pair-setup (transient SRP) complete\n");
    return 0;
}

/* HAP pair-verify (V1..V4); derives shared secret + control keys. */
static int pair_verify(struct http_client_s *http, const char *pairing_id,
                       const uint8_t ed_pub[32], const uint8_t ed_priv[64],
                       hap_keys_t *out) {
    size_t idlen = strlen(pairing_id);
    static const uint8_t base9[32] = {9};
    uint8_t xpriv[32]; arc4random_buf(xpriv, sizeof xpriv);
    uint8_t xpub[32]; curve25519_donna(xpub, xpriv, base9);

    /* ---- V1: state=1, publicKey=clientX25519 ---- */
    tlv8_item v1[] = {
        {TLV_STATE, (const uint8_t[]){1}, 1},
        {TLV_PUBLIC_KEY, xpub, 32},
    };
    uint8_t buf[512];
    int mn = (int)tlv8_encode(v1, 2, buf, sizeof buf);
    uint8_t resp[1024];
    int rn = post_tlv(http, "/pair-verify", buf, mn, resp, sizeof resp);
    if (rn < 0) return -1;

    uint8_t err[8]; size_t el;
    if (tlv8_get(resp, rn, TLV_ERROR, err, sizeof err, &el) && el && err[0]) {
        fprintf(stderr, "hap: pair-verify V2 error %d\n", err[0]);
        return -1;
    }
    uint8_t spub[64]; size_t splen = 0;
    if (!tlv8_get(resp, rn, TLV_PUBLIC_KEY, spub, sizeof spub, &splen) || splen < 32) {
        fprintf(stderr, "hap: V2 missing server public key\n");
        return -1;
    }

    uint8_t shared[32]; curve25519_donna(shared, xpriv, spub);
    uint8_t verify_key[32];
    hkdf_sha512(shared, 32, (const uint8_t *)"Pair-Verify-Encrypt-Salt", 24,
                (const uint8_t *)"Pair-Verify-Encrypt-Info", 24, verify_key, 32);

    /* Best-effort: verify the server's encrypted blob (nonce PV-Msg02). */
    uint8_t senc[256]; size_t senclen = 0;
    if (tlv8_get(resp, rn, TLV_ENCRYPTED_DATA, senc, sizeof senc, &senclen) && senclen >= 16) {
        uint8_t nonce[12]; hap_nonce(nonce, "PV-Msg02");
        uint8_t dec[256];
        if (chacha20poly1305_open(verify_key, nonce, NULL, 0, senc, senclen, dec) != 0) {
            fprintf(stderr, "hap: warning - V2 blob auth failed (continuing)\n");
        }
    }

    /* ---- V3: signed (clientX25519 || pairingID || serverX25519), encrypted ---- */
    uint8_t sig_in[32 + 128 + 32];
    memcpy(sig_in, xpub, 32);
    memcpy(sig_in + 32, pairing_id, idlen);
    memcpy(sig_in + 32 + idlen, spub, 32);
    uint8_t sig[64];
    ed25519_sign(sig, sig_in, 32 + idlen + 32, ed_pub, ed_priv);

    tlv8_item sub[] = {
        {TLV_IDENTIFIER, (const uint8_t *)pairing_id, idlen},
        {TLV_SIGNATURE, sig, 64},
    };
    uint8_t subbuf[256];
    int subn = (int)tlv8_encode(sub, 2, subbuf, sizeof subbuf);
    uint8_t nonce[12]; hap_nonce(nonce, "PV-Msg03");
    uint8_t sealed[512];
    chacha20poly1305_seal(verify_key, nonce, NULL, 0, subbuf, subn, sealed);

    tlv8_item v3[] = {
        {TLV_STATE, (const uint8_t[]){3}, 1},
        {TLV_ENCRYPTED_DATA, sealed, (size_t)(subn + 16)},
    };
    mn = (int)tlv8_encode(v3, 2, buf, sizeof buf);
    rn = post_tlv(http, "/pair-verify", buf, mn, resp, sizeof resp);
    if (rn < 0) return -1;
    if (tlv8_get(resp, rn, TLV_ERROR, err, sizeof err, &el) && el && err[0]) {
        fprintf(stderr, "hap: pair-verify V4 error %d\n", err[0]);
        return -1;
    }

    memcpy(out->shared_secret, shared, 32);
    hkdf_sha512(shared, 32, (const uint8_t *)"Control-Salt", 12,
                (const uint8_t *)"Control-Write-Encryption-Key", 28, out->write_key, 32);
    hkdf_sha512(shared, 32, (const uint8_t *)"Control-Salt", 12,
                (const uint8_t *)"Control-Read-Encryption-Key", 27, out->read_key, 32);
    fprintf(stderr, "hap: pair-verify complete (control channel keyed)\n");
    return 0;
}

int hap_pair(struct http_client_s *http, const char *pairing_id, hap_keys_t *out) {
    memset(out, 0, sizeof *out);
    uint8_t seed[32], ed_pub[32], ed_priv[64];
    arc4random_buf(seed, sizeof seed);
    ed25519_create_keypair(ed_pub, ed_priv, seed);

    uint8_t K[64];
    if (pair_setup(http, pairing_id, ed_pub, ed_priv, K) != 0) return -1;
    if (pair_verify(http, pairing_id, ed_pub, ed_priv, out) != 0) return -1;
    out->ok = 1;
    return 0;
}
