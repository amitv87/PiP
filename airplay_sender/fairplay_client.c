/**
 *  Copyright (C) 2024  PiP Project
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 */

/*
 * Real FairPlay SAP handshake.
 *
 * The old implementation faked m3 by echoing the receiver's m2 and wrapped the
 * ekey by running the receiver's playfair backwards against a fabricated
 * message3, so it only interoperated with PiP's own receiver. This version runs
 * Apple's real FairPlay code (fpemu) to compute a valid m3 for any receiver's
 * challenge, then derives the stream AES key exactly the way the receiver does
 * — playfair_decrypt(real_m3, random_ekey) — so the two sides agree. This
 * mirrors doubletake/airfry's proven flow.
 */

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>

#include "fairplay_client.h"
#include "http_client.h"
#include "../airplay/playfair/playfair.h"
#include "fpemu/fpemu.h"

typedef enum {
  FAIRPLAY_STATE_INIT,
  FAIRPLAY_STATE_SETUP_DONE,
  FAIRPLAY_STATE_HANDSHAKE_DONE
} fairplay_state_t;

#define FAIRPLAY_EKEY_SIZE 72
#define FAIRPLAY_AES_KEY_SIZE 16

struct fairplay_client_s {
  fairplay_state_t state;
  unsigned char m2[FAIRPLAY_SETUP_RESPONSE_SIZE];  /* 142: receiver's challenge */
  unsigned char m3[FAIRPLAY_HANDSHAKE_SIZE];       /* 164: our computed response */
  unsigned char ekey[FAIRPLAY_EKEY_SIZE];          /* 72: random, sent in SETUP */
  unsigned char aes_key[FAIRPLAY_AES_KEY_SIZE];    /* 16: derived from (m3, ekey) */
};

/* The fixed FairPlay m1 that matches the interpreter snapshot state.
 * Identical to doubletake/airfry's fairPlayM1. */
static const unsigned char fairplay_m1[FAIRPLAY_CHALLENGE_SIZE] = {
  0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x01, 0x00,
  0x00, 0x00, 0x00, 0x04, 0x02, 0x00, 0x03, 0xbb
};

#define FP_HEADERS "Content-Type: application/octet-stream\r\nX-Apple-ET: 32\r\n"

fairplay_client_t *
fairplay_client_init(void)
{
  fairplay_client_t *client = calloc(1, sizeof(fairplay_client_t));
  if (!client) {
    return NULL;
  }
  client->state = FAIRPLAY_STATE_INIT;
  return client;
}

int
fairplay_client_setup(fairplay_client_t *client, http_client_t *http_client)
{
  http_client_response_t *response;

  assert(client);
  assert(http_client);

  if (client->state != FAIRPLAY_STATE_INIT) {
    return -1;
  }

  /* Phase 1: POST m1, receive m2 (142-byte FPLY blob). */
  response = http_client_request(http_client, "POST", "/fp-setup", FP_HEADERS,
                                 (const char *)fairplay_m1,
                                 FAIRPLAY_CHALLENGE_SIZE);

  if (!response || response->status_code != 200) {
    fprintf(stderr, "fairplay_client: fp-setup m1 failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) {
      http_client_response_destroy(response);
    }
    return -1;
  }

  if (!response->body || response->body_len != FAIRPLAY_SETUP_RESPONSE_SIZE) {
    fprintf(stderr, "fairplay_client: invalid m2 (len=%d, want %d)\n",
            response ? response->body_len : -1, FAIRPLAY_SETUP_RESPONSE_SIZE);
    http_client_response_destroy(response);
    return -1;
  }

  memcpy(client->m2, response->body, FAIRPLAY_SETUP_RESPONSE_SIZE);
  client->state = FAIRPLAY_STATE_SETUP_DONE;

  http_client_response_destroy(response);
  return 0;
}

int
fairplay_client_handshake(fairplay_client_t *client, http_client_t *http_client)
{
  http_client_response_t *response;

  assert(client);
  assert(http_client);

  if (client->state != FAIRPLAY_STATE_SETUP_DONE) {
    return -1;
  }

  /* Phase 2: compute m3 from the receiver's m2 by running Apple's real
   * FairPlay code, then POST it. */
  if (fpsap_exchange_m3(client->m2, FAIRPLAY_SETUP_RESPONSE_SIZE, client->m3) != 0) {
    fprintf(stderr, "fairplay_client: fpsap_exchange_m3 failed\n");
    return -1;
  }

  response = http_client_request(http_client, "POST", "/fp-setup", FP_HEADERS,
                                 (const char *)client->m3,
                                 FAIRPLAY_HANDSHAKE_SIZE);

  if (!response || response->status_code != 200) {
    fprintf(stderr, "fairplay_client: fp-setup m3 failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) {
      http_client_response_destroy(response);
    }
    return -1;
  }
  /* m4 is acknowledgement only; its contents are not needed. */
  http_client_response_destroy(response);

  /* Build a random 72-byte ekey (FPLY-framed) and derive the stream AES key
   * the same way the receiver will: playfair_decrypt(m3, ekey). Both sides
   * compute the identical key from the same (m3, ekey) inputs. */
  memset(client->ekey, 0, FAIRPLAY_EKEY_SIZE);
  memcpy(client->ekey, "FPLY", 4);
  client->ekey[4] = 0x01;
  client->ekey[5] = 0x02;
  client->ekey[6] = 0x01;
  client->ekey[7] = 0x00;
  client->ekey[11] = 0x3c; /* 60 = remaining bytes */
  arc4random_buf(&client->ekey[16], 16); /* chunk1 */
  arc4random_buf(&client->ekey[56], 16); /* chunk2 */

  playfair_decrypt(client->m3, client->ekey, client->aes_key);

  client->state = FAIRPLAY_STATE_HANDSHAKE_DONE;
  return 0;
}

int
fairplay_client_get_session_key(fairplay_client_t *client,
                                unsigned char key[FAIRPLAY_SESSION_KEY_SIZE])
{
  assert(client);

  if (client->state != FAIRPLAY_STATE_HANDSHAKE_DONE) {
    return -1;
  }

  /* The FairPlay-derived key is 16 bytes; callers hash the first 16 bytes with
   * the pair-verify ECDH secret. Zero-pad the rest for API compatibility. */
  memcpy(key, client->aes_key, FAIRPLAY_AES_KEY_SIZE);
  memset(key + FAIRPLAY_AES_KEY_SIZE, 0,
         FAIRPLAY_SESSION_KEY_SIZE - FAIRPLAY_AES_KEY_SIZE);
  return 0;
}

int
fairplay_client_encrypt_key(fairplay_client_t *client,
                            const unsigned char key_in[16],
                            unsigned char ekey_out[72])
{
  assert(client);
  assert(ekey_out);

  /* key_in is ignored: the ekey is the random blob generated during the
   * handshake, from which aes_key was already derived. It is kept in the
   * signature for source compatibility with the previous API. */
  (void)key_in;

  if (client->state != FAIRPLAY_STATE_HANDSHAKE_DONE) {
    fprintf(stderr, "fairplay_client: cannot get ekey - handshake not done\n");
    return -1;
  }

  memcpy(ekey_out, client->ekey, FAIRPLAY_EKEY_SIZE);
  return 0;
}

void
fairplay_client_destroy(fairplay_client_t *client)
{
  if (client) {
    memset(client->aes_key, 0, sizeof(client->aes_key));
    free(client);
  }
}
