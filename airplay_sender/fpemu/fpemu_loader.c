/* Snapshot loader + public entry points.
 * Faithful port of loader.rs (fp_sap_exchange_standalone / _m3, dedupFixups). */
#include <stdlib.h>
#include <string.h>

#include "fpemu.h"
#include "fpemu_priv.h"

static uint16_t rd_u16(const uint8_t *d, size_t p) {
    return (uint16_t)(d[p] | (d[p + 1] << 8));
}
static uint32_t rd_u32(const uint8_t *d, size_t p) {
    return (uint32_t)d[p] | ((uint32_t)d[p + 1] << 8) |
           ((uint32_t)d[p + 2] << 16) | ((uint32_t)d[p + 3] << 24);
}
static uint64_t rd_u64(const uint8_t *d, size_t p) {
    uint64_t r = 0;
    for (int i = 0; i < 8; i++) r |= (uint64_t)d[p + i] << (i * 8);
    return r;
}

/* The constant 144-byte FPLY-framed prefix of every m3 response. */
static const uint8_t M3_PREFIX[144] = {
    0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00, 0x98,
    0x03, 0x8f, 0x1a, 0x9c, 0x99, 0x1e, 0xa2, 0x2c, 0x51, 0x1e, 0x45, 0xba,
    0x97, 0xf1, 0xaf, 0x8d, 0xfb, 0x0f, 0x86, 0xf5, 0x50, 0xc5, 0x44, 0x86,
    0xfe, 0x6b, 0x3a, 0xb2, 0x33, 0xda, 0x43, 0x1e, 0xf8, 0xe5, 0xfc, 0x11,
    0x56, 0xdb, 0xa3, 0x21, 0xff, 0xfe, 0xab, 0xb1, 0xb3, 0x92, 0xb0, 0x9d,
    0x22, 0x7e, 0x88, 0xc7, 0x12, 0x20, 0x28, 0x66, 0xeb, 0x7b, 0xbf, 0x31,
    0x00, 0x15, 0xaa, 0x1d, 0x19, 0xa5, 0xdf, 0x36, 0xd5, 0xdf, 0xd8, 0xd3,
    0xca, 0x16, 0x39, 0xb3, 0x76, 0xea, 0xec, 0xe9, 0x46, 0xed, 0xfe, 0x8b,
    0x7a, 0x66, 0xcd, 0x30, 0x2d, 0x04, 0xaa, 0xc3, 0xc1, 0x25, 0x17, 0x14,
    0x01, 0x9b, 0xd5, 0xf2, 0xd4, 0x9b, 0x54, 0x3e, 0x11, 0xee, 0xd1, 0x64,
    0x62, 0x91, 0xec, 0x8e, 0xfd, 0x96, 0xb6, 0x91, 0x01, 0xb8, 0x49, 0xfd,
    0x93, 0xa0, 0x28, 0x60, 0xd1, 0xa0, 0xdf, 0xf5, 0xcd, 0x44, 0x14, 0xaa};

/* Duplicate data regions zeroed in the snapshot, restored after page load.
 * (dst, src, n). */
typedef struct { uint64_t dst, src; size_t n; } dedup_fixup;
static const dedup_fixup DEDUP_FIXUPS[] = {
    {0x1b10a8020ULL, 0x1b10a6820ULL, 256}, {0x1b10a9420ULL, 0x1b10a8c20ULL, 256},
    {0x1b10aac20ULL, 0x1b10a5020ULL, 256}, {0x1b10ab820ULL, 0x1b10a5420ULL, 256},
    {0x1b10ac420ULL, 0x1b10aa020ULL, 256}, {0x1b10b1980ULL, 0x1b10b0d80ULL, 128},
    {0x1b10b4180ULL, 0x1b10b0d80ULL, 128}, {0x1b10b1080ULL, 0x1b10af880ULL, 128},
    {0x1b10a5180ULL, 0x1b10a3980ULL, 128}, {0x1b10ac180ULL, 0x1b10a3980ULL, 128},
    {0x1b10a9980ULL, 0x1b10a7980ULL, 128}, {0x1b10b7480ULL, 0x1b10b4880ULL, 128},
    {0x1b10b2980ULL, 0x1b10b0980ULL, 128}, {0x1b10b5480ULL, 0x1b10b3080ULL, 128},
    {0x1b10b5d80ULL, 0x1b10af980ULL, 128}, {0x1b10b7080ULL, 0x1b10b3c80ULL, 128},
    {0x1b10b2480ULL, 0x1b10b1c80ULL, 128}, {0x1b10b6580ULL, 0x1b10b2580ULL, 128},
    {0x1b10a6980ULL, 0x1b10a3d80ULL, 128}, {0x1b10a9580ULL, 0x1b10a4580ULL, 128},
    {0x1b10b5980ULL, 0x1b10b5180ULL, 128}, {0x1b10b7180ULL, 0x1b10b5180ULL, 128},
    {0x1b10a8980ULL, 0x1b10a7d80ULL, 128}, {0x1b10ab180ULL, 0x1b10a7d80ULL, 128},
    {0x1a12c6a80ULL, 0x1a12c3140ULL, 32}, {0x1a12cdaa0ULL, 0x1a12bfb80ULL, 32},
    {0x1a12d0aa0ULL, 0x1a12cf5e0ULL, 32}, {0x1a12d4460ULL, 0x1a12cc1a0ULL, 96},
    {0x1a12d4620ULL, 0x1a12cc360ULL, 32}, {0x1a12d4680ULL, 0x1a12cc3c0ULL, 32},
    {0x1a12d46e0ULL, 0x1a12cc420ULL, 32}, {0x1a12d4940ULL, 0x1a12cc680ULL, 32},
    {0x1a12d49a0ULL, 0x1a12cc6e0ULL, 32}, {0x1a12d4a60ULL, 0x1a12cc7a0ULL, 32},
    {0x1a12d8660ULL, 0x1a12cda40ULL, 32}, {0x1a12d86a0ULL, 0x1a12cda80ULL, 32},
    {0x1a12d86c0ULL, 0x1a12c3140ULL, 32}, {0x1a130c180ULL, 0x1a13075a0ULL, 96},
    {0x1a13151a0ULL, 0x1a13085c0ULL, 32}, {0x1b10a3180ULL, 0x1b10a30a0ULL, 32},
    {0x1b10a3320ULL, 0x1b10a30a0ULL, 32}, {0x1b10a3560ULL, 0x1b10a3480ULL, 32},
    {0x1b10a36a0ULL, 0x1b10a30a0ULL, 32}, {0x1b10a3780ULL, 0x1b10a34e0ULL, 32},
    {0x1b10a5120ULL, 0x1b10a3920ULL, 96}, {0x1b10a5200ULL, 0x1b10a3a00ULL, 32},
    {0x1b10a6920ULL, 0x1b10a3d20ULL, 96}, {0x1b10a6a00ULL, 0x1b10a3e00ULL, 32},
    {0x1b10a8920ULL, 0x1b10a7d20ULL, 96}, {0x1b10a8a00ULL, 0x1b10a7e00ULL, 32},
    {0x1b10a9520ULL, 0x1b10a4520ULL, 96}, {0x1b10a9600ULL, 0x1b10a4600ULL, 32},
    {0x1b10a9920ULL, 0x1b10a7920ULL, 96}, {0x1b10a9a00ULL, 0x1b10a7a00ULL, 32},
    {0x1b10ab120ULL, 0x1b10a7d20ULL, 96}, {0x1b10ab200ULL, 0x1b10a7e00ULL, 32},
    {0x1b10ac120ULL, 0x1b10a3920ULL, 96}, {0x1b10ac200ULL, 0x1b10a3a00ULL, 32},
    {0x1b10b0360ULL, 0x1b10afba0ULL, 32}, {0x1b10b03a0ULL, 0x1b10afb60ULL, 32},
    {0x1b10b03e0ULL, 0x1b10afc20ULL, 32}, {0x1b10b0420ULL, 0x1b10afbe0ULL, 32},
    {0x1b10b1060ULL, 0x1b10af860ULL, 32}, {0x1b10b1100ULL, 0x1b10af900ULL, 64},
    {0x1b10b1260ULL, 0x1b10b06e0ULL, 96}, {0x1b10b12e0ULL, 0x1b10b0660ULL, 96},
    {0x1b10b1560ULL, 0x1b10b09e0ULL, 96}, {0x1b10b15e0ULL, 0x1b10b0960ULL, 96},
    {0x1b10b1960ULL, 0x1b10b0d60ULL, 32}, {0x1b10b1a00ULL, 0x1b10b0e00ULL, 64},
    {0x1b10b2460ULL, 0x1b10b1c60ULL, 32}, {0x1b10b2500ULL, 0x1b10b1d00ULL, 64},
    {0x1b10b2960ULL, 0x1b10b0960ULL, 32}, {0x1b10b2a00ULL, 0x1b10b0a00ULL, 64},
    {0x1b10b3060ULL, 0x1b10b2ce0ULL, 32}, {0x1b10b3100ULL, 0x1b10b2c80ULL, 64},
    {0x1b10b3360ULL, 0x1b10b0fa0ULL, 32}, {0x1b10b33a0ULL, 0x1b10b0f60ULL, 32},
    {0x1b10b33e0ULL, 0x1b10b1020ULL, 32}, {0x1b10b3420ULL, 0x1b10b0fe0ULL, 32},
    {0x1b10b3660ULL, 0x1b10afee0ULL, 96}, {0x1b10b36e0ULL, 0x1b10afe60ULL, 96},
    {0x1b10b3a60ULL, 0x1b10b16a0ULL, 32}, {0x1b10b3aa0ULL, 0x1b10b1660ULL, 32},
    {0x1b10b3ae0ULL, 0x1b10b1720ULL, 32}, {0x1b10b3b20ULL, 0x1b10b16e0ULL, 32},
    {0x1b10b4160ULL, 0x1b10b0d60ULL, 32}, {0x1b10b4200ULL, 0x1b10b0e00ULL, 64},
    {0x1b10b4660ULL, 0x1b10b02a0ULL, 32}, {0x1b10b46a0ULL, 0x1b10b0260ULL, 32},
    {0x1b10b46e0ULL, 0x1b10b0320ULL, 32}, {0x1b10b4720ULL, 0x1b10b02e0ULL, 32},
    {0x1b10b5460ULL, 0x1b10b2ce0ULL, 32}, {0x1b10b5500ULL, 0x1b10b2c80ULL, 64},
    {0x1b10b5560ULL, 0x1b10b49a0ULL, 32}, {0x1b10b55a0ULL, 0x1b10b4960ULL, 32},
    {0x1b10b55e0ULL, 0x1b10b4a20ULL, 32}, {0x1b10b5620ULL, 0x1b10b49e0ULL, 32},
    {0x1b10b5660ULL, 0x1b10af2e0ULL, 96}, {0x1b10b56e0ULL, 0x1b10af260ULL, 96},
    {0x1b10b5960ULL, 0x1b10b5160ULL, 32}, {0x1b10b5a00ULL, 0x1b10b5200ULL, 64},
    {0x1b10b5d60ULL, 0x1b10af960ULL, 32}, {0x1b10b5e00ULL, 0x1b10afa00ULL, 64},
    {0x1b10b6060ULL, 0x1b10b18e0ULL, 96}, {0x1b10b60e0ULL, 0x1b10b1860ULL, 96},
    {0x1b10b6460ULL, 0x1b10b58e0ULL, 96}, {0x1b10b64e0ULL, 0x1b10b5860ULL, 96},
    {0x1b10b6560ULL, 0x1b10b2560ULL, 32}, {0x1b10b6600ULL, 0x1b10b2600ULL, 64},
    {0x1b10b6660ULL, 0x1b10b0ea0ULL, 32}, {0x1b10b66a0ULL, 0x1b10b0e60ULL, 32},
    {0x1b10b66e0ULL, 0x1b10b0f20ULL, 32}, {0x1b10b6720ULL, 0x1b10b0ee0ULL, 32},
    {0x1b10b6760ULL, 0x1b10b13e0ULL, 96}, {0x1b10b67e0ULL, 0x1b10b1360ULL, 96},
    {0x1b10b6960ULL, 0x1b10af5a0ULL, 32}, {0x1b10b69a0ULL, 0x1b10af560ULL, 32},
    {0x1b10b69e0ULL, 0x1b10af620ULL, 32}, {0x1b10b6a20ULL, 0x1b10af5e0ULL, 32},
    {0x1b10b6a60ULL, 0x1b10afaa0ULL, 32}, {0x1b10b6aa0ULL, 0x1b10afa60ULL, 32},
    {0x1b10b6ae0ULL, 0x1b10afb20ULL, 32}, {0x1b10b6b20ULL, 0x1b10afae0ULL, 32},
    {0x1b10b7060ULL, 0x1b10b3c60ULL, 32}, {0x1b10b7100ULL, 0x1b10b3d00ULL, 64},
    {0x1b10b7160ULL, 0x1b10b5160ULL, 32}, {0x1b10b7200ULL, 0x1b10b5200ULL, 64},
    {0x1b10b7260ULL, 0x1b10af6a0ULL, 32}, {0x1b10b72a0ULL, 0x1b10af660ULL, 32},
    {0x1b10b72e0ULL, 0x1b10af720ULL, 32}, {0x1b10b7320ULL, 0x1b10af6e0ULL, 32},
    {0x1b10b7460ULL, 0x1b10b4860ULL, 32}, {0x1b10b7500ULL, 0x1b10b4900ULL, 64},
    {0x1b10b7760ULL, 0x1b10b1c20ULL, 32}, {0x1b10b77a0ULL, 0x1b10b1be0ULL, 32},
    {0x1b10b77e0ULL, 0x1b10b1ba0ULL, 32}, {0x1b10b7820ULL, 0x1b10b1b60ULL, 32},
};
#define DEDUP_FIXUPS_N (sizeof(DEDUP_FIXUPS) / sizeof(DEDUP_FIXUPS[0]))

int fpsap_exchange_standalone(const uint8_t payload[128], uint8_t hash_out[20]) {
    const uint8_t *data = fpemu_blob;
    fp_state s;
    state_init(&s);
    size_t pos = 0;

    uint32_t n_pages = rd_u32(data, pos); pos += 4;
    uint64_t heap_ptr = rd_u64(data, pos); pos += 8;
    uint64_t ctx = rd_u64(data, pos); pos += 8;

    /* Named stubs. */
    for (;;) {
        uint64_t addr = rd_u64(data, pos); pos += 8;
        if (addr == 0) break;
        size_t name_len = rd_u16(data, pos); pos += 2;
        char *name = (char *)malloc(name_len + 1);
        memcpy(name, data + pos, name_len);
        name[name_len] = '\0';
        pos += name_len;
        u64map_put(&s.stubs, addr, name);
    }

    /* Sparse pages. */
    for (uint32_t i = 0; i < n_pages; i++) {
        uint64_t addr = rd_u64(data, pos); pos += 8;
        uint16_t n_spans = rd_u16(data, pos); pos += 2;
        mem_map_range(&s.mem, addr, 4096);
        if (n_spans == 0xFFFF) {
            mem_write_n(&s.mem, addr, data + pos, 4096);
            pos += 4096;
        } else {
            for (uint16_t j = 0; j < n_spans; j++) {
                uint64_t off = rd_u16(data, pos); pos += 2;
                size_t ln = rd_u16(data, pos); pos += 2;
                mem_write_n(&s.mem, addr + off, data + pos, ln);
                pos += ln;
            }
        }
    }

    /* Apply dedup fixups. */
    for (size_t i = 0; i < DEDUP_FIXUPS_N; i++) {
        uint8_t buf[256];
        mem_read_n(&s.mem, DEDUP_FIXUPS[i].src, buf, DEDUP_FIXUPS[i].n);
        mem_write_n(&s.mem, DEDUP_FIXUPS[i].dst, buf, DEDUP_FIXUPS[i].n);
    }

    /* Trampoline: BLR X8 ; BRK #0. */
    mem_map_range(&s.mem, FP_TRAMPOLINE_ADDR, 0x1000);
    mem_write32(&s.mem, FP_TRAMPOLINE_ADDR, 0xD63F0100);
    mem_write32(&s.mem, FP_TRAMPOLINE_ADDR + 4, 0xD4200000);

    /* Misc region. */
    mem_map_range(&s.mem, 0x30000000, 0x1000);
    {
        static const uint8_t magic[8] = {0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE};
        mem_write_n(&s.mem, 0x30000000, magic, 8);
    }
    mem_write32(&s.mem, 0x30000800, 0xD4200000);

    /* Build code instruction cache. */
    mem_set_code_region(&s.mem, FP_CODE_BASE, FP_CODE_END);

    s.heap_ptr = heap_ptr;

    /* FPSAPExchange(version=3, hwInfo, ctx, inBuf, inLen, &outBuf, &outLen, &rc) */
    uint64_t hw_addr = state_heap_alloc(&s, 24);
    {
        uint8_t zeros[24];
        memset(zeros, 0, sizeof(zeros));
        mem_write_n(&s.mem, hw_addr, zeros, 24);
    }

    static const uint8_t m2_header[14] = {
        0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x82, 0x02, 0x03,
    };
    uint8_t m2[142];
    memcpy(m2, m2_header, 14);
    memcpy(m2 + 14, payload, 128);
    uint64_t in_addr = state_heap_alloc(&s, 142);
    mem_write_n(&s.mem, in_addr, m2, 142);

    uint64_t out_ptr_addr = state_heap_alloc(&s, 8);
    uint64_t out_len_addr = state_heap_alloc(&s, 4);
    uint64_t rc_addr = state_heap_alloc(&s, 4);
    mem_write64(&s.mem, out_ptr_addr, 0);
    mem_write32(&s.mem, out_len_addr, 0);
    mem_write32(&s.mem, rc_addr, 0);

    uint64_t sp = FP_STACK_BASE + FP_STACK_SZ - 0x100;
    s.cpu.sp = sp;
    s.cpu.x[0] = 3;
    s.cpu.x[1] = hw_addr;
    s.cpu.x[2] = ctx;
    s.cpu.x[3] = in_addr;
    s.cpu.x[4] = 142;
    s.cpu.x[5] = out_ptr_addr;
    s.cpu.x[6] = out_len_addr;
    s.cpu.x[7] = rc_addr;
    s.cpu.x[8] = FP_ENTRY;
    s.cpu.pc = FP_TRAMPOLINE_ADDR;

    uint64_t halt_pc = FP_TRAMPOLINE_ADDR + 4;
    int rc = fp_run(&s, halt_pc);

    int ok = -1;
    if (rc == 0) {
        uint64_t out_ptr = mem_read64(&s.mem, out_ptr_addr);
        uint32_t out_len = mem_read32(&s.mem, out_len_addr);
        if (out_len >= 164 && out_ptr != 0) {
            uint8_t out[164];
            mem_read_n(&s.mem, out_ptr, out, 164);
            memcpy(hash_out, out + 144, 20);
            ok = 0;
        }
    }

    state_free(&s);
    return ok;
}

int fpsap_exchange_m3(const uint8_t *m2, size_t m2_len, uint8_t m3_out[164]) {
    if (m2_len < 142) return -1;
    uint8_t payload[128];
    memcpy(payload, m2 + 14, 128);
    uint8_t hash[20];
    if (fpsap_exchange_standalone(payload, hash) != 0)
        return -1;
    memcpy(m3_out, M3_PREFIX, 144);
    memcpy(m3_out + 144, hash, 20);
    return 0;
}
