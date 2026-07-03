/* libc / CommonCrypto stubs + interpreter state lifecycle.
 * Faithful port of stubs.rs (handle_stub, dyn_stub_classify) and the lib.rs
 * State (heap_alloc, sha/aes contexts). The crypto crates airfry pulls from
 * crates.io (aes/ctr/sha1/sha2) are replaced here by macOS CommonCrypto. */
#include <stdlib.h>
#include <string.h>

#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonDigest.h>

#include "fpemu_priv.h"

/* ---- SHA context tracked per guest ctx pointer -------------------------- */
enum { SHA_KIND_1 = 1, SHA_KIND_512 = 5 };
typedef struct {
    int kind;
    CC_SHA1_CTX c1;
    CC_SHA512_CTX c5;
} sha_ctx;

static void sha_ctx_free(void *p) { free(p); }
static void aes_ctx_free(void *p) { if (p) CCCryptorRelease((CCCryptorRef)p); }
static void name_free(void *p) { free(p); }

/* ---- State lifecycle ---------------------------------------------------- */
void state_init(fp_state *s) {
    memset(&s->cpu, 0, sizeof(s->cpu));
    mem_init(&s->mem);
    s->heap_ptr = FP_HEAP_BASE;
    u64map_init(&s->sha_ctxs);
    u64map_init(&s->aes_ctxs);
    u64map_init(&s->stubs);
}

void state_free(fp_state *s) {
    u64map_free(&s->sha_ctxs, sha_ctx_free);
    u64map_free(&s->aes_ctxs, aes_ctx_free);
    u64map_free(&s->stubs, name_free);
    mem_free(&s->mem);
}

uint64_t state_heap_alloc(fp_state *s, uint64_t n) {
    n = (n + 15) & ~15ULL;
    uint64_t addr = s->heap_ptr;
    s->heap_ptr += n;
    return addr;
}

/* ---- SHA helpers -------------------------------------------------------- */
static sha_ctx *sha_get_or_insert(fp_state *s, uint64_t key, int kind) {
    void *p = NULL;
    if (u64map_get(&s->sha_ctxs, key, &p))
        return (sha_ctx *)p;
    sha_ctx *ctx = (sha_ctx *)calloc(1, sizeof(sha_ctx));
    ctx->kind = kind;
    if (kind == SHA_KIND_1) CC_SHA1_Init(&ctx->c1);
    else CC_SHA512_Init(&ctx->c5);
    u64map_put(&s->sha_ctxs, key, ctx);
    return ctx;
}

/* ---- The stub dispatcher ------------------------------------------------ */
int state_handle_stub(fp_state *s, const char *name) {
    fp_cpu *cpu = &s->cpu;
    uint64_t x0 = cpu->x[0], x1 = cpu->x[1], x2 = cpu->x[2], x3 = cpu->x[3];

    if (strcmp(name, "_malloc") == 0) {
        uint64_t sz = x0 == 0 ? 16 : x0;
        cpu->x[0] = state_heap_alloc(s, sz);
    } else if (strcmp(name, "_calloc") == 0) {
        uint64_t total = (x0 * x1) == 0 ? 16 : (x0 * x1);
        uint64_t addr = state_heap_alloc(s, total);
        uint8_t *zeros = (uint8_t *)calloc((size_t)total, 1);
        mem_write_n(&s->mem, addr, zeros, (size_t)total);
        free(zeros);
        cpu->x[0] = addr;
    } else if (strcmp(name, "_realloc") == 0) {
        uint64_t sz = x1 == 0 ? 16 : x1;
        cpu->x[0] = state_heap_alloc(s, sz);
    } else if (strcmp(name, "_free") == 0) {
        cpu->x[0] = 0;
    } else if (strcmp(name, "_memcpy") == 0 || strcmp(name, "_memmove") == 0 ||
               strcmp(name, "___memcpy_chk") == 0) {
        if (x2 > 0 && x1 != 0 && x0 != 0) {
            uint8_t *tmp = (uint8_t *)malloc((size_t)x2);
            mem_read_n(&s->mem, x1, tmp, (size_t)x2);
            mem_write_n(&s->mem, x0, tmp, (size_t)x2);
            free(tmp);
        }
        cpu->x[0] = x0;
    } else if (strcmp(name, "_memset") == 0 || strcmp(name, "___memset_chk") == 0) {
        if (x2 > 0) {
            uint8_t *buf = (uint8_t *)malloc((size_t)x2);
            memset(buf, (int)(uint8_t)x1, (size_t)x2);
            mem_write_n(&s->mem, x0, buf, (size_t)x2);
            free(buf);
        }
        cpu->x[0] = x0;
    } else if (strcmp(name, "_memcmp") == 0) {
        if (x2 == 0) {
            cpu->x[0] = 0;
        } else {
            uint8_t *a = (uint8_t *)malloc((size_t)x2);
            uint8_t *b = (uint8_t *)malloc((size_t)x2);
            mem_read_n(&s->mem, x0, a, (size_t)x2);
            mem_read_n(&s->mem, x1, b, (size_t)x2);
            uint64_t r = 0;
            for (size_t i = 0; i < (size_t)x2; i++) {
                if (a[i] != b[i]) { r = a[i] < b[i] ? ~0ULL : 1; break; }
            }
            free(a);
            free(b);
            cpu->x[0] = r;
        }
    } else if (strcmp(name, "_bzero") == 0) {
        if (x1 > 0) {
            uint8_t *buf = (uint8_t *)calloc((size_t)x1, 1);
            mem_write_n(&s->mem, x0, buf, (size_t)x1);
            free(buf);
        }
    } else if (strcmp(name, "_strlen") == 0) {
        uint64_t n = 0;
        while (mem_read8(&s->mem, x0 + n) != 0) {
            n++;
            if (n > (1ULL << 20)) break;
        }
        cpu->x[0] = n;
    } else if (strcmp(name, "_CC_SHA1_Init") == 0) {
        /* Rust unconditionally inserts a fresh Sha1; mirror that. */
        {
            void *old = NULL;
            if (u64map_remove(&s->sha_ctxs, x0, &old)) free(old);
        }
        sha_ctx *ctx = (sha_ctx *)calloc(1, sizeof(sha_ctx));
        ctx->kind = SHA_KIND_1;
        CC_SHA1_Init(&ctx->c1);
        u64map_put(&s->sha_ctxs, x0, ctx);
        cpu->x[0] = 1;
    } else if (strcmp(name, "_CC_SHA1_Update") == 0) {
        sha_ctx *ctx = sha_get_or_insert(s, x0, SHA_KIND_1);
        if (x2 > 0 && ctx->kind == SHA_KIND_1) {
            uint8_t *data = (uint8_t *)malloc((size_t)x2);
            mem_read_n(&s->mem, x1, data, (size_t)x2);
            CC_SHA1_Update(&ctx->c1, data, (CC_LONG)x2);
            free(data);
        }
        cpu->x[0] = 1;
    } else if (strcmp(name, "_CC_SHA1_Final") == 0) {
        void *p = NULL;
        uint8_t out[20];
        memset(out, 0, sizeof(out));
        if (u64map_remove(&s->sha_ctxs, x1, &p)) {
            sha_ctx *ctx = (sha_ctx *)p;
            if (ctx->kind == SHA_KIND_1) {
                CC_SHA1_Final(out, &ctx->c1);
            } else {
                uint8_t full[64];
                CC_SHA512_Final(full, &ctx->c5);
                memcpy(out, full, 20);
            }
            free(ctx);
        }
        mem_write_n(&s->mem, x0, out, 20);
        cpu->x[0] = 1;
    } else if (strcmp(name, "_CC_SHA512_Init") == 0) {
        {
            void *old = NULL;
            if (u64map_remove(&s->sha_ctxs, x0, &old)) free(old);
        }
        sha_ctx *ctx = (sha_ctx *)calloc(1, sizeof(sha_ctx));
        ctx->kind = SHA_KIND_512;
        CC_SHA512_Init(&ctx->c5);
        u64map_put(&s->sha_ctxs, x0, ctx);
        cpu->x[0] = 1;
    } else if (strcmp(name, "_CC_SHA512_Update") == 0) {
        sha_ctx *ctx = sha_get_or_insert(s, x0, SHA_KIND_512);
        if (x2 > 0 && ctx->kind == SHA_KIND_512) {
            uint8_t *data = (uint8_t *)malloc((size_t)x2);
            mem_read_n(&s->mem, x1, data, (size_t)x2);
            CC_SHA512_Update(&ctx->c5, data, (CC_LONG)x2);
            free(data);
        }
        cpu->x[0] = 1;
    } else if (strcmp(name, "_CC_SHA512_Final") == 0) {
        void *p = NULL;
        uint8_t out[64];
        memset(out, 0, sizeof(out));
        if (u64map_remove(&s->sha_ctxs, x1, &p)) {
            sha_ctx *ctx = (sha_ctx *)p;
            if (ctx->kind == SHA_KIND_512) {
                CC_SHA512_Final(out, &ctx->c5);
            } else {
                uint8_t sh[20];
                CC_SHA1_Final(sh, &ctx->c1);
                memcpy(out, sh, 20);
            }
            free(ctx);
        }
        mem_write_n(&s->mem, x0, out, 64);
        cpu->x[0] = 1;
    } else if (strcmp(name, "_AES_CTR_Init") == 0) {
        uint8_t *key = (uint8_t *)malloc((size_t)(x2 ? x2 : 1));
        uint8_t iv[16];
        mem_read_n(&s->mem, x1, key, (size_t)x2);
        mem_read_n(&s->mem, x3, iv, 16);
        CCCryptorRef cref = NULL;
        CCCryptorStatus st = CCCryptorCreateWithMode(
            kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding,
            iv, key, (size_t)x2, NULL, 0, 0, kCCModeOptionCTR_BE, &cref);
        free(key);
        if (st == kCCSuccess && cref) {
            void *old = NULL;
            if (u64map_remove(&s->aes_ctxs, x0, &old) && old)
                CCCryptorRelease((CCCryptorRef)old);
            u64map_put(&s->aes_ctxs, x0, cref);
            cpu->x[0] = 0;
        } else {
            if (cref) CCCryptorRelease(cref);
            cpu->x[0] = ~0ULL;
        }
    } else if (strcmp(name, "_AES_CTR_Update") == 0) {
        if (x2 > 0) {
            void *p = NULL;
            if (u64map_get(&s->aes_ctxs, x0, &p) && p) {
                uint8_t *in = (uint8_t *)malloc((size_t)x2);
                uint8_t *out = (uint8_t *)malloc((size_t)x2);
                mem_read_n(&s->mem, x1, in, (size_t)x2);
                size_t moved = 0;
                CCCryptorUpdate((CCCryptorRef)p, in, (size_t)x2, out, (size_t)x2, &moved);
                mem_write_n(&s->mem, x3, out, (size_t)x2);
                free(in);
                free(out);
            }
        }
        cpu->x[0] = 0;
    } else if (strcmp(name, "_AES_CTR_Final") == 0) {
        void *old = NULL;
        if (u64map_remove(&s->aes_ctxs, x0, &old) && old)
            CCCryptorRelease((CCCryptorRef)old);
        cpu->x[0] = 0;
    } else if (strcmp(name, "_abort") == 0) {
        return -1;
    } else if (strcmp(name, "_arc4random") == 0) {
        cpu->x[0] = 0;
    } else if (strcmp(name, "_FigGetUpTimeNanoseconds") == 0) {
        cpu->x[0] = 1000000000ULL;
    } else if (strcmp(name, "_CFRetain") == 0) {
        /* X0 unchanged */
    } else if (strcmp(name, "_pthread_once") == 0 || strcmp(name, "_FigThreadRunOnce") == 0) {
        if (mem_read8(&s->mem, x0) == 0) {
            uint8_t one[4] = {1, 0, 0, 0};
            mem_write_n(&s->mem, x0, one, 4);
        }
        cpu->x[0] = 0;
    } else if (strcmp(name, "_dispatch_once") == 0) {
        if (mem_read64(&s->mem, x0) == 0)
            mem_write64(&s->mem, x0, ~0ULL);
        cpu->x[0] = 0;
    } else {
        cpu->x[0] = 0; /* nop returning 0 */
    }
    return 0;
}

const char *state_dyn_stub_classify(const fp_state *s, uint64_t pc) {
    const uint64_t STUB_PB = 0x20000000ULL;
    const uint64_t STUB_PS = 0x10000ULL;
    if (pc >= STUB_PB && pc < STUB_PB + STUB_PS)
        return "_nop";
    uint64_t x0 = s->cpu.x[0], x1 = s->cpu.x[1], x2 = s->cpu.x[2];
#define IS_TEXT(v) ((v) >= 0x1a1210000ULL && (v) < 0x1a1316000ULL)
#define IS_GDATA(v) ((v) >= 0x1a0000000ULL && (v) < 0x1c0000000ULL)
    if (IS_GDATA(x0) && (IS_TEXT(x1) || IS_TEXT(x2)))
        return "_dispatch_once";
    if (x0 > 0 && x0 < 0x100000ULL)
        return "_malloc";
#undef IS_TEXT
#undef IS_GDATA
    return "_nop";
}
