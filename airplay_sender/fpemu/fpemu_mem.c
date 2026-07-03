/* Paged memory — faithful port of mem.rs. */
#include <stdlib.h>
#include <string.h>

#include "fpemu_priv.h"

#define PAGE_SZ 4096

void mem_init(fp_mem *m) {
    u64map_init(&m->pages);
    m->code_insts = NULL;
    m->code_n = 0;
    m->code_base = 0;
    m->code_end = 0;
    m->cache_base = 0;
    m->cache_ptr = NULL;
    m->cache_valid = false;
}

void mem_free(fp_mem *m) {
    u64map_free(&m->pages, free);
    free(m->code_insts);
    m->code_insts = NULL;
}

/* Non-allocating page lookup (matches Rust pages.get). */
static uint8_t *mem_peek(fp_mem *m, uint64_t base) {
    void *p = NULL;
    if (u64map_get(&m->pages, base, &p)) return (uint8_t *)p;
    return NULL;
}

/* Lazily-allocating page lookup (matches Rust page()). */
static uint8_t *mem_page(fp_mem *m, uint64_t addr) {
    uint64_t base = addr & ~0xFFFULL;
    if (m->cache_valid && m->cache_base == base)
        return m->cache_ptr;
    uint8_t *p = mem_peek(m, base);
    if (!p) {
        p = (uint8_t *)calloc(PAGE_SZ, 1);
        u64map_put(&m->pages, base, p);
    }
    m->cache_base = base;
    m->cache_ptr = p;
    m->cache_valid = true;
    return p;
}

uint8_t mem_read8(fp_mem *m, uint64_t a) {
    return mem_page(m, a)[a & 0xFFF];
}
void mem_write8(fp_mem *m, uint64_t a, uint8_t v) {
    mem_page(m, a)[a & 0xFFF] = v;
}

uint16_t mem_read16(fp_mem *m, uint64_t a) {
    if ((a & 0xFFF) <= 0xFFE) {
        uint8_t *p = mem_page(m, a);
        size_t o = a & 0xFFF;
        return (uint16_t)(p[o] | (p[o + 1] << 8));
    }
    return (uint16_t)(mem_read8(m, a) | (mem_read8(m, a + 1) << 8));
}
void mem_write16(fp_mem *m, uint64_t a, uint16_t v) {
    if ((a & 0xFFF) <= 0xFFE) {
        uint8_t *p = mem_page(m, a);
        size_t o = a & 0xFFF;
        p[o] = (uint8_t)v;
        p[o + 1] = (uint8_t)(v >> 8);
    } else {
        mem_write8(m, a, (uint8_t)v);
        mem_write8(m, a + 1, (uint8_t)(v >> 8));
    }
}

uint32_t mem_read32(fp_mem *m, uint64_t a) {
    if ((a & 0xFFF) <= 0xFFC) {
        uint8_t *p = mem_page(m, a);
        size_t o = a & 0xFFF;
        return (uint32_t)p[o] | ((uint32_t)p[o + 1] << 8) |
               ((uint32_t)p[o + 2] << 16) | ((uint32_t)p[o + 3] << 24);
    }
    return (uint32_t)mem_read8(m, a) | ((uint32_t)mem_read8(m, a + 1) << 8) |
           ((uint32_t)mem_read8(m, a + 2) << 16) | ((uint32_t)mem_read8(m, a + 3) << 24);
}
void mem_write32(fp_mem *m, uint64_t a, uint32_t v) {
    if ((a & 0xFFF) <= 0xFFC) {
        uint8_t *p = mem_page(m, a);
        size_t o = a & 0xFFF;
        p[o] = (uint8_t)v;
        p[o + 1] = (uint8_t)(v >> 8);
        p[o + 2] = (uint8_t)(v >> 16);
        p[o + 3] = (uint8_t)(v >> 24);
    } else {
        mem_write8(m, a, (uint8_t)v);
        mem_write8(m, a + 1, (uint8_t)(v >> 8));
        mem_write8(m, a + 2, (uint8_t)(v >> 16));
        mem_write8(m, a + 3, (uint8_t)(v >> 24));
    }
}

uint64_t mem_read64(fp_mem *m, uint64_t a) {
    if ((a & 0xFFF) <= 0xFF8) {
        uint8_t *p = mem_page(m, a);
        size_t o = a & 0xFFF;
        uint64_t r = 0;
        for (int i = 0; i < 8; i++) r |= (uint64_t)p[o + i] << (i * 8);
        return r;
    }
    return (uint64_t)mem_read32(m, a) | ((uint64_t)mem_read32(m, a + 4) << 32);
}
void mem_write64(fp_mem *m, uint64_t a, uint64_t v) {
    if ((a & 0xFFF) <= 0xFF8) {
        uint8_t *p = mem_page(m, a);
        size_t o = a & 0xFFF;
        for (int i = 0; i < 8; i++) p[o + i] = (uint8_t)(v >> (i * 8));
    } else {
        mem_write32(m, a, (uint32_t)v);
        mem_write32(m, a + 4, (uint32_t)(v >> 32));
    }
}

void mem_read_n(fp_mem *m, uint64_t addr, uint8_t *dst, size_t n) {
    size_t off = 0;
    while (off < n) {
        uint64_t cur = addr + off;
        size_t page_off = cur & 0xFFF;
        uint8_t *p = mem_page(m, cur);
        size_t nc = n - off;
        if (nc > PAGE_SZ - page_off) nc = PAGE_SZ - page_off;
        memcpy(dst + off, p + page_off, nc);
        off += nc;
    }
}

void mem_write_n(fp_mem *m, uint64_t addr, const uint8_t *src, size_t n) {
    size_t off = 0;
    while (off < n) {
        uint64_t cur = addr + off;
        size_t page_off = cur & 0xFFF;
        uint8_t *p = mem_page(m, cur);
        size_t nc = n - off;
        if (nc > PAGE_SZ - page_off) nc = PAGE_SZ - page_off;
        memcpy(p + page_off, src + off, nc);
        off += nc;
    }
}

void mem_map_range(fp_mem *m, uint64_t addr, uint64_t size) {
    uint64_t p = addr & ~0xFFFULL;
    while (p < addr + size) {
        mem_page(m, p);
        p += 0x1000;
    }
}

void mem_set_code_region(fp_mem *m, uint64_t base, uint64_t end) {
    size_t n = (size_t)((end - base) / 4);
    free(m->code_insts);
    m->code_insts = (uint32_t *)calloc(n, sizeof(uint32_t));
    m->code_n = n;
    for (size_t i = 0; i < n; i++) {
        uint64_t addr = base + (uint64_t)i * 4;
        uint8_t *p = mem_peek(m, addr & ~0xFFFULL);
        if (p) {
            size_t o = addr & 0xFFF;
            m->code_insts[i] = (uint32_t)p[o] | ((uint32_t)p[o + 1] << 8) |
                               ((uint32_t)p[o + 2] << 16) | ((uint32_t)p[o + 3] << 24);
        }
    }
    m->code_base = base;
    m->code_end = end;
}

uint32_t mem_fetch_inst(fp_mem *m, uint64_t pc) {
    if (pc >= m->code_base && pc < m->code_end)
        return m->code_insts[(pc - m->code_base) >> 2];
    uint8_t *p = mem_peek(m, pc & ~0xFFFULL);
    if (!p) return 0;
    size_t o = pc & 0xFFF;
    return (uint32_t)p[o] | ((uint32_t)p[o + 1] << 8) |
           ((uint32_t)p[o + 2] << 16) | ((uint32_t)p[o + 3] << 24);
}
