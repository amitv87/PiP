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
#include <inttypes.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "sender.h"
#include "../airplay/ed25519/sha512.h"
#include "../airplay/byteutils.h"
#include "discovery.h"
#include "http_client.h"
#include "pairing_client.h"
#include "hap_pairing.h"
#include "fairplay_client.h"
#include "stream_client.h"
#include "ntp_client.h"
#include "video_encoder.h"
#include "video_packetizer.h"
#include "mirror_crypto.h"
#include "frame_capture.h"
#include "audio_capture.h"
#include "audio_encoder.h"
#include "rtp_audio.h"

struct sender_s {
  sender_state_t state;
  sender_state_callback_t state_callback;
  void *state_callback_ctx;

  // Components
  http_client_t *http_client;
  pairing_client_t *pairing_client;
  fairplay_client_t *fairplay_client;
  stream_client_t *stream_client;
  ntp_client_t *ntp_client;
  video_encoder_t *video_encoder;
  video_packetizer_t *video_packetizer;
  frame_capture_t *frame_capture;
  audio_capture_t *audio_capture;
  audio_encoder_t *audio_encoder;
  rtp_audio_t *rtp_audio;

  // Connection info
  char *receiver_host;
  uint16_t receiver_port;
  stream_info_t stream_info;

  // FairPlay session key (16 bytes)
  unsigned char fairplay_session_key[16];
  unsigned char fp_aes_key[16];  // raw playfair_decrypt output (ChaCha HKDF IKM)
  int fairplay_initialized;
  int use_hap;    // 1 = HAP pairing + ChaCha video; 0 = raw pairing + AES-CTR video
  int apple_rx;   // 1 = Apple receiver frame format (per-AU, LE boot-relative NTP,
                  //     per-keyframe codec); 0 = PiP's own/loopback format (per-NAL,
                  //     BE microsecond NTP). Set for both HAP and raw-Apple modes.

  // ECDH shared secret (32 bytes) for audio AES key hashing
  unsigned char ecdh_secret[32];

  // Streaming state
  int streaming;
  void *source_id;
  uint64_t video_stream_start_time;  // Local time (microseconds) when video streaming started

  // Video AES key and IV (derived from stream connection ID)
  unsigned char video_aes_key[16];
  unsigned char video_aes_iv[16];
  int video_encryption_initialized;

  // NTP timing responder: for AirPlay 2 mirroring the sender is the timing
  // server. The receiver probes this UDP port before completing SETUP.
  int timing_fd;
  pthread_t timing_thread;
  volatile int timing_running;
  uint16_t timing_local_port;

  // Audio control UDP port advertised in the audio (type 96) SETUP.
  int audio_ctrl_fd;
  uint16_t audio_ctrl_port;

  // Session UUID shared across SETUP/RECORD.
  char session_uuid[40];

  // Boot-relative NTP anchor for video frame timestamps (matches timing responder base).
  uint64_t video_stream_start_ntp;
};

// NTP timestamp: boot-relative time + 1900 epoch, as 64-bit fixed point.
static uint64_t
sender_ntp_boot_timestamp(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  uint64_t sec = (uint64_t)ts.tv_sec + 2208988800ULL; // 1900 -> 1970
  uint64_t frac = ((uint64_t)ts.tv_nsec << 32) / 1000000000ULL;
  return (sec << 32) | frac;
}

// Convert a microsecond duration to 64-bit NTP fixed-point (no overflow).
static uint64_t
us_to_ntp(uint64_t us)
{
  uint64_t sec = us / 1000000ULL;
  uint64_t usec = us % 1000000ULL;
  return (sec << 32) | ((usec << 32) / 1000000ULL);
}

// Display lead so the receiver has a small playout buffer (~100 ms).
#define VIDEO_NTP_BIAS 429496729ULL

static void
put_be64(uint8_t *p, uint64_t v)
{
  for (int i = 0; i < 8; i++) {
    p[i] = (uint8_t)(v >> (56 - 8 * i));
  }
}

// Responds to the receiver's NTP timing probes (port model mirrors doubletake's
// ntpTimingResponder). Runs until timing_running is cleared.
static void *
timing_responder_thread(void *arg)
{
  sender_t *s = (sender_t *)arg;
  uint8_t buf[128];
  int probe_count = 0;

  while (s->timing_running) {
    struct sockaddr_in from;
    socklen_t fl = sizeof(from);
    ssize_t n = recvfrom(s->timing_fd, buf, sizeof(buf), 0,
                         (struct sockaddr *)&from, &fl);
    if (n < 32) {
      continue; // timeout (SO_RCVTIMEO) or short packet
    }

    // Diagnostic: confirms the receiver can reach our timing port and is
    // actively engaging with the media session.
    if (probe_count < 3) {
      fprintf(stderr, "sender: timing responder got probe #%d (%zd bytes) from %s:%u\n",
              probe_count, n, inet_ntoa(from.sin_addr), ntohs(from.sin_port));
    }
    probe_count++;

    uint8_t reply[32];
    memcpy(reply, buf, 32);
    reply[0] = 0x80;
    reply[1] = 0xd3;
    // reference timestamp = the sender's transmit timestamp (bytes 24..31)
    memcpy(reply + 8, buf + 24, 8);
    uint64_t now = sender_ntp_boot_timestamp();
    put_be64(reply + 16, now); // receive timestamp
    put_be64(reply + 24, now); // transmit timestamp

    sendto(s->timing_fd, reply, sizeof(reply), 0,
           (struct sockaddr *)&from, fl);
  }
  return NULL;
}

static int
sender_start_timing_responder(sender_t *s)
{
  s->timing_fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (s->timing_fd < 0) {
    return -1;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = 0; // ephemeral
  if (bind(s->timing_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(s->timing_fd);
    s->timing_fd = -1;
    return -1;
  }
  socklen_t sl = sizeof(addr);
  if (getsockname(s->timing_fd, (struct sockaddr *)&addr, &sl) < 0) {
    close(s->timing_fd);
    s->timing_fd = -1;
    return -1;
  }
  s->timing_local_port = ntohs(addr.sin_port);

  // Recv timeout so the thread can observe timing_running and exit.
  struct timeval tv = {0, 250000}; // 250 ms
  setsockopt(s->timing_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

  s->timing_running = 1;
  if (pthread_create(&s->timing_thread, NULL, timing_responder_thread, s) != 0) {
    s->timing_running = 0;
    close(s->timing_fd);
    s->timing_fd = -1;
    return -1;
  }
  fprintf(stderr, "sender: NTP timing responder listening on UDP port %u\n",
          s->timing_local_port);
  return 0;
}

static void
sender_stop_timing_responder(sender_t *s)
{
  if (s->timing_running) {
    s->timing_running = 0;
    pthread_join(s->timing_thread, NULL);
  }
  if (s->timing_fd >= 0) {
    close(s->timing_fd);
    s->timing_fd = -1;
  }
  if (s->audio_ctrl_fd >= 0) {
    close(s->audio_ctrl_fd);
    s->audio_ctrl_fd = -1;
  }
}

// Bind a UDP socket to an ephemeral port; returns the port (0 on failure).
static uint16_t
bind_udp_ephemeral(int *out_fd)
{
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return 0;
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = 0;
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return 0; }
  socklen_t sl = sizeof(addr);
  if (getsockname(fd, (struct sockaddr *)&addr, &sl) < 0) { close(fd); return 0; }
  *out_fd = fd;
  return ntohs(addr.sin_port);
}

static void
sender_set_state(sender_t *s, sender_state_t new_state, const char *error)
{
  assert(s);

  if (s->state == new_state) {
    return;
  }

  s->state = new_state;

  if (s->state_callback) {
    s->state_callback(new_state, error, s->state_callback_ctx);
  }
}

static void
cleanup_components(sender_t *s)
{
  sender_stop_timing_responder(s);

  if (s->rtp_audio) {
    rtp_audio_destroy(s->rtp_audio);
    s->rtp_audio = NULL;
  }

  if (s->audio_encoder) {
    audio_encoder_destroy(s->audio_encoder);
    s->audio_encoder = NULL;
  }

  if (s->audio_capture) {
    audio_capture_destroy(s->audio_capture);
    s->audio_capture = NULL;
  }

  if (s->frame_capture) {
    frame_capture_destroy(s->frame_capture);
    s->frame_capture = NULL;
  }

  if (s->video_packetizer) {
    video_packetizer_destroy(s->video_packetizer);
    s->video_packetizer = NULL;
  }

  if (s->video_encoder) {
    video_encoder_destroy(s->video_encoder);
    s->video_encoder = NULL;
  }

  if (s->ntp_client) {
    ntp_client_destroy(s->ntp_client);
    s->ntp_client = NULL;
  }

  if (s->stream_client) {
    stream_client_disconnect_video(s->stream_client);
    stream_client_disconnect_feedback(s->stream_client);
    stream_client_destroy(s->stream_client);
    s->stream_client = NULL;
  }

  if (s->fairplay_client) {
    fairplay_client_destroy(s->fairplay_client);
    s->fairplay_client = NULL;
  }

  if (s->pairing_client) {
    pairing_client_destroy(s->pairing_client);
    s->pairing_client = NULL;
  }

  if (s->http_client) {
    http_client_disconnect(s->http_client);
    http_client_destroy(s->http_client);
    s->http_client = NULL;
  }

  s->fairplay_initialized = 0;
  s->streaming = 0;
}

sender_t *
sender_init(void)
{
  sender_t *s;

  s = calloc(1, sizeof(sender_t));
  if (!s) {
    return NULL;
  }

  s->state = SENDER_STATE_IDLE;
  s->state_callback = NULL;
  s->state_callback_ctx = NULL;
  s->http_client = NULL;
  s->pairing_client = NULL;
  s->fairplay_client = NULL;
  s->stream_client = NULL;
  s->ntp_client = NULL;
  s->video_encoder = NULL;
  s->video_packetizer = NULL;
  s->frame_capture = NULL;
  s->audio_capture = NULL;
  s->audio_encoder = NULL;
  s->rtp_audio = NULL;
  s->receiver_host = NULL;
  s->receiver_port = 0;
  s->fairplay_initialized = 0;
  s->streaming = 0;
  s->source_id = NULL;
  s->video_stream_start_time = 0;
  s->video_encryption_initialized = 0;
  s->timing_fd = -1;
  s->timing_running = 0;
  s->timing_local_port = 0;
  s->audio_ctrl_fd = -1;
  s->audio_ctrl_port = 0;

  return s;
}

// Callback: Encoded video frame -> packetizer
static void
on_encoded_frame(uint8_t *data, int len, bool is_keyframe,
                uint8_t *sps, int sps_len, uint8_t *pps, int pps_len,
                uint64_t pts, void *ctx)
{
  sender_t *s = (sender_t *)ctx;
  uint64_t ntp_timestamp;
  uint64_t absolute_local_time;
  static int encoded_count = 0;

  if (!s || !s->video_packetizer || !s->ntp_client) {
    if (encoded_count == 0 || encoded_count % 30 == 0) {
      fprintf(stderr, "sender: on_encoded_frame - sender=%p, packetizer=%p, ntp=%p\n",
              (void *)s, (void *)(s ? s->video_packetizer : NULL), (void *)(s ? s->ntp_client : NULL));
    }
    return;
  }

  // Timestamp basis follows the receiver frame format (apple_rx), independent of
  // the cipher:
  //  - Apple receivers (HAP or raw): little-endian boot-relative NTP, sharing
  //    the clock base with our NTP timing responder (matches airfry).
  //  - PiP's own receiver (loopback): big-endian microsecond NTP.
  if (s->apple_rx) {
    if (pts == 0 && s->video_stream_start_ntp == 0) {
      s->video_stream_start_ntp = sender_ntp_boot_timestamp();
    }
    ntp_timestamp = s->video_stream_start_ntp + us_to_ntp(pts) + VIDEO_NTP_BIAS;
  } else {
    if (pts == 0 && s->video_stream_start_time == 0) {
      s->video_stream_start_time = ntp_client_get_local_time(s->ntp_client);
    }
    absolute_local_time = s->video_stream_start_time + pts;
    ntp_timestamp = ntp_client_convert_to_ntp(s->ntp_client, absolute_local_time);
  }

  if (encoded_count == 0 || encoded_count % 30 == 0) {
    fprintf(stderr, "sender: on_encoded_frame - frame %d, len=%d, keyframe=%d, pts=%" PRIu64 ", ntp=%" PRIu64 "\n",
            encoded_count, len, is_keyframe, pts, ntp_timestamp);
  }

  // Packetize and send
  int result = video_packetizer_packetize(s->video_packetizer, data, len, is_keyframe,
                                          sps, sps_len, pps, pps_len, ntp_timestamp);
  if (result != 0 && (encoded_count == 0 || encoded_count % 30 == 0)) {
    fprintf(stderr, "sender: video_packetizer_packetize failed: %d\n", result);
  }

  encoded_count++;
}

// Callback: Packetized video data -> stream client
static void
on_packetized_video(const uint8_t *packet, int packet_len, void *ctx)
{
  sender_t *s = (sender_t *)ctx;
  static int packet_count = 0;

  if (!s || !s->stream_client || packet_len < 128) {
    if (packet_count == 0 || packet_count % 30 == 0) {
      fprintf(stderr, "sender: on_packetized_video - sender=%p, stream_client=%p, len=%d\n",
              (void *)s, (void *)(s ? s->stream_client : NULL), packet_len);
    }
    return;
  }

  if (packet_count == 0 || packet_count % 30 == 0) {
    fprintf(stderr, "sender: on_packetized_video - packet %d, len=%d\n", packet_count, packet_len);
  }

  // Send raw packet (header + encrypted payload) directly via stream client
  int result = stream_client_send_raw_video_packet(s->stream_client, packet, packet_len);
  if (result != 0 && (packet_count == 0 || packet_count % 30 == 0)) {
    fprintf(stderr, "sender: stream_client_send_raw_video_packet failed: %d\n", result);
  }

  packet_count++;
}

// Callback: Captured frame -> video encoder
static void
on_captured_frame(uint8_t *rgba_data, int width, int height, int stride,
                 uint64_t pts, void *ctx)
{
  sender_t *s = (sender_t *)ctx;
  static int frame_count = 0;

  if (!s || !s->video_encoder) {
    if (frame_count == 0 || frame_count % 30 == 0) {
      fprintf(stderr, "sender: on_captured_frame - sender=%p, encoder=%p\n",
              (void *)s, (void *)(s ? s->video_encoder : NULL));
    }
    return;
  }

  if (frame_count == 0 || frame_count % 30 == 0) {
    fprintf(stderr, "sender: on_captured_frame - frame %d, %dx%d, stride=%d, pts=%" PRIu64 "\n",
            frame_count, width, height, stride, pts);
  }

  int result = video_encoder_encode_frame(s->video_encoder, rgba_data, stride, pts);
  if (result != 0 && (frame_count == 0 || frame_count % 30 == 0)) {
    fprintf(stderr, "sender: video_encoder_encode_frame failed: %d\n", result);
  }

  frame_count++;
}

// Callback: Encoded audio -> RTP
static void
on_encoded_audio(uint8_t *data, int data_len, uint64_t pts, void *ctx)
{
  sender_t *s = (sender_t *)ctx;

  if (!s || !s->rtp_audio) {
    return;
  }

  rtp_audio_send(s->rtp_audio, data, data_len, pts);
}

// Callback: Captured audio samples -> audio encoder
static void
on_captured_audio(float *samples, int num_frames, int channels,
                 int sample_rate, uint64_t pts, void *ctx)
{
  sender_t *s = (sender_t *)ctx;

  if (!s || !s->audio_encoder) {
    return;
  }

  audio_encoder_encode(s->audio_encoder, samples, num_frames, pts);
}

void
sender_set_state_callback(sender_t *s, sender_state_callback_t cb, void *ctx)
{
  assert(s);
  s->state_callback = cb;
  s->state_callback_ctx = ctx;
}

int
sender_connect(sender_t *s, airplay_receiver_t *receiver,
               const char *device_id, const char *os_name,
               const char *os_version, const char *model, const char *name)
{
  unsigned char shared_secret[32];
  unsigned char fairplay_session_key[32];
  unsigned char audio_aes_key[16];
  stream_info_t stream_info;

  assert(s);
  assert(receiver);
  assert(device_id);
  assert(os_name);
  assert(os_version);
  assert(model);

  if (s->state != SENDER_STATE_IDLE) {
    return -1;
  }

  sender_set_state(s, SENDER_STATE_CONNECTING, NULL);

  // Initialize HTTP client
  s->http_client = http_client_init(receiver->host, receiver->port);
  if (!s->http_client) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize HTTP client");
    return -1;
  }

  if (http_client_connect(s->http_client) != 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to connect to receiver");
    cleanup_components(s);
    return -1;
  }

  // Store receiver info
  s->receiver_host = strdup(receiver->host);
  s->receiver_port = receiver->port;

  // Step 1 & 2: Pairing + receiver profile (PIP_PAIRING):
  //   hap  → HAP SRP-6a transient pair-setup + X25519 pair-verify + encrypted
  //          control channel + ChaCha video + Apple frame format. For receivers
  //          that accept PIN-less HAP transient pairing.
  //   raw  → legacy/UxPlay raw pair-setup + raw pair-verify (plaintext control)
  //          + AES-CTR video + Apple frame format. This is what real
  //          Apple-compatible receivers (e.g. the Motorola SoftMedia receiver)
  //          that reject PIN-less HAP transient use — same path airfry tries
  //          FIRST. No PIN required.
  //   unset→ raw pairing + AES-CTR + PiP's own/loopback frame format (BE
  //          microsecond NTP, per-NAL), which the PiP receiver expects.
  // Both hap and raw talk to Apple-format receivers (apple_rx=1); only the
  // default (loopback) uses PiP's own frame format.
  sender_set_state(s, SENDER_STATE_PAIRING, NULL);

  const char *pairing_mode = getenv("PIP_PAIRING");
  int want_raw_apple = (pairing_mode && strcmp(pairing_mode, "raw") == 0);
  int no_encrypt = (getenv("PIP_NOENC") != NULL);
  if (no_encrypt) {
    // Unencrypted mirroring test: replicate macOS's flow MINUS FairPlay. No
    // pairing, no fp-setup, no ekey in SETUP, and plaintext H.264 frames. Only
    // works if this receiver tolerates unencrypted mirror video (macOS itself
    // uses ET:32, so this is a probe of whether et=0 is accepted).
    s->apple_rx = 1;
    memset(shared_secret, 0, 32);
    fprintf(stderr, "sender: PIP_NOENC - no pairing / no FairPlay / plaintext video (Apple frame format)\n");
  } else if (pairing_mode && strcmp(pairing_mode, "hap") == 0) {
    char pid[40];
    unsigned char u[16];
    for (int i = 0; i < 16; i++) u[i] = (unsigned char)(rand() & 0xff);
    snprintf(pid, sizeof pid,
             "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
             u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
    hap_keys_t hk;
    if (hap_pair(s->http_client, pid, &hk) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "HAP pairing failed");
      cleanup_components(s);
      return -1;
    }
    memcpy(shared_secret, hk.shared_secret, 32);
    s->use_hap = 1;
    s->apple_rx = 1;  /* HAP receivers use the Apple frame format */
    /* pair-verify has switched the receiver into HAP-encrypted mode. From here
     * every RTSP request (fp-setup, SETUP, RECORD, SET_PARAMETER) MUST be
     * ChaCha20-Poly1305 framed on this socket, exactly as Apple's built-in
     * sender does. Without this the receiver decrypts our plaintext as garbage
     * and the whole session (including the video media key) desynchronises. */
    http_client_enable_encryption(s->http_client, hk.write_key, hk.read_key);
    fprintf(stderr, "sender: HAP pairing OK; encrypted control channel + Apple video profile (ChaCha+LE)\n");
  } else {
    s->pairing_client = pairing_client_init();
    if (!s->pairing_client) {
      sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize pairing client");
      cleanup_components(s);
      return -1;
    }
    if (pairing_client_setup(s->pairing_client, s->http_client) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "Pair-setup failed");
      cleanup_components(s);
      return -1;
    }
    if (pairing_client_verify_step1(s->pairing_client, s->http_client) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "Pair-verify step 1 failed");
      cleanup_components(s);
      return -1;
    }
    if (pairing_client_verify_step2(s->pairing_client, s->http_client) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "Pair-verify step 2 failed");
      cleanup_components(s);
      return -1;
    }
    if (pairing_client_get_shared_secret(s->pairing_client, shared_secret) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "Failed to get shared secret");
      cleanup_components(s);
      return -1;
    }
    // Raw pairing serves both the Apple-format path (PIP_PAIRING=raw, e.g. the
    // Motorola receiver) and the PiP loopback. The pairing bytes are identical;
    // only the video frame format differs (apple_rx).
    if (want_raw_apple) {
      s->apple_rx = 1;
      fprintf(stderr, "sender: raw pairing OK; using Apple frame format (AES-CTR + LE boot NTP + per-AU)\n");
    }
  }

  // Store ECDH/HAP shared secret (audio AES key hash + ChaCha media key IKM).
  memcpy(s->ecdh_secret, shared_secret, 32);

  // Step 3: FairPlay Setup (skipped entirely for the unencrypted test).
  if (!no_encrypt) {
    s->fairplay_client = fairplay_client_init();
    if (!s->fairplay_client) {
      sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize FairPlay client");
      cleanup_components(s);
      return -1;
    }

    if (fairplay_client_setup(s->fairplay_client, s->http_client) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "FairPlay setup failed");
      cleanup_components(s);
      return -1;
    }

    if (fairplay_client_handshake(s->fairplay_client, s->http_client) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "FairPlay handshake failed");
      cleanup_components(s);
      return -1;
    }

    // Get FairPlay session key (this will be used to derive audio AES key)
    if (fairplay_client_get_session_key(s->fairplay_client, fairplay_session_key) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "Failed to get FairPlay session key");
      cleanup_components(s);
      return -1;
    }
  } else {
    memset(fairplay_session_key, 0, 16);
  }

  // Base AES key = the FairPlay-unwrapped key (playfair_decrypt output).
  memcpy(audio_aes_key, fairplay_session_key, 16);
  // Save the raw FairPlay key — also the IKM for ChaCha DataStream (HAP receivers).
  memcpy(s->fp_aes_key, fairplay_session_key, 16);
  s->fairplay_initialized = 1;

  // Stream key base for the AES-CTR video/audio key derivation:
  //  - PiP's own receiver (loopback) hashes the FairPlay key with the pair-verify
  //    ECDH secret: SHA512(fpKey || ecdh)[:16].
  //  - AirPlay-1 / UxPlay-style receivers (e.g. the Motorola AppleTV3,2 emulation,
  //    features=0xe) have NO pair-verify shared secret and derive the video key
  //    from the FairPlay key DIRECTLY. Mixing in ecdh corrupts it there.
  // Apple-format receivers (apple_rx) use the unmixed key unless PIP_MIX forces it.
  int mix_key = !s->apple_rx || getenv("PIP_MIX") != NULL;
  if (mix_key) {
    unsigned char hashed_audio_key[64];
    sha512_context ctx;
    sha512_init(&ctx);
    sha512_update(&ctx, audio_aes_key, 16);
    sha512_update(&ctx, s->ecdh_secret, 32);
    sha512_final(&ctx, hashed_audio_key);
    memcpy(s->fairplay_session_key, hashed_audio_key, 16);
    fprintf(stderr, "sender: stream key = SHA512(fpKey || ecdh)[:16] (mixed, PiP/loopback style)\n");
  } else {
    memcpy(s->fairplay_session_key, audio_aes_key, 16);
    fprintf(stderr, "sender: stream key = raw FairPlay key (unmixed, AirPlay-1/UxPlay style)\n");
  }

  // Step 4: Stream Setup
  s->stream_client = stream_client_init();
  if (!s->stream_client) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize stream client");
    cleanup_components(s);
    return -1;
  }

  // Step 4: Stream Setup (AirPlay 2 mirroring)

  // We are the NTP timing server for the session — the receiver probes this
  // UDP port before completing SETUP. Start it before sending SETUP.
  if (sender_start_timing_responder(s) != 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to start timing responder");
    cleanup_components(s);
    return -1;
  }

  // A session UUID shared by SETUP and RECORD.
  {
    unsigned char u[16];
    for (int i = 0; i < 16; i++) {
      u[i] = (unsigned char)(rand() & 0xff);
    }
    snprintf(s->session_uuid, sizeof(s->session_uuid),
             "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
             u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
  }

  // GET /info RTSP/1.0 (real senders do this before SETUP)
  if (stream_client_get_info_rtsp(s->stream_client, s->http_client) != 0) {
    fprintf(stderr, "sender: warning - GET /info RTSP failed (non-fatal)\n");
  }

  // Random stream IV (also advertised as the stream shiv).
  unsigned char eiv[16];
  for (int i = 0; i < 16; i++) {
    eiv[i] = (unsigned char)(rand() & 0xff);
  }

  // FairPlay ekey (72-byte wrapped key) for the SETUP body. For the unencrypted
  // test we send NO ekey/eiv/shk/shiv, so the receiver treats video as plaintext.
  unsigned char ekey[72];
  const unsigned char *ekey_arg = NULL, *eiv_arg = NULL, *shk_arg = NULL, *shiv_arg = NULL;
  if (!no_encrypt) {
    if (fairplay_client_encrypt_key(s->fairplay_client, audio_aes_key, ekey) != 0) {
      sender_set_state(s, SENDER_STATE_ERROR, "Failed to encrypt key with FairPlay");
      cleanup_components(s);
      return -1;
    }
    ekey_arg = ekey; eiv_arg = eiv;
    shk_arg = s->fairplay_session_key; shiv_arg = eiv;
  }

  // Phase 1: create the session with an AUDIO (type 96) SETUP first. Real
  // senders (and doubletake) do this before the video stream; the receiver
  // attaches video to this session and only then renders. Skipping it is why
  // the receiver stalled ~5s and showed nothing.
  s->audio_ctrl_port = bind_udp_ephemeral(&s->audio_ctrl_fd);
  fprintf(stderr, "sender: audio control UDP port=%u\n", s->audio_ctrl_port);
  if (stream_client_setup_audio_rtsp(s->stream_client, s->http_client,
                                     s->receiver_host, s->receiver_port,
                                     ekey_arg, eiv_arg, s->timing_local_port, s->session_uuid,
                                     s->audio_ctrl_port, device_id, model, name) != 0) {
    fprintf(stderr, "sender: warning - audio (type 96) SETUP failed; continuing to video SETUP\n");
    // Non-fatal: some receivers may still accept a video-only session.
  }

  fprintf(stderr, "sender: sending mirroring SETUP (timingPort=%u, sessionUUID=%s)\n",
          s->timing_local_port, s->session_uuid);

  // Phase 2: AirPlay 2 mirroring video SETUP: our timing port, session context,
  // ekey/eiv at root, and shk/shiv (the FairPlay-derived stream key + IV).
  if (stream_client_setup_rtsp(s->stream_client, s->http_client,
                                s->receiver_host, s->receiver_port,
                                ekey_arg, eiv_arg, s->timing_local_port, s->session_uuid,
                                shk_arg, shiv_arg,
                                device_id, os_name, os_version, model, name) != 0) {
    fprintf(stderr, "sender: mirroring SETUP failed\n");
    sender_set_state(s, SENDER_STATE_ERROR, "RTSP SETUP failed");
    cleanup_components(s);
    return -1;
  }

  fprintf(stderr, "sender: first SETUP succeeded\n");

  // Get stream info from first SETUP response (already contains all ports including dataPort)
  // Real devices don't send a second SETUP - they use the dataPort from the first SETUP response
  if (stream_client_get_info(s->stream_client, &stream_info) != 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to get stream info from first SETUP");
    cleanup_components(s);
    return -1;
  }
  s->stream_info = stream_info;

  // Verify we got the dataPort from the first SETUP
  if (stream_info.data_port == 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "First SETUP did not return dataPort");
    cleanup_components(s);
    return -1;
  }

  fprintf(stderr, "sender: using dataPort=%d from first SETUP response\n", stream_info.data_port);

  // Connect the reverse event channel to the receiver's eventPort. Real senders
  // open this TCP channel; some receivers gate rendering on it. Non-fatal.
  if (stream_info.event_port != 0) {
    if (stream_client_connect_feedback(s->stream_client, s->receiver_host) == 0) {
      fprintf(stderr, "sender: connected event channel to receiver port %u\n",
              stream_info.event_port);
    } else {
      fprintf(stderr, "sender: warning - event channel connect to port %u failed\n",
              stream_info.event_port);
    }
  }

  // Initialize NTP client
  s->ntp_client = ntp_client_init();
  if (!s->ntp_client) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize NTP client");
    cleanup_components(s);
    return -1;
  }

  // Connect NTP client to receiver's timing port
  if (stream_info.timing_port != 0) {
    if (ntp_client_connect(s->ntp_client, s->receiver_host, stream_info.timing_port) != 0) {
      fprintf(stderr, "sender: warning - failed to connect NTP client\n");
      // Non-fatal, continue without NTP sync
    } else {
      fprintf(stderr, "sender: NTP client connected, performing sync\n");
      // Perform initial NTP sync
      if (ntp_client_sync(s->ntp_client) == 0) {
        int64_t offset = ntp_client_get_offset(s->ntp_client);
        fprintf(stderr, "sender: NTP sync successful, offset=%lld microseconds\n", (long long)offset);
      } else {
        fprintf(stderr, "sender: NTP sync failed\n");
      }
    }
  } else {
    fprintf(stderr, "sender: warning - no timing port available for NTP\n");
  }

  sender_set_state(s, SENDER_STATE_IDLE, NULL);
  return 0;
}

int
sender_start_mirroring(sender_t *s, void *source_id)
{
  unsigned char video_aes_key[16];
  unsigned char video_aes_iv[16];
  stream_info_t stream_info;

  assert(s);

  if (s->state != SENDER_STATE_IDLE) {
    return -1;
  }

  if (!s->stream_client || !s->fairplay_initialized) {
    return -1;
  }

  if (stream_client_get_info(s->stream_client, &stream_info) != 0) {
    return -1;
  }

  // Step 7: RTSP RECORD (iPad does this before connecting video stream)
  if (stream_client_record_rtsp(s->stream_client, s->http_client,
                                 s->receiver_host, s->receiver_port) != 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "RTSP RECORD failed");
    return -1;
  }

  // Connect video stream
  if (stream_client_connect_video(s->stream_client, s->receiver_host) != 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to connect video stream");
    return -1;
  }

  // Perform another NTP sync right before starting video to ensure accurate timestamps
  // Reset video stream start time
  s->video_stream_start_time = 0;
  s->video_stream_start_ntp = 0;

  if (s->ntp_client && stream_info.timing_port != 0) {
    fprintf(stderr, "sender: performing NTP sync before video start\n");
    ntp_client_sync(s->ntp_client);
    int64_t offset = ntp_client_get_offset(s->ntp_client);
    fprintf(stderr, "sender: NTP offset before video: %lld microseconds\n", (long long)offset);
  }

  // Initialize video encryption in stream_client
  // Audio AES key is derived from FairPlay session key
  // For now, use the FairPlay session key directly
  if (stream_client_init_video_encryption(s->stream_client, s->fairplay_session_key) != 0) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize video encryption");
    stream_client_disconnect_video(s->stream_client);
    return -1;
  }

  // Derive video AES key and IV from stream connection ID for packetizer
  // This matches stream_client_init_video_encryption logic
  char key_str[64];
  char iv_str[64];
  unsigned char aeskey_video[64];
  unsigned char aesiv_video[64];

  fprintf(stderr, "sender: deriving video AES key/IV with streamConnectionID=%llu\n",
          (unsigned long long)stream_info.stream_connection_id);
  fprintf(stderr, "sender: using fairplay_session_key (first 16 bytes): ");
  for (int i = 0; i < 16; i++) {
    fprintf(stderr, "%02x ", s->fairplay_session_key[i]);
  }
  fprintf(stderr, "\n");

  snprintf(key_str, sizeof(key_str), "AirPlayStreamKey%" PRIu64,
           stream_info.stream_connection_id);
  snprintf(iv_str, sizeof(iv_str), "AirPlayStreamIV%" PRIu64,
           stream_info.stream_connection_id);

  sha512_context ctx;
  sha512_init(&ctx);
  sha512_update(&ctx, (const unsigned char *)key_str, strlen(key_str));
  sha512_update(&ctx, s->fairplay_session_key, 16);
  sha512_final(&ctx, aeskey_video);

  sha512_init(&ctx);
  sha512_update(&ctx, (const unsigned char *)iv_str, strlen(iv_str));
  sha512_update(&ctx, s->fairplay_session_key, 16);
  sha512_final(&ctx, aesiv_video);

  memcpy(s->video_aes_key, aeskey_video, 16);
  memcpy(s->video_aes_iv, aesiv_video, 16);
  s->video_encryption_initialized = 1;

  fprintf(stderr, "sender: derived video AES key (first 16 bytes): ");
  for (int i = 0; i < 16; i++) {
    fprintf(stderr, "%02x ", s->video_aes_key[i]);
  }
  fprintf(stderr, "\n");
  fprintf(stderr, "sender: derived video AES IV (first 16 bytes): ");
  for (int i = 0; i < 16; i++) {
    fprintf(stderr, "%02x ", s->video_aes_iv[i]);
  }
  fprintf(stderr, "\n");

  // Initialize video packetizer
  s->video_packetizer = video_packetizer_init();
  if (!s->video_packetizer) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize video packetizer");
    stream_client_disconnect_video(s->stream_client);
    return -1;
  }

  // AES-CTR key/IV (used by the loopback per-NAL path AND the raw-Apple per-AU
  // path; the HAP path overrides with ChaCha below).
  video_packetizer_set_encryption(s->video_packetizer, s->video_aes_key, s->video_aes_iv);

  // Apple receiver frame format (HAP or raw pairing): one packet per access unit,
  // little-endian boot-relative NTP, codec packet resent per keyframe. Applies to
  // both the AES-CTR and ChaCha ciphers. Loopback keeps PiP's own format.
  if (s->apple_rx) {
    video_packetizer_set_apple_format(s->video_packetizer);
  }

  // Video cipher selection:
  //  - HAP pairing (use_hap) always uses ChaCha20-Poly1305 (Apple DataStream),
  //    keyed by HKDF-SHA512 over the HAP pair-verify shared secret.
  //  - Raw-Apple pairing defaults to AES-CTR (UxPlay style), BUT an Apple-only
  //    receiver (e.g. the Motorola) rejects UxPlay AES-CTR and expects the
  //    DataStream ChaCha cipher even over a plaintext-RTSP session. Since raw
  //    pair-verify also establishes an X25519 shared secret (s->ecdh_secret),
  //    PIP_VIDEO=chacha derives the ChaCha key from it — no PIN required.
  const char *video_cipher = getenv("PIP_VIDEO");
  int use_chacha = s->use_hap ||
                   (s->apple_rx && video_cipher && strcmp(video_cipher, "chacha") == 0);
  if (use_chacha) {
    const char *ikm_sel = getenv("PIP_CHACHA_IKM");
    const uint8_t *ikm;
    size_t ikm_len;
    const char *ikm_name;
    if (ikm_sel && strcmp(ikm_sel, "fp") == 0) {
      ikm = s->fp_aes_key; ikm_len = 16; ikm_name = "fpAesKey";
    } else {
      ikm = s->ecdh_secret; ikm_len = 32; ikm_name = "ecdh_secret";
    }
    uint8_t chacha_key[32];
    mirror_derive_datastream_key(ikm, ikm_len, stream_info.stream_connection_id, chacha_key);
    video_packetizer_set_chacha(s->video_packetizer, chacha_key);
    fprintf(stderr, "sender: video ChaCha20-Poly1305 key derived (%s pairing, IKM=%s/%zuB, scid=%" PRIu64 ")\n",
            s->use_hap ? "HAP" : "raw", ikm_name, ikm_len, stream_info.stream_connection_id);
  } else {
    fprintf(stderr, "sender: AES-CTR video profile (%s)\n",
            s->apple_rx ? "Apple frame format: per-AU + LE boot NTP"
                        : "PiP/loopback: per-NAL + BE microsecond NTP");
  }

  // Unencrypted test (PIP_NOENC): override any cipher with plaintext per-AU.
  if (getenv("PIP_NOENC") != NULL) {
    video_packetizer_set_plaintext(s->video_packetizer);
  }

  // Set packetizer callback to send via stream_client
  // The packetizer encrypts the payload and formats the complete packet,
  // then sends it via stream_client_send_raw_video_packet
  video_packetizer_set_callback(s->video_packetizer, on_packetized_video, s);

  // Initialize RTP audio (platform code will set encoder and capture)
  // Default to 44100 Hz sample rate
  // Note: Audio port is not part of stream_info for screen mirroring (type 110)
  // Audio streaming would require a separate audio stream setup (type 96) in the /stream request
  // For now, we initialize RTP audio but don't connect it
  // TODO: Add audio stream setup to /stream request if audio is enabled
  s->rtp_audio = rtp_audio_init(44100);
  if (!s->rtp_audio) {
    sender_set_state(s, SENDER_STATE_ERROR, "Failed to initialize RTP audio");
    video_packetizer_destroy(s->video_packetizer);
    s->video_packetizer = NULL;
    stream_client_disconnect_video(s->stream_client);
    return -1;
  }

  // Audio connection will be set up when audio streaming is properly implemented
  // For now, RTP audio is initialized but not connected

  // Video encoder and frame capture are platform-specific
  // Platform code should call sender_set_video_encoder() and sender_set_frame_capture()
  // after creating these components

  // Audio encoder and capture are platform-specific
  // Platform code should call sender_set_audio_encoder() and sender_set_audio_capture()
  // after creating these components

  s->source_id = source_id;
  s->streaming = 1;
  sender_set_state(s, SENDER_STATE_STREAMING, NULL);

  return 0;
}

void
sender_set_volume(sender_t *s, float volume)
{
  assert(s);
  // Volume control will be implemented when audio streaming is added
  (void)volume;
}

void
sender_set_video_encoder(sender_t *s, void *video_encoder)
{
  assert(s);
  s->video_encoder = (video_encoder_t *)video_encoder;

  if (s->video_encoder) {
    // Wire encoder callback to packetizer
    video_encoder_set_callback(s->video_encoder, on_encoded_frame, s);
  }
}

void
sender_set_frame_capture(sender_t *s, void *frame_capture)
{
  assert(s);
  s->frame_capture = (frame_capture_t *)frame_capture;

  if (s->frame_capture) {
    // Wire capture callback to encoder
    frame_capture_set_callback(s->frame_capture, on_captured_frame, s);
  }
}

void
sender_set_audio_encoder(sender_t *s, void *audio_encoder)
{
  assert(s);
  s->audio_encoder = (audio_encoder_t *)audio_encoder;

  if (s->audio_encoder) {
    // Wire encoder callback to RTP audio
    audio_encoder_set_callback(s->audio_encoder, on_encoded_audio, s);
  }
}

void
sender_set_audio_capture(sender_t *s, void *audio_capture)
{
  assert(s);
  s->audio_capture = (audio_capture_t *)audio_capture;

  if (s->audio_capture) {
    // Wire capture callback to encoder
    audio_capture_set_callback(s->audio_capture, on_captured_audio, s);
  }
}

void
sender_stop(sender_t *s)
{
  assert(s);

  if (s->streaming) {
    if (s->frame_capture) {
      frame_capture_stop(s->frame_capture);
    }
    if (s->audio_capture) {
      audio_capture_stop(s->audio_capture);
    }
    s->streaming = 0;
  }

  cleanup_components(s);

  if (s->receiver_host) {
    free(s->receiver_host);
    s->receiver_host = NULL;
  }

  sender_set_state(s, SENDER_STATE_IDLE, NULL);
}

sender_state_t
sender_get_state(sender_t *s)
{
  assert(s);
  return s->state;
}

void
sender_destroy(sender_t *s)
{
  if (s) {
    sender_stop(s);
    free(s);
  }
}