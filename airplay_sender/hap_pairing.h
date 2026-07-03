/*
 * hap_pairing — AirPlay 2 HomeKit (HAP) transient pairing for the sender.
 *
 * Performs SRP-6a transient pair-setup (PIN-less, fixed PIN "3939") followed by
 * HAP pair-verify (ephemeral X25519). On success it yields the X25519 shared
 * secret (the IKM the media stream key derives from) and the ChaCha20-Poly1305
 * write/read keys for the encrypted RTSP control channel. Faithful port of
 * airfry's pairing.rs. Legacy (non-HAP) receivers keep using pairing_client.c.
 */
#ifndef HAP_PAIRING_H
#define HAP_PAIRING_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct http_client_s;

typedef struct {
    int ok;
    uint8_t shared_secret[32];  /* X25519 pair-verify shared secret */
    uint8_t write_key[32];      /* control-channel encrypt key (client->receiver) */
    uint8_t read_key[32];       /* control-channel decrypt key (receiver->client) */
} hap_keys_t;

/*
 * Run HAP transient pair-setup + pair-verify over the (plaintext) http_client.
 * pairing_id is a client UUID string. Returns 0 and fills out on success.
 */
int hap_pair(struct http_client_s *http, const char *pairing_id, hap_keys_t *out);

#ifdef __cplusplus
}
#endif

#endif /* HAP_PAIRING_H */
