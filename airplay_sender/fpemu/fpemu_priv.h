/*
 * fpemu internal definitions — CPU/memory/state model + helpers.
 * Faithful port of airfry's rust/fpemu (cpu.rs, mem.rs, helpers.rs, lib.rs).
 */
#ifndef FPEMU_PRIV_H
#define FPEMU_PRIV_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- Memory layout constants (port of the Go/Rust consts) --------------- */
#define FP_TRAMPOLINE_ADDR 0x10000000ULL
#define FP_STACK_BASE      0x70000000ULL
#define FP_STACK_SZ        0x800000ULL /* 8 MB */
#define FP_HEAP_BASE       0x80000000ULL
#define FP_CODE_BASE       0x1a1210000ULL
#define FP_CODE_END        0x1a1316000ULL
#define FP_DATA_BASE       0x1b10a3000ULL
#define FP_GOT_BASE        0x1aeab6000ULL
#define FP_ENTRY           0x1a12bfb88ULL

/* ---- u64-keyed hash map (linear probing) -------------------------------- */
typedef struct {
    uint64_t *keys;
    void **vals;
    uint8_t *state; /* 0=empty, 1=used */
    size_t cap;
    size_t len;
} u64map;

void u64map_init(u64map *m);
void u64map_free(u64map *m, void (*free_val)(void *));
/* Returns 1 and sets *out if found, else 0. */
int u64map_get(const u64map *m, uint64_t key, void **out);
void u64map_put(u64map *m, uint64_t key, void *val);
/* Removes key; if it existed, sets *old (may be NULL) and returns 1. */
int u64map_remove(u64map *m, uint64_t key, void **old);

/* ---- ARM64 CPU state (port of cpu.rs) ----------------------------------- */
typedef struct {
    uint64_t x[31]; /* X0-X30 (X30=LR); X31 reads as 0 */
    uint64_t sp;
    uint64_t pc;
    bool n, z, c, v;
    uint64_t vreg[32][2]; /* NEON 128-bit as [lo64, hi64] */
} fp_cpu;

static inline uint64_t cpu_reg(const fp_cpu *c, uint32_t n) {
    return n >= 31 ? 0 : c->x[n];
}
static inline void cpu_set_reg(fp_cpu *c, uint32_t n, uint64_t v) {
    if (n < 31) c->x[n] = v;
}
static inline uint64_t cpu_reg_sp(const fp_cpu *c, uint32_t n) {
    return n == 31 ? c->sp : c->x[n];
}
static inline void cpu_set_reg_sp(fp_cpu *c, uint32_t n, uint64_t v) {
    if (n == 31) c->sp = v; else c->x[n] = v;
}
bool cpu_cond_holds(const fp_cpu *c, uint32_t cond);

/* ---- Paged memory (port of mem.rs) -------------------------------------- */
typedef struct {
    u64map pages;      /* page base addr -> uint8_t[4096] */
    uint32_t *code_insts;
    size_t code_n;
    uint64_t code_base;
    uint64_t code_end;
    uint64_t cache_base; /* one-entry page cache */
    uint8_t *cache_ptr;
    bool cache_valid;
} fp_mem;

void mem_init(fp_mem *m);
void mem_free(fp_mem *m);
uint8_t mem_read8(fp_mem *m, uint64_t a);
uint16_t mem_read16(fp_mem *m, uint64_t a);
uint32_t mem_read32(fp_mem *m, uint64_t a);
uint64_t mem_read64(fp_mem *m, uint64_t a);
void mem_write8(fp_mem *m, uint64_t a, uint8_t v);
void mem_write16(fp_mem *m, uint64_t a, uint16_t v);
void mem_write32(fp_mem *m, uint64_t a, uint32_t v);
void mem_write64(fp_mem *m, uint64_t a, uint64_t v);
void mem_read_n(fp_mem *m, uint64_t addr, uint8_t *dst, size_t n);
void mem_write_n(fp_mem *m, uint64_t addr, const uint8_t *src, size_t n);
void mem_map_range(fp_mem *m, uint64_t addr, uint64_t size);
void mem_set_code_region(fp_mem *m, uint64_t base, uint64_t end);
uint32_t mem_fetch_inst(fp_mem *m, uint64_t pc);

/* ---- Full interpreter state (port of lib.rs State) ---------------------- */
typedef struct {
    fp_cpu cpu;
    fp_mem mem;
    uint64_t heap_ptr;
    u64map sha_ctxs; /* guest ctx ptr -> sha_ctx* */
    u64map aes_ctxs; /* guest ctx ptr -> CCCryptorRef */
    u64map stubs;    /* stub addr -> char* name */
} fp_state;

void state_init(fp_state *s);
void state_free(fp_state *s);
uint64_t state_heap_alloc(fp_state *s, uint64_t n);

/* stubs.c — returns 0 on success, non-zero on abort/fatal. */
int state_handle_stub(fp_state *s, const char *name);
const char *state_dyn_stub_classify(const fp_state *s, uint64_t pc);

/* decode.c — returns 0 on success, non-zero on unhandled/error. */
int fp_run(fp_state *s, uint64_t halt_pc);
int fp_step(fp_state *s, uint32_t inst);

/* ---- Arithmetic helpers (port of helpers.rs) ---------------------------- */
typedef struct { uint64_t r; bool n, z, c, v; } fp_addc;
typedef struct { uint64_t wmask, tmask; } fp_bitmasks;

uint64_t fp_sign_extend(uint64_t val, uint32_t bits);
fp_addc fp_add_with_carry64(uint64_t x, uint64_t y, uint64_t carry);
fp_addc fp_add_with_carry32(uint32_t x, uint32_t y, uint32_t carry);
fp_bitmasks fp_decode_bit_masks(uint32_t n_bit, uint32_t imms, uint32_t immr, bool is64);
uint64_t fp_shift_val(uint64_t val, uint32_t shift_type, uint32_t amount, bool is64);
uint32_t fp_rev32(uint32_t v);
uint64_t fp_rev64(uint64_t v);
uint64_t fp_rbit64(uint64_t v);
uint32_t fp_rbit32(uint32_t v);
uint64_t fp_rev16_64(uint64_t v);
uint32_t fp_rev16_32(uint32_t v);
uint32_t fp_clz64(uint64_t v);
uint32_t fp_clz32(uint32_t v);
uint64_t fp_mulhi64(uint64_t a, uint64_t b);
uint64_t fp_smulhi64(uint64_t a, uint64_t b);
uint32_t fp_vfp_expand_imm32(uint32_t imm8);
uint64_t fp_vfp_expand_imm64(uint32_t imm8);

/* The Apple FairPlay snapshot, provided by fp_blob.S (.incbin). */
extern const uint8_t fpemu_blob[];
extern const uint8_t fpemu_blob_end[];

#endif /* FPEMU_PRIV_H */
