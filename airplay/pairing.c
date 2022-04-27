/**
 *  Copyright (C) 2018  Juho Vähä-Herttua
 *  Copyright (C) 2020  Jaslo Ziska
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

#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "pairing.h"

#define SALT_KEY "Pair-Verify-AES-Key"
#define SALT_IV "Pair-Verify-AES-IV"

struct pairing_s {
    unsigned char ed_private[PAIRING_SIG_SIZE];
    unsigned char ed_public[ED25519_KEY_SIZE];
};

typedef enum {
    STATUS_INITIAL,
    STATUS_SETUP,
    STATUS_HANDSHAKE,
    STATUS_FINISHED
} status_t;

struct pairing_session_s {
    status_t status;

    unsigned char ed_private[PAIRING_SIG_SIZE];
    unsigned char ed_ours[ED25519_KEY_SIZE];
    unsigned char ed_theirs[ED25519_KEY_SIZE];

    unsigned char ecdh_ours[X25519_KEY_SIZE];
    unsigned char ecdh_theirs[X25519_KEY_SIZE];
    unsigned char ecdh_secret[X25519_KEY_SIZE];
};

static int
derive_key_internal(pairing_session_t *session, const unsigned char *salt, unsigned int saltlen, unsigned char *key, unsigned int keylen)
{
    unsigned char hash[SHA512_DIGEST_LENGTH];

    if (keylen > sizeof(hash)) {
        return -1;
    }

    sha512_context ctx;
    sha512_init(&ctx);
    sha512_update(&ctx, salt, saltlen);
    sha512_update(&ctx, session->ecdh_secret, X25519_KEY_SIZE);
    sha512_final(&ctx, hash);

    memcpy(key, hash, keylen);
    return 0;
}

pairing_t *
pairing_init_generate()
{
    unsigned char seed[ED25519_KEY_SIZE];
    if (ed25519_create_seed(seed)) {
        return NULL;
    }

    pairing_t *pairing;

    pairing = calloc(1, sizeof(pairing_t));
    if (!pairing) {
        return NULL;
    }

    ed25519_create_keypair(pairing->ed_public, pairing->ed_private, seed);

    return pairing;
}

void
pairing_get_public_key(pairing_t *pairing, unsigned char public_key[ED25519_KEY_SIZE])
{
    assert(pairing);
    memcpy(public_key, pairing->ed_public, ED25519_KEY_SIZE);
}

void
pairing_get_ecdh_secret_key(pairing_session_t *session, unsigned char ecdh_secret[X25519_KEY_SIZE])
{
    assert(session);
    memcpy(ecdh_secret, session->ecdh_secret, X25519_KEY_SIZE);
}


pairing_session_t *
pairing_session_init(pairing_t *pairing)
{
    pairing_session_t *session;

    if (!pairing) {
        return NULL;
    }

    session = calloc(1, sizeof(pairing_session_t));
    if (!session) {
        return NULL;
    }

    memcpy(session->ed_private, pairing->ed_private, PAIRING_SIG_SIZE);
    memcpy(session->ed_ours, pairing->ed_public, ED25519_KEY_SIZE);

    session->status = STATUS_INITIAL;

    return session;
}

void
pairing_session_set_setup_status(pairing_session_t *session)
{
    assert(session);
    session->status = STATUS_SETUP;
}

int
pairing_session_check_handshake_status(pairing_session_t *session)
{
    assert(session);
    switch (session->status) {
    case STATUS_SETUP:
    case STATUS_HANDSHAKE:
        return 0;
    default:
        return -1;
    }
}

int
pairing_session_handshake(pairing_session_t *session, const unsigned char ecdh_key[X25519_KEY_SIZE],
                          const unsigned char ed_key[ED25519_KEY_SIZE])
{
    assert(session);

    if (session->status == STATUS_FINISHED) {
        return -1;
    }

    unsigned char ecdh_priv[X25519_KEY_SIZE];

    if (ed25519_create_seed(ecdh_priv)) {
        return -2;
    }

    memcpy(session->ecdh_theirs, ecdh_key, X25519_KEY_SIZE);
    memcpy(session->ed_theirs, ed_key, ED25519_KEY_SIZE);
    curve25519_donna(session->ecdh_ours, ecdh_priv, kCurve25519BasePoint);
    curve25519_donna(session->ecdh_secret, ecdh_priv, session->ecdh_theirs);

    session->status = STATUS_HANDSHAKE;
    return 0;
}

int
pairing_session_get_public_key(pairing_session_t *session, unsigned char ecdh_key[X25519_KEY_SIZE])
{
    assert(session);

    if (session->status != STATUS_HANDSHAKE) {
        return -1;
    }

    memcpy(ecdh_key, session->ecdh_ours, X25519_KEY_SIZE);

    return 0;
}

int
pairing_session_get_signature(pairing_session_t *session, unsigned char signature[PAIRING_SIG_SIZE])
{
    unsigned char sig_msg[PAIRING_SIG_SIZE];
    unsigned char key[AES_128_BLOCK_SIZE];
    unsigned char iv[AES_128_BLOCK_SIZE];
    AES_CTR_CTX aes_ctx;

    assert(session);

    if (session->status != STATUS_HANDSHAKE) {
        return -1;
    }

    /* First sign the public ECDH keys of both parties */
    memcpy(sig_msg, session->ecdh_ours, X25519_KEY_SIZE);
    memcpy(sig_msg + X25519_KEY_SIZE, session->ecdh_theirs, X25519_KEY_SIZE);

    ed25519_sign(signature, sig_msg, PAIRING_SIG_SIZE, session->ed_ours, session->ed_private);

    /* Then encrypt the result with keys derived from the shared secret */
    derive_key_internal(session, (const unsigned char *) SALT_KEY, strlen(SALT_KEY), key, sizeof(key));
    derive_key_internal(session, (const unsigned char *) SALT_IV, strlen(SALT_IV), iv, sizeof(iv));

    AES_ctr_set_key(&aes_ctx, key, iv, AES_MODE_128);
    AES_ctr_encrypt(&aes_ctx, signature, signature, PAIRING_SIG_SIZE);

    return 0;
}

int
pairing_session_finish(pairing_session_t *session, const unsigned char signature[PAIRING_SIG_SIZE])
{
    unsigned char sig_buffer[PAIRING_SIG_SIZE];
    unsigned char sig_msg[PAIRING_SIG_SIZE];
    unsigned char key[AES_128_BLOCK_SIZE];
    unsigned char iv[AES_128_BLOCK_SIZE];
    AES_CTR_CTX aes_ctx;

    assert(session);

    if (session->status != STATUS_HANDSHAKE) {
        return -1;
    }

    /* First decrypt the signature with keys derived from the shared secret */
    derive_key_internal(session, (const unsigned char *) SALT_KEY, strlen(SALT_KEY), key, sizeof(key));
    derive_key_internal(session, (const unsigned char *) SALT_IV, strlen(SALT_IV), iv, sizeof(iv));

    AES_ctr_set_key(&aes_ctx, key, iv, AES_MODE_128);
    /* One fake round for the initial handshake encryption */
    AES_ctr_encrypt(&aes_ctx, sig_buffer, sig_buffer, PAIRING_SIG_SIZE);
    AES_ctr_encrypt(&aes_ctx, signature, sig_buffer, PAIRING_SIG_SIZE);

    /* Then verify the signature with public ECDH keys of both parties */
    memcpy(sig_msg, session->ecdh_theirs, X25519_KEY_SIZE);
    memcpy(sig_msg + X25519_KEY_SIZE, session->ecdh_ours, X25519_KEY_SIZE);
    if (!ed25519_verify(sig_buffer, sig_msg, sizeof(sig_msg), session->ed_theirs)) {
        return -2;
    }

    session->status = STATUS_FINISHED;
    return 0;
}

void
pairing_session_destroy(pairing_session_t *session)
{
    if (session) {
        free(session);
    }
}

void
pairing_destroy(pairing_t *pairing)
{
    if (pairing) {
        free(pairing);
    }
}
