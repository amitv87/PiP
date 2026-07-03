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

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#include <time.h>
#include <inttypes.h>
#include <errno.h>

#include "../airplay/plist/plist/plist.h"
#include "../airplay/compat.h"
#include "../airplay/sockets.h"
#include "../airplay/aes_ctr.h"
#include "../airplay/ed25519/sha512.h"
#include "../airplay/byteutils.h"
#include "../airplay/raop_rtp.h"
#include "stream_client.h"
#include "http_client.h"

struct stream_client_s {
  stream_info_t info;
  int setup_done;
  int video_socket_fd;
  int feedback_socket_fd;
  AES_CTR_CTX aes_ctx;
  int encryption_initialized;
};

static uint64_t
generate_random_uint64(void)
{
  uint64_t result = 0;
  uint32_t *parts = (uint32_t *)&result;

  // Generate random 64-bit value
  parts[0] = (uint32_t)rand();
  parts[1] = (uint32_t)rand();

  return result;
}

static void
generate_uuid(char *uuid, size_t uuid_size)
{
  // Generate a simple UUID-like string
  // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  uint32_t parts[4];
  parts[0] = (uint32_t)rand();
  parts[1] = (uint32_t)rand();
  parts[2] = (uint32_t)rand();
  parts[3] = (uint32_t)rand();

  snprintf(uuid, uuid_size, "%08x-%04x-%04x-%04x-%08x%04x",
           parts[0],
           (parts[1] >> 16) & 0xffff,
           parts[1] & 0xffff,
           (parts[2] >> 16) & 0xffff,
           parts[2] & 0xffff,
           parts[3] & 0xffff);
}

static int
connect_to_host_port(const char *host, uint16_t port)
{
  struct addrinfo hints, *result, *rp;
  int sockfd = -1;
  char port_str[6];
  int ret;
  struct timeval timeout;
  fd_set write_fds;
  int error;
  socklen_t error_len;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  snprintf(port_str, sizeof(port_str), "%u", port);

  if (getaddrinfo(host, port_str, &hints, &result) != 0) {
    return -1;
  }

  for (rp = result; rp != NULL; rp = rp->ai_next) {
    sockfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (sockfd == -1) {
      continue;
    }

    ret = connect(sockfd, rp->ai_addr, rp->ai_addrlen);
    if (ret == 0) {
      freeaddrinfo(result);
      return sockfd;
    }

    closesocket(sockfd);
    sockfd = -1;
  }

  freeaddrinfo(result);
  return -1;
}

stream_client_t *
stream_client_init(void)
{
  stream_client_t *client;

  client = calloc(1, sizeof(stream_client_t));
  if (!client) {
    return NULL;
  }

  client->setup_done = 0;
  client->info.data_port = 0;
  client->info.control_port = 0;
  client->info.event_port = 0;
  client->info.timing_port = 0;
  client->info.stream_connection_id = 0;
  client->video_socket_fd = -1;
  client->feedback_socket_fd = -1;
  client->encryption_initialized = 0;

  // Seed random number generator
  srand((unsigned int)time(NULL));

  return client;
}

int
stream_client_setup(stream_client_t *client, http_client_t *http_client,
                   const char *device_id, const char *os_name,
                   const char *os_version, const char *model)
{
  http_client_response_t *response;
  plist_t root_node;
  plist_t streams_node;
  plist_t stream_node;
  plist_t timestamp_info_node;
  plist_t timestamp_node;
  char session_uuid[37];
  uint64_t stream_connection_id;
  char *plist_data = NULL;
  uint32_t plist_len = 0;
  int ret = -1;

  assert(client);
  assert(http_client);
  assert(device_id);
  assert(os_name);
  assert(os_version);
  assert(model);

  // Generate stream connection ID (8 bytes = 64 bits)
  stream_connection_id = generate_random_uint64();
  client->info.stream_connection_id = stream_connection_id;

  // Generate session UUID
  generate_uuid(session_uuid, sizeof(session_uuid));

  // Build binary plist request
  root_node = plist_new_dict();
  if (!root_node) {
    return -1;
  }

  // Create streams array
  streams_node = plist_new_array();
  stream_node = plist_new_dict();

  // Stream type: 110 = Screen mirroring
  plist_t type_node = plist_new_uint(110);
  plist_dict_set_item(stream_node, "type", type_node);

  // Stream connection ID
  plist_t stream_id_node = plist_new_uint(stream_connection_id);
  plist_dict_set_item(stream_node, "streamConnectionID", stream_id_node);

  // Timestamp info
  timestamp_info_node = plist_new_array();
  timestamp_node = plist_new_dict();
  plist_t name_node = plist_new_string("local");
  plist_t rate_node = plist_new_uint(1000000);
  plist_dict_set_item(timestamp_node, "name", name_node);
  plist_dict_set_item(timestamp_node, "rate", rate_node);
  plist_array_append_item(timestamp_info_node, timestamp_node);
  plist_dict_set_item(stream_node, "timestampInfo", timestamp_info_node);

  plist_array_append_item(streams_node, stream_node);
  plist_dict_set_item(root_node, "streams", streams_node);

  // Device ID
  plist_t device_id_node = plist_new_string(device_id);
  plist_dict_set_item(root_node, "deviceID", device_id_node);

  // Session UUID
  plist_t session_uuid_node = plist_new_string(session_uuid);
  plist_dict_set_item(root_node, "sessionUUID", session_uuid_node);

  // OS name
  plist_t os_name_node = plist_new_string(os_name);
  plist_dict_set_item(root_node, "osName", os_name_node);

  // OS version
  plist_t os_version_node = plist_new_string(os_version);
  plist_dict_set_item(root_node, "osVersion", os_version_node);

  // Model
  plist_t model_node = plist_new_string(model);
  plist_dict_set_item(root_node, "model", model_node);

  // Convert to binary plist
  plist_to_bin(root_node, &plist_data, &plist_len);
  plist_free(root_node);

  if (!plist_data || plist_len == 0) {
    return -1;
  }

  // Send POST /stream request
  response = http_client_request(http_client, "POST", "/stream",
                                 "Content-Type: application/x-apple-binary-plist\r\n",
                                 plist_data, (int)plist_len);

  free(plist_data);

  if (!response || response->status_code != 200) {
    fprintf(stderr, "stream_client: stream setup failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) {
      http_client_response_destroy(response);
    }
    return -1;
  }

  if (!response->body || response->body_len == 0) {
    fprintf(stderr, "stream_client: empty response body\n");
    http_client_response_destroy(response);
    return -1;
  }

  // Parse response plist
  plist_t res_root_node = NULL;
  plist_from_bin(response->body, response->body_len, &res_root_node);
  http_client_response_destroy(response);

  if (!res_root_node) {
    fprintf(stderr, "stream_client: failed to parse response plist\n");
    return -1;
  }

  // Parse eventPort
  plist_t event_port_node = plist_dict_get_item(res_root_node, "eventPort");
  if (event_port_node && plist_get_node_type(event_port_node) == PLIST_UINT) {
    uint64_t val;
    plist_get_uint_val(event_port_node, &val);
    client->info.event_port = (uint16_t)val;
  }

  // Parse timingPort
  plist_t timing_port_node = plist_dict_get_item(res_root_node, "timingPort");
  if (timing_port_node && plist_get_node_type(timing_port_node) == PLIST_UINT) {
    uint64_t val;
    plist_get_uint_val(timing_port_node, &val);
    client->info.timing_port = (uint16_t)val;
  }

  // Parse streams array
  plist_t res_streams_node = plist_dict_get_item(res_root_node, "streams");
  if (res_streams_node && PLIST_IS_ARRAY(res_streams_node)) {
    uint32_t count = plist_array_get_size(res_streams_node);
    if (count > 0) {
      plist_t res_stream_node = plist_array_get_item(res_streams_node, 0);
      if (res_stream_node && PLIST_IS_DICT(res_stream_node)) {
        // Parse dataPort
        plist_t data_port_node = plist_dict_get_item(res_stream_node, "dataPort");
        if (data_port_node && plist_get_node_type(data_port_node) == PLIST_UINT) {
          uint64_t val;
          plist_get_uint_val(data_port_node, &val);
          client->info.data_port = (uint16_t)val;
        }

        // Parse controlPort (if present)
        plist_t control_port_node = plist_dict_get_item(res_stream_node, "controlPort");
        if (control_port_node && plist_get_node_type(control_port_node) == PLIST_UINT) {
          uint64_t val;
          plist_get_uint_val(control_port_node, &val);
          client->info.control_port = (uint16_t)val;
        }
      }
    }
  }

  plist_free(res_root_node);

  if (client->info.data_port == 0) {
    fprintf(stderr, "stream_client: no dataPort in response\n");
    return -1;
  }

  client->setup_done = 1;
  return 0;
}

int
stream_client_get_info(stream_client_t *client, stream_info_t *info)
{
  assert(client);
  assert(info);

  if (!client->setup_done) {
    return -1;
  }

  memcpy(info, &client->info, sizeof(stream_info_t));
  return 0;
}

int
stream_client_connect_video(stream_client_t *client, const char *host)
{
  assert(client);
  assert(host);

  if (!client->setup_done || client->info.data_port == 0) {
    return -1;
  }

  if (client->video_socket_fd != -1) {
    // Already connected
    return 0;
  }

  client->video_socket_fd = connect_to_host_port(host, client->info.data_port);
  if (client->video_socket_fd == -1) {
    fprintf(stderr, "stream_client: failed to connect video stream to %s:%u\n",
            host, client->info.data_port);
    return -1;
  }

  fprintf(stderr, "stream_client: video socket connected to %s:%u (fd=%d)\n",
          host, client->info.data_port, client->video_socket_fd);

  // Set TCP keepalive options
  int option = 1;
  setsockopt(client->video_socket_fd, SOL_SOCKET, SO_KEEPALIVE, &option, sizeof(option));

  return 0;
}

int
stream_client_init_video_encryption(stream_client_t *client,
                                    const unsigned char *audio_aes_key)
{
  unsigned char aeskey_video[64];
  unsigned char aesiv_video[64];
  char key_str[64];
  char iv_str[64];

  assert(client);
  assert(audio_aes_key);

  if (client->info.stream_connection_id == 0) {
    return -1;
  }

  // Derive video AES key: SHA512("AirPlayStreamKey" + streamConnectionID + audio_aes_key)
  snprintf(key_str, sizeof(key_str), "AirPlayStreamKey%" PRIu64,
           client->info.stream_connection_id);

  sha512_context ctx;
  sha512_init(&ctx);
  sha512_update(&ctx, (const unsigned char *)key_str, strlen(key_str));
  sha512_update(&ctx, audio_aes_key, RAOP_AESKEY_LEN);
  sha512_final(&ctx, aeskey_video);

  // Derive video AES IV: SHA512("AirPlayStreamIV" + streamConnectionID + audio_aes_key)
  snprintf(iv_str, sizeof(iv_str), "AirPlayStreamIV%" PRIu64,
           client->info.stream_connection_id);

  sha512_init(&ctx);
  sha512_update(&ctx, (const unsigned char *)iv_str, strlen(iv_str));
  sha512_update(&ctx, audio_aes_key, RAOP_AESKEY_LEN);
  sha512_final(&ctx, aesiv_video);

  // Initialize AES-CTR with 16-byte key and IV
  AES_ctr_set_key(&client->aes_ctx, aeskey_video, aesiv_video, AES_MODE_128);
  client->encryption_initialized = 1;

  return 0;
}

int
stream_client_send_video_packet(stream_client_t *client,
                                uint8_t packet_type,
                                const uint8_t *data, int data_len,
                                uint64_t ntp_timestamp)
{
  unsigned char header[128];
  unsigned char *encrypted_data = NULL;
  int sent;
  int ret;

  assert(client);
  assert(data);
  assert(data_len > 0);

  if (client->video_socket_fd == -1) {
    return -1;
  }

  // Build 128-byte header
  memset(header, 0, sizeof(header));

  // Bytes 0-3: Payload size (big-endian)
  // Receiver expects little-endian payload size (byteutils_get_int reads little-endian)
  uint32_t payload_size_le = (uint32_t)data_len;
  memcpy(header, &payload_size_le, 4);

  // Byte 4: Packet type
  header[4] = packet_type;

  // Bytes 5-7: Flags (usually 0x00 or 0x10 for encrypted packets)
  if (packet_type == 0x00) {
    header[5] = 0x10;  // Encrypted video packet
    header[6] = 0x00;
    header[7] = 0x00;
  } else if (packet_type == 0x01) {
    // SPS/PPS packet
    header[5] = 0x00;
    header[6] = 0x01;
    header[7] = 0x16;
  } else if (packet_type == 0x05) {
    // Streaming report
    header[5] = 0x00;
    header[6] = 0x00;
    header[7] = 0x00;
  }

  // Bytes 8-15: NTP timestamp (big-endian, only for type 0x00 and 0x01)
  if (packet_type == 0x00 || packet_type == 0x01) {
    byteutils_put_ntp_timestamp(header, 8, ntp_timestamp);
  }

  // Encrypt data if needed (type 0x00)
  if (packet_type == 0x00 && client->encryption_initialized) {
    encrypted_data = malloc(data_len);
    if (!encrypted_data) {
      return -1;
    }
    AES_ctr_encrypt(&client->aes_ctx, data, encrypted_data, data_len);
    data = encrypted_data;
  }

  // Send header
  sent = 0;
  while (sent < 128) {
    ret = send(client->video_socket_fd, header + sent, 128 - sent, 0);
    if (ret == -1) {
      fprintf(stderr, "stream_client: failed to send video header\n");
      if (encrypted_data) {
        free(encrypted_data);
      }
      return -1;
    }
    sent += ret;
  }

  // Send payload
  sent = 0;
  while (sent < data_len) {
    ret = send(client->video_socket_fd, data + sent, data_len - sent, 0);
    if (ret == -1) {
      fprintf(stderr, "stream_client: failed to send video payload\n");
      if (encrypted_data) {
        free(encrypted_data);
      }
      return -1;
    }
    sent += ret;
  }

  if (encrypted_data) {
    free(encrypted_data);
  }

  return 0;
}

int
stream_client_send_raw_video_packet(stream_client_t *client,
                                    const uint8_t *packet, int packet_len)
{
  int sent;
  int ret;
  static int send_count = 0;

  assert(client);
  assert(packet);
  assert(packet_len > 0);

  if (client->video_socket_fd == -1) {
    if (send_count == 0 || send_count % 30 == 0) {
      fprintf(stderr, "stream_client: video socket not connected (fd=-1)\n");
    }
    return -1;
  }

  // Send complete packet (header + payload) directly
  sent = 0;
  while (sent < packet_len) {
    ret = send(client->video_socket_fd, packet + sent, packet_len - sent, 0);
    if (ret == -1) {
      fprintf(stderr, "stream_client: failed to send raw video packet: %s\n", strerror(errno));
      return -1;
    }
    sent += ret;
  }

  if (send_count == 0 || send_count % 30 == 0) {
    fprintf(stderr, "stream_client: sent raw video packet %d, len=%d, bytes_sent=%d\n",
            send_count, packet_len, sent);
  }

  send_count++;
  return 0;
}

int
stream_client_connect_feedback(stream_client_t *client, const char *host)
{
  assert(client);
  assert(host);

  if (!client->setup_done || client->info.event_port == 0) {
    return -1;
  }

  if (client->feedback_socket_fd != -1) {
    // Already connected
    return 0;
  }

  client->feedback_socket_fd = connect_to_host_port(host, client->info.event_port);
  if (client->feedback_socket_fd == -1) {
    fprintf(stderr, "stream_client: failed to connect feedback to %s:%u\n",
            host, client->info.event_port);
    return -1;
  }

  return 0;
}

void
stream_client_disconnect_video(stream_client_t *client)
{
  assert(client);

  if (client->video_socket_fd != -1) {
    closesocket(client->video_socket_fd);
    client->video_socket_fd = -1;
  }
  client->encryption_initialized = 0;
}

void
stream_client_disconnect_feedback(stream_client_t *client)
{
  assert(client);

  if (client->feedback_socket_fd != -1) {
    closesocket(client->feedback_socket_fd);
    client->feedback_socket_fd = -1;
  }
}

int
stream_client_get_info_rtsp(stream_client_t *client, struct http_client_s *http_client)
{
  http_client_response_t *response;

  assert(client);
  assert(http_client);

  // Send GET /info RTSP/1.0 request
  // Note: HTTP client will handle RTSP/1.0 in the response
  // Note: User-Agent is automatically added by http_client_request
  response = http_client_request(http_client, "GET", "/info",
                                 NULL,
                                 NULL, 0);

  if (!response || response->status_code != 200) {
    fprintf(stderr, "stream_client: GET /info RTSP failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) {
      http_client_response_destroy(response);
    }
    return -1;
  }

  http_client_response_destroy(response);
  return 0;
}

int
stream_client_setup_rtsp(stream_client_t *client, struct http_client_s *http_client,
                         const char *host, uint16_t port,
                         const unsigned char *ekey, const unsigned char *eiv,
                         uint16_t timing_port, const char *session_uuid,
                         const unsigned char *shk, const unsigned char *shiv,
                         const char *device_id, const char *os_name,
                         const char *os_version, const char *model, const char *name);

int
stream_client_setup_audio_rtsp(stream_client_t *client, struct http_client_s *http_client,
                               const char *host, uint16_t port,
                               const unsigned char *ekey, const unsigned char *eiv,
                               uint16_t timing_port, const char *session_uuid,
                               uint16_t audio_control_port,
                               const char *device_id, const char *model, const char *name)
{
  http_client_response_t *response;
  plist_t root_node;
  char *plist_data = NULL;
  uint32_t plist_len = 0;
  char setup_url[256];

  assert(client);
  assert(http_client);
  assert(host);
  assert(device_id);

  uint64_t audio_scid = generate_random_uint64();

  root_node = plist_new_dict();
  plist_dict_set_item(root_node, "deviceID", plist_new_string(device_id));
  plist_dict_set_item(root_node, "macAddress", plist_new_string(device_id));
  if (session_uuid) {
    plist_dict_set_item(root_node, "sessionUUID", plist_new_string(session_uuid));
  }
  plist_dict_set_item(root_node, "sourceVersion", plist_new_string("280.33"));
  plist_dict_set_item(root_node, "osBuildVersion", plist_new_string("20G165"));
  plist_dict_set_item(root_node, "model", plist_new_string(model));
  plist_dict_set_item(root_node, "name", plist_new_string(name ? name : model));
  plist_dict_set_item(root_node, "timingProtocol", plist_new_string("NTP"));
  plist_dict_set_item(root_node, "timingPort", plist_new_uint(timing_port));
  if (ekey && eiv) {
    plist_dict_set_item(root_node, "et", plist_new_uint(32));
    plist_dict_set_item(root_node, "ekey", plist_new_data((const char *)ekey, 72));
    plist_dict_set_item(root_node, "eiv", plist_new_data((const char *)eiv, 16));
  }

  // Audio stream descriptor (type 96, ALAC) — values from doubletake.
  plist_t streams_node = plist_new_array();
  plist_t sd = plist_new_dict();
  plist_dict_set_item(sd, "type", plist_new_uint(96));
  plist_dict_set_item(sd, "streamConnectionID", plist_new_uint(audio_scid));
  plist_dict_set_item(sd, "ct", plist_new_uint(2));            // ALAC
  plist_dict_set_item(sd, "spf", plist_new_uint(352));
  plist_dict_set_item(sd, "sr", plist_new_uint(44100));
  plist_dict_set_item(sd, "audioFormat", plist_new_uint(0x40000));
  plist_dict_set_item(sd, "audioFormatIndex", plist_new_uint(0x12));
  plist_dict_set_item(sd, "controlPort", plist_new_uint(audio_control_port));
  plist_dict_set_item(sd, "audioMode", plist_new_string("default"));
  plist_dict_set_item(sd, "usingScreen", plist_new_bool(1));
  plist_dict_set_item(sd, "latencyMin", plist_new_uint(4410));
  plist_dict_set_item(sd, "latencyMax", plist_new_uint(4410));
  plist_dict_set_item(sd, "redundantAudio", plist_new_uint(0));
  plist_dict_set_item(sd, "disableRetransmits", plist_new_bool(1));
  plist_array_append_item(streams_node, sd);
  plist_dict_set_item(root_node, "streams", streams_node);

  plist_to_bin(root_node, &plist_data, &plist_len);
  plist_free(root_node);
  if (!plist_data || plist_len == 0) {
    return -1;
  }

  snprintf(setup_url, sizeof(setup_url), "rtsp://%s:%u/%" PRIu64, host, port, audio_scid);

  char headers[256];
  snprintf(headers, sizeof(headers),
           "Content-Type: application/x-apple-binary-plist\r\n");

  response = http_client_request(http_client, "SETUP", setup_url, headers,
                                 plist_data, (int)plist_len);
  free(plist_data);

  if (!response || response->status_code != 200) {
    fprintf(stderr, "stream_client: audio SETUP (type 96) failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) http_client_response_destroy(response);
    return -1;
  }

  // Parse eventPort if present (the video SETUP also returns one).
  if (response->body && response->body_len > 0) {
    plist_t res = NULL;
    plist_from_bin(response->body, response->body_len, &res);
    if (res) {
      plist_t ep = plist_dict_get_item(res, "eventPort");
      if (ep && plist_get_node_type(ep) == PLIST_UINT) {
        uint64_t v;
        plist_get_uint_val(ep, &v);
        client->info.event_port = (uint16_t)v;
      }
      plist_free(res);
    }
  }
  fprintf(stderr, "stream_client: audio SETUP (type 96) ok, eventPort=%u\n",
          client->info.event_port);
  http_client_response_destroy(response);
  return 0;
}

int
stream_client_setup_rtsp(stream_client_t *client, struct http_client_s *http_client,
                         const char *host, uint16_t port,
                         const unsigned char *ekey, const unsigned char *eiv,
                         uint16_t timing_port, const char *session_uuid,
                         const unsigned char *shk, const unsigned char *shiv,
                         const char *device_id, const char *os_name,
                         const char *os_version, const char *model, const char *name)
{
  http_client_response_t *response;
  plist_t root_node;
  char *plist_data = NULL;
  uint32_t plist_len = 0;
  char setup_url[256];

  (void)os_name;
  (void)os_version;

  assert(client);
  assert(http_client);
  assert(host);
  assert(device_id);
  assert(model);

  root_node = plist_new_dict();

  // ---- Session identity ----
  plist_dict_set_item(root_node, "deviceID", plist_new_string(device_id));
  plist_dict_set_item(root_node, "macAddress", plist_new_string(device_id));
  if (session_uuid) {
    plist_dict_set_item(root_node, "sessionUUID", plist_new_string(session_uuid));
  }
  plist_dict_set_item(root_node, "sourceVersion", plist_new_string("280.33"));
  plist_dict_set_item(root_node, "osBuildVersion", plist_new_string("20G165"));
  plist_dict_set_item(root_node, "model", plist_new_string(model));
  plist_dict_set_item(root_node, "name", plist_new_string(name ? name : model));

  // ---- Screen-mirroring session + NTP timing (we run the timing server) ----
  plist_dict_set_item(root_node, "isScreenMirroringSession", plist_new_bool(1));
  plist_dict_set_item(root_node, "timingProtocol", plist_new_string("NTP"));
  plist_dict_set_item(root_node, "timingPort", plist_new_uint(timing_port));

  // ---- FairPlay ekey/eiv at root (UxPlay reads these to derive the key) ----
  if (ekey && eiv) {
    plist_dict_set_item(root_node, "et", plist_new_uint(32));
    plist_dict_set_item(root_node, "ekey", plist_new_data((const char *)ekey, 72));
    plist_dict_set_item(root_node, "eiv", plist_new_data((const char *)eiv, 16));
  }

  // ---- streams: [ video mirroring stream (type 110) ] ----
  plist_t streams_node = plist_new_array();
  plist_t stream_node = plist_new_dict();

  plist_dict_set_item(stream_node, "type", plist_new_uint(110));  // video mirroring

  if (client->info.stream_connection_id == 0) {
    client->info.stream_connection_id = generate_random_uint64();
  }
  plist_dict_set_item(stream_node, "streamConnectionID",
                      plist_new_uint(client->info.stream_connection_id));

  // timestampInfo descriptors, as real senders send them
  plist_t ts_info_node = plist_new_array();
  static const char *ts_names[] = {"SubSu", "BePxT", "AfPxT", "BefEn", "EmEnc"};
  for (size_t i = 0; i < sizeof(ts_names) / sizeof(ts_names[0]); i++) {
    plist_t ts_node = plist_new_dict();
    plist_dict_set_item(ts_node, "name", plist_new_string(ts_names[i]));
    plist_array_append_item(ts_info_node, ts_node);
  }
  plist_dict_set_item(stream_node, "timestampInfo", ts_info_node);

  // Stream encryption key/iv live on the stream descriptor
  if (shk) {
    plist_dict_set_item(stream_node, "shk", plist_new_data((const char *)shk, 16));
  }
  if (shiv) {
    plist_dict_set_item(stream_node, "shiv", plist_new_data((const char *)shiv, 16));
  }

  plist_array_append_item(streams_node, stream_node);
  plist_dict_set_item(root_node, "streams", streams_node);

  // Convert to binary plist
  plist_to_bin(root_node, &plist_data, &plist_len);
  plist_free(root_node);

  if (!plist_data || plist_len == 0) {
    return -1;
  }

  // Build RTSP URL for SETUP
  snprintf(setup_url, sizeof(setup_url), "rtsp://%s:%u/%" PRIu64,
           host, port, client->info.stream_connection_id);

  // AirPlay 2 mirroring SETUP is a plain plist request — no RAOP Transport header
  // (that header is what made the receiver reject the old SETUP with 501).
  char headers[512];
  snprintf(headers, sizeof(headers),
           "Content-Type: application/x-apple-binary-plist\r\n");

  // Use http_client_request with "SETUP" method (receiver accepts RTSP methods)
  response = http_client_request(http_client, "SETUP", setup_url,
                                 headers,
                                 plist_data, (int)plist_len);

  free(plist_data);

  if (!response || response->status_code != 200) {
    fprintf(stderr, "stream_client: RTSP SETUP failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) {
      http_client_response_destroy(response);
    }
    return -1;
  }

  // Parse response to update stream info (same as stream_client_setup)
  if (response->body && response->body_len > 0) {
    plist_t res_root_node = NULL;
    plist_from_bin(response->body, response->body_len, &res_root_node);

    if (res_root_node) {
      fprintf(stderr, "stream_client: parsed RTSP SETUP response, body_len=%d\n", response->body_len);

      // Parse eventPort
      plist_t event_port_node = plist_dict_get_item(res_root_node, "eventPort");
      if (event_port_node && plist_get_node_type(event_port_node) == PLIST_UINT) {
        uint64_t val;
        plist_get_uint_val(event_port_node, &val);
        client->info.event_port = (uint16_t)val;
        fprintf(stderr, "stream_client: parsed eventPort=%d\n", client->info.event_port);
      }

      // Parse timingPort
      plist_t timing_port_node = plist_dict_get_item(res_root_node, "timingPort");
      if (timing_port_node && plist_get_node_type(timing_port_node) == PLIST_UINT) {
        uint64_t val;
        plist_get_uint_val(timing_port_node, &val);
        client->info.timing_port = (uint16_t)val;
        fprintf(stderr, "stream_client: parsed timingPort=%d\n", client->info.timing_port);
      }

      // Parse streams array to get updated ports
      plist_t res_streams_node = plist_dict_get_item(res_root_node, "streams");
      if (res_streams_node && PLIST_IS_ARRAY(res_streams_node)) {
        uint32_t count = plist_array_get_size(res_streams_node);
        fprintf(stderr, "stream_client: found streams array with %u items\n", count);
        if (count > 0) {
          plist_t res_stream_node = plist_array_get_item(res_streams_node, 0);
          if (res_stream_node && PLIST_IS_DICT(res_stream_node)) {
            // Parse dataPort
            plist_t data_port_node = plist_dict_get_item(res_stream_node, "dataPort");
            if (data_port_node && plist_get_node_type(data_port_node) == PLIST_UINT) {
              uint64_t val;
              plist_get_uint_val(data_port_node, &val);
              client->info.data_port = (uint16_t)val;
              fprintf(stderr, "stream_client: parsed dataPort=%d\n", client->info.data_port);
            } else {
              fprintf(stderr, "stream_client: dataPort node not found or wrong type (node=%p, type=%d)\n",
                      data_port_node, data_port_node ? plist_get_node_type(data_port_node) : -1);
            }

            // Parse controlPort (if present)
            plist_t control_port_node = plist_dict_get_item(res_stream_node, "controlPort");
            if (control_port_node && plist_get_node_type(control_port_node) == PLIST_UINT) {
              uint64_t val;
              plist_get_uint_val(control_port_node, &val);
              client->info.control_port = (uint16_t)val;
              fprintf(stderr, "stream_client: parsed controlPort=%d\n", client->info.control_port);
            }
          } else {
            fprintf(stderr, "stream_client: first stream node is not a dict (node=%p)\n", res_stream_node);
          }
        } else {
          fprintf(stderr, "stream_client: streams array is empty\n");
        }
      } else {
        fprintf(stderr, "stream_client: streams node not found or not an array (node=%p, is_array=%d)\n",
                res_streams_node, res_streams_node ? PLIST_IS_ARRAY(res_streams_node) : 0);
      }

      plist_free(res_root_node);
    } else {
      fprintf(stderr, "stream_client: failed to parse response plist (body_len=%d)\n", response->body_len);
    }
  } else {
    fprintf(stderr, "stream_client: no response body (body=%p, body_len=%d)\n", response->body, response->body_len);
  }

  // Check if we have required data
  // Note: dataPort will be 0 if mirroring is not initialized (receiver will disconnect anyway)
  if (client->info.data_port == 0) {
    fprintf(stderr, "stream_client: dataPort is 0 in RTSP SETUP response - mirroring not initialized\n");
    fprintf(stderr, "stream_client: This means the first SETUP with ekey/eiv was not sent\n");
    fprintf(stderr, "stream_client: Receiver will disconnect - cannot continue without mirroring\n");
    // Fail here - without mirroring initialized, we can't proceed
    http_client_response_destroy(response);
    return -1;
  }

  // Mark setup as done (same as stream_client_setup)
  client->setup_done = 1;

  http_client_response_destroy(response);
  return 0;
}

int
stream_client_record_rtsp(stream_client_t *client, struct http_client_s *http_client,
                         const char *host, uint16_t port)
{
  http_client_response_t *response;
  char stream_url[256];

  assert(client);
  assert(http_client);
  assert(host);

  // Build RTSP URL for RECORD
  snprintf(stream_url, sizeof(stream_url), "rtsp://%s:%u/%" PRIu64,
           host, port, client->info.stream_connection_id);

  // Send RTSP RECORD request
  // Format: RECORD <stream_url> RTSP/1.0
  // Note: User-Agent is automatically added by http_client_request
  char headers[256];
  snprintf(headers, sizeof(headers), "");

  // Use http_client_request with "RECORD" method
  response = http_client_request(http_client, "RECORD", stream_url,
                                 headers,
                                 NULL, 0);

  if (!response || (response->status_code != 200 && response->status_code != 201)) {
    fprintf(stderr, "stream_client: RTSP RECORD failed, status=%d\n",
            response ? response->status_code : -1);
    if (response) {
      http_client_response_destroy(response);
    }
    return -1;
  }

  http_client_response_destroy(response);
  return 0;
}

void
stream_client_destroy(stream_client_t *client)
{
  if (client) {
    stream_client_disconnect_video(client);
    stream_client_disconnect_feedback(client);
    free(client);
  }
}