/**
 *  ts_muxer.c
 *  PiP
 *
 *  MPEG-TS muxer implementation. Converts H.264 NAL units (AVCC format)
 *  into MPEG-TS segments for HLS streaming.
 *
 *  MPEG-TS overview:
 *  - Fixed 188-byte packets, each starting with sync byte 0x47
 *  - PAT (PID 0x0000) maps programs to PMT PIDs
 *  - PMT (PID 0x1000) describes elementary streams in a program
 *  - PES packets on PID 0x0100 carry H.264 video data
 *  - Each PID has an independent 4-bit continuity counter (wraps at 16)
 */

#include "ts_muxer.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

#define TS_PACKET_SIZE      188
#define TS_SYNC_BYTE        0x47

#define PID_PAT             0x0000
#define PID_PMT             0x1000
#define PID_VIDEO           0x0100
#define PID_AUDIO           0x0101

#define STREAM_TYPE_H264    0x1B
#define STREAM_TYPE_AAC     0x0F
#define STREAM_ID_VIDEO     0xE0
#define STREAM_ID_AUDIO     0xC0

#define INITIAL_BUFFER_SIZE (256 * 1024)  /* 256 KB */
#define PCR_INTERVAL_90KHZ 3600          /* 40ms in 90kHz ticks */

/* ------------------------------------------------------------------ */
/* CRC32/MPEG2 lookup table                                            */
/* ------------------------------------------------------------------ */

static uint32_t crc32_table[256];
static pthread_once_t crc32_once = PTHREAD_ONCE_INIT;

/**
 * Initialize the CRC32/MPEG2 lookup table.
 * MPEG-2 CRC uses polynomial 0x04C11DB7 with no final inversion.
 * Thread-safe via pthread_once.
 */
static void
crc32_init_table(void)
{
    for (int i = 0; i < 256; i++) {
        uint32_t crc = (uint32_t)i << 24;
        for (int j = 0; j < 8; j++) {
            if (crc & 0x80000000) {
                crc = (crc << 1) ^ 0x04C11DB7;
            } else {
                crc = crc << 1;
            }
        } // end of bit loop (j)
        crc32_table[i] = crc;
    } // end of byte loop (i)
} // end of function crc32_init_table()

/**
 * Compute CRC32/MPEG2 over a block of data.
 * @param data   Pointer to the data
 * @param length Number of bytes
 * @return CRC32 value
 */
static uint32_t
crc32_mpeg2(const uint8_t *data, size_t length)
{
    pthread_once(&crc32_once, crc32_init_table);

    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc = (crc << 8) ^ crc32_table[((crc >> 24) ^ data[i]) & 0xFF];
    }
    return crc;
} // end of function crc32_mpeg2()

/* ------------------------------------------------------------------ */
/* Muxer state structure                                               */
/* ------------------------------------------------------------------ */

struct ts_muxer_s {
    /* Segment configuration */
    int segment_duration_seconds;
    ts_segment_callback_t callback;
    void *callback_ctx;

    /* SPS/PPS parameter sets (stored copies, without start codes) */
    uint8_t *sps;
    size_t sps_size;
    uint8_t *pps;
    size_t pps_size;

    /* Segment buffer (accumulates TS packets) */
    uint8_t *segment_buf;
    size_t segment_buf_size;     /* allocated size */
    size_t segment_buf_used;     /* bytes written */

    /* Timing */
    uint64_t segment_start_pts;  /* PTS of first frame in current segment (us) */
    uint64_t segment_last_pts;   /* PTS of last frame pushed (us) */
    int segment_has_data;        /* non-zero if segment_buf has any video data */

    /* Segment index counter */
    uint64_t segment_index;

    /* Continuity counters (4-bit, per PID) */
    uint8_t cc_pat;
    uint8_t cc_pmt;
    uint8_t cc_video;
    uint8_t cc_audio;

    /* AAC configuration used to build ADTS headers */
    int audio_sample_rate;
    int audio_channels;
    int has_audio;
    int segment_audio_enabled;

    /* Startup/resync state: drop frames until first IDR */
    int waiting_for_keyframe;

    /* PCR cadence: next deadline in 90kHz ticks for PCR insertion */
    uint64_t next_pcr_90khz;
};

/* ------------------------------------------------------------------ */
/* Internal helpers: buffer management                                 */
/* ------------------------------------------------------------------ */

/**
 * Ensure the segment buffer has room for at least `needed` more bytes.
 * Grows the buffer by 2x when capacity is insufficient.
 * @param muxer  The muxer instance
 * @param needed Number of additional bytes required
 * @return 0 on success, -1 on allocation failure
 */
static int
ensure_buffer_space(ts_muxer_t *muxer, size_t needed)
{
    if (muxer->segment_buf_used + needed <= muxer->segment_buf_size) {
        return 0;
    }

    size_t new_size = muxer->segment_buf_size;
    while (new_size < muxer->segment_buf_used + needed) {
        new_size *= 2;
    }

    uint8_t *new_buf = realloc(muxer->segment_buf, new_size);
    if (!new_buf) {
        return -1;
    }

    muxer->segment_buf = new_buf;
    muxer->segment_buf_size = new_size;
    return 0;
} // end of function ensure_buffer_space()

/**
 * Append a complete 188-byte TS packet to the segment buffer.
 * @param muxer  The muxer instance
 * @param packet Pointer to a 188-byte TS packet
 * @return 0 on success, -1 on allocation failure
 */
static int
append_ts_packet(ts_muxer_t *muxer, const uint8_t *packet)
{
    if (ensure_buffer_space(muxer, TS_PACKET_SIZE) != 0) {
        return -1;
    }
    memcpy(muxer->segment_buf + muxer->segment_buf_used, packet, TS_PACKET_SIZE);
    muxer->segment_buf_used += TS_PACKET_SIZE;
    return 0;
} // end of function append_ts_packet()

/* ------------------------------------------------------------------ */
/* Internal helpers: TS packet construction                            */
/* ------------------------------------------------------------------ */

/**
 * Write a PAT (Program Association Table) as a single TS packet.
 *
 * PAT structure (after TS header + pointer_field):
 *   table_id (8)         = 0x00
 *   section_syntax (1)   = 1
 *   '0' (1)              = 0
 *   reserved (2)         = 0x3
 *   section_length (12)  = 13 (5 header + 4 program + 4 CRC)
 *   transport_stream_id (16) = 0x0001
 *   reserved (2)         = 0x3
 *   version (5)          = 0
 *   current_next (1)     = 1
 *   section_number (8)   = 0
 *   last_section (8)     = 0
 *   program_number (16)  = 0x0001
 *   reserved (3)         = 0x7
 *   program_map_PID (13) = 0x1000
 *   CRC32 (32)
 *
 * @param muxer The muxer instance
 * @return 0 on success, -1 on failure
 */
static int
write_pat(ts_muxer_t *muxer)
{
    uint8_t packet[TS_PACKET_SIZE];
    memset(packet, 0xFF, TS_PACKET_SIZE);

    /* TS header (4 bytes) */
    packet[0] = TS_SYNC_BYTE;
    packet[1] = 0x40 | ((PID_PAT >> 8) & 0x1F);  /* PUSI=1, PID high */
    packet[2] = PID_PAT & 0xFF;                    /* PID low */
    packet[3] = 0x10 | (muxer->cc_pat & 0x0F);    /* no adaptation, payload only */
    muxer->cc_pat = (muxer->cc_pat + 1) & 0x0F;

    /* Pointer field (1 byte) */
    packet[4] = 0x00;

    /* PAT section data */
    int section_start = 5;
    uint8_t *p = &packet[section_start];

    p[0] = 0x00;  /* table_id */
    /* section_syntax_indicator=1, '0'=0, reserved=11, section_length=13 */
    p[1] = 0xB0;
    p[2] = 13;    /* section_length: 5 (after length) + 4 (program) + 4 (CRC) */
    p[3] = 0x00;  /* transport_stream_id high */
    p[4] = 0x01;  /* transport_stream_id low */
    /* reserved=11, version=00000, current_next=1 */
    p[5] = 0xC1;
    p[6] = 0x00;  /* section_number */
    p[7] = 0x00;  /* last_section_number */
    /* program_number = 1 */
    p[8] = 0x00;
    p[9] = 0x01;
    /* reserved=111, program_map_PID = 0x1000 */
    p[10] = 0xE0 | ((PID_PMT >> 8) & 0x1F);
    p[11] = PID_PMT & 0xFF;

    /* CRC32 over section data (from table_id to just before CRC) */
    uint32_t crc = crc32_mpeg2(p, 12);
    p[12] = (crc >> 24) & 0xFF;
    p[13] = (crc >> 16) & 0xFF;
    p[14] = (crc >> 8) & 0xFF;
    p[15] = crc & 0xFF;

    return append_ts_packet(muxer, packet);
} // end of function write_pat()

/**
 * Write a PMT (Program Map Table) as a single TS packet.
 *
 * PMT structure (after TS header + pointer_field):
 *   table_id (8)         = 0x02
 *   section_syntax (1)   = 1
 *   '0' (1)              = 0
 *   reserved (2)         = 0x3
 *   section_length (12)  = 18 (video only) or 23 (video + audio)
 *   program_number (16)  = 0x0001
 *   reserved (2)         = 0x3
 *   version (5)          = 0
 *   current_next (1)     = 1
 *   section_number (8)   = 0
 *   last_section (8)     = 0
 *   reserved (3)         = 0x7
 *   PCR_PID (13)         = 0x0100
 *   reserved (4)         = 0xF
 *   program_info_length (12) = 0
 *   -- stream entry (video) --
 *   stream_type (8)      = 0x1B (H.264)
 *   reserved (3)         = 0x7
 *   elementary_PID (13)  = 0x0100
 *   reserved (4)         = 0xF
 *   ES_info_length (12)  = 0
 *   -- optional stream entry (audio) --
 *   stream_type (8)      = 0x0F (AAC/ADTS)
 *   reserved (3)         = 0x7
 *   elementary_PID (13)  = 0x0101
 *   reserved (4)         = 0xF
 *   ES_info_length (12)  = 0
 *   CRC32 (32)
 *
 * @param muxer The muxer instance
 * @return 0 on success, -1 on failure
 */
static int
write_pmt(ts_muxer_t *muxer)
{
    uint8_t packet[TS_PACKET_SIZE];
    memset(packet, 0xFF, TS_PACKET_SIZE);

    /* TS header (4 bytes) */
    packet[0] = TS_SYNC_BYTE;
    packet[1] = 0x40 | ((PID_PMT >> 8) & 0x1F);  /* PUSI=1, PID high */
    packet[2] = PID_PMT & 0xFF;                    /* PID low */
    packet[3] = 0x10 | (muxer->cc_pmt & 0x0F);    /* no adaptation, payload only */
    muxer->cc_pmt = (muxer->cc_pmt + 1) & 0x0F;

    /* Pointer field */
    packet[4] = 0x00;

    /* PMT section data */
    int section_start = 5;
    uint8_t *p = &packet[section_start];

    p[0] = 0x02;  /* table_id */
    int section_length = muxer->has_audio ? 23 : 18;
    /* section_syntax_indicator=1, '0'=0, reserved=11 */
    p[1] = 0xB0;
    p[2] = (uint8_t)section_length;
    p[3] = 0x00;  /* program_number high */
    p[4] = 0x01;  /* program_number low */
    /* reserved=11, version=00000, current_next=1 */
    p[5] = 0xC1;
    p[6] = 0x00;  /* section_number */
    p[7] = 0x00;  /* last_section_number */
    /* reserved=111, PCR_PID = 0x0100 */
    p[8] = 0xE0 | ((PID_VIDEO >> 8) & 0x1F);
    p[9] = PID_VIDEO & 0xFF;
    /* reserved=1111, program_info_length = 0 */
    p[10] = 0xF0;
    p[11] = 0x00;

    /* Stream entry: H.264 video on PID 0x0100 */
    p[12] = STREAM_TYPE_H264;   /* stream_type */
    /* reserved=111, elementary_PID = 0x0100 */
    p[13] = 0xE0 | ((PID_VIDEO >> 8) & 0x1F);
    p[14] = PID_VIDEO & 0xFF;
    /* reserved=1111, ES_info_length = 0 */
    p[15] = 0xF0;
    p[16] = 0x00;

    int section_data_len = 17; /* through video entry */

    if (muxer->has_audio) {
        /* Optional stream entry: AAC audio on PID 0x0101 */
        p[17] = STREAM_TYPE_AAC;
        p[18] = 0xE0 | ((PID_AUDIO >> 8) & 0x1F);
        p[19] = PID_AUDIO & 0xFF;
        p[20] = 0xF0;
        p[21] = 0x00;
        section_data_len = 22;
    }

    /* CRC32 over section data (from table_id through stream entries) */
    uint32_t crc = crc32_mpeg2(p, (size_t)section_data_len);
    p[section_data_len + 0] = (crc >> 24) & 0xFF;
    p[section_data_len + 1] = (crc >> 16) & 0xFF;
    p[section_data_len + 2] = (crc >> 8) & 0xFF;
    p[section_data_len + 3] = crc & 0xFF;

    return append_ts_packet(muxer, packet);
} // end of function write_pmt()

/**
 * Write 5-byte PTS (or DTS) field in PES header format.
 * The 33-bit timestamp is encoded across 5 bytes with marker bits.
 *
 * Format: '00xx' (4 bits marker) | PTS[32..30] | '1' | PTS[29..15] | '1' | PTS[14..0] | '1'
 *
 * @param buf    Destination buffer (at least 5 bytes)
 * @param marker Upper 4-bit marker value (0x20 for PTS-only, 0x30 for PTS in PTS+DTS, 0x10 for DTS)
 * @param ts     The 33-bit timestamp in 90kHz units
 */
static void
write_pts_dts(uint8_t *buf, uint8_t marker, uint64_t ts)
{
    buf[0] = (uint8_t)(marker | (((ts >> 30) & 0x07) << 1) | 0x01);
    buf[1] = (uint8_t)((ts >> 22) & 0xFF);
    buf[2] = (uint8_t)((((ts >> 15) & 0x7F) << 1) | 0x01);
    buf[3] = (uint8_t)((ts >> 7) & 0xFF);
    buf[4] = (uint8_t)(((ts & 0x7F) << 1) | 0x01);
} // end of function write_pts_dts()

/**
 * Write PCR (Program Clock Reference) into a 6-byte adaptation field area.
 * PCR = base (33 bits, 90 kHz) + extension (9 bits, 27 MHz).
 * We set extension to 0 for simplicity (sufficient precision for HLS).
 *
 * Format: base[32..25] | base[24..17] | base[16..9] | base[8..1] |
 *         base[0] | reserved(6) | ext[8] | ext[7..0]
 *
 * @param buf      Destination buffer (at least 6 bytes)
 * @param pcr_base The 33-bit PCR base value in 90kHz units
 */
static void
write_pcr(uint8_t *buf, uint64_t pcr_base)
{
    uint64_t pcr_ext = 0;
    buf[0] = (uint8_t)((pcr_base >> 25) & 0xFF);
    buf[1] = (uint8_t)((pcr_base >> 17) & 0xFF);
    buf[2] = (uint8_t)((pcr_base >> 9) & 0xFF);
    buf[3] = (uint8_t)((pcr_base >> 1) & 0xFF);
    buf[4] = (uint8_t)(((pcr_base & 0x01) << 7) | 0x7E | ((pcr_ext >> 8) & 0x01));
    buf[5] = (uint8_t)(pcr_ext & 0xFF);
} // end of function write_pcr()

/**
 * Build an Annex B formatted access unit from AVCC-format NAL data.
 * On keyframes, SPS and PPS are prepended with start codes.
 *
 * AVCC format: [4-byte big-endian length][NAL unit] repeated
 * Annex B format: [00 00 00 01][NAL unit] repeated
 *
 * @param muxer       The muxer instance (for SPS/PPS)
 * @param avcc_data   Input AVCC-format NAL data
 * @param avcc_size   Size of avcc_data in bytes
 * @param is_keyframe Non-zero to prepend SPS/PPS
 * @param out_data    Output pointer to allocated Annex B data (caller must free)
 * @param out_size    Output size of the Annex B data
 * @return 0 on success, -1 on failure
 */
static int
build_annex_b_au(ts_muxer_t *muxer, uint8_t *avcc_data, size_t avcc_size,
                 int is_keyframe, uint8_t **out_data, size_t *out_size)
{
    /* Calculate output size: for each NAL, replace 4-byte length with 4-byte start code.
       Add 6 bytes for AUD NAL unit (start code + 2-byte NAL).
       For keyframes, also add SPS (4 + sps_size) and PPS (4 + pps_size). */
    size_t estimated_size = avcc_size + 6;  /* +6 for AUD NAL with start code */
    if (is_keyframe && muxer->sps && muxer->pps) {
        estimated_size += 4 + muxer->sps_size + 4 + muxer->pps_size;
    }

    uint8_t *buf = malloc(estimated_size);
    if (!buf) {
        return -1;
    }

    size_t offset = 0;

    /* Prepend AUD (Access Unit Delimiter) NAL unit.
       Required by HLS spec for proper access unit boundary detection in browsers.
       AUD NAL: nal_ref_idc=0, nal_unit_type=9, primary_pic_type=7 (any). */
    buf[offset++] = 0x00;
    buf[offset++] = 0x00;
    buf[offset++] = 0x00;
    buf[offset++] = 0x01;
    buf[offset++] = 0x09;  /* NAL header: type 9 (AUD) */
    buf[offset++] = 0xF0;  /* primary_pic_type=7 (111), rbsp_stop=1, align=0000 */

    /* Prepend SPS and PPS with Annex B start codes on keyframes */
    if (is_keyframe && muxer->sps && muxer->pps) {
        /* SPS */
        buf[offset++] = 0x00;
        buf[offset++] = 0x00;
        buf[offset++] = 0x00;
        buf[offset++] = 0x01;
        memcpy(buf + offset, muxer->sps, muxer->sps_size);
        offset += muxer->sps_size;

        /* PPS */
        buf[offset++] = 0x00;
        buf[offset++] = 0x00;
        buf[offset++] = 0x00;
        buf[offset++] = 0x01;
        memcpy(buf + offset, muxer->pps, muxer->pps_size);
        offset += muxer->pps_size;
    } // end of keyframe SPS/PPS prepend

    /* Convert each NAL unit from AVCC (length-prefixed) to Annex B (start code prefixed) */
    int parse_error = 0;
    size_t pos = 0;
    while (pos + 4 <= avcc_size) {
        /* Read 4-byte big-endian NAL unit length */
        uint32_t nal_len = ((uint32_t)avcc_data[pos] << 24) |
                           ((uint32_t)avcc_data[pos + 1] << 16) |
                           ((uint32_t)avcc_data[pos + 2] << 8) |
                           ((uint32_t)avcc_data[pos + 3]);
        pos += 4;

        if (nal_len == 0 || pos + nal_len > avcc_size) {
            parse_error = 1;
            break;
        }

        /* Write Annex B start code */
        buf[offset++] = 0x00;
        buf[offset++] = 0x00;
        buf[offset++] = 0x00;
        buf[offset++] = 0x01;

        /* Copy NAL unit data */
        memcpy(buf + offset, avcc_data + pos, nal_len);
        offset += nal_len;
        pos += nal_len;
    } // end of AVCC-to-Annex-B NAL conversion loop

    /* Treat malformed AVCC data as a hard error: don't emit partial AUs.
       Also reject if trailing bytes remain (pos != avcc_size). */
    if (parse_error || offset == 0 || pos != avcc_size) {
        free(buf);
        return -1;
    }

    *out_data = buf;
    *out_size = offset;
    return 0;
} // end of function build_annex_b_au()

/**
 * Write a PES-wrapped H.264 access unit as a series of TS packets.
 * The first TS packet includes an adaptation field with PCR (for keyframes)
 * and the PES header with PTS. Subsequent packets are continuation packets.
 *
 * @param muxer       The muxer instance
 * @param au_data     Annex B formatted access unit data
 * @param au_size     Size of au_data in bytes
 * @param pts_us      Presentation timestamp in microseconds
 * @param is_keyframe Non-zero if this is a keyframe
 * @return 0 on success, -1 on failure
 */
static int
write_pes_packets(ts_muxer_t *muxer, uint8_t *au_data, size_t au_size,
                  uint64_t pts_us, int is_keyframe)
{
    /* Convert PTS from microseconds to 90kHz MPEG-TS clock */
    uint64_t pts_90khz = pts_us * 90 / 1000;

    /* Build PES header */
    /* PES header: start_code(3) + stream_id(1) + pes_length(2) + flags(2) + header_data_length(1) + PTS(5) = 14 bytes */
    uint8_t pes_header[14];
    pes_header[0] = 0x00;  /* packet_start_code_prefix */
    pes_header[1] = 0x00;
    pes_header[2] = 0x01;
    pes_header[3] = STREAM_ID_VIDEO;  /* stream_id */

    /* PES packet length: 0 means unbounded (allowed for video in TS) */
    pes_header[4] = 0x00;
    pes_header[5] = 0x00;

    /* Flags: '10' (2), PES_scrambling_control=00, PES_priority=0,
       data_alignment_indicator=1, copyright=0, original_or_copy=0 */
    pes_header[6] = 0x84;  /* 10 00 0 1 0 0 = 0x84 (data alignment set) */
    /* PTS_DTS_flags=10 (PTS only), rest=0 */
    pes_header[7] = 0x80;
    /* PES_header_data_length = 5 (PTS only) */
    pes_header[8] = 0x05;

    /* Write PTS (marker 0x20 for PTS-only) */
    write_pts_dts(&pes_header[9], 0x20, pts_90khz);

    size_t pes_header_len = 14;

    /* Total PES payload = PES header + AU data */
    size_t total_payload = pes_header_len + au_size;
    size_t payload_pos = 0;  /* how much of total_payload we've written */

    int first_packet = 1;

    while (payload_pos < total_payload) {
        uint8_t packet[TS_PACKET_SIZE];
        memset(packet, 0xFF, TS_PACKET_SIZE);

        /* TS header (4 bytes) */
        packet[0] = TS_SYNC_BYTE;

        uint8_t pusi = first_packet ? 0x40 : 0x00;
        packet[1] = pusi | ((PID_VIDEO >> 8) & 0x1F);
        packet[2] = PID_VIDEO & 0xFF;

        size_t header_size = 4;   /* TS header so far */
        size_t adapt_size = 0;    /* adaptation field size (including length byte) */
        int include_adapt = 0;

        /* Calculate available payload space to determine if we need adaptation field stuffing */
        size_t remaining_payload = total_payload - payload_pos;

        /* Determine if this packet needs PCR:
           - Always on keyframe first packets (with random_access_indicator)
           - On first packet when PCR cadence deadline is reached (~40ms) */
        int need_pcr = 0;
        if (first_packet) {
            if (is_keyframe || pts_90khz >= muxer->next_pcr_90khz) {
                need_pcr = 1;
            }
        }

        if (need_pcr) {
            /* Include adaptation field with PCR.
               Adaptation field: length(1) + flags(1) + PCR(6) = 8 bytes */
            include_adapt = 1;
            adapt_size = 8;

            size_t available = TS_PACKET_SIZE - header_size - adapt_size;
            if (remaining_payload < available) {
                /* Need stuffing bytes to fill the packet */
                size_t stuff = available - remaining_payload;
                adapt_size += stuff;
            }

            packet[3] = 0x30 | (muxer->cc_video & 0x0F);  /* adaptation + payload */
            muxer->cc_video = (muxer->cc_video + 1) & 0x0F;

            /* Adaptation field */
            size_t af_start = header_size;
            packet[af_start] = (uint8_t)(adapt_size - 1);  /* adaptation_field_length (excludes itself) */
            /* Flags: PCR_flag=1, random_access_indicator=1 only on keyframes */
            packet[af_start + 1] = is_keyframe ? 0x50 : 0x10;  /* PCR + optional random_access */

            /* PCR (6 bytes) */
            write_pcr(&packet[af_start + 2], pts_90khz);
            muxer->next_pcr_90khz = pts_90khz + PCR_INTERVAL_90KHZ;

            /* Fill remaining adaptation field with stuffing bytes (0xFF) */
            for (size_t s = 8; s < adapt_size; s++) {
                packet[af_start + s] = 0xFF;
            }
        } else {
            /* No PCR needed: may still need adaptation field for stuffing
               if payload doesn't fill the packet */
            size_t available = TS_PACKET_SIZE - header_size;
            if (remaining_payload < available) {
                /* Need adaptation field for stuffing */
                include_adapt = 1;
                adapt_size = available - remaining_payload;

                /* Minimum adaptation field is 1 byte (length=0, no flags).
                   If >= 2 bytes, we have length byte + flags byte + optional stuffing. */
                if (adapt_size == 1) {
                    /* adaptation_field_length = 0: just the length byte, no flags */
                    adapt_size = 1;
                } else if (adapt_size < 2) {
                    adapt_size = 2;
                }

                packet[3] = 0x30 | (muxer->cc_video & 0x0F);  /* adaptation + payload */
                muxer->cc_video = (muxer->cc_video + 1) & 0x0F;

                size_t af_start = header_size;
                packet[af_start] = (uint8_t)(adapt_size - 1);  /* adaptation_field_length */
                if (adapt_size >= 2) {
                    packet[af_start + 1] = 0x00;  /* no flags set */
                }
                /* Stuff remaining with 0xFF */
                for (size_t s = 2; s < adapt_size; s++) {
                    packet[af_start + s] = 0xFF;
                }
            } else {
                /* No adaptation field needed, payload fills entire packet */
                packet[3] = 0x10 | (muxer->cc_video & 0x0F);  /* payload only */
                muxer->cc_video = (muxer->cc_video + 1) & 0x0F;
            }
        } // end of TS header + adaptation field construction

        /* Calculate payload offset within the packet */
        size_t payload_start = header_size + (include_adapt ? adapt_size : 0);
        size_t payload_space = TS_PACKET_SIZE - payload_start;

        /* Copy payload data (PES header first, then AU data) */
        size_t written = 0;
        while (written < payload_space && payload_pos < total_payload) {
            if (payload_pos < pes_header_len) {
                /* Still writing PES header bytes */
                size_t pes_remaining = pes_header_len - payload_pos;
                size_t space_remaining = payload_space - written;
                size_t chunk = (pes_remaining < space_remaining) ? pes_remaining : space_remaining;
                memcpy(&packet[payload_start + written], &pes_header[payload_pos], chunk);
                payload_pos += chunk;
                written += chunk;
            } else {
                /* Writing AU data */
                size_t au_offset = payload_pos - pes_header_len;
                size_t au_remaining = au_size - au_offset;
                size_t space_remaining = payload_space - written;
                size_t chunk = (au_remaining < space_remaining) ? au_remaining : space_remaining;
                memcpy(&packet[payload_start + written], &au_data[au_offset], chunk);
                payload_pos += chunk;
                written += chunk;
            }
        } // end of payload copy loop

        if (append_ts_packet(muxer, packet) != 0) {
            return -1;
        }

        first_packet = 0;
    } // end of TS packet generation loop for this PES

    return 0;
} // end of function write_pes_packets()

/**
 * Map AAC sample rate (Hz) to ADTS sampling_frequency_index.
 * Falls back to 48 kHz index when unknown.
 */
static int
aac_sample_rate_index(int sample_rate)
{
    static const int rates[] = {
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350
    };

    for (int i = 0; i < (int)(sizeof(rates) / sizeof(rates[0])); i++) {
        if (rates[i] == sample_rate) {
            return i;
        }
    }
    return 3; /* 48kHz */
}

/**
 * Build a 7-byte ADTS header for one AAC-LC frame.
 */
static void
build_adts_header(uint8_t *hdr, size_t aac_payload_size, int sample_rate, int channels)
{
    int sr_idx = aac_sample_rate_index(sample_rate);
    int chan = channels < 1 ? 2 : channels;
    if (chan > 7) {
        chan = 2;
    }

    size_t frame_len = aac_payload_size + 7;

    /* MPEG-4 AAC LC, no CRC */
    hdr[0] = 0xFF;
    hdr[1] = 0xF1; /* 1111 1 00 1: sync + MPEG-4 + layer + protection_absent */
    hdr[2] = (uint8_t)(((2 - 1) << 6) | ((sr_idx & 0x0F) << 2) | ((chan >> 2) & 0x01));
    hdr[3] = (uint8_t)(((chan & 0x03) << 6) | ((frame_len >> 11) & 0x03));
    hdr[4] = (uint8_t)((frame_len >> 3) & 0xFF);
    hdr[5] = (uint8_t)(((frame_len & 0x07) << 5) | 0x1F);
    hdr[6] = 0xFC;
}

/**
 * Write a PES-wrapped AAC frame as TS packets on the audio PID.
 */
static int
write_pes_audio_packets(ts_muxer_t *muxer, uint8_t *adts_frame, size_t adts_size, uint64_t pts_us)
{
    uint64_t pts_90khz = pts_us * 90 / 1000;

    uint8_t pes_header[14];
    pes_header[0] = 0x00;
    pes_header[1] = 0x00;
    pes_header[2] = 0x01;
    pes_header[3] = STREAM_ID_AUDIO;

    /* PES length includes bytes after this field: 3 + 5 + payload */
    uint32_t pes_len = (uint32_t)(adts_size + 8);
    if (pes_len > 0xFFFF) {
        pes_len = 0;
    }
    pes_header[4] = (uint8_t)((pes_len >> 8) & 0xFF);
    pes_header[5] = (uint8_t)(pes_len & 0xFF);
    pes_header[6] = 0x80;
    pes_header[7] = 0x80; /* PTS only */
    pes_header[8] = 0x05;
    write_pts_dts(&pes_header[9], 0x20, pts_90khz);

    size_t pes_header_len = 14;
    size_t total_payload = pes_header_len + adts_size;
    size_t payload_pos = 0;
    int first_packet = 1;

    while (payload_pos < total_payload) {
        uint8_t packet[TS_PACKET_SIZE];
        memset(packet, 0xFF, TS_PACKET_SIZE);

        packet[0] = TS_SYNC_BYTE;
        packet[1] = (first_packet ? 0x40 : 0x00) | ((PID_AUDIO >> 8) & 0x1F);
        packet[2] = PID_AUDIO & 0xFF;

        size_t header_size = 4;
        size_t remaining_payload = total_payload - payload_pos;
        size_t payload_start = header_size;
        size_t payload_space = TS_PACKET_SIZE - payload_start;

        if (remaining_payload < payload_space) {
            /* Add adaptation field stuffing on final short packet. */
            size_t adapt_size = payload_space - remaining_payload;
            if (adapt_size < 2) {
                adapt_size = 2;
            }

            packet[3] = 0x30 | (muxer->cc_audio & 0x0F);
            muxer->cc_audio = (muxer->cc_audio + 1) & 0x0F;

            size_t af_start = header_size;
            packet[af_start] = (uint8_t)(adapt_size - 1);
            packet[af_start + 1] = 0x00;
            for (size_t s = 2; s < adapt_size; s++) {
                packet[af_start + s] = 0xFF;
            }

            payload_start = header_size + adapt_size;
            payload_space = TS_PACKET_SIZE - payload_start;
        } else {
            packet[3] = 0x10 | (muxer->cc_audio & 0x0F);
            muxer->cc_audio = (muxer->cc_audio + 1) & 0x0F;
        }

        size_t written = 0;
        while (written < payload_space && payload_pos < total_payload) {
            if (payload_pos < pes_header_len) {
                size_t pes_remaining = pes_header_len - payload_pos;
                size_t space_remaining = payload_space - written;
                size_t chunk = (pes_remaining < space_remaining) ? pes_remaining : space_remaining;
                memcpy(&packet[payload_start + written], &pes_header[payload_pos], chunk);
                payload_pos += chunk;
                written += chunk;
            } else {
                size_t adts_offset = payload_pos - pes_header_len;
                size_t adts_remaining = adts_size - adts_offset;
                size_t space_remaining = payload_space - written;
                size_t chunk = (adts_remaining < space_remaining) ? adts_remaining : space_remaining;
                memcpy(&packet[payload_start + written], &adts_frame[adts_offset], chunk);
                payload_pos += chunk;
                written += chunk;
            }
        }

        if (append_ts_packet(muxer, packet) != 0) {
            return -1;
        }

        first_packet = 0;
    }

    return 0;
}

/**
 * Drop the current segment due to an error, resetting buffer state
 * and forcing re-sync on the next keyframe.
 * @param muxer The muxer instance
 */
static void
drop_current_segment(ts_muxer_t *muxer)
{
    muxer->segment_buf_used = 0;
    muxer->segment_has_data = 0;
    muxer->segment_start_pts = 0;
    muxer->segment_last_pts = 0;
    muxer->waiting_for_keyframe = 1;
    muxer->segment_audio_enabled = 0;
} // end of function drop_current_segment()

/**
 * Emit the current segment via the callback and reset the buffer.
 * Calculates segment duration from the PTS of the first and last frames.
 * @param muxer The muxer instance
 */
static void
emit_segment(ts_muxer_t *muxer)
{
    if (!muxer->segment_has_data || muxer->segment_buf_used == 0) {
        return;
    }

    double duration = 0.0;
    if (muxer->segment_last_pts > muxer->segment_start_pts) {
        duration = (double)(muxer->segment_last_pts - muxer->segment_start_pts) / 1000000.0;
    }

    if (muxer->callback) {
        muxer->callback(muxer->callback_ctx, muxer->segment_buf,
                        muxer->segment_buf_used, duration, muxer->segment_index);
    }

    muxer->segment_index++;
    muxer->segment_buf_used = 0;
    muxer->segment_has_data = 0;
    muxer->segment_audio_enabled = 0;
} // end of function emit_segment()

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

/**
 * Create a new MPEG-TS muxer instance.
 * @param segment_duration_seconds Target duration for each segment in seconds
 * @param callback                 Callback to invoke when a segment is complete
 * @param context                  User context passed to the callback
 * @return New muxer instance, or NULL on allocation failure
 */
ts_muxer_t *
ts_muxer_create(int segment_duration_seconds, ts_segment_callback_t callback, void *context)
{
    ts_muxer_t *muxer = calloc(1, sizeof(ts_muxer_t));
    if (!muxer) {
        return NULL;
    }

    muxer->segment_duration_seconds = segment_duration_seconds;
    muxer->callback = callback;
    muxer->callback_ctx = context;

    muxer->sps = NULL;
    muxer->sps_size = 0;
    muxer->pps = NULL;
    muxer->pps_size = 0;

    muxer->segment_buf = malloc(INITIAL_BUFFER_SIZE);
    if (!muxer->segment_buf) {
        free(muxer);
        return NULL;
    }
    muxer->segment_buf_size = INITIAL_BUFFER_SIZE;
    muxer->segment_buf_used = 0;

    muxer->segment_start_pts = 0;
    muxer->segment_last_pts = 0;
    muxer->segment_has_data = 0;
    muxer->segment_index = 0;

    muxer->cc_pat = 0;
    muxer->cc_pmt = 0;
    muxer->cc_video = 0;
    muxer->cc_audio = 0;
    muxer->audio_sample_rate = 48000;
    muxer->audio_channels = 2;
    muxer->has_audio = 0;
    muxer->segment_audio_enabled = 0;

    muxer->waiting_for_keyframe = 1;  /* wait for first IDR before emitting data */
    muxer->next_pcr_90khz = 0;       /* force PCR on first AU */

    return muxer;
} // end of function ts_muxer_create()

/**
 * Destroy a muxer instance and free all associated resources.
 * @param muxer The muxer instance to destroy (may be NULL)
 */
void
ts_muxer_destroy(ts_muxer_t *muxer)
{
    if (!muxer) {
        return;
    }

    if (muxer->segment_buf) {
        free(muxer->segment_buf);
        muxer->segment_buf = NULL;
    }

    if (muxer->sps) {
        free(muxer->sps);
        muxer->sps = NULL;
    }

    if (muxer->pps) {
        free(muxer->pps);
        muxer->pps = NULL;
    }

    free(muxer);
} // end of function ts_muxer_destroy()

/**
 * Push an H.264 access unit (one or more NAL units) to the muxer.
 * The data must be in AVCC format (4-byte big-endian length prefix per NAL).
 * The muxer converts to Annex B format, wraps in PES/TS packets, and
 * accumulates into the current segment.
 *
 * Segment boundary logic: when a keyframe arrives and the current segment
 * duration >= target duration, the current segment is emitted first.
 *
 * @param muxer       The muxer instance
 * @param nal_data    H.264 NAL data in AVCC format
 * @param nal_size    Size of nal_data in bytes
 * @param pts         Presentation timestamp in microseconds
 * @param is_keyframe Non-zero if this is a keyframe (IDR)
 */
void
ts_muxer_push_h264(ts_muxer_t *muxer, uint8_t *nal_data, size_t nal_size,
                   uint64_t pts, int is_keyframe)
{
    if (!muxer || !nal_data || nal_size == 0) {
        return;
    }

    /* Drop frames until first IDR after start or error recovery */
    if (muxer->waiting_for_keyframe) {
        if (!is_keyframe) {
            return;
        }
        muxer->waiting_for_keyframe = 0;
    }

    /* Check if we should start a new segment:
       a keyframe has arrived and the current segment has enough duration.
       Use a tolerance of 100ms to account for keyframes arriving slightly
       before the exact boundary (e.g. 1.967s when target is 2.0s). */
    if (is_keyframe && muxer->segment_has_data) {
        double elapsed = (double)(pts - muxer->segment_start_pts) / 1000000.0;
        double threshold = (double)muxer->segment_duration_seconds - 0.1;
        if (elapsed >= threshold) {
            emit_segment(muxer);
        }
    } // end of segment boundary check

    /* If starting a new segment (either first frame or after emit), record start PTS */
    if (!muxer->segment_has_data) {
        muxer->segment_start_pts = pts;

        /* Write PAT and PMT at the start of each segment */
        if (write_pat(muxer) != 0 || write_pmt(muxer) != 0) {
            drop_current_segment(muxer);
            return;
        }
        muxer->segment_audio_enabled = muxer->has_audio;
    }

    /* Convert AVCC to Annex B format */
    uint8_t *au_data = NULL;
    size_t au_size = 0;
    if (build_annex_b_au(muxer, nal_data, nal_size, is_keyframe, &au_data, &au_size) != 0) {
        drop_current_segment(muxer);
        return;
    }

    /* Write PES-wrapped TS packets */
    if (write_pes_packets(muxer, au_data, au_size, pts, is_keyframe) != 0) {
        free(au_data);
        drop_current_segment(muxer);
        return;
    }

    free(au_data);

    muxer->segment_last_pts = pts;
    muxer->segment_has_data = 1;
} // end of function ts_muxer_push_h264()

void
ts_muxer_push_aac(ts_muxer_t *muxer, uint8_t *aac_data, size_t aac_size,
                  uint64_t pts, int sample_rate, int channels)
{
    if (!muxer || !aac_data || aac_size == 0) {
        return;
    }

    /* Keep muxer audio config up to date for ADTS headers. */
    if (sample_rate > 0) {
        muxer->audio_sample_rate = sample_rate;
    }
    if (channels > 0) {
        muxer->audio_channels = channels;
    }

    if (!muxer->has_audio) {
        /* Enable audio from the next segment boundary to keep PMT and packets aligned. */
        muxer->has_audio = 1;
        return;
    }

    /* Do not start segments from audio before first video keyframe, and only
       write audio when this segment's PMT advertises an audio stream. */
    if (muxer->waiting_for_keyframe || !muxer->segment_has_data || !muxer->segment_audio_enabled) {
        return;
    }

    uint8_t *adts_frame = malloc(aac_size + 7);
    if (!adts_frame) {
        return;
    }

    build_adts_header(adts_frame, aac_size, muxer->audio_sample_rate, muxer->audio_channels);
    memcpy(adts_frame + 7, aac_data, aac_size);

    if (write_pes_audio_packets(muxer, adts_frame, aac_size + 7, pts) != 0) {
        free(adts_frame);
        drop_current_segment(muxer);
        return;
    }

    free(adts_frame);

    if (pts > muxer->segment_last_pts) {
        muxer->segment_last_pts = pts;
    }
    muxer->segment_has_data = 1;
}

/**
 * Set the SPS and PPS parameter sets for the H.264 stream.
 * These are stored internally and prepended to keyframes in the TS output.
 * @param muxer    The muxer instance
 * @param sps      SPS NAL unit data (without start code or length prefix)
 * @param sps_size Size of the SPS data in bytes
 * @param pps      PPS NAL unit data (without start code or length prefix)
 * @param pps_size Size of the PPS data in bytes
 */
void
ts_muxer_set_sps_pps(ts_muxer_t *muxer, uint8_t *sps, size_t sps_size,
                      uint8_t *pps, size_t pps_size)
{
    if (!muxer) {
        return;
    }

    /* Update SPS */
    if (sps && sps_size > 0) {
        uint8_t *new_sps = malloc(sps_size);
        if (new_sps) {
            if (muxer->sps) {
                free(muxer->sps);
            }
            memcpy(new_sps, sps, sps_size);
            muxer->sps = new_sps;
            muxer->sps_size = sps_size;
        }
    }

    /* Update PPS */
    if (pps && pps_size > 0) {
        uint8_t *new_pps = malloc(pps_size);
        if (new_pps) {
            if (muxer->pps) {
                free(muxer->pps);
            }
            memcpy(new_pps, pps, pps_size);
            muxer->pps = new_pps;
            muxer->pps_size = pps_size;
        }
    }
} // end of function ts_muxer_set_sps_pps()

/**
 * Flush the current segment, invoking the callback with whatever data
 * has been accumulated so far. Used when stopping the stream.
 * @param muxer The muxer instance
 */
void
ts_muxer_flush(ts_muxer_t *muxer)
{
    if (!muxer) {
        return;
    }

    emit_segment(muxer);
} // end of function ts_muxer_flush()
