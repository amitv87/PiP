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

#ifndef VIDEO_PACKETIZER_H
#define VIDEO_PACKETIZER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct video_packetizer_s video_packetizer_t;

/**
 * Callback for packetized video data ready to send
 * packet: Complete packet (128-byte header + encrypted payload)
 * packet_len: Total packet length
 * ctx: User context
 */
typedef void (*packetized_data_callback_t)(
    const uint8_t *packet, int packet_len,
    void *ctx
);

/**
 * Initialize video packetizer
 * Returns packetizer instance or NULL on error
 */
video_packetizer_t *video_packetizer_init(void);

/**
 * Set callback for packetized data
 */
void video_packetizer_set_callback(video_packetizer_t *pkt, packetized_data_callback_t cb, void *ctx);

/**
 * Set AES encryption key and IV (16 bytes each)
 * Must be called before packetizing
 */
int video_packetizer_set_encryption(video_packetizer_t *pkt,
                                    const uint8_t *key, const uint8_t *iv);

/**
 * Enable ChaCha20-Poly1305 mode with a 32-byte stream key (Apple receivers).
 * The whole access unit is sealed as one packet with a per-frame nonce; the
 * 128-byte packet header is the AEAD associated data. Overrides AES-CTR.
 */
int video_packetizer_set_chacha(video_packetizer_t *pkt, const uint8_t key[32]);

/**
 * Enable the Apple receiver frame format (airfry/doubletake, real Apple TVs):
 * one packet per H.264 access unit (all VCL NAL types 1-5 concatenated in AVCC),
 * little-endian boot-relative NTP timestamps, and the SPS/PPS codec packet
 * resent before every keyframe. Independent of the cipher — use with AES-CTR
 * (video_packetizer_set_encryption, raw pairing) OR ChaCha (set_chacha, HAP).
 * Without it, PiP's own/loopback format is used (per-NAL AES-CTR, big-endian
 * timestamps, codec packet sent once).
 */
void video_packetizer_set_apple_format(video_packetizer_t *pkt);

/**
 * Send video with NO encryption (plaintext H.264), using the Apple per-AU
 * framing. For receivers that accept unencrypted mirror video. Overrides the
 * AES-CTR/ChaCha ciphers.
 */
void video_packetizer_set_plaintext(video_packetizer_t *pkt);

/**
 * Packetize encoded frame data
 * data: H.264 NAL units in AVCC format (length-prefixed)
 * data_len: Length of data
 * is_keyframe: True if this is a keyframe
 * sps: SPS NAL unit (NULL if not provided)
 * sps_len: Length of SPS
 * pps: PPS NAL unit (NULL if not provided)
 * pps_len: Length of PPS
 * ntp_timestamp: NTP timestamp in microseconds
 * Returns 0 on success, -1 on error
 */
int video_packetizer_packetize(video_packetizer_t *pkt,
                               const uint8_t *data, int data_len,
                               bool is_keyframe,
                               const uint8_t *sps, int sps_len,
                               const uint8_t *pps, int pps_len,
                               uint64_t ntp_timestamp);

/**
 * Clean up video packetizer
 */
void video_packetizer_destroy(video_packetizer_t *pkt);

#ifdef __cplusplus
}
#endif

#endif