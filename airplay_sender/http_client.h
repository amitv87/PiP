/**
 *  Copyright (C) 2011-2012  Juho Vähä-Herttua
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

#ifndef HTTP_CLIENT_H
#define HTTP_CLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct http_client_s http_client_t;

typedef struct http_client_response_s {
  int status_code;
  char *headers;
  char *body;
  int body_len;
} http_client_response_t;

http_client_t *http_client_init(const char *host, uint16_t port);
int http_client_connect(http_client_t *client);
http_client_response_t *http_client_request(http_client_t *client,
    const char *method, const char *path,
    const char *headers, const char *body, int body_len);

/* Enable HAP (HomeKit) control-channel encryption after pair-verify. From then
 * on every request/response on this client is ChaCha20-Poly1305 framed
 * ([2-byte LE length][ciphertext][16-byte tag], 1024-byte chunks, per-direction
 * LE64 nonce counter). write_key encrypts client->receiver; read_key decrypts
 * receiver->client. Matches airfry/doubletake and Apple's built-in sender. */
void http_client_enable_encryption(http_client_t *client,
    const uint8_t write_key[32], const uint8_t read_key[32]);

void http_client_disconnect(http_client_t *client);
void http_client_destroy(http_client_t *client);

void http_client_response_destroy(http_client_response_t *response);

/* Server info request helper */
typedef struct audio_format_s {
  uint64_t type;
  uint64_t audioInputFormats;
  uint64_t audioOutputFormats;
} audio_format_t;

typedef struct display_s {
  char *uuid;
  uint8_t widthPhysical;  /* bool stored as uint8_t */
  uint8_t heightPhysical;  /* bool stored as uint8_t */
  uint64_t width;
  uint64_t height;
  uint64_t widthPixels;
  uint64_t heightPixels;
  uint8_t rotation;  /* bool stored as uint8_t */
  uint64_t refreshRate;
  uint64_t maxFPS;
  uint8_t overscanned;  /* bool stored as uint8_t */
  uint64_t features;
} display_t;

typedef struct server_info_s {
  uint64_t features;
  char *sourceVersion;
  char *deviceID;
  audio_format_t *audioFormats;
  int audioFormatsCount;
  display_t *displays;
  int displaysCount;
} server_info_t;

server_info_t *http_client_get_info(http_client_t *client);
void server_info_destroy(server_info_t *info);

#ifdef __cplusplus
}
#endif

#endif
