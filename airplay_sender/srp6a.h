/*
 *  SRP-6a client (3072-bit RFC 5054 group, SHA-512) for AirPlay 2 HomeKit-style
 *  pair-setup. Username is always "Pair-Setup"; the password is the PIN, or ""
 *  for transient (PIN-less) pairing.
 *
 *  Built on the vendored axTLS bigint (airplay/crypto).
 */
#ifndef SRP6A_H
#define SRP6A_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SRP6A_MODULUS_LEN 384 /* 3072 bits */

typedef struct {
  uint8_t A_pad[SRP6A_MODULUS_LEN];       /* client public A, left-zero-padded (for TLV PublicKey) */
  uint8_t A_min[SRP6A_MODULUS_LEN];       /* client public A, natural/minimal big-endian (for proofs) */
  size_t  A_min_len;
  uint8_t K[64];                          /* session key K = SHA-512(S) */
  uint8_t M1[64];                         /* client proof */
} srp6a_client_t;

/*
 * Run the client half of SRP-6a. a_priv is 32 random bytes (the client secret
 * exponent). salt and serverB come from the server's pair-setup M2. Returns 0
 * on success, -1 on invalid server public key.
 */
int srp6a_client_compute(const uint8_t *salt, size_t salt_len,
                         const char *password,
                         const uint8_t *serverB, size_t serverB_len,
                         const uint8_t a_priv[32],
                         srp6a_client_t *out);

/*
 * Verify the server proof M2 from pair-setup M4: expected = SHA-512(A || M1 || K),
 * with A in natural (minimal) representation. Returns 1 if valid, 0 otherwise.
 */
int srp6a_verify_server_proof(const srp6a_client_t *c,
                              const uint8_t *server_proof, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* SRP6A_H */
