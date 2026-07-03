/* u64-keyed open-addressing hash map (linear probing, shift-back deletion). */
#include <stdlib.h>
#include <string.h>

#include "fpemu_priv.h"

static uint64_t mix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

void u64map_init(u64map *m) {
    m->cap = 16;
    m->len = 0;
    m->keys = (uint64_t *)calloc(m->cap, sizeof(uint64_t));
    m->vals = (void **)calloc(m->cap, sizeof(void *));
    m->state = (uint8_t *)calloc(m->cap, sizeof(uint8_t));
}

void u64map_free(u64map *m, void (*free_val)(void *)) {
    if (free_val) {
        for (size_t i = 0; i < m->cap; i++)
            if (m->state[i]) free_val(m->vals[i]);
    }
    free(m->keys);
    free(m->vals);
    free(m->state);
    m->keys = NULL;
    m->vals = NULL;
    m->state = NULL;
    m->cap = m->len = 0;
}

static size_t slot_for(const u64map *m, uint64_t key) {
    size_t mask = m->cap - 1;
    size_t i = (size_t)(mix64(key) & mask);
    while (m->state[i] && m->keys[i] != key)
        i = (i + 1) & mask;
    return i;
}

int u64map_get(const u64map *m, uint64_t key, void **out) {
    size_t i = slot_for(m, key);
    if (m->state[i]) {
        if (out) *out = m->vals[i];
        return 1;
    }
    return 0;
}

static void u64map_grow(u64map *m) {
    size_t old_cap = m->cap;
    uint64_t *ok = m->keys;
    void **ov = m->vals;
    uint8_t *os = m->state;

    m->cap = old_cap * 2;
    m->keys = (uint64_t *)calloc(m->cap, sizeof(uint64_t));
    m->vals = (void **)calloc(m->cap, sizeof(void *));
    m->state = (uint8_t *)calloc(m->cap, sizeof(uint8_t));
    m->len = 0;

    for (size_t i = 0; i < old_cap; i++) {
        if (os[i]) u64map_put(m, ok[i], ov[i]);
    }
    free(ok);
    free(ov);
    free(os);
}

void u64map_put(u64map *m, uint64_t key, void *val) {
    if ((m->len + 1) * 10 >= m->cap * 7)
        u64map_grow(m);
    size_t i = slot_for(m, key);
    if (!m->state[i]) {
        m->state[i] = 1;
        m->keys[i] = key;
        m->len++;
    }
    m->vals[i] = val;
}

int u64map_remove(u64map *m, uint64_t key, void **old) {
    size_t mask = m->cap - 1;
    size_t i = slot_for(m, key);
    if (!m->state[i]) return 0;
    if (old) *old = m->vals[i];

    /* Knuth 6.4 algorithm R: shift back the following cluster. */
    size_t j = i;
    for (;;) {
        j = (j + 1) & mask;
        if (!m->state[j]) break;
        size_t k = (size_t)(mix64(m->keys[j]) & mask);
        /* Can element at j move to fill the hole at i? */
        int can;
        if (i <= j)
            can = (k <= i) || (k > j);
        else
            can = (k <= i) && (k > j);
        if (can) {
            m->keys[i] = m->keys[j];
            m->vals[i] = m->vals[j];
            i = j;
        }
    }
    m->state[i] = 0;
    m->len--;
    return 1;
}
