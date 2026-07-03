/* Arithmetic / bit-twiddling helpers + condition codes.
 * Faithful port of helpers.rs and cpu.rs `cond_holds`. */
#include "fpemu_priv.h"

uint64_t fp_sign_extend(uint64_t val, uint32_t bits) {
    if (bits >= 64) return val;
    if (val & (1ULL << (bits - 1)))
        return val | (~0ULL << bits);
    return val;
}

fp_addc fp_add_with_carry64(uint64_t x, uint64_t y, uint64_t carry) {
    fp_addc o;
    o.r = x + y + carry;
    o.n = (o.r >> 63) != 0;
    o.z = o.r == 0;
    o.c = carry == 0 ? (o.r < x) : (o.r <= x);
    o.v = (((x ^ o.r) & (y ^ o.r)) >> 63) != 0;
    return o;
}

fp_addc fp_add_with_carry32(uint32_t x, uint32_t y, uint32_t carry) {
    fp_addc o;
    uint64_t s = (uint64_t)x + (uint64_t)y + (uint64_t)carry;
    uint32_t result = (uint32_t)s;
    o.r = result;
    o.n = (result >> 31) != 0;
    o.z = result == 0;
    o.c = s > 0xFFFFFFFFULL;
    o.v = (((x ^ result) & (y ^ result)) >> 31) != 0;
    return o;
}

static uint64_t ones(uint32_t n) {
    return n >= 64 ? ~0ULL : ((1ULL << n) - 1);
}

fp_bitmasks fp_decode_bit_masks(uint32_t n_bit, uint32_t imms, uint32_t immr, bool is64) {
    uint32_t combined = (n_bit << 6) | ((~imms) & 0x3F);
    uint32_t length = 0;
    for (int i = 6; i >= 1; i--) {
        if (combined & (1u << i)) { length = (uint32_t)i; break; }
    }
    uint32_t esize = 1u << length;
    uint32_t levels = esize - 1;
    uint32_t s = imms & levels;
    uint32_t r = immr & levels;
    uint32_t diff = (s - r) & levels;

    uint64_t welem = ones(s + 1);
    if (r != 0) {
        welem = (welem >> r) | (welem << (esize - r));
        welem &= ones(esize);
    }
    uint64_t telem = ones(diff + 1);

    fp_bitmasks out;
    out.wmask = 0;
    out.tmask = 0;
    for (uint32_t i = 0; i < 64; i += esize) {
        out.wmask |= welem << i;
        out.tmask |= telem << i;
    }
    if (!is64) {
        out.wmask &= 0xFFFFFFFFULL;
        out.tmask &= 0xFFFFFFFFULL;
    }
    return out;
}

uint64_t fp_shift_val(uint64_t val, uint32_t shift_type, uint32_t amount, bool is64) {
    if (amount == 0) return val;
    uint32_t bits;
    if (is64) {
        bits = 64;
    } else {
        val &= 0xFFFFFFFFULL;
        bits = 32;
    }
    amount &= bits - 1;
    if (amount == 0)
        return is64 ? val : (val & 0xFFFFFFFFULL);
    switch (shift_type) {
        case 0: val <<= amount; break;
        case 1: val >>= amount; break;
        case 2:
            if (is64)
                val = (uint64_t)(((int64_t)val) >> amount);
            else
                val = (uint32_t)(((int32_t)(uint32_t)val) >> amount);
            break;
        case 3: val = (val >> amount) | (val << (bits - amount)); break;
        default: break;
    }
    if (!is64) val &= 0xFFFFFFFFULL;
    return val;
}

uint32_t fp_rev32(uint32_t v) {
    return ((v >> 24) & 0xFF) | ((v >> 8) & 0xFF00) | ((v << 8) & 0xFF0000) | (v << 24);
}
uint64_t fp_rev64(uint64_t v) {
    return ((uint64_t)fp_rev32((uint32_t)v) << 32) | (uint64_t)fp_rev32((uint32_t)(v >> 32));
}
uint64_t fp_rbit64(uint64_t v) {
    v = ((v & 0x5555555555555555ULL) << 1) | ((v & 0xAAAAAAAAAAAAAAAAULL) >> 1);
    v = ((v & 0x3333333333333333ULL) << 2) | ((v & 0xCCCCCCCCCCCCCCCCULL) >> 2);
    v = ((v & 0x0F0F0F0F0F0F0F0FULL) << 4) | ((v & 0xF0F0F0F0F0F0F0F0ULL) >> 4);
    return fp_rev64(v);
}
uint32_t fp_rbit32(uint32_t v) {
    v = ((v & 0x55555555u) << 1) | ((v & 0xAAAAAAAAu) >> 1);
    v = ((v & 0x33333333u) << 2) | ((v & 0xCCCCCCCCu) >> 2);
    v = ((v & 0x0F0F0F0Fu) << 4) | ((v & 0xF0F0F0F0u) >> 4);
    return fp_rev32(v);
}
uint64_t fp_rev16_64(uint64_t v) {
    return ((v & 0xFF00FF00FF00FF00ULL) >> 8) | ((v & 0x00FF00FF00FF00FFULL) << 8);
}
uint32_t fp_rev16_32(uint32_t v) {
    return ((v & 0xFF00FF00u) >> 8) | ((v & 0x00FF00FFu) << 8);
}

uint32_t fp_clz64(uint64_t v) { return v == 0 ? 64 : (uint32_t)__builtin_clzll(v); }
uint32_t fp_clz32(uint32_t v) { return v == 0 ? 32 : (uint32_t)__builtin_clz(v); }

uint64_t fp_mulhi64(uint64_t a, uint64_t b) {
    return (uint64_t)(((unsigned __int128)a * (unsigned __int128)b) >> 64);
}
uint64_t fp_smulhi64(uint64_t a, uint64_t b) {
    return (uint64_t)(((__int128)(int64_t)a * (__int128)(int64_t)b) >> 64);
}

uint32_t fp_vfp_expand_imm32(uint32_t imm8) {
    uint32_t a = (imm8 >> 7) & 1;
    uint32_t b = (imm8 >> 6) & 1;
    uint32_t cdefgh = imm8 & 0x3F;
    uint32_t result = a << 31;
    if (b) result |= 0x1Fu << 25;
    else result |= 1u << 30;
    result |= cdefgh << 19;
    return result;
}
uint64_t fp_vfp_expand_imm64(uint32_t imm8) {
    uint64_t a = (imm8 >> 7) & 1;
    uint64_t b = (imm8 >> 6) & 1;
    uint64_t cdefgh = imm8 & 0x3F;
    uint64_t result = a << 63;
    if (b) result |= 0xFFULL << 54;
    else result |= 1ULL << 62;
    result |= cdefgh << 48;
    return result;
}

bool cpu_cond_holds(const fp_cpu *c, uint32_t cond) {
    bool r;
    switch (cond >> 1) {
        case 0: r = c->z; break;
        case 1: r = c->c; break;
        case 2: r = c->n; break;
        case 3: r = c->v; break;
        case 4: r = c->c && !c->z; break;
        case 5: r = c->n == c->v; break;
        case 6: r = (c->n == c->v) && !c->z; break;
        case 7: r = true; break;
        default: r = false; break;
    }
    if ((cond & 1) != 0 && cond != 15)
        r = !r;
    return r;
}
