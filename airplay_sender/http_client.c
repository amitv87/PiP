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

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <sys/select.h>
#include <sys/time.h>
#include <errno.h>

#ifndef WIN32
#include <fcntl.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#else
#include <winsock2.h>
#include <ws2tcpip.h>
#define gai_strerror(x) "getaddrinfo error"
#endif

#include "../airplay/compat.h"
#include "../airplay/sockets.h"
#include "../airplay/llhttp/llhttp.h"
#include "../airplay/plist/plist/plist.h"
#include "http_client.h"
#include "mirror_crypto.h"

#define HTTP_CLIENT_BUFFER_SIZE 4096
#define HTTP_CLIENT_TIMEOUT_SEC 10

struct http_client_s {
  char *host;
  uint16_t port;
  int socket_fd;
  int connected;

  /* HAP (HomeKit) control-channel encryption, enabled after pair-verify. */
  int encrypted;
  uint8_t enc_write_key[32];
  uint8_t enc_read_key[32];
  uint64_t enc_write_nonce;
  uint64_t enc_read_nonce;
};

struct http_response_parser_s {
  llhttp_t parser;
  llhttp_settings_t parser_settings;

  int status_code;
  char *headers;
  int headers_size;
  int headers_length;
  char *body;
  int body_len;
  int complete;
  int protocol_replaced;  // Track if we've already replaced RTSP with HTTP
};

static int
on_status(llhttp_t *parser, const char *at, size_t length)
{
  return 0;
}

static int
on_header_field(llhttp_t *parser, const char *at, size_t length)
{
  struct http_response_parser_s *resp_parser = (struct http_response_parser_s *)parser->data;
  int current_len = resp_parser->headers_length;

  // Allocate space for: existing data + new data + ": " + null terminator
  resp_parser->headers = realloc(resp_parser->headers, current_len + length + 2 + 1);
  if (!resp_parser->headers) {
    return -1;
  }

  memcpy(resp_parser->headers + current_len, at, length);
  resp_parser->headers[current_len + length] = ':';
  resp_parser->headers[current_len + length + 1] = ' ';
  resp_parser->headers_length += length + 2;
  resp_parser->headers[resp_parser->headers_length] = '\0';

  return 0;
}

static int
on_header_value(llhttp_t *parser, const char *at, size_t length)
{
  struct http_response_parser_s *resp_parser = (struct http_response_parser_s *)parser->data;
  int current_len = resp_parser->headers_length;

  // Allocate space for: existing data + new data + "\r\n" + null terminator
  resp_parser->headers = realloc(resp_parser->headers, current_len + length + 2 + 1);
  if (!resp_parser->headers) {
    return -1;
  }

  memcpy(resp_parser->headers + current_len, at, length);
  resp_parser->headers[current_len + length] = '\r';
  resp_parser->headers[current_len + length + 1] = '\n';
  resp_parser->headers_length += length + 2;
  resp_parser->headers[resp_parser->headers_length] = '\0';

  return 0;
}

static int
on_body(llhttp_t *parser, const char *at, size_t length)
{
  struct http_response_parser_s *resp_parser = (struct http_response_parser_s *)parser->data;
  size_t new_size;
  char *old_body;

  if (!at || length == 0) {
    return 0;
  }

  fprintf(stderr, "http_client: on_body called with length=%zu, current body_len=%d\n", length, resp_parser->body_len);

  // Check for overflow
  if (resp_parser->body_len < 0) {
    fprintf(stderr, "http_client: body_len is negative: %d\n", resp_parser->body_len);
    return -1;
  }

  new_size = (size_t)resp_parser->body_len + length;
  if (new_size < (size_t)resp_parser->body_len) {
    fprintf(stderr, "http_client: size overflow detected\n");
    return -1;
  }

  old_body = resp_parser->body;
  resp_parser->body = realloc(resp_parser->body, new_size);
  if (!resp_parser->body) {
    fprintf(stderr, "http_client: realloc failed for body (size=%zu)\n", new_size);
    return -1;
  }

  // Validate the source pointer is reasonable
  if ((uintptr_t)at < 0x1000 || (uintptr_t)at > 0x7fffffffffff) {
    fprintf(stderr, "http_client: suspicious source pointer: %p\n", at);
    return -1;
  }

  // Debug: log first few bytes of what we're copying
  if (length > 0) {
    fprintf(stderr, "http_client: copying %zu bytes from %p, first 8 bytes: ", length, at);
    for (size_t i = 0; i < 8 && i < length; i++) {
      fprintf(stderr, "%02x ", (unsigned char)at[i]);
    }
    fprintf(stderr, "\n");
  }

  memcpy(resp_parser->body + resp_parser->body_len, at, length);
  resp_parser->body_len = (int)new_size;

  // Debug: verify what we copied
  if (resp_parser->body_len > 0) {
    fprintf(stderr, "http_client: body_len now=%d, first 8 bytes of accumulated body: ", resp_parser->body_len);
    for (int i = 0; i < 8 && i < resp_parser->body_len; i++) {
      fprintf(stderr, "%02x ", (unsigned char)resp_parser->body[i]);
    }
    fprintf(stderr, "\n");
  }

  return 0;
}

static int
on_message_complete(llhttp_t *parser)
{
  struct http_response_parser_s *resp_parser = (struct http_response_parser_s *)parser->data;

  resp_parser->status_code = parser->status_code;
  resp_parser->complete = 1;
  return 0;
}

static int
connect_to_host(const char *host, uint16_t port)
{
  struct addrinfo hints, *result, *rp;
  int sockfd = -1;
  char port_str[6];
  int ret;
  struct timeval timeout;
  fd_set write_fds;
  int error;
  socklen_t error_len;
  int getaddrinfo_error;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  snprintf(port_str, sizeof(port_str), "%u", port);

  getaddrinfo_error = getaddrinfo(host, port_str, &hints, &result);
  if (getaddrinfo_error != 0) {
    fprintf(stderr, "http_client: getaddrinfo failed for %s:%u: %s\n",
            host, port, gai_strerror(getaddrinfo_error));
    return -1;
  }

  for (rp = result; rp != NULL; rp = rp->ai_next) {
    sockfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (sockfd == -1) {
      continue;
    }

    // Set socket to non-blocking mode
#ifndef WIN32
    int flags = fcntl(sockfd, F_GETFL, 0);
    if (flags == -1 || fcntl(sockfd, F_SETFL, flags | O_NONBLOCK) == -1) {
      closesocket(sockfd);
      sockfd = -1;
      continue;
    }
#else
    u_long mode = 1;
    if (ioctlsocket(sockfd, FIONBIO, &mode) != 0) {
      closesocket(sockfd);
      sockfd = -1;
      continue;
    }
#endif

    // Attempt connection (will return immediately with non-blocking socket)
    ret = connect(sockfd, rp->ai_addr, rp->ai_addrlen);

    if (ret == 0) {
      // Connected immediately
      goto connected;
    }

#ifndef WIN32
    if (errno != EINPROGRESS && errno != EWOULDBLOCK) {
      closesocket(sockfd);
      sockfd = -1;
      continue;
    }
#else
    if (WSAGetLastError() != WSAEWOULDBLOCK && WSAGetLastError() != WSAEINPROGRESS) {
      closesocket(sockfd);
      sockfd = -1;
      continue;
    }
#endif

    // Wait for connection with timeout
    FD_ZERO(&write_fds);
    FD_SET(sockfd, &write_fds);
    timeout.tv_sec = HTTP_CLIENT_TIMEOUT_SEC;
    timeout.tv_usec = 0;

    ret = select(sockfd + 1, NULL, &write_fds, NULL, &timeout);
    if (ret <= 0 || !FD_ISSET(sockfd, &write_fds)) {
      // Timeout or error
      closesocket(sockfd);
      sockfd = -1;
      continue;
    }

    // Check if connection succeeded
    error_len = sizeof(error);
    if (getsockopt(sockfd, SOL_SOCKET, SO_ERROR, (char *)&error, &error_len) == 0) {
      if (error == 0) {
        // Connection successful
        goto connected;
      } else {
        fprintf(stderr, "http_client: connection failed to %s:%u: error %d\n", host, port, error);
      }
    } else {
      fprintf(stderr, "http_client: getsockopt failed for %s:%u\n", host, port);
    }

    // Connection failed
    closesocket(sockfd);
    sockfd = -1;
    continue;

connected:
    // Set socket back to blocking mode
#ifndef WIN32
    flags = fcntl(sockfd, F_GETFL, 0);
    if (flags != -1) {
      fcntl(sockfd, F_SETFL, flags & ~O_NONBLOCK);
    }
#else
    mode = 0;
    ioctlsocket(sockfd, FIONBIO, &mode);
#endif

    // Set socket timeouts for send/recv
    timeout.tv_sec = HTTP_CLIENT_TIMEOUT_SEC;
    timeout.tv_usec = 0;
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (char *)&timeout, sizeof(timeout));
    setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, (char *)&timeout, sizeof(timeout));

    // Disable Nagle's algorithm (TCP_NODELAY) to ensure requests are sent immediately
    // This prevents TCP from batching small requests, which can cause the parser
    // to receive headers and body in separate packets, triggering the \r\n bug
    int flag = 1;
    setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY, (char *)&flag, sizeof(flag));

    freeaddrinfo(result);
    return sockfd;
  }

  freeaddrinfo(result);
  fprintf(stderr, "http_client: failed to connect to %s:%u after trying all addresses\n", host, port);
  return -1;
}

http_client_t *
http_client_init(const char *host, uint16_t port)
{
  http_client_t *client;

  assert(host);

  client = calloc(1, sizeof(http_client_t));
  if (!client) {
    return NULL;
  }

  client->host = strdup(host);
  if (!client->host) {
    free(client);
    return NULL;
  }

  client->port = port;
  client->socket_fd = -1;
  client->connected = 0;

  return client;
}

int
http_client_connect(http_client_t *client)
{
  assert(client);

  if (client->connected) {
    return 0;
  }

  client->socket_fd = connect_to_host(client->host, client->port);
  if (client->socket_fd == -1) {
    return -1;
  }

  // Small delay to ensure connection is fully established
  // This helps with localhost connections that might have timing issues
  usleep(10000); // 10ms delay

  client->connected = 1;
  return 0;
}

void
http_client_enable_encryption(http_client_t *client,
                              const uint8_t write_key[32],
                              const uint8_t read_key[32])
{
  assert(client);
  memcpy(client->enc_write_key, write_key, 32);
  memcpy(client->enc_read_key, read_key, 32);
  client->enc_write_nonce = 0;
  client->enc_read_nonce = 0;
  client->encrypted = 1;
  fprintf(stderr, "http_client: HAP control-channel encryption enabled\n");
}

/* ---- HAP (HomeKit) control-channel framing --------------------------------
 * After pair-verify, every RTSP request/response on this socket is carried as a
 * sequence of ChaCha20-Poly1305 frames: [2-byte LE plaintext length][ciphertext
 * ][16-byte tag], plaintext chunked at 1024 bytes. The AAD is the 2-byte length
 * prefix; the nonce is [0;4]||LE64(per-direction counter). Faithful port of
 * airfry rtsp.rs encrypt()/read_encrypted_frame(). */

static void
put_le64_bytes(uint8_t *p, uint64_t v)
{
  for (int i = 0; i < 8; i++) {
    p[i] = (uint8_t)(v >> (8 * i));
  }
}

/* Blocking recv of exactly len bytes, tolerating the socket's SO_RCVTIMEO so a
 * slow receiver (SETUP can take >10s) does not abort the read. Returns 0 on
 * success, -1 on EOF/error/overall-timeout. */
static int
recv_exact(http_client_t *client, uint8_t *buf, int len)
{
  int got = 0;
  int timeouts = 0;
  const int MAX_TIMEOUTS = 4;  /* ~4 * SO_RCVTIMEO before giving up */
  while (got < len) {
    int r = recv(client->socket_fd, buf + got, len - got, 0);
    if (r > 0) {
      got += r;
      continue;
    }
    if (r == 0) {
      return -1;  /* peer closed */
    }
    if (errno == EINTR) {
      continue;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      if (++timeouts >= MAX_TIMEOUTS) {
        return -1;
      }
      continue;
    }
    return -1;
  }
  return 0;
}

/* Encrypt a plaintext buffer as HAP frames and send it. Returns 0 / -1. */
static int
hap_send(http_client_t *client, const uint8_t *data, int len)
{
  int off = 0;
  while (off < len) {
    int n = len - off;
    if (n > 1024) {
      n = 1024;
    }
    uint8_t frame[2 + 1024 + 16];
    frame[0] = (uint8_t)(n & 0xff);
    frame[1] = (uint8_t)((n >> 8) & 0xff);
    uint8_t nonce[12];
    memset(nonce, 0, sizeof(nonce));
    put_le64_bytes(nonce + 4, client->enc_write_nonce++);
    chacha20poly1305_seal(client->enc_write_key, nonce, frame, 2,
                          data + off, (size_t)n, frame + 2);
    int total = 2 + n + 16;
    int sent = 0;
    while (sent < total) {
      int r = send(client->socket_fd, frame + sent, total - sent, 0);
      if (r <= 0) {
        return -1;
      }
      sent += r;
    }
    off += n;
  }
  return 0;
}

/* Read + decrypt one HAP frame into out (capacity >= 1024). Returns the
 * plaintext length, or -1 on error. */
static int
hap_read_frame(http_client_t *client, uint8_t *out)
{
  uint8_t lenbuf[2];
  if (recv_exact(client, lenbuf, 2) != 0) {
    return -1;
  }
  int plen = (int)lenbuf[0] | ((int)lenbuf[1] << 8);
  if (plen <= 0 || plen > 1024) {
    fprintf(stderr, "http_client: suspicious HAP frame length %d\n", plen);
    return -1;
  }
  uint8_t ct[1024 + 16];
  if (recv_exact(client, ct, plen + 16) != 0) {
    return -1;
  }
  uint8_t nonce[12];
  memset(nonce, 0, sizeof(nonce));
  put_le64_bytes(nonce + 4, client->enc_read_nonce++);
  if (chacha20poly1305_open(client->enc_read_key, nonce, lenbuf, 2,
                            ct, (size_t)(plen + 16), out) != 0) {
    fprintf(stderr, "http_client: HAP frame decrypt failed (nonce %llu)\n",
            (unsigned long long)(client->enc_read_nonce - 1));
    return -1;
  }
  return plen;
}

/* Scan the (already-complete) header block for Content-Length. Only matches at a
 * line start to avoid false positives inside header values. Returns 0 if absent. */
static int
parse_content_length_hdr(const uint8_t *buf, int header_end)
{
  static const char *K = "content-length:";
  int klen = 15;
  for (int i = 0; i + klen <= header_end; i++) {
    if (i != 0 && buf[i - 1] != '\n') {
      continue;
    }
    int match = 1;
    for (int j = 0; j < klen; j++) {
      int c = buf[i + j];
      if (c >= 'A' && c <= 'Z') {
        c += 32;
      }
      if (c != K[j]) {
        match = 0;
        break;
      }
    }
    if (!match) {
      continue;
    }
    int p = i + klen;
    while (p < header_end && (buf[p] == ' ' || buf[p] == '\t')) {
      p++;
    }
    int val = 0;
    while (p < header_end && buf[p] >= '0' && buf[p] <= '9') {
      val = val * 10 + (buf[p] - '0');
      p++;
    }
    return val;
  }
  return 0;
}

/* Send an encrypted RTSP request over the HAP control channel and read the
 * encrypted response, returning it in the same shape as the plaintext path.
 * Bypasses the plaintext read loop's EOF heuristics: HAP framing is
 * self-delimiting and responses always carry Content-Length (or none == 0). */
static http_client_response_t *
http_client_request_encrypted(http_client_t *client, const char *request, int request_len)
{
  if (hap_send(client, (const uint8_t *)request, request_len) != 0) {
    fprintf(stderr, "http_client: HAP send failed\n");
    http_client_disconnect(client);
    return NULL;
  }

  uint8_t *dec = NULL;
  int dec_len = 0, dec_cap = 0;
  int header_end = -1, content_length = 0, have_header = 0;

  for (;;) {
    uint8_t framebuf[1024];
    int plen = hap_read_frame(client, framebuf);
    if (plen < 0) {
      free(dec);
      http_client_disconnect(client);
      return NULL;
    }
    if (dec_len + plen > dec_cap) {
      int ncap = (dec_len + plen) * 2 + 256;
      uint8_t *nd = realloc(dec, ncap);
      if (!nd) {
        free(dec);
        http_client_disconnect(client);
        return NULL;
      }
      dec = nd;
      dec_cap = ncap;
    }
    memcpy(dec + dec_len, framebuf, plen);
    dec_len += plen;

    if (!have_header) {
      for (int i = 0; i + 3 < dec_len; i++) {
        if (dec[i] == '\r' && dec[i + 1] == '\n' &&
            dec[i + 2] == '\r' && dec[i + 3] == '\n') {
          header_end = i + 4;
          have_header = 1;
          content_length = parse_content_length_hdr(dec, header_end);
          break;
        }
      }
    }
    if (have_header && dec_len >= header_end + content_length) {
      break;
    }
    if (dec_len > 1024 * 1024) {
      fprintf(stderr, "http_client: encrypted response too large\n");
      free(dec);
      http_client_disconnect(client);
      return NULL;
    }
  }

  /* llhttp expects HTTP; rewrite the RTSP status-line token in place. */
  if (dec_len >= 7 && memcmp(dec, "RTSP/1.", 7) == 0) {
    memcpy(dec, "HTTP", 4);
  }

  struct http_response_parser_s resp_parser;
  resp_parser.status_code = 0;
  resp_parser.headers = NULL;
  resp_parser.headers_size = 0;
  resp_parser.headers_length = 0;
  resp_parser.body = NULL;
  resp_parser.body_len = 0;
  resp_parser.complete = 0;
  resp_parser.protocol_replaced = 1;

  llhttp_settings_init(&resp_parser.parser_settings);
  resp_parser.parser_settings.on_status = &on_status;
  resp_parser.parser_settings.on_header_field = &on_header_field;
  resp_parser.parser_settings.on_header_value = &on_header_value;
  resp_parser.parser_settings.on_body = &on_body;
  resp_parser.parser_settings.on_message_complete = &on_message_complete;

  llhttp_init(&resp_parser.parser, HTTP_RESPONSE, &resp_parser.parser_settings);
  resp_parser.parser.data = &resp_parser;

  llhttp_errno_t ret = llhttp_execute(&resp_parser.parser, (const char *)dec, dec_len);
  if (ret == HPE_OK && !resp_parser.complete) {
    llhttp_finish(&resp_parser.parser);
  }
  if (resp_parser.status_code == 0) {
    resp_parser.status_code = resp_parser.parser.status_code;
  }
  free(dec);

  if (ret != HPE_OK && !resp_parser.complete) {
    fprintf(stderr, "http_client: encrypted parse error: %d\n", ret);
    free(resp_parser.headers);
    free(resp_parser.body);
    http_client_disconnect(client);
    return NULL;
  }

  http_client_response_t *response = calloc(1, sizeof(http_client_response_t));
  if (!response) {
    free(resp_parser.headers);
    free(resp_parser.body);
    return NULL;
  }
  response->status_code = resp_parser.status_code;
  response->headers = resp_parser.headers;
  response->body = resp_parser.body;
  response->body_len = resp_parser.body_len;
  fprintf(stderr, "http_client: encrypted response complete, status: %d, body: %d bytes\n",
          response->status_code, response->body_len);
  return response;
}

http_client_response_t *
http_client_request(http_client_t *client, const char *method, const char *path,
                    const char *headers, const char *body, int body_len)
{
  char request[8192];
  int request_len;
  int sent;
  char buffer[HTTP_CLIENT_BUFFER_SIZE];
  int received;
  struct http_response_parser_s resp_parser;
  http_client_response_t *response;
  int ret;

  assert(client);
  assert(method);
  assert(path);

  if (!client->connected) {
    if (http_client_connect(client) != 0) {
      return NULL;
    }
  }

  // AirPlay uses RTSP/1.0 for requests (matching real Apple devices)
  // Include CSeq header which is required for RTSP/AirPlay
  static int cseq_counter = 1;
  int cseq = cseq_counter++;

  request_len = snprintf(request, sizeof(request),
                         "%s %s RTSP/1.0\r\n"
                         "Host: %s:%u\r\n"
                         "CSeq: %d\r\n"
                         "User-Agent: AirPlay/320.20\r\n",
                         method, path, client->host, client->port, cseq);

  // Ensure we don't exceed buffer
  if (request_len >= sizeof(request) - 1) {
    return NULL;
  }

  if (headers) {
    int headers_len = strlen(headers);
    if (request_len + headers_len < sizeof(request) - 2) {
      memcpy(request + request_len, headers, headers_len);
      request_len += headers_len;
    }
  }

  if (body && body_len > 0) {
    char content_length[32];
    int clen = snprintf(content_length, sizeof(content_length),
                        "Content-Length: %d\r\n", body_len);
    if (request_len + clen < sizeof(request) - 2) {
      memcpy(request + request_len, content_length, clen);
      request_len += clen;
    }
  }

  // RTSP/HTTP requests must end with \r\n (empty line) before body
  // Check if the last character is already \n (from a header ending with \r\n)
  // If so, we only need to add \r\n (one more line break)
  // If not, we need to add \r\n\r\n (two line breaks)
  if (request_len > 0 && request[request_len - 1] == '\n') {
    // Last character is \n, so we already have \r\n from last header
    // Just add \r\n for the empty line
    if (request_len + 2 < sizeof(request)) {
      memcpy(request + request_len, "\r\n", 2);
      request_len += 2;
    } else {
      return NULL;
    }
  } else {
    // Last character is not \n, add \r\n\r\n (empty line)
    if (request_len + 4 < sizeof(request)) {
      memcpy(request + request_len, "\r\n\r\n", 4);
      request_len += 4;
    } else {
      return NULL;
    }
  }

  // Append body data after the empty line
  if (body && body_len > 0) {
    if (request_len + body_len < sizeof(request)) {
      memcpy(request + request_len, body, body_len);
      request_len += body_len;
    } else {
      return NULL;
    }
  }

  // Ensure request is null-terminated for debugging (but don't include null in send)
  request[request_len] = '\0';

  // Debug: log the request being sent
  fprintf(stderr, "http_client: sending request (%d bytes):\n%.*s\n", request_len, request_len, request);

  // HAP control channel: once pair-verify has enabled encryption, every RTSP
  // request/response on this socket is ChaCha20-Poly1305 framed. Take the
  // self-contained encrypted path (send + read + parse) and return.
  if (client->encrypted) {
    return http_client_request_encrypted(client, request, request_len);
  }

  sent = 0;
  while (sent < request_len) {
    ret = send(client->socket_fd, request + sent, request_len - sent, 0);
    if (ret == -1) {
      fprintf(stderr, "http_client: send failed: %s\n", strerror(errno));
      http_client_disconnect(client);
      return NULL;
    }
    sent += ret;
  }

  fprintf(stderr, "http_client: sent %d bytes\n", sent);

  // Note: Body is already included in the request buffer above (lines 437-444),
  // so we don't need to send it again. The duplicate send below was a bug.
  // Real Apple devices send everything in one packet, which is why they don't
  // trigger the parser's \r\n bug. We've added TCP_NODELAY to ensure the same behavior.

  // Initialize parser structure - don't use memset as it might interfere with parser internals
  resp_parser.status_code = 0;
  resp_parser.headers = NULL;
  resp_parser.headers_size = 0;
  resp_parser.headers_length = 0;
  resp_parser.body = NULL;
  resp_parser.body_len = 0;
  resp_parser.complete = 0;
  resp_parser.protocol_replaced = 0;

  llhttp_settings_init(&resp_parser.parser_settings);
  resp_parser.parser_settings.on_status = &on_status;
  resp_parser.parser_settings.on_header_field = &on_header_field;
  resp_parser.parser_settings.on_header_value = &on_header_value;
  resp_parser.parser_settings.on_body = &on_body;
  resp_parser.parser_settings.on_message_complete = &on_message_complete;

  llhttp_init(&resp_parser.parser, HTTP_RESPONSE, &resp_parser.parser_settings);
  resp_parser.parser.data = &resp_parser;

  int retry_count = 0;
  const int MAX_RETRIES = 15;  // Retry up to 15 times when waiting for body (receiver may take ~11 seconds due to conn_init blocking)
  int consecutive_timeouts = 0;  // Track consecutive timeouts to detect connection issues

  while (!resp_parser.complete) {
    char *parse_buffer;
    fd_set read_fds;
    struct timeval timeout;
    int select_ret;

    // Use select() to wait for data to be available
    // This handles both blocking and non-blocking sockets correctly
    // For responses that need EOF (no Content-Length), use a shorter timeout
    // to check more frequently if data is available
    FD_ZERO(&read_fds);
    FD_SET(client->socket_fd, &read_fds);

    // Use much shorter timeout when we've already received headers - response should come quickly
    // Use full timeout only for initial wait before headers are received
    llhttp_errno_t parser_err_check = llhttp_get_errno(&resp_parser.parser);
    int needs_eof_check = llhttp_message_needs_eof(&resp_parser.parser);
    if (parser_err_check == HPE_OK && resp_parser.headers != NULL) {
      // Headers received - use very short timeout (response body or EOF should come immediately)
      // This helps detect EOF quickly when receiver disconnects
      timeout.tv_sec = 0;  // 0 seconds - check immediately
      timeout.tv_usec = 50000;  // 50ms timeout when headers are already received
      fprintf(stderr, "http_client: headers received, using 50ms timeout to check for EOF\n");
    } else {
      // No headers yet - use shorter timeout for initial wait (response should come quickly)
      // If receiver disconnects immediately, we want to detect it fast
      timeout.tv_sec = 1;  // 1 second instead of 10 - response should come immediately
      timeout.tv_usec = 0;
      fprintf(stderr, "http_client: no headers yet, using 1 second timeout\n");
    }

    fprintf(stderr, "http_client: calling select() (has_headers=%d, body_len=%d, complete=%d)\n",
            resp_parser.headers != NULL, resp_parser.body_len, resp_parser.complete);
    select_ret = select(client->socket_fd + 1, &read_fds, NULL, NULL, &timeout);
    fprintf(stderr, "http_client: select() returned %d\n", select_ret);
    if (select_ret <= 0) {
      if (select_ret == 0) {
        consecutive_timeouts++;
        // After a timeout with no headers, check if data is available (select() might miss it)
        // This helps catch responses that arrive but select() doesn't detect
        if (resp_parser.headers == NULL) {
          int flags = fcntl(client->socket_fd, F_GETFL, 0);
          if (flags != -1) {
            fcntl(client->socket_fd, F_SETFL, flags | O_NONBLOCK);
            char eof_check[1];
            int eof_ret = recv(client->socket_fd, eof_check, 1, MSG_PEEK);
            fcntl(client->socket_fd, F_SETFL, flags & ~O_NONBLOCK);
            if (eof_ret == 0) {
              // Connection closed before we received response
              fprintf(stderr, "http_client: connection closed before receiving response\n");
              http_client_disconnect(client);
              return NULL;
            } else if (eof_ret > 0) {
              // Data is available but select() didn't detect it - try reading immediately
              fprintf(stderr, "http_client: data available but select() timed out, reading immediately\n");
              consecutive_timeouts = 0;
              // Fall through to read the data
              goto read_data;
            } else if (consecutive_timeouts > 2) {
              fprintf(stderr, "http_client: multiple timeouts with no headers and no data available\n");
            }
          }
        }
        // Timeout - check if connection is closed by trying a non-blocking recv
        // When receiver disconnects, we should detect EOF immediately
        if (resp_parser.headers != NULL) {
          int flags = fcntl(client->socket_fd, F_GETFL, 0);
          if (flags != -1) {
            fcntl(client->socket_fd, F_SETFL, flags | O_NONBLOCK);
            char eof_check[1];
            int eof_ret = recv(client->socket_fd, eof_check, 1, MSG_PEEK);
            fcntl(client->socket_fd, F_SETFL, flags & ~O_NONBLOCK);
            if (eof_ret == 0) {
              // Connection closed - signal EOF immediately
              fprintf(stderr, "http_client: connection closed (EOF detected), signaling EOF\n");
              llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
              if (finish_ret == HPE_OK && resp_parser.complete) {
                break;
              }
            }
          }
        }
        // Timeout - no more data available
        llhttp_errno_t parser_err = llhttp_get_errno(&resp_parser.parser);
        int needs_eof = llhttp_message_needs_eof(&resp_parser.parser);

        // Debug: log received headers
        if (resp_parser.headers) {
          fprintf(stderr, "http_client: received headers: %s\n", resp_parser.headers);
        }

        // If parser needs EOF and we have headers but no body, keep trying to read
        // The body might be coming in a separate TCP packet
        if (parser_err == HPE_OK && needs_eof && resp_parser.body_len == 0 && !resp_parser.complete) {
          // Check if we've received headers and status code - if so, response might be complete
          int parser_status = resp_parser.parser.status_code;
          if (parser_status > 0 && resp_parser.headers && retry_count == 0) {
            // We have headers and status code, but no body after first timeout
            // For 200 OK responses with no Content-Length, this likely means no body
            // Try non-blocking recv() once to check, then signal EOF if nothing available
            fprintf(stderr, "http_client: headers received, status=%d, checking for body in buffer\n", parser_status);
            int flags = fcntl(client->socket_fd, F_GETFL, 0);
            if (flags != -1) {
              fcntl(client->socket_fd, F_SETFL, flags | O_NONBLOCK);
              int quick_check = recv(client->socket_fd, buffer, sizeof(buffer), 0);
              fcntl(client->socket_fd, F_SETFL, flags & ~O_NONBLOCK);

              if (quick_check <= 0) {
                // No body data available - response is likely complete (no body)
                fprintf(stderr, "http_client: no body data available, signaling EOF\n");
                llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
                if (finish_ret == HPE_OK && resp_parser.complete) {
                  retry_count = 0;
                  break;
                }
              } else if (quick_check > 0) {
                // Body data found! Parse it and continue
                char *parse_buffer = malloc(quick_check);
                if (parse_buffer) {
                  memcpy(parse_buffer, buffer, quick_check);
                  llhttp_errno_t ret = llhttp_execute(&resp_parser.parser, parse_buffer, quick_check);
                  free(parse_buffer);
                  if (ret == 0 && resp_parser.complete) {
                    retry_count = 0;
                    break;
                  }
                }
                continue;  // Continue to read more
              }
            }
          }

          // Retry reading a few more times - the body might arrive shortly
          if (retry_count < MAX_RETRIES) {
            retry_count++;
            fprintf(stderr, "http_client: timeout waiting for body, retry %d/%d\n", retry_count, MAX_RETRIES);
            // Use a shorter timeout for retries
            continue;  // Continue the loop to try reading again (timeout will be shorter)
          }
          // After max retries, try non-blocking recv() one more time
          retry_count = 0;  // Reset for next request

        // Before timing out, try one more non-blocking recv() to see if body is already in buffer
        // The body might be in the TCP receive buffer even though select() timed out
        // Set socket to non-blocking temporarily
        fprintf(stderr, "http_client: trying non-blocking recv() to check for body in buffer\n");
        int flags = fcntl(client->socket_fd, F_GETFL, 0);
        if (flags != -1) {
          fcntl(client->socket_fd, F_SETFL, flags | O_NONBLOCK);
          int nonblock_ret = recv(client->socket_fd, buffer, sizeof(buffer), 0);
          fcntl(client->socket_fd, F_SETFL, flags & ~O_NONBLOCK); // Restore blocking mode

          fprintf(stderr, "http_client: non-blocking recv() returned %d (errno=%d: %s)\n",
                  nonblock_ret, errno, (nonblock_ret < 0) ? strerror(errno) : "success");

          if (nonblock_ret > 0) {
            // Body data is available! Parse it
            fprintf(stderr, "http_client: found %d bytes of body data in buffer after timeout\n", nonblock_ret);
            char *parse_buffer = malloc(nonblock_ret);
            if (parse_buffer) {
              memcpy(parse_buffer, buffer, nonblock_ret);
              llhttp_errno_t ret = llhttp_execute(&resp_parser.parser, parse_buffer, nonblock_ret);
              free(parse_buffer);
              fprintf(stderr, "http_client: parsed body data, ret=%d, complete=%d\n", ret, resp_parser.complete);
              if (ret == 0 && resp_parser.complete) {
                // Message is now complete
                retry_count = 0;  // Reset retry count
                break;
              }
            }
            // Continue loop to read more if needed
            retry_count = 0;  // Reset retry count on successful read
            continue;
          } else if (nonblock_ret == 0) {
            // Connection closed - signal EOF
            fprintf(stderr, "http_client: connection closed, calling llhttp_finish\n");
            llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
            if (finish_ret == HPE_OK && resp_parser.complete) {
              break;
            }
          } else {
            // EAGAIN/EWOULDBLOCK - no data available
            fprintf(stderr, "http_client: no body data in buffer (errno=%d: %s)\n", errno, strerror(errno));
          }
        }

        // If we still don't have a body and needs_eof=1, the response might be complete (no body)
        // But for 200 OK responses, we expect a body. If we've exhausted retries, signal EOF
        if (parser_err == HPE_OK && needs_eof && resp_parser.body_len == 0 && !resp_parser.complete) {
          // Get status code to check if this should have a body
          int status_check = resp_parser.parser.status_code;
          if (status_check == 200) {
            // 200 OK should have a body, but we haven't received it
            // This is likely a receiver-side issue, but try signaling EOF anyway
            fprintf(stderr, "http_client: 200 OK response has no body, signaling EOF\n");
            llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
            if (finish_ret == HPE_OK && resp_parser.complete) {
              break;
            }
          }
        }

      // Get status code from parser (it's available even before message is complete)
      // Note: llhttp_get_status_code might not be available, use parser.status_code directly
      int parser_status_code = resp_parser.parser.status_code;
      if (parser_status_code > 0 && resp_parser.status_code == 0) {
        resp_parser.status_code = parser_status_code;
      }

        // Check if this is a response that should have no body
        // For pair-verify, we expect a body, so don't finish yet
        // Only finish if status code indicates no body (204, 304, etc.)
        int status_to_check = (resp_parser.status_code > 0) ? resp_parser.status_code : parser_status;
        if (status_to_check == 204 || status_to_check == 304 ||
            (status_to_check >= 100 && status_to_check < 200)) {
          // Response should have no body - signal EOF to complete the message
          llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
          fprintf(stderr, "http_client: timeout, calling llhttp_finish (status=%d, needs_eof=1, no body), ret=%d, complete=%d\n",
                  status_to_check, finish_ret, resp_parser.complete);
          if (finish_ret == HPE_OK && resp_parser.complete) {
            // Message is now complete
            break;
          }
        } else {
          // Response should have a body but we haven't received it
          // This is an error - the body should have arrived
          fprintf(stderr, "http_client: timeout waiting for response body (status=%d, needs_eof=1)\n",
                  status_to_check);
        }
        }
        fprintf(stderr, "http_client: timeout waiting for response data\n");
      } else {
        fprintf(stderr, "http_client: select error: %s\n", strerror(errno));
      }
      http_client_disconnect(client);
      return NULL;
    }

    if (!FD_ISSET(client->socket_fd, &read_fds)) {
      fprintf(stderr, "http_client: socket not ready for reading\n");
      http_client_disconnect(client);
      return NULL;
    }

read_data:
    // Reset consecutive timeouts when we successfully read
    consecutive_timeouts = 0;

    // Read data - if recv() returns 0, that's EOF (connection closed)
    received = recv(client->socket_fd, buffer, sizeof(buffer), 0);
    if (received <= 0) {
      if (received == 0) {
        // Connection closed - finish parsing to get any response that was already received
        fprintf(stderr, "http_client: connection closed by peer (EOF), finishing parser\n");
        llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
        if (finish_ret == HPE_OK && resp_parser.complete) {
          // Response is complete, break out of loop to process it
          break;
        } else {
          // Response incomplete, but connection is closed - this is an error
          fprintf(stderr, "http_client: connection closed but response incomplete (finish_ret=%d, complete=%d)\n",
                  finish_ret, resp_parser.complete);
          http_client_disconnect(client);
          return NULL;
        }
      } else {
        // Check if it's a temporary error that we should retry
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          // This shouldn't happen if socket is blocking, but retry once
          fprintf(stderr, "http_client: recv would block, retrying...\n");
          continue;
        }
        fprintf(stderr, "http_client: recv error: %s\n", strerror(errno));
        http_client_disconnect(client);
        return NULL;
      }
    }

    fprintf(stderr, "http_client: received %d bytes of response\n", received);

    // Create a copy of the buffer for the parser to avoid any issues with
    // the parser storing pointers into the buffer
    parse_buffer = malloc(received);
    if (!parse_buffer) {
      fprintf(stderr, "http_client: failed to allocate parse buffer\n");
      http_client_disconnect(client);
      return NULL;
    }
    memcpy(parse_buffer, buffer, received);

    // Replace RTSP/1.0 with HTTP/1.0 ONLY in the status line (before first \r\n)
    // The llhttp parser expects HTTP, not RTSP, but the formats are identical
    // We must only replace in the status line to avoid corrupting binary plist data in body
    if (!resp_parser.protocol_replaced && received >= 8) {
      // Find the end of the status line (first \r\n) to ensure we only replace in status line
      int status_line_end = -1;
      for (int i = 0; i < received - 1; i++) {
        if (parse_buffer[i] == '\r' && parse_buffer[i + 1] == '\n') {
          status_line_end = i;
          break;
        }
      }

      // Only replace if we found the status line boundary and the replacement is within it
      // The status line format is: "RTSP/1.0 200 OK\r\n" or "RTSP/1.1 200 OK\r\n"
      if (status_line_end >= 7 && strncmp(parse_buffer, "RTSP/1.", 7) == 0) {
        // Safe to modify: we're only changing "RTSP" to "HTTP" (4 bytes)
        // This works for both RTSP/1.0 and RTSP/1.1
        memcpy(parse_buffer, "HTTP", 4);
        resp_parser.protocol_replaced = 1;
        fprintf(stderr, "http_client: replaced RTSP/1. with HTTP/1. in response status line\n");
      }
    }

    ret = llhttp_execute(&resp_parser.parser, parse_buffer, received);
    free(parse_buffer);

    if (ret != 0) {
      fprintf(stderr, "http_client: parser error: %d\n", ret);
      http_client_disconnect(client);
      return NULL;
    }

    // Debug: check parser state after parsing
    if (!resp_parser.complete) {
      llhttp_errno_t parser_err = llhttp_get_errno(&resp_parser.parser);
      int needs_eof = llhttp_message_needs_eof(&resp_parser.parser);
      // Get status code from parser (it's set after status line is parsed)
      // Access parser.status_code directly since llhttp_get_status_code might not be available
      int parser_status = resp_parser.parser.status_code;
      fprintf(stderr, "http_client: message not complete yet, parser_err=%d, needs_eof=%d, "
              "content_length=%llu, body_len=%d, parser_status=%d\n", parser_err, needs_eof,
              (unsigned long long)resp_parser.parser.content_length, resp_parser.body_len, parser_status);

      // Update status code if parser has it (even if message isn't complete yet)
      if (parser_status > 0 && resp_parser.status_code == 0) {
        resp_parser.status_code = parser_status;
      }

      // If we have headers but no body, check for EOF immediately (receiver might have disconnected)
      if (parser_err == HPE_OK && needs_eof && resp_parser.body_len == 0 && resp_parser.headers != NULL) {
        // Check if connection is closed right after receiving headers
        int flags = fcntl(client->socket_fd, F_GETFL, 0);
        if (flags != -1) {
          fcntl(client->socket_fd, F_SETFL, flags | O_NONBLOCK);
          char eof_check[1];
          int eof_ret = recv(client->socket_fd, eof_check, 1, MSG_PEEK);
          fcntl(client->socket_fd, F_SETFL, flags & ~O_NONBLOCK);
          if (eof_ret == 0) {
            // Connection closed - finish parsing to get the response
            fprintf(stderr, "http_client: connection closed after headers (EOF detected), finishing parser\n");
            llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
            if (finish_ret == HPE_OK && resp_parser.complete) {
              break;
            }
          }
        }
        // Response might be complete (no body), but we can't be sure until we try to read more
        // Continue the loop - if select() times out, we'll handle it there
      }

      // If parser is in valid state and doesn't need EOF, check if we've received all data
      if (parser_err == HPE_OK && !needs_eof) {
        // Check if content_length is 0 or we've received all expected data
        if (resp_parser.parser.content_length == 0 ||
            (resp_parser.parser.content_length > 0 &&
             resp_parser.body_len >= (int)resp_parser.parser.content_length)) {
          // Message should be complete, try calling finish
          llhttp_errno_t finish_ret = llhttp_finish(&resp_parser.parser);
          fprintf(stderr, "http_client: called llhttp_finish (content_length match), ret=%d, complete=%d\n",
                  finish_ret, resp_parser.complete);
          if (finish_ret == HPE_OK && resp_parser.complete) {
            // Message is now complete
            break;
          }
        }
      }
    }
  }

  fprintf(stderr, "http_client: response complete, status: %d\n", resp_parser.status_code);

  response = calloc(1, sizeof(http_client_response_t));
  if (!response) {
    return NULL;
  }

  response->status_code = resp_parser.status_code;
  response->headers = resp_parser.headers;
  response->body = resp_parser.body;
  response->body_len = resp_parser.body_len;

  return response;
}

void
http_client_disconnect(http_client_t *client)
{
  assert(client);

  if (client->socket_fd != -1) {
    closesocket(client->socket_fd);
    client->socket_fd = -1;
  }
  client->connected = 0;
}

void
http_client_destroy(http_client_t *client)
{
  if (client) {
    http_client_disconnect(client);
    free(client->host);
    free(client);
  }
}

void
http_client_response_destroy(http_client_response_t *response)
{
  if (response) {
    free(response->headers);
    free(response->body);
    free(response);
  }
}

server_info_t *
http_client_get_info(http_client_t *client)
{
  http_client_response_t *response;
  plist_t root_node = NULL;
  plist_t node;
  server_info_t *info;

  assert(client);

  response = http_client_request(client, "GET", "/info", NULL, NULL, 0);
  if (!response || response->status_code != 200) {
    if (response) {
      http_client_response_destroy(response);
    }
    return NULL;
  }

  if (!response->body || response->body_len == 0) {
    http_client_response_destroy(response);
    return NULL;
  }

  // Validate that body starts with binary plist magic
  if (response->body_len < 8 || memcmp(response->body, "bplist00", 8) != 0) {
    fprintf(stderr, "http_client: invalid plist data (length=%d, magic=%.8s)\n",
            response->body_len, response->body_len >= 8 ? response->body : "too short");
    http_client_response_destroy(response);
    return NULL;
  }

  fprintf(stderr, "http_client: parsing plist (length=%d, first 16 bytes: ", response->body_len);
  for (int i = 0; i < 16 && i < response->body_len; i++) {
    fprintf(stderr, "%02x ", (unsigned char)response->body[i]);
  }
  fprintf(stderr, ")\n");

  plist_from_bin(response->body, response->body_len, &root_node);
  if (!root_node) {
    http_client_response_destroy(response);
    return NULL;
  }

  info = calloc(1, sizeof(server_info_t));
  if (!info) {
    plist_free(root_node);
    http_client_response_destroy(response);
    return NULL;
  }

  node = plist_dict_get_item(root_node, "features");
  if (node && plist_get_node_type(node) == PLIST_UINT) {
    uint64_t val;
    plist_get_uint_val(node, &val);
    info->features = val;
    printf("http_client: extracted features: 0x%llx\n", (unsigned long long)info->features);
  }

  node = plist_dict_get_item(root_node, "sourceVersion");
  if (node && plist_get_node_type(node) == PLIST_STRING) {
    char *val;
    plist_get_string_val(node, &val);
    info->sourceVersion = val;
    printf("http_client: extracted sourceVersion: %s\n", info->sourceVersion ? info->sourceVersion : "(null)");
  }

  node = plist_dict_get_item(root_node, "deviceID");
  if (node && plist_get_node_type(node) == PLIST_STRING) {
    char *val;
    plist_get_string_val(node, &val);
    info->deviceID = val;
    printf("http_client: extracted deviceID: %s\n", info->deviceID ? info->deviceID : "(null)");
  }

  /* Parse audioFormats array */
  node = plist_dict_get_item(root_node, "audioFormats");
  if (node && PLIST_IS_ARRAY(node)) {
    uint32_t count = plist_array_get_size(node);
    printf("http_client: found audioFormats array with %u entries\n", count);
    if (count > 0) {
      info->audioFormats = calloc(count, sizeof(audio_format_t));
      if (info->audioFormats) {
        info->audioFormatsCount = 0;
        for (uint32_t i = 0; i < count; i++) {
          plist_t format_node = plist_array_get_item(node, i);
          if (format_node && PLIST_IS_DICT(format_node)) {
            plist_t type_node = plist_dict_get_item(format_node, "type");
            if (type_node && plist_get_node_type(type_node) == PLIST_UINT) {
              plist_get_uint_val(type_node, &info->audioFormats[info->audioFormatsCount].type);
            }
            plist_t input_node = plist_dict_get_item(format_node, "audioInputFormats");
            if (input_node && plist_get_node_type(input_node) == PLIST_UINT) {
              plist_get_uint_val(input_node, &info->audioFormats[info->audioFormatsCount].audioInputFormats);
            }
            plist_t output_node = plist_dict_get_item(format_node, "audioOutputFormats");
            if (output_node && plist_get_node_type(output_node) == PLIST_UINT) {
              plist_get_uint_val(output_node, &info->audioFormats[info->audioFormatsCount].audioOutputFormats);
            }
            printf("http_client: audioFormat[%d]: type=%llu, inputFormats=0x%llx, outputFormats=0x%llx\n",
                   info->audioFormatsCount,
                   (unsigned long long)info->audioFormats[info->audioFormatsCount].type,
                   (unsigned long long)info->audioFormats[info->audioFormatsCount].audioInputFormats,
                   (unsigned long long)info->audioFormats[info->audioFormatsCount].audioOutputFormats);
            info->audioFormatsCount++;
          }
        }
        printf("http_client: extracted %d audio format(s)\n", info->audioFormatsCount);
      }
    }
  } else {
    printf("http_client: no audioFormats array found\n");
  }

  /* Parse displays array */
  node = plist_dict_get_item(root_node, "displays");
  if (node && PLIST_IS_ARRAY(node)) {
    uint32_t count = plist_array_get_size(node);
    printf("http_client: found displays array with %u entries\n", count);
    if (count > 0) {
      info->displays = calloc(count, sizeof(display_t));
      if (info->displays) {
        info->displaysCount = 0;
        for (uint32_t i = 0; i < count; i++) {
          plist_t display_node = plist_array_get_item(node, i);
          if (display_node && PLIST_IS_DICT(display_node)) {
            plist_t uuid_node = plist_dict_get_item(display_node, "uuid");
            if (uuid_node && plist_get_node_type(uuid_node) == PLIST_STRING) {
              char *val;
              plist_get_string_val(uuid_node, &val);
              info->displays[info->displaysCount].uuid = val;
            }
            plist_t width_phys_node = plist_dict_get_item(display_node, "widthPhysical");
            if (width_phys_node && plist_get_node_type(width_phys_node) == PLIST_BOOLEAN) {
              uint8_t val;
              plist_get_bool_val(width_phys_node, &val);
              info->displays[info->displaysCount].widthPhysical = val;
            }
            plist_t height_phys_node = plist_dict_get_item(display_node, "heightPhysical");
            if (height_phys_node && plist_get_node_type(height_phys_node) == PLIST_BOOLEAN) {
              uint8_t val;
              plist_get_bool_val(height_phys_node, &val);
              info->displays[info->displaysCount].heightPhysical = val;
            }
            plist_t width_node = plist_dict_get_item(display_node, "width");
            if (width_node && plist_get_node_type(width_node) == PLIST_UINT) {
              plist_get_uint_val(width_node, &info->displays[info->displaysCount].width);
            }
            plist_t height_node = plist_dict_get_item(display_node, "height");
            if (height_node && plist_get_node_type(height_node) == PLIST_UINT) {
              plist_get_uint_val(height_node, &info->displays[info->displaysCount].height);
            }
            plist_t width_pixels_node = plist_dict_get_item(display_node, "widthPixels");
            if (width_pixels_node && plist_get_node_type(width_pixels_node) == PLIST_UINT) {
              plist_get_uint_val(width_pixels_node, &info->displays[info->displaysCount].widthPixels);
            }
            plist_t height_pixels_node = plist_dict_get_item(display_node, "heightPixels");
            if (height_pixels_node && plist_get_node_type(height_pixels_node) == PLIST_UINT) {
              plist_get_uint_val(height_pixels_node, &info->displays[info->displaysCount].heightPixels);
            }
            plist_t rotation_node = plist_dict_get_item(display_node, "rotation");
            if (rotation_node && plist_get_node_type(rotation_node) == PLIST_BOOLEAN) {
              uint8_t val;
              plist_get_bool_val(rotation_node, &val);
              info->displays[info->displaysCount].rotation = val;
            }
            plist_t refresh_rate_node = plist_dict_get_item(display_node, "refreshRate");
            if (refresh_rate_node && plist_get_node_type(refresh_rate_node) == PLIST_UINT) {
              plist_get_uint_val(refresh_rate_node, &info->displays[info->displaysCount].refreshRate);
            }
            plist_t max_fps_node = plist_dict_get_item(display_node, "maxFPS");
            if (max_fps_node && plist_get_node_type(max_fps_node) == PLIST_UINT) {
              plist_get_uint_val(max_fps_node, &info->displays[info->displaysCount].maxFPS);
            }
            plist_t overscanned_node = plist_dict_get_item(display_node, "overscanned");
            if (overscanned_node && plist_get_node_type(overscanned_node) == PLIST_BOOLEAN) {
              uint8_t val;
              plist_get_bool_val(overscanned_node, &val);
              info->displays[info->displaysCount].overscanned = val;
            }
            plist_t features_node = plist_dict_get_item(display_node, "features");
            if (features_node && plist_get_node_type(features_node) == PLIST_UINT) {
              plist_get_uint_val(features_node, &info->displays[info->displaysCount].features);
            }
            printf("http_client: display[%d]: uuid=%s, width=%llu, height=%llu, widthPixels=%llu, heightPixels=%llu, refreshRate=%llu, maxFPS=%llu, overscanned=%u, features=0x%llx\n",
                   info->displaysCount,
                   info->displays[info->displaysCount].uuid ? info->displays[info->displaysCount].uuid : "(null)",
                   (unsigned long long)info->displays[info->displaysCount].width,
                   (unsigned long long)info->displays[info->displaysCount].height,
                   (unsigned long long)info->displays[info->displaysCount].widthPixels,
                   (unsigned long long)info->displays[info->displaysCount].heightPixels,
                   (unsigned long long)info->displays[info->displaysCount].refreshRate,
                   (unsigned long long)info->displays[info->displaysCount].maxFPS,
                   info->displays[info->displaysCount].overscanned,
                   (unsigned long long)info->displays[info->displaysCount].features);
            info->displaysCount++;
          }
        }
        printf("http_client: extracted %d display(s)\n", info->displaysCount);
      }
    }
  } else {
    printf("http_client: no displays array found\n");
  }

  plist_free(root_node);
  http_client_response_destroy(response);

  return info;
}

void
server_info_destroy(server_info_t *info)
{
  if (info) {
    free(info->sourceVersion);
    free(info->deviceID);
    if (info->audioFormats) {
      free(info->audioFormats);
    }
    if (info->displays) {
      for (int i = 0; i < info->displaysCount; i++) {
        free(info->displays[i].uuid);
      }
      free(info->displays);
    }
    free(info);
  }
}
