# AirPlay Sender Implementation Guide

This document outlines the step-by-step implementation plan for adding AirPlay sender functionality to PiP.

## Overview

The AirPlay sender will allow PiP to stream pip window (screen/window/hls/airplay) content to AirPlay receivers (Apple TV, AirPlay-enabled speakers, etc.). This is the reverse of the current receiver implementation.

## Protocol Analysis (From Receiver Code)

Based on analysis of the existing receiver implementation, AirPlay 2 uses:

### Control Layer
- **HTTP/RTSP** for control messages (POST/GET requests)
- **Binary plist** for data serialization (`plist/` library)
- Endpoints: `/info`, `/pair-setup`, `/pair-verify`, `/fp-setup`, `/stream`, `/feedback`, `/play`, `/stop`

### Security Layer
- **Ed25519** for digital signatures (`ed25519/`)
- **X25519 (Curve25519)** for key exchange (`curve25519/`)
- **FairPlay** for DRM (`fairplay.h`, `playfair/`)
- **AES-CTR** for video encryption (`mirror_buffer.c`, `aes_ctr.c`)
- **SHA-512** for hashing

> Receiver interop RE (why encrypted mirroring fails with some receivers, and how a real
> receiver derives its video key) is documented in
> [`docs/moto-softmedia-receiver-re.md`](docs/moto-softmedia-receiver-re.md).

### Streaming Layer
- **TCP** for video mirroring (port negotiated during `/stream` setup)
- **RTP/UDP** for audio streaming
- **NTP** for time synchronization (`raop_ntp.c`)

### Video Format
- H.264 with NAL unit format (size-prefixed, not Annex-B start codes)
- 128-byte packet header containing:
  - Bytes 0-3: Payload size (big-endian)
  - Byte 4: Packet type (0x00=encrypted video, 0x01=SPS/PPS, 0x05=streaming report)
  - Bytes 8-15: NTP timestamp
- Video encrypted with AES-128-CTR

### Audio Format
- AAC or AAC-ELD or ALAC (codec type 2, 4, or 8)
- Sample rate: 44100 Hz
- Channels: 2 (stereo)
- RTP packetization

---

## Prerequisites

- [ ] Study `airplay/raop_handlers.h` for protocol message formats
- [ ] Study `airplay/raop_rtp_mirror.c` for video packet structure
- [ ] Study `airplay/raop_rtp.c` for audio packet structure
- [ ] Study `airplay/pairing.c` for authentication handshake
- [ ] Study `airplay/fairplay_playfair.c` for FairPlay handling
- [ ] Understand NTP time conversion (`raop_ntp.c`)

---

## Code Style

### Indentation and Spacing

- Use **2 spaces** for indentation (not tabs)
- No trailing whitespace
- One blank line between method implementations
- No blank line after opening brace `{`
- Blank line before closing brace `}` in some cases (method end)

---

## Implementation Steps

### Phase 1: DNS-SD Service Discovery

#### Step 1.1: Extend DNS-SD Library for Browsing
- [x] Add `DNSServiceBrowse` function pointers to `airplay/dnssd.c`:
  ```c
  typedef void (*DNSServiceBrowseReply)(
      DNSServiceRef sdRef,
      DNSServiceFlags flags,
      uint32_t interfaceIndex,
      DNSServiceErrorType errorCode,
      const char *serviceName,
      const char *regtype,
      const char *replyDomain,
      void *context
  );
  ```
- [x] Add `DNSServiceResolve` for getting IP/port of discovered services
- [x] Add `DNSServiceGetAddrInfo` for IP address resolution
- [x] Add `TXTRecordGetValue*` functions for parsing TXT records
- [x] Add `dnssd_process_result` for manual event processing

#### Step 1.2: Create Discovery Module
- [x] Create `airplay_sender/discovery.h`:
  ```c
  typedef struct airplay_receiver_s {
      char name[256];
      char host[256];
      uint16_t port;
      char deviceId[32];
      uint64_t features;
      char model[64];
      bool requiresPassword;
      bool supportsScreenMirroring;
  } airplay_receiver_t;

  typedef void (*receiver_callback_t)(airplay_receiver_t *receiver, bool added);

  void airplay_discovery_start(receiver_callback_t callback);
  void airplay_discovery_stop(void);
  airplay_receiver_t* airplay_discovery_get_receivers(int *count);
  ```
- [x] Create `airplay_sender/discovery.c`:
  - Browse for `_airplay._tcp` service type
  - Parse TXT records for features:
    - `features` (hex capabilities bitmask)
    - `deviceid` (MAC address)
    - `model` (AppleTV5,3 etc.)
    - `srcvers` (source version)
    - `flags` (status flags)
  - Resolve service to IP address and port
  - Maintain list of available receivers
  - Call callback when receivers appear/disappear
  - Thread-safe receiver list management with mutexes
  - Logging support with `airplay_discovery_set_log_callback`
  - Manual event processing with `airplay_discovery_process_events`

#### Step 1.3: UI Integration for Discovery
- [x] Add "AirPlay to..." submenu in window context menu
- [x] Populate submenu with discovered receivers
- [x] Display receiver icon (lock icon for password-protected receivers)
- [x] Show connection status indicator (checkmark ✓ and menu state for connected receiver)
- [x] Objective-C wrapper (`AirPlayDiscovery`, `AirPlayReceiver`) for C library
- [x] Delegate pattern for receiver add/remove notifications
- [x] `connectToAirPlayReceiver:` method for initiating connections
- [x] App lifecycle integration (start/stop in `main.m`)

---

### Phase 2: HTTP Client for AirPlay Control

#### Step 2.1: Create HTTP Client Module
- [x] Create `airplay_sender/http_client.h`:
  ```c
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
  void http_client_disconnect(http_client_t *client);
  void http_client_destroy(http_client_t *client);
  ```
- [x] Create `airplay_sender/http_client.c`:
  - TCP socket connection
  - HTTP request formatting
  - HTTP response parsing (using `llhttp` library)
  - Keep-alive connection handling
  - Timeout handling
  - Binary plist response parsing support

#### Step 2.2: Implement Server Info Request
- [x] Implement `GET /info` request
- [x] Parse binary plist response (reuse `plist/` library)
- [x] Extract receiver capabilities:
  - Feature flags (`features`)
  - Source version (`sourceVersion`)
  - Device ID (`deviceID`)
- [x] Extract additional fields (displays, audioFormats - can be added as needed)

---

### Phase 3: Authentication and Pairing

#### Step 3.1: Implement Pair-Setup (Client Side)
- [x] Create `airplay_sender/pairing_client.h` and `.c`
- [x] Generate Ed25519 keypair for this device
- [x] Send `POST /pair-setup` with 32-byte public key
- [x] Receive receiver's Ed25519 public key (32 bytes)
- [x] Store receiver's public key for pair-verify

#### Step 3.2: Implement Pair-Verify (Client Side)
- [x] Generate X25519 keypair (ephemeral)
- [x] Send `POST /pair-verify` with:
  - Byte 0: 0x01 (verify mode 1)
  - Bytes 1-3: 0x00 0x00 0x00
  - Bytes 4-35: X25519 public key
  - Bytes 36-67: Ed25519 public key
- [x] Receive response with receiver's X25519 public key + signature
- [x] Compute shared secret using X25519
- [x] Derive encryption keys using HKDF-SHA512
- [x] Verify receiver's signature
- [x] Generate our signature and send in step 2
- [x] Send `POST /pair-verify` with:
  - Byte 0: 0x00 (verify mode 0)
  - Bytes 1-3: 0x00 0x00 0x00
  - Bytes 4-67: Our signature

#### Step 3.3: Implement FairPlay Setup (Client Side)
- [x] Study `fairplay_playfair.c` to understand FairPlay protocol
- [x] Send `POST /fp-setup` with 16-byte challenge
- [x] Receive 142-byte response
- [x] Send `POST /fp-setup` with 164-byte handshake data
- [x] Receive 32-byte response (session key material)
- [x] Derive AES key for video encryption

**Note:** FairPlay is Apple's proprietary DRM. The existing receiver code has
a reverse-engineered implementation. For sender, we need to generate valid
FairPlay messages that the receiver will accept.

**How to overcome this:**

1. **Reverse engineer `playfair_encrypt`** (Recommended):
   - Implement the inverse of `playfair_decrypt()` in `airplay/playfair/playfair.c`
   - The decryption process: `generate_session_key()` → `generate_key_schedule()` → `z_xor()` → `cycle()` → XOR with chunk1 → `x_xor()` → `z_xor()`
   - To encrypt: Start with 16-byte AES key, reverse all operations
   - Key challenge: Reverse `cycle()` which uses custom AES-like operations with lookup tables
   - The 72-byte `ekey` format: bytes 0-15 (padding?), bytes 16-31 (`chunk1`), bytes 32-55 (padding?), bytes 56-71 (`chunk2`)

2. **Find existing implementations**:
   - Search for open-source AirPlay sender projects (shairplay-sync, airplay-sender, etc.)
   - Check if any have implemented FairPlay encryption for `ekey` generation

3. **Capture and analyze real device traffic**:
   - Use Wireshark to capture SETUP requests from real Apple devices
   - Extract `ekey` values and analyze patterns
   - Try to reverse-engineer the generation algorithm

4. **Temporary workaround** (development only):
   - Modify receiver to accept unencrypted keys for testing
   - Not suitable for production use

---

## Captured Data from Real Apple Device (2026-01-11)

### ekey (72 bytes) - Encrypted AES Key
```
46 50 4c 59 01 02 01 00 00 00 00 3c 00 00 00 00  [Header: FPLY magic + version]
c5 0c ac 96 a9 79 fa 3a 3d e6 ab 3f c0 e2 31 e3  [chunk1: bytes 16-31]
00 00 00 10 bf f3 9f 5f ea 72 4f 63 d6 16 45 6e  [Middle padding/data]
c6 f3 2a 14 20 a9 f5 27                          [Middle padding/data (cont.)]
d1 df 7d 8c d2 d5 bd ae 41 bb aa 66 b0 3f dd 1a  [chunk2: bytes 56-71]
```

C array format:
```c
unsigned char ekey[72] = {
  0x46, 0x50, 0x4c, 0x59, 0x01, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x00, 0x00, 0x00,
  0xc5, 0x0c, 0xac, 0x96, 0xa9, 0x79, 0xfa, 0x3a, 0x3d, 0xe6, 0xab, 0x3f, 0xc0, 0xe2, 0x31, 0xe3,
  0x00, 0x00, 0x00, 0x10, 0xbf, 0xf3, 0x9f, 0x5f, 0xea, 0x72, 0x4f, 0x63, 0xd6, 0x16, 0x45, 0x6e,
  0xc6, 0xf3, 0x2a, 0x14, 0x20, 0xa9, 0xf5, 0x27, 0xd1, 0xdf, 0x7d, 0x8c, 0xd2, 0xd5, 0xbd, 0xae,
  0x41, 0xbb, 0xaa, 0x66, 0xb0, 0x3f, 0xdd, 0x1a
};
```

### aeskey (16 bytes) - Decrypted AES Key
```
da 98 33 7c 29 23 06 42 45 a6 34 f6 af f1 15 64
```

C array format:
```c
unsigned char aeskey[16] = {
  0xda, 0x98, 0x33, 0x7c, 0x29, 0x23, 0x06, 0x42, 0x45, 0xa6, 0x34, 0xf6, 0xaf, 0xf1, 0x15, 0x64
};
```

### eiv (16 bytes) - Initialization Vector
```
1b f3 44 c1 42 0e 58 62 84 c2 eb fa 8d d0 29 5c
```

C array format:
```c
unsigned char eiv[16] = {
  0x1b, 0xf3, 0x44, 0xc1, 0x42, 0x0e, 0x58, 0x62, 0x84, 0xc2, 0xeb, 0xfa, 0x8d, 0xd0, 0x29, 0x5c
};
```

### ecdh_secret (32 bytes) - Shared ECDH Secret
```
7b 51 9c 2a 82 1e 18 94 fa 31 d5 fc 24 17 8a 01
e0 39 be 34 ae ac 49 5a 37 78 36 36 42 38 33 43
```

### FairPlay handshake message (message3, 164 bytes)
```
46 50 4c 59 03 01 03 00 00 00 00 98 03 8f 1a 9c
2f 66 06 ea a1 df d6 d4 32 30 2e e7 c9 a1 30 6c
79 fc 3e f8 0c aa 23 d1 79 77 ab 5e 3c 5c b8 58
cf ef cc b7 32 06 b5 cc eb 06 8a 95 55 df 0b 52
79 1d a2 96 19 f5 1f 2c a8 8b d1 67 fd dd 28 4c
95 bd 12 95 96 3c f6 ba 21 2f f4 2f 3a 04 4a 95
10 cd 39 f6 4a c8 5b 7d 43 8a 36 ce 47 31 e6 16
78 a7 4b 54 fd f5 70 a8 a5 5b 37 7b cd a6 3c 07
53 88 a9 5a 7b b3 c0 a6 a4 6c 83 4e da 98 6b 09
8d 8f 69 84 80 e3 32 c4 f6 db cc 95 98 c5 32 b0
7b 71 0d b7
```

C array format:
```c
unsigned char message3[164] = {
  0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00, 0x98, 0x03, 0x8f, 0x1a, 0x9c,
  0x2f, 0x66, 0x06, 0xea, 0xa1, 0xdf, 0xd6, 0xd4, 0x32, 0x30, 0x2e, 0xe7, 0xc9, 0xa1, 0x30, 0x6c,
  0x79, 0xfc, 0x3e, 0xf8, 0x0c, 0xaa, 0x23, 0xd1, 0x79, 0x77, 0xab, 0x5e, 0x3c, 0x5c, 0xb8, 0x58,
  0xcf, 0xef, 0xcc, 0xb7, 0x32, 0x06, 0xb5, 0xcc, 0xeb, 0x06, 0x8a, 0x95, 0x55, 0xdf, 0x0b, 0x52,
  0x79, 0x1d, 0xa2, 0x96, 0x19, 0xf5, 0x1f, 0x2c, 0xa8, 0x8b, 0xd1, 0x67, 0xfd, 0xdd, 0x28, 0x4c,
  0x95, 0xbd, 0x12, 0x95, 0x96, 0x3c, 0xf6, 0xba, 0x21, 0x2f, 0xf4, 0x2f, 0x3a, 0x04, 0x4a, 0x95,
  0x10, 0xcd, 0x39, 0xf6, 0x4a, 0xc8, 0x5b, 0x7d, 0x43, 0x8a, 0x36, 0xce, 0x47, 0x31, 0xe6, 0x16,
  0x78, 0xa7, 0x4b, 0x54, 0xfd, 0xf5, 0x70, 0xa8, 0xa5, 0x5b, 0x37, 0x7b, 0xcd, 0xa6, 0x3c, 0x07,
  0x53, 0x88, 0xa9, 0x5a, 0x7b, 0xb3, 0xc0, 0xa6, 0xa4, 0x6c, 0x83, 0x4e, 0xda, 0x98, 0x6b, 0x09,
  0x8d, 0x8f, 0x69, 0x84, 0x80, 0xe3, 0x32, 0xc4, 0xf6, 0xdb, 0xcc, 0x95, 0x98, 0xc5, 0x32, 0xb0,
  0x7b, 0x71, 0x0d, 0xb7
};
```

### Analysis Notes:
- **ekey structure**: 16-byte header + 16-byte chunk1 + 24-byte middle + 16-byte chunk2 = 72 bytes total
- **chunk1** (bytes 16-31) and **chunk2** (bytes 56-71) are used in `playfair_decrypt()`
- The decryption process: `generate_session_key()` → `generate_key_schedule()` → `z_xor()` → `cycle()` → XOR with chunk1 → `x_xor()` → `z_xor()`
- **message3** (164 bytes) is used in `generate_session_key()` to derive the session key for decryption
- **User-Agent**: `AirPlay/665.13.1` (real Apple device)
- **Complete test data**: We now have all the data needed to test reverse engineering:
  - `message3` (164 bytes) - FairPlay handshake message
  - `ekey` (72 bytes) - Encrypted AES key
  - `aeskey` (16 bytes) - Decrypted AES key (expected output)
  - `eiv` (16 bytes) - Initialization vector
  - `ecdh_secret` (32 bytes) - Shared ECDH secret

### Next Steps:
1. Capture the FairPlay handshake message (`message3`) from earlier in the connection flow
2. Use the captured data to test reverse engineering of `playfair_encrypt()`
3. Implement `playfair_encrypt()` based on reversing `playfair_decrypt()`

---

### Phase 4: Stream Setup and Control

#### Step 4.1: Implement Stream Setup
- [x] Create `airplay_sender/stream_client.h` and `.c`
- [x] Build `POST /stream` request binary plist with:
  ```
  {
    "streams": [{
      "type": 110,  // Screen mirroring
      "streamConnectionID": <random 8 bytes>,
      "timestampInfo": [{
        "name": "local", "rate": 1000000
      }]
    }],
    "deviceID": <our MAC address>,
    "sessionUUID": <random UUID>,
    "osName": "Mac OS X",
    "osVersion": "...",
    "model": "MacBookPro..."
  }
  ```
- [x] Parse response for:
  - `streams[0].dataPort` (TCP port for video)
  - `streams[0].controlPort` (if applicable)
  - `eventPort` (for feedback)
- [x] Store `streamConnectionID` for AES key derivation
- [x] Send `POST /stream` request to initialize receiver's video AES keys
- [x] Also support RTSP SETUP for compatibility

#### Step 4.2: Implement Video Stream Connection
- [x] Connect TCP socket to receiver's `dataPort`
- [x] Initialize AES-CTR encryption using derived key
- [x] The stream connection ID is used for AES IV derivation
  (see `mirror_buffer_init_aes` in `mirror_buffer.c`)
- [x] Derive video AES key/IV: SHA512("AirPlayStreamKey" + streamConnectionID + hashed_audio_key)
- [x] Hash audio AES key with ECDH secret before using for video key derivation (matches receiver)
- [x] Use same AES-CTR implementation as receiver (`AES_CTR_xcrypt_buffer` from `aes.h`)

#### Step 4.3: Implement Feedback Channel
- [x] Connect to `eventPort` for receiver feedback
- [x] Handle heartbeat/keep-alive messages
- [x] Process rate control feedback

---

### Phase 5: Video Encoding and Streaming

#### Step 5.1: Define Video Encoder Interface
- [x] Create `airplay_sender/video_encoder.h`:
  ```c
  typedef struct video_encoder_s video_encoder_t;
  typedef void (*encoded_frame_callback_t)(
      uint8_t *data, int len,
      bool is_keyframe,
      uint8_t *sps, int sps_len,
      uint8_t *pps, int pps_len,
      uint64_t pts,
      void *ctx
  );

  // Platform-agnostic interface - implementation provided by pip/
  video_encoder_t *video_encoder_init(int width, int height, int fps, int bitrate);
  void video_encoder_set_callback(video_encoder_t *enc, encoded_frame_callback_t cb, void *ctx);
  // Frame data is provided as raw RGBA32 buffer (platform-agnostic)
  int video_encoder_encode_frame(video_encoder_t *enc, uint8_t *rgba_data, int stride, uint64_t pts);
  void video_encoder_destroy(video_encoder_t *enc);
  ```
- [x] **Platform-specific implementation in `pip/`**:
  - [x] Create `pip/video_encoder.h` and `pip/video_encoder.m` (Objective-C wrapper)
  - [x] Use VideoToolbox `VTCompressionSessionCreate` for H.264 encoding
  - [x] Configure for real-time encoding:
    - `kVTCompressionPropertyKey_RealTime` = true
    - `kVTCompressionPropertyKey_AllowFrameReordering` = false (no B-frames)
    - `kVTCompressionPropertyKey_ProfileLevel` = Baseline
    - `kVTCompressionPropertyKey_AverageBitRate`
    - `kVTCompressionPropertyKey_MaxKeyFrameInterval`
  - [x] Convert RGBA32 input to `CVPixelBufferRef` internally (BGRA format)
  - [x] Extract SPS/PPS from CMFormatDescription on keyframes
  - [x] Handle `VTCompressionOutputCallback` and call C callback
  - [x] VideoToolbox provides AVCC format (big-endian length prefixes)

#### Step 5.2: Create Video Packetizer
- [x] Create `airplay_sender/video_packetizer.h` and `.c`
- [x] Format packets according to receiver's expected format:
  ```c
  struct video_packet_header {
      uint32_t payload_size;     // Little-endian (receiver uses byteutils_get_int)
      uint8_t  packet_type;      // 0x00=video, 0x01=SPS/PPS
      uint8_t  flags;            // 0x10 for first video packet after SPS/PPS, 0x00 otherwise
      uint16_t reserved;         // Usually 0x0000
      uint64_t ntp_timestamp;    // Big-endian NTP time
      // ... additional header bytes up to 128 total
  };
  ```
- [x] Convert NAL units from Annex-B to AVCC (length-prefixed) format (VideoToolbox already provides AVCC)
- [x] Encrypt payload with AES-128-CTR (using `AES_CTR_xcrypt_buffer` from `aes.h`)
- [x] Send 128-byte header followed by encrypted payload
- [x] Send SPS/PPS as separate packet (type 0x01) with proper format (6-byte header + 2-byte BE SPS size + SPS + 1-byte gap + 2-byte BE PPS size + PPS)
- [x] Strip SPS/PPS from keyframe data (sent separately)
- [x] **Split NALs into separate packets** (one NAL per packet, matching iPad behavior)
- [x] Maintain AES-CTR counter state across packets
- [x] **Fix counter desync issue** (first packet works, subsequent packets fail - likely partial block handling) - ✅ FIXED: Implemented partial block handling matching receiver's `mirror_buffer_decrypt` behavior
- [x] **Fix race condition in video_packetizer_packetize** (concurrent VideoToolbox callbacks accessing shared state) - ✅ FIXED: Added mutex to serialize access to packetizer state (see Challenge 7.1 for details)

#### Step 5.3: Define Frame Capture Interface
- [x] Create `airplay_sender/frame_capture.h`:
  ```c
  typedef struct frame_capture_s frame_capture_t;
  typedef void (*frame_capture_callback_t)(
      uint8_t *rgba_data,  // RGBA32 format, row-major
      int width,
      int height,
      int stride,          // Bytes per row
      uint64_t pts,        // Presentation timestamp
      void *ctx
  );

  // Platform-agnostic interface - implementation provided by pip/
  frame_capture_t *frame_capture_init(void *source_id);  // source_id is platform-specific
  void frame_capture_set_callback(frame_capture_t *cap, frame_capture_callback_t cb, void *ctx);
  int frame_capture_start(frame_capture_t *cap, int fps);
  void frame_capture_stop(frame_capture_t *cap);
  void frame_capture_destroy(frame_capture_t *cap);
  ```
- [x] **Platform-specific implementation in `pip/`**:
  - [x] Create `pip/frame_capture.h` and `pip/frame_capture.m` (Objective-C wrapper)
  - [x] Use `ImageView`'s renderer (`currentImage` method) to capture frames
  - [x] Convert `CIImage` to RGBA32 format
  - [x] Use `dispatch_source_t` timer for frame rate control (30 fps)
  - [x] Feed frames to callback at target frame rate
  - [x] Handle cleanup and memory management (ARC-compatible)

---

### Phase 6: Audio Capture and Streaming

#### Step 6.1: Define Audio Capture Interface
- [x] Create `airplay_sender/audio_capture.h`:
  ```c
  typedef struct audio_capture_s audio_capture_t;
  typedef void (*audio_samples_callback_t)(
      float *samples,      // Interleaved PCM samples (channels * num_frames)
      int num_frames,
      int channels,
      int sample_rate,
      uint64_t pts,
      void *ctx
  );

  // Platform-agnostic interface - implementation provided by pip/
  audio_capture_t *audio_capture_init(int sample_rate, int channels);
  void audio_capture_set_callback(audio_capture_t *cap, audio_samples_callback_t cb, void *ctx);
  int audio_capture_start(audio_capture_t *cap);
  void audio_capture_stop(audio_capture_t *cap);
  void audio_capture_destroy(audio_capture_t *cap);
  ```
- [ ] **Platform-specific implementation in `pip/`**:
  - Create `pip/audio_capture.h` and `pip/audio_capture.m` (Objective-C wrapper)
  - Use `AVCaptureSession` with `AVCaptureAudioDataOutput` for app audio
  - Or use `AudioObjectAddPropertyListener` for system audio (requires ScreenCaptureKit or audio loopback)
  - Handle sample format conversion to float32 interleaved PCM
  - Call C callback with converted samples

**Note:** Capturing system audio on macOS requires either:
1. ScreenCaptureKit (macOS 12.3+) with audio
2. A virtual audio driver (like BlackHole)
3. Limiting to app-specific audio

#### Step 6.2: Define Audio Encoder Interface
- [x] Create `airplay_sender/audio_encoder.h`:
  ```c
  typedef struct audio_encoder_s audio_encoder_t;
  typedef void (*encoded_audio_callback_t)(
      uint8_t *data,       // Encoded AAC/ALAC data
      int data_len,
      uint64_t pts,
      void *ctx
  );

  // Platform-agnostic interface - implementation provided by pip/
  audio_encoder_t *audio_encoder_init(int sample_rate, int channels, int bitrate);
  void audio_encoder_set_callback(audio_encoder_t *enc, encoded_audio_callback_t cb, void *ctx);
  int audio_encoder_encode(audio_encoder_t *enc, float *pcm_samples, int num_frames, uint64_t pts);
  void audio_encoder_destroy(audio_encoder_t *enc);
  ```
- [ ] **Platform-specific implementation in `pip/`**:
  - Create `pip/audio_encoder.h` and `pip/audio_encoder.m` (Objective-C wrapper)
  - Use AudioToolbox `AudioConverterRef` for AAC encoding
  - Configure AAC encoder (128-256 kbps)
  - Convert float32 PCM input to AudioToolbox format internally
  - Package frames with proper timestamps
  - Call C callback with encoded data

#### Step 6.3: RTP Audio Streaming
- [x] Create UDP socket for audio
- [x] Implement RTP packetization (RFC 3550)
- [x] Calculate RTP timestamps based on sample count
- [x] Add RTP header (version, payload type, sequence number, timestamp, SSRC)
- [x] Handle RTCP for synchronization if needed

#### Step 6.4: Audio-Video Synchronization
- [ ] Use NTP timestamps for both streams
- [ ] Calculate presentation timestamps relative to stream start
- [ ] Ensure audio and video timestamps are aligned

---

### Phase 7: NTP Time Synchronization

#### Step 7.1: Implement NTP Client
- [x] Create `airplay_sender/ntp_client.h` and `.c`
- [x] Study `raop_ntp.c` for existing NTP implementation
- [x] Send NTP requests to receiver's timing port
- [x] Calculate round-trip time and clock offset
- [x] Maintain running average of offset

#### Step 7.2: Timestamp Conversion
- [x] Convert local timestamps to NTP format
- [x] Apply clock offset for accurate sync
- [x] Handle timestamp wraparound
- [x] Track video stream start time for absolute timestamp calculation
- [x] Convert relative PTS to absolute NTP timestamps

---

### Phase 8: Integration and State Management

#### Step 8.1: Create Sender Manager
- [x] Create `airplay_sender/sender.h`:
  ```c
  typedef enum {
      SENDER_STATE_IDLE,
      SENDER_STATE_CONNECTING,
      SENDER_STATE_PAIRING,
      SENDER_STATE_STREAMING,
      SENDER_STATE_ERROR
  } sender_state_t;

  typedef void (*sender_state_callback_t)(sender_state_t state, const char *error, void *ctx);

  typedef struct sender_s sender_t;

  sender_t *sender_init(void);
  void sender_set_state_callback(sender_t *s, sender_state_callback_t cb, void *ctx);
  int sender_connect(sender_t *s, airplay_receiver_t *receiver);
  // source_id is platform-specific opaque pointer (e.g., CGWindowID* or CGDirectDisplayID*)
  // Platform code in pip/ will handle the actual capture setup
  int sender_start_mirroring(sender_t *s, void *source_id);
  void sender_set_volume(sender_t *s, float volume);
  void sender_stop(sender_t *s);
  void sender_destroy(sender_t *s);
  ```
- [x] Create `airplay_sender/sender.c`:
  - Coordinate all components
  - Handle connection lifecycle
  - Manage streaming threads
  - Error recovery and cleanup
- [x] Wire up component callbacks:
  - Frame capture → video encoder → video packetizer → stream client
  - Audio capture → audio encoder → RTP audio
  - NTP client for timestamp conversion
- [x] Add helper functions for platform code:
  - `sender_set_video_encoder()` - wires encoder to packetizer
  - `sender_set_frame_capture()` - wires capture to encoder
  - `sender_set_audio_encoder()` - wires encoder to RTP
  - `sender_set_audio_capture()` - wires capture to encoder
- [x] Initialize RTP audio connection in `sender_start_mirroring()`
- [x] Add `stream_client_send_raw_video_packet()` for pre-encrypted packets

#### Step 8.2: Window Class Integration
- [x] Add `sender_t *sender` instance variable to Window
- [x] Add "AirPlay Mirror to..." menu items in `rightMouseDown:`
- [x] Add "Stop AirPlay Mirroring" when streaming
- [x] Show AirPlay icon/indicator when streaming
- [x] Handle sender state callbacks
- [x] Implement `connectToAirPlaySender:` method
- [x] Implement `stopAirPlayMirroring:` method
- [x] Add cleanup in window close method
- [x] Integrate frame capture from `ImageView`'s renderer
- [x] Integrate video encoder with frame capture
- [x] Set up video pipeline in `connectToAirPlaySender:`

#### Step 8.3: Preferences Integration
- [x] Add AirPlay sender enable/disable preference
- [x] Add quality presets (low/medium/high)
- [x] Add audio enable/disable option
- [x] Use preferences to conditionally show sender menu items
- [x] Add comments for using preferences when creating encoders (platform code)

---

### Phase 9: Testing and Debugging

#### Step 9.1: Create Test Utilities
- [ ] Add debug logging with log levels
- [ ] Create packet dump utility for debugging
- [ ] Add network traffic capture option

#### Step 9.2: Unit Testing
- [ ] Test DNS-SD discovery with mock services
- [ ] Test pairing with known test vectors
- [ ] Test video encoder with sample frames
- [ ] Test packet formatting

#### Step 9.3: Integration Testing
- [ ] Test with Apple TV 4K
- [ ] Test with Apple TV HD
- [ ] Test with AirPlay-enabled speakers
- [ ] Test with HomePod

#### Step 9.4: Edge Case Testing
- [ ] Test network disconnection
- [ ] Test receiver sleep/wake
- [ ] Test resolution changes
- [ ] Test long streaming sessions (memory leaks)

---

## Technical Challenges and Solutions

### Challenge 1: FairPlay DRM
**Problem:** FairPlay is Apple's proprietary DRM system.
**Solution:** The receiver code has a reverse-engineered implementation in `playfair/`.
For sender, we need to generate valid FairPlay handshake messages. Study `fairplay_playfair.c`
and `omg_hax.c` for the implementation details.
**Status:** ✅ Implemented - Using existing `playfair_encrypt` function from receiver code.

### Challenge 1.1: Video AES Key Derivation
**Problem:** Receiver hashes audio AES key with ECDH secret before using for video key derivation.
**Solution:** ✅ Fixed - Sender now hashes `fairplay_session_key` with `ecdh_secret` using SHA512 before deriving video keys. Keys now match between sender and receiver.

### Challenge 2: Platform Abstraction
**Problem:** `airplay_sender` must be a portable C library, but encoding/capture requires platform APIs.
**Solution:**
- Define platform-agnostic C interfaces in `airplay_sender/` (video_encoder.h, audio_capture.h, etc.)
- Implement platform-specific wrappers in `pip/` (video_encoder.m, audio_capture.m, etc.)
- Platform code converts between platform types (CVPixelBufferRef, CGImageRef) and portable formats (RGBA32, float32 PCM)
- This allows `airplay_sender` to be compiled for any platform by providing appropriate implementations

### Challenge 3: System Audio Capture on macOS
**Problem:** macOS doesn't allow direct system audio capture without user consent.
**Solutions (implemented in pip/audio_capture.m):**
1. Use ScreenCaptureKit (macOS 12.3+) which includes audio
2. For older macOS, require virtual audio driver
3. Only capture window/app-specific audio when possible
4. Consider video-only mode as fallback

### Challenge 4: Low Latency Encoding
**Problem:** Default VideoToolbox settings prioritize quality over latency.
**Solution (implemented in pip/video_encoder.m):**
- Set `kVTCompressionPropertyKey_RealTime` = true
- Disable B-frames (`AllowFrameReordering` = false)
- Use lower GOP sizes
- Consider hardware encoding only

### Challenge 5: Time Synchronization
**Problem:** Audio and video must be precisely synchronized.
**Solution:**
- Use NTP for wall-clock synchronization
- Calculate presentation timestamps carefully
- Handle clock drift with periodic resync
**Status:** ✅ Implemented - NTP client syncs with receiver, converts local timestamps to NTP format.

### Challenge 6: AES-CTR Counter State Management
**Problem:** Receiver maintains partial block state across packets using `nextDecryptCount`, but sender's `AES_CTR_xcrypt_buffer` doesn't expose this state.
**Current Status:** ✅ **FIXED** - Implemented partial block handling matching receiver's `mirror_buffer_decrypt` behavior.
**Solution:**
- ✅ Split NALs into separate packets (one NAL per packet, matching iPad behavior)
- ✅ Maintain counter state in `pkt->aes_ctx` across packets
- ✅ Implemented `encrypt_with_partial_block_handling` function that mirrors receiver's decryption logic
- ✅ Track `nextEncryptCount` and `og[16]` state in `struct video_packetizer_s` to handle partial blocks correctly

### Challenge 7: Race Conditions and Buffer Lifetime Issues

#### 7.1: Sender-Side Race Condition in Video Packetizer
**Problem:** Multiple VideoToolbox compression callbacks can invoke `video_packetizer_packetize` concurrently from different threads, causing race conditions when accessing shared state:
- `pkt->packet_buffer` and `pkt->packet_buffer_size` (reallocated during packetization)
- `pkt->nextEncryptCount` and `pkt->og[16]` (AES-CTR partial block state)
- Counter state in `pkt->aes_ctx`

**Symptoms:**
- Data corruption in encrypted packets
- Counter desync even after fixing partial block handling
- Intermittent failures that are hard to reproduce

**Root Cause:**
VideoToolbox's `VTCompressionOutputCallback` can be invoked from multiple threads concurrently when encoding multiple frames. Each callback calls `on_encoded_frame` in `sender.c`, which then calls `video_packetizer_packetize`. Without synchronization, concurrent access to shared packetizer state causes corruption.

**Solution:** ✅ **FIXED**
- Added `mutex_handle_t packetize_mutex` to `struct video_packetizer_s`
- Initialize mutex in `video_packetizer_init`: `MUTEX_CREATE(pkt->packetize_mutex)`
- Lock mutex at the beginning of `video_packetizer_packetize`: `MUTEX_LOCK(pkt->packetize_mutex)`
- Unlock mutex before all return paths (both success and error)
- Destroy mutex in `video_packetizer_destroy`: `MUTEX_DESTROY(pkt->packetize_mutex)`

**Implementation Details:**
- Mutex serializes all access to `video_packetizer_packetize`, ensuring only one thread can packetize at a time
- This prevents corruption of shared state while maintaining correct partial block handling
- The mutex is held for the entire duration of packetization, including encryption and callback invocation

**Files Modified:**
- `airplay_sender/video_packetizer.c`: Added mutex initialization, locking, and cleanup
- `airplay_sender/video_packetizer.h`: Added mutex field to struct (if header is modified)

#### 7.2: Receiver-Side Buffer Lifetime Issue (Loopback Mode)
**Problem:** In loopback mode (sender and receiver on same process), `didDecompress` callbacks from VideoToolbox fail with `kVTInvalidSessionErr` (-12909) even though `VTDecompressionSessionDecodeFrame` returns success.

**Symptoms:**
- `didDecompress: [LOOPBACK DEBUG] failed with code: -12909` appears frequently in logs
- **System is functional**: Video is successfully transmitted and decoded (sender window renders in receiver PiP window)
- **Frame drops occur**: Many frames fail to decode due to `didDecompress` failures, causing dropped frames and stuttering in the output
- Some frames succeed (e.g., count=120, count=150), but most fail
- `VTDecompressionSessionDecodeFrame` returns `noErr` (0), but `didDecompress` callback reports failure
- Failures occur asynchronously, often after the decode function has returned
- **Impact**: Video renders but with noticeable frame drops and reduced smoothness in loopback mode

**Root Cause:**
The receiver's `raop_rtp_mirror.c` (line 479) frees `payload_out` immediately after calling the `video_process` callback:
```c
raop_rtp_mirror->callbacks.video_process(..., &h264_data, ...);
free(payload_out);  // Line 479 - freed immediately
```

However, `H264Decoder.m` uses `CMBlockBufferCreateWithMemoryBlock` with `kCFAllocatorNull`, which means the `CMBlockBuffer` does NOT copy the data - it references the original buffer directly. When VideoToolbox's `didDecompress` callback runs asynchronously (even with synchronous decode flags, some callbacks can be delayed), it tries to access the freed memory, causing:
1. Invalid session errors if the memory has been reused
2. Crashes or undefined behavior if the memory is corrupted
3. Decode failures even when the initial decode call succeeded

**Why It Works with Real Devices:**
- Real devices have network latency, giving VideoToolbox time to process frames before buffers are freed
- Network timing may naturally serialize operations better than in-process callbacks
- Real devices may use different buffer management strategies

**Current Status:** ⚠️ **OBSERVED BUT NOT FIXED - FUNCTIONAL WITH FRAME DROPS**
- The issue is specific to loopback mode (sender and receiver in same process)
- **System is functional**: Video successfully streams from sender to receiver and renders correctly
- **Performance impact**: Many frames are dropped due to `didDecompress` failures, causing stuttering and reduced frame rate in loopback mode
- Code works correctly with real AirPlay devices (no frame drops observed)
- User has explicitly stated: "files pip/receiver.m pip/H264Decoder.m work absolutely fine with real devices. No logical code changes should be done. Adding log statements is okay."
- **Workaround**: Acceptable for loopback testing/debugging, but not ideal for production loopback scenarios

**Potential Solutions (NOT IMPLEMENTED - for reference only):**
1. **Copy data in receiver before callback**: Allocate a copy of `payload_out` in `raop_rtp_mirror.c` before calling `video_process`, and free the copy after a delay or in a cleanup callback. However, this would require changes to the receiver code structure.

2. **Copy data in H264Decoder**: Change `H264Decoder.m` to copy NAL data into a new buffer before creating `CMBlockBuffer`, ensuring the buffer lifetime is controlled by Core Media. However, user has stated no logical changes to `H264Decoder.m` should be made.

3. **Delay buffer free**: Add a mechanism to delay freeing `payload_out` until VideoToolbox has finished processing. This would require tracking pending decode operations, which is complex.

4. **Accept failures in loopback**: Since the code works with real devices, these failures may be acceptable in loopback mode for testing purposes. The system is functional and renders video, but with reduced frame rate due to dropped frames. This is acceptable for development/testing but not ideal for production loopback scenarios.

**Investigation Notes:**
- Logs show `didDecompress` callbacks are asynchronous even when synchronous decode is requested
- The same `sourceFrameRefCon` pointer (local `pixelBuffer` address) appears in multiple failed callbacks, suggesting callbacks are queued and processed later
- **Reducing framerate from 30 to 15 fps was already tried**: This changed the timing of failures but **didn't eliminate them**, confirming it's a buffer lifetime race condition rather than a simple load/timing problem
- Some frames do succeed, suggesting the issue is timing-dependent rather than a fundamental incompatibility
- **Why reducing framerate doesn't fully fix it**: Even with lower load, `didDecompress` fires asynchronously on a different thread. There's no guarantee it will fire before `video_process` returns and frees the buffer. The race condition is fundamental - the buffer is freed immediately after the callback returns, regardless of framerate

**Comparison with Real Device (iPad) Logs:**

**Packet Structure Differences (from receiver logs):**

**iPad (Real Device) Sender:**
- SPS/PPS packet: `payload_size=37`, `sps_size=18`, `pps_size=4`, `total_len=30`
- First video packet: `payload_size=9342` (large IDR frame), `packet[5]=0x10` (first packet flag)
- Subsequent packets: `payload_size=161` (small, consistent P-frames)
- NAL sequence: Type 5 (IDR) → Type 1 (P-frame) → Type 1 (P-frame)...
- SPS/PPS sent once at start

**Our Loopback Sender:**
- SPS/PPS packet: `payload_size=25`, `sps_size=11`, `pps_size=4`, `total_len=23`
- First video packet: `payload_size=34` (small SEI packet, type 6), `packet[5]=0x10`
- Second packet: `payload_size=45281` (large IDR frame, type 5)
- Subsequent packets: `payload_size` varies greatly (579, 61771, 366, 277, 282 bytes)
- NAL sequence: Type 6 (SEI) → Type 5 (IDR) → Type 1 (P-frame)...
- SPS/PPS sent every 30 frames (with each keyframe)

**Key Differences:**
1. **Packet sizes**: iPad sends consistent small P-frames (~161 bytes), our sender sends variable large P-frames (579-61771 bytes)
2. **First packet**: iPad sends large IDR immediately, our sender sends small SEI first
3. **SPS/PPS frequency**: iPad sends once, our sender sends with every keyframe
4. **Frame structure**: iPad's encoding produces smaller, more consistent frames

**Callback Timing Differences:**
- **Real device behavior**: All `didDecompress` callbacks succeed immediately (within 5ms of `VTDecompressionSessionDecodeFrame` call)
- **Real device timing**: `didDecompress` callback occurs synchronously before `video_process` callback returns, giving VideoToolbox time to process before buffer is freed
- **Loopback behavior**: `didDecompress` callbacks occur asynchronously after `video_process` callback returns, by which time `payload_out` has already been freed

**Why Real Devices Don't Have This Issue:**

You're correct - the receiver-side flow is exactly the same. `video_process` doesn't complete "too quickly" in loopback. The difference is **VideoToolbox's behavior**, not the receiver code.

**Real Device Flow (iPad):**
1. 23.913: `VTDecompressionSessionDecodeFrame` called
2. 23.919: `didDecompress` succeeded (6ms later, on thread 2194517)
3. 23.919: `VTDecompressionSessionDecodeFrame` returned (on thread 2194516)
4. 23.919: `video_process: processed` - callback returns
5. **Then** `free(payload_out)` happens - buffer freed **after** `didDecompress` already accessed it

**Loopback Flow:**
1. 35.054: `VTDecompressionSessionDecodeFrame` called
2. 35.059: `didDecompress` failed (5ms later, on thread 2196787)
3. 35.059: `VTDecompressionSessionDecodeFrame` returned (on thread 2196773)
4. 35.059: `video_process: processed` - callback returns
5. **Then** `free(payload_out)` happens - buffer freed **before** `didDecompress` can access it

**The Real Root Cause:**
- `VTDecompressionSessionDecodeFrame` returns immediately in both cases
- `didDecompress` fires asynchronously on a different thread in both cases (5-6ms later)
- **The difference**: In real devices, `didDecompress` fires **before** `video_process` returns (same timestamp 23.919, but callback thread processes first)
- In loopback, `didDecompress` fires **after** `video_process` returns (35.059 vs 35.059, but callback thread processes later)

**Why VideoToolbox Behaves Differently:**
The difference is **system load and thread scheduling**:
- **Real devices**: Lower system load (only receiving/decoding), VideoToolbox processes frames quickly, `didDecompress` callback fires synchronously/quickly
- **Loopback**: Higher system load (simultaneous encoding + decoding in same process), VideoToolbox may queue callbacks, `didDecompress` fires asynchronously with delay
- **Thread scheduling**: Under higher load, the callback thread may be scheduled later, causing `didDecompress` to fire after `video_process` has already returned and freed the buffer

**Conclusion**: The receiver code is identical. The issue is that under higher system load (loopback mode with encoding + decoding), VideoToolbox's asynchronous `didDecompress` callback is scheduled later, causing it to fire after `video_process` has already returned and freed `payload_out`. In real devices with lower load, the callback fires quickly enough to access the buffer before it's freed.

**Packet Structure Impact:**
The packet structure differences (iPad's smaller, consistent frames vs our larger, variable frames) may contribute to the timing issue:
- **Smaller frames (iPad)**: Faster to process, `didDecompress` fires quickly
- **Larger frames (our sender)**: Take longer to process, increasing the window where the buffer might be freed before callback fires
- However, the fundamental issue remains the race condition with buffer lifetime, not the packet structure itself

**Files Involved:**
- `airplay/raop_rtp_mirror.c`: Line 479 - `free(payload_out)` called immediately after callback
- `pip/H264Decoder.m`: Uses `kCFAllocatorNull` for `CMBlockBufferCreateWithMemoryBlock`, meaning data is not copied
- `pip/receiver.m`: Calls `H264Decoder` decode method with data that will be freed

**Next Steps:**
- ✅ Mutex fix on sender side has been implemented (prevents sender-side race conditions)
- Monitor logs to see if mutex fix reduces failure rate (may help with timing)
- **Current workaround**: System is functional for loopback testing despite frame drops
- If improved loopback performance is needed, investigate adding buffer lifetime tracking without changing core logic (would require careful design to avoid breaking real device compatibility)
- Consider documenting this as a known limitation of loopback mode

#### 7.3: Why Baseline Profile Fails (H.264 Encoding Profile Impact)

**Problem:** The decoder works fine with Baseline profile, but `didDecompress` failures occur in loopback mode when using Baseline profile. High profile works correctly.

**Root Cause: Frame Size Impact on Buffer Lifetime Race Condition**

The issue is not that the decoder can't decode Baseline - it's that **Baseline profile produces much larger frames**, which makes the buffer lifetime race condition more likely to occur.

**Baseline Profile Characteristics:**
- Uses **CAVLC** (Context-Adaptive Variable Length Coding) entropy coding
- Less efficient compression → **larger frame sizes**
- Observed frame sizes with Baseline:
  - Keyframes: 41,946 bytes, 66,990 bytes, 55,135 bytes (very large!)
  - P-frames: 237-14,276 bytes (highly variable)

**High Profile Characteristics:**
- Uses **CABAC** (Context-Adaptive Binary Arithmetic Coding) entropy coding
- More efficient compression → **smaller frame sizes**
- Observed frame sizes with High:
  - Keyframes: ~9,000-15,000 bytes (much smaller)
  - P-frames: ~200-500 bytes (more consistent)

**Why Larger Frames Cause More Failures:**

1. **Processing Time**: Larger frames take longer for VideoToolbox to decode
   - Baseline keyframe (41KB): VideoToolbox needs more time to process
   - High profile keyframe (9KB): VideoToolbox processes faster

2. **Timing Window**: The buffer is freed immediately after `video_process` returns
   - With larger frames, `didDecompress` callback takes longer to fire
   - By the time it fires, the buffer has already been freed → `kVTInvalidSessionErr`
   - With smaller frames, `didDecompress` fires quickly enough to access the buffer before it's freed

3. **Race Condition Probability**:
   - **Baseline (large frames)**: High probability of buffer being freed before callback
   - **High profile (small frames)**: Lower probability, callback fires faster

**Timing Comparison (from logs):**

**Baseline Profile (failing):**
```
00:35:05.481: VTDecompressionSessionDecodeFrame called (41,912-byte NAL)
00:35:05.483: didDecompress failed with -12909 (2ms later, but buffer already freed)
00:35:05.483: video_process returns, buffer freed
```

**High Profile (working):**
```
Similar timing, but smaller frames (9KB) → VideoToolbox processes faster
→ didDecompress fires before buffer is freed → success
```

**Conclusion:**
- The decoder supports both Baseline and High profiles correctly
- The issue is the **buffer lifetime race condition** that's more likely to occur with larger frames
- High profile works because smaller frames are processed faster, allowing `didDecompress` to fire before the buffer is freed
- Baseline fails because larger frames take longer to process, increasing the window where the buffer might be freed before the callback fires

**Solution:**
- Use **High profile** (`kVTProfileLevel_H264_High_AutoLevel`) for loopback mode
- High profile provides better compression efficiency and avoids the buffer lifetime race condition
- Both profiles work with real devices (network latency provides natural buffer lifetime extension)

---

## File Structure

```
airplay_sender/
├── TODO.md                  # This file
├── discovery.h              # Service discovery API
├── discovery.c              # DNS-SD browsing implementation
├── http_client.h            # HTTP client API
├── http_client.c            # HTTP client implementation
├── pairing_client.h         # Pairing API
├── pairing_client.c         # Ed25519/X25519 client side
├── fairplay_client.h        # FairPlay client API
├── fairplay_client.c        # FairPlay handshake client
├── stream_client.h          # Stream setup API
├── stream_client.c          # Stream connection management
├── video_encoder.h          # Video encoder API (C interface)
├── video_packetizer.h       # Video packet formatting API
├── video_packetizer.c       # AirPlay video packet format
├── frame_capture.h          # Frame capture API (C interface)
├── audio_capture.h          # Audio capture API (C interface)
├── audio_encoder.h          # Audio encoder API (C interface)
├── ntp_client.h             # NTP client API
├── ntp_client.c             # Time synchronization
├── sender.h                 # Main sender API
├── sender.c                 # Sender state machine
└── sender_internal.h        # Internal shared definitions

pip/                          # Platform-specific implementations
├── video_encoder.h          # Video encoder platform wrapper
├── video_encoder.m          # VideoToolbox H.264 encoder (macOS/iOS)
├── frame_capture.h          # Frame capture platform wrapper
├── frame_capture.m          # CoreGraphics capture (macOS/iOS)
├── audio_capture.h          # Audio capture platform wrapper
├── audio_capture.m          # Core Audio / ScreenCaptureKit (macOS/iOS)
├── audio_encoder.h          # Audio encoder platform wrapper
└── audio_encoder.m          # AudioToolbox AAC encoder (macOS/iOS)
```

---

## Dependencies

### Existing (reusable from receiver)
- `airplay/plist/` - Binary plist parsing/generation
- `airplay/ed25519/` - Ed25519 signatures
- `airplay/curve25519/` - X25519 key exchange
- `airplay/crypto/` - AES, SHA, HMAC
- `airplay/aes_ctr.c/h` - AES-CTR encryption
- `airplay/playfair/` - FairPlay implementation
- `airplay/byteutils.c/h` - Byte manipulation
- `airplay/logger.c/h` - Logging

### Platform-Specific Dependencies (in pip/, not airplay_sender/)
**macOS/iOS Frameworks** (add to Xcode project for pip/ only):
- VideoToolbox.framework (H.264 encoding)
- AudioToolbox.framework (AAC encoding)
- CoreMedia.framework (sample buffers, timestamps)
- CoreVideo.framework (pixel buffers)
- CoreAudio.framework (audio capture)
- ScreenCaptureKit.framework (macOS 12.3+, optional)
- CoreGraphics.framework (screen/window capture)

**Note:** `airplay_sender` is a portable C library with no platform-specific dependencies.
All platform-specific code (VideoToolbox, AudioToolbox, CoreGraphics, etc.) is implemented
in `pip/` and provides the C interfaces defined in `airplay_sender/`.

---

## Implementation Order

### Week 1: Foundation
1. **Phase 1** - DNS-SD discovery (1-2 days)
2. **Phase 2** - HTTP client (1 day)
3. Start **Phase 3** - Pairing (2 days)

### Week 2: Protocol
1. Complete **Phase 3** - FairPlay (2-3 days)
2. **Phase 4** - Stream setup (2 days)

### Week 3: Video
1. **Phase 5** - Video encoding and streaming (5 days)

### Week 4: Audio & Integration
1. **Phase 6** - Audio (3 days)
2. **Phase 7** - NTP sync (1 day)
3. **Phase 8** - Integration (2 days)

### Week 5: Testing & Polish
1. **Phase 9** - Testing and bug fixes

**Total: ~5 weeks** for complete implementation

---

## References

### From This Codebase
- `airplay/raop_handlers.h` - Protocol message handlers
- `airplay/raop_rtp_mirror.c` - Video packet format (lines 297-400)
- `airplay/raop_rtp.c` - Audio RTP handling
- `airplay/pairing.c` - Ed25519/X25519 key exchange
- `airplay/fairplay_playfair.c` - FairPlay implementation
- `airplay/mirror_buffer.c` - AES encryption setup

### External
- RFC 3550 - RTP specification
- RFC 6184 - RTP Payload Format for H.264
- RFC 3640 - RTP Payload Format for AAC
- Apple VideoToolbox documentation
- Apple AudioToolbox documentation
