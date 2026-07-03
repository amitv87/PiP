/* ARM64 decode/execute — faithful port of decode.rs (fpRun/fpStep/fpExec*). */
#include <stdio.h>
#include <string.h>

#include "fpemu_priv.h"

static int fail(uint32_t inst, const char *what) {
    fprintf(stderr, "fpemu: %s inst=0x%08x\n", what, inst);
    return -1;
}

/* ============================================================
 * Data Processing — Immediate
 * ============================================================ */

static int exec_pcrel(fp_cpu *c, uint32_t inst) {
    uint32_t rd = inst & 0x1F;
    uint32_t immhi = (inst >> 5) & 0x7FFFF;
    uint32_t immlo = (inst >> 29) & 0x3;
    uint64_t imm = fp_sign_extend(((uint64_t)immhi << 2) | immlo, 21);
    if (inst >> 31) {
        cpu_set_reg(c, rd, (c->pc & ~0xFFFULL) + (uint64_t)(((int64_t)imm) << 12));
    } else {
        cpu_set_reg(c, rd, c->pc + imm);
    }
    c->pc += 4;
    return 0;
}

static int exec_add_sub_imm(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op = (inst >> 30) & 1;
    uint32_t setf = (inst >> 29) & 1;
    uint32_t shift = (inst >> 22) & 3;
    uint64_t imm12 = (inst >> 10) & 0xFFF;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    if (shift == 1) imm12 <<= 12;
    uint64_t a = cpu_reg_sp(c, rn);
    if (!is64) a &= 0xFFFFFFFFULL;
    if (setf) {
        uint64_t y;
        uint64_t carry;
        if (op == 0) { y = imm12; carry = 0; }
        else if (is64) { y = ~imm12; carry = 1; }
        else { y = (uint64_t)(~(uint32_t)imm12); carry = 1; }
        uint64_t result;
        if (is64) {
            fp_addc o = fp_add_with_carry64(a, y, carry);
            result = o.r; c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        } else {
            fp_addc o = fp_add_with_carry32((uint32_t)a, (uint32_t)y, (uint32_t)carry);
            result = o.r; c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        }
        cpu_set_reg(c, rd, result);
    } else {
        uint64_t result = op == 0 ? (a + imm12) : (a - imm12);
        if (!is64) result &= 0xFFFFFFFFULL;
        cpu_set_reg_sp(c, rd, result);
    }
    c->pc += 4;
    return 0;
}

static int exec_log_imm(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t opc = (inst >> 29) & 0x3;
    uint32_t n_bit = (inst >> 22) & 1;
    uint32_t immr = (inst >> 16) & 0x3F;
    uint32_t imms = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    fp_bitmasks bm = fp_decode_bit_masks(n_bit, imms, immr, is64);
    uint64_t a = cpu_reg(c, rn);
    if (!is64) a &= 0xFFFFFFFFULL;
    uint64_t result;
    switch (opc) {
        case 0: case 3: result = a & bm.wmask; break;
        case 1: result = a | bm.wmask; break;
        case 2: result = a ^ bm.wmask; break;
        default: result = 0; break;
    }
    if (!is64) result &= 0xFFFFFFFFULL;
    if (opc == 3) {
        c->n = is64 ? ((result >> 63) != 0) : ((result >> 31) != 0);
        c->z = result == 0;
        c->c = false;
        c->v = false;
        cpu_set_reg(c, rd, result);
    } else {
        cpu_set_reg_sp(c, rd, result);
    }
    c->pc += 4;
    return 0;
}

static int exec_move_wide(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t opc = (inst >> 29) & 0x3;
    uint32_t hw = (inst >> 21) & 0x3;
    uint64_t imm16 = (inst >> 5) & 0xFFFF;
    uint32_t rd = inst & 0x1F;
    uint32_t shift = hw * 16;
    switch (opc) {
        case 0: {
            uint64_t r = ~(imm16 << shift);
            if (sf == 0) r &= 0xFFFFFFFFULL;
            cpu_set_reg(c, rd, r);
            break;
        }
        case 2:
            cpu_set_reg(c, rd, imm16 << shift);
            break;
        case 3: {
            uint64_t mask = 0xFFFFULL << shift;
            cpu_set_reg(c, rd, (cpu_reg(c, rd) & ~mask) | (imm16 << shift));
            break;
        }
        default: return fail(inst, "reserved move-wide");
    }
    c->pc += 4;
    return 0;
}

static int exec_bitfield(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t opc = (inst >> 29) & 0x3;
    uint32_t n_bit = (inst >> 22) & 1;
    uint32_t immr = (inst >> 16) & 0x3F;
    uint32_t imms = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    fp_bitmasks bm = fp_decode_bit_masks(n_bit, imms, immr, is64);
    uint32_t datasize = is64 ? 64 : 32;
    uint64_t src = cpu_reg(c, rn);
    if (!is64) src &= 0xFFFFFFFFULL;
    uint32_t r = immr;
    uint64_t rotated;
    if (r == 0) {
        rotated = src;
    } else {
        rotated = (src >> r) | (src << (datasize - r));
        if (!is64) rotated &= 0xFFFFFFFFULL;
    }
    switch (opc) {
        case 0: { /* SBFM */
            uint64_t bot = rotated & bm.wmask;
            uint64_t top = 0;
            if ((src >> imms) & 1) {
                top = ~0ULL;
                if (!is64) top &= 0xFFFFFFFFULL;
            }
            uint64_t result = (top & ~bm.tmask) | (bot & bm.tmask);
            if (!is64) result &= 0xFFFFFFFFULL;
            cpu_set_reg(c, rd, result);
            break;
        }
        case 1: { /* BFM */
            uint64_t dst = cpu_reg(c, rd);
            if (!is64) dst &= 0xFFFFFFFFULL;
            uint64_t bot = (dst & ~bm.wmask) | (rotated & bm.wmask);
            uint64_t result = (dst & ~bm.tmask) | (bot & bm.tmask);
            if (!is64) result &= 0xFFFFFFFFULL;
            cpu_set_reg(c, rd, result);
            break;
        }
        case 2: { /* UBFM */
            uint64_t result = (rotated & bm.wmask) & bm.tmask;
            if (!is64) result &= 0xFFFFFFFFULL;
            cpu_set_reg(c, rd, result);
            break;
        }
        default: return fail(inst, "reserved bitfield");
    }
    c->pc += 4;
    return 0;
}

static int exec_extract(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t imms = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t hi = cpu_reg(c, rn);
    uint64_t lo = cpu_reg(c, rm);
    uint32_t lsb = imms;
    uint64_t result;
    if (is64) {
        result = lsb == 0 ? lo : ((hi << (64 - lsb)) | (lo >> lsb));
    } else {
        hi &= 0xFFFFFFFFULL;
        lo &= 0xFFFFFFFFULL;
        result = lsb == 0 ? lo : (((hi << (32 - lsb)) | (lo >> lsb)) & 0xFFFFFFFFULL);
    }
    cpu_set_reg(c, rd, result);
    c->pc += 4;
    return 0;
}

static int exec_dpimm(fp_cpu *c, uint32_t inst) {
    switch ((inst >> 23) & 0x7) {
        case 0: case 1: return exec_pcrel(c, inst);
        case 2: return exec_add_sub_imm(c, inst);
        case 4: return exec_log_imm(c, inst);
        case 5: return exec_move_wide(c, inst);
        case 6: return exec_bitfield(c, inst);
        case 7: return exec_extract(c, inst);
        default: return fail(inst, "unhandled DP-Imm");
    }
}

/* ============================================================
 * Data Processing — Register
 * ============================================================ */

static int exec_log_shift_reg(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t opc = (inst >> 29) & 0x3;
    uint32_t shift_type = (inst >> 22) & 0x3;
    uint32_t n_bit = (inst >> 21) & 1;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t imm6 = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t a = cpu_reg(c, rn);
    uint64_t b = fp_shift_val(cpu_reg(c, rm), shift_type, imm6, is64);
    if (n_bit) {
        b = ~b;
        if (!is64) b &= 0xFFFFFFFFULL;
    }
    if (!is64) a &= 0xFFFFFFFFULL;
    uint64_t result;
    switch (opc) {
        case 0: case 3: result = a & b; break;
        case 1: result = a | b; break;
        case 2: result = a ^ b; break;
        default: result = 0; break;
    }
    if (!is64) result &= 0xFFFFFFFFULL;
    if (opc == 3) {
        c->n = is64 ? ((result >> 63) != 0) : ((result >> 31) != 0);
        c->z = result == 0;
        c->c = false;
        c->v = false;
    }
    cpu_set_reg(c, rd, result);
    c->pc += 4;
    return 0;
}

static int exec_add_sub_shift_reg(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op = (inst >> 30) & 1;
    uint32_t setf = (inst >> 29) & 1;
    uint32_t shift_type = (inst >> 22) & 0x3;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t imm6 = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t a = cpu_reg(c, rn);
    uint64_t b = fp_shift_val(cpu_reg(c, rm), shift_type, imm6, is64);
    if (!is64) { a &= 0xFFFFFFFFULL; b &= 0xFFFFFFFFULL; }
    uint64_t y, carry;
    if (op == 0) { y = b; carry = 0; }
    else if (is64) { y = ~b; carry = 1; }
    else { y = (uint64_t)(~(uint32_t)b); carry = 1; }
    if (setf) {
        uint64_t result;
        if (is64) {
            fp_addc o = fp_add_with_carry64(a, y, carry);
            result = o.r; c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        } else {
            fp_addc o = fp_add_with_carry32((uint32_t)a, (uint32_t)y, (uint32_t)carry);
            result = o.r; c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        }
        cpu_set_reg(c, rd, result);
    } else {
        uint64_t result = op == 0 ? (a + b) : (a - b);
        if (!is64) result &= 0xFFFFFFFFULL;
        cpu_set_reg(c, rd, result);
    }
    c->pc += 4;
    return 0;
}

static int exec_add_sub_ext_reg(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op = (inst >> 30) & 1;
    uint32_t setf = (inst >> 29) & 1;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t option = (inst >> 13) & 0x7;
    uint32_t imm3 = (inst >> 10) & 0x7;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t a = cpu_reg_sp(c, rn);
    uint64_t rm_val = cpu_reg(c, rm);
    uint64_t extended;
    switch (option) {
        case 0: extended = rm_val & 0xFF; break;
        case 1: extended = rm_val & 0xFFFF; break;
        case 2: extended = rm_val & 0xFFFFFFFFULL; break;
        case 3: extended = rm_val; break;
        case 4: extended = fp_sign_extend(rm_val & 0xFF, 8); break;
        case 5: extended = fp_sign_extend(rm_val & 0xFFFF, 16); break;
        case 6: extended = fp_sign_extend(rm_val & 0xFFFFFFFFULL, 32); break;
        case 7: extended = rm_val; break;
        default: extended = 0; break;
    }
    extended <<= imm3;
    if (!is64) { a &= 0xFFFFFFFFULL; extended &= 0xFFFFFFFFULL; }
    if (setf) {
        uint64_t y, carry;
        if (op == 0) { y = extended; carry = 0; }
        else if (is64) { y = ~extended; carry = 1; }
        else { y = (uint64_t)(~(uint32_t)extended); carry = 1; }
        uint64_t result;
        if (is64) {
            fp_addc o = fp_add_with_carry64(a, y, carry);
            result = o.r; c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        } else {
            fp_addc o = fp_add_with_carry32((uint32_t)a, (uint32_t)y, (uint32_t)carry);
            result = o.r; c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        }
        cpu_set_reg(c, rd, result);
    } else {
        uint64_t result = op == 0 ? (a + extended) : (a - extended);
        if (!is64) result &= 0xFFFFFFFFULL;
        cpu_set_reg_sp(c, rd, result);
    }
    c->pc += 4;
    return 0;
}

static int exec_cond_compare(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op = (inst >> 30) & 1;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t cond = (inst >> 12) & 0xF;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t nzcv = inst & 0xF;
    bool is64 = sf != 0;
    bool is_imm = ((inst >> 11) & 1) != 0;
    if (cpu_cond_holds(c, cond)) {
        uint64_t a = cpu_reg(c, rn);
        uint64_t b = is_imm ? (uint64_t)rm : cpu_reg(c, rm);
        if (!is64) { a &= 0xFFFFFFFFULL; b &= 0xFFFFFFFFULL; }
        uint64_t y, carry;
        if (op == 1) {
            if (is64) { y = ~b; carry = 1; }
            else { y = (uint64_t)(~(uint32_t)b); carry = 1; }
        } else { y = b; carry = 0; }
        if (is64) {
            fp_addc o = fp_add_with_carry64(a, y, carry);
            c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        } else {
            fp_addc o = fp_add_with_carry32((uint32_t)a, (uint32_t)y, (uint32_t)carry);
            c->n = o.n; c->z = o.z; c->c = o.c; c->v = o.v;
        }
    } else {
        c->n = ((nzcv >> 3) & 1) != 0;
        c->z = ((nzcv >> 2) & 1) != 0;
        c->c = ((nzcv >> 1) & 1) != 0;
        c->v = (nzcv & 1) != 0;
    }
    c->pc += 4;
    return 0;
}

static int exec_cond_select(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op = (inst >> 30) & 1;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t cond = (inst >> 12) & 0xF;
    uint32_t op2 = (inst >> 10) & 0x3;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t a = cpu_reg(c, rn);
    uint64_t b = cpu_reg(c, rm);
    uint64_t result;
    if (cpu_cond_holds(c, cond)) {
        result = a;
    } else {
        switch ((op << 1) | (op2 & 1)) {
            case 0: result = b; break;
            case 1: result = b + 1; break;
            case 2: result = ~b; break;
            case 3: result = 0ULL - b; break;
            default: result = 0; break;
        }
    }
    if (!is64) result &= 0xFFFFFFFFULL;
    cpu_set_reg(c, rd, result);
    c->pc += 4;
    return 0;
}

static int exec_dp_2src(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t opcode = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t a = cpu_reg(c, rn);
    uint64_t b = cpu_reg(c, rm);
    if (!is64) { a &= 0xFFFFFFFFULL; b &= 0xFFFFFFFFULL; }
    uint64_t result;
    switch (opcode) {
        case 2: /* UDIV */
            if (b == 0) result = 0;
            else if (is64) result = a / b;
            else result = (uint64_t)((uint32_t)a / (uint32_t)b);
            break;
        case 3: /* SDIV */
            if (b == 0) result = 0;
            else if (is64) result = (uint64_t)((int64_t)a / (int64_t)b);
            else result = (uint64_t)(uint32_t)((int32_t)(uint32_t)a / (int32_t)(uint32_t)b);
            break;
        case 8: { uint64_t mask = is64 ? 63 : 31; result = a << (b & mask); break; }
        case 9: { uint64_t mask = is64 ? 63 : 31; result = a >> (b & mask); break; }
        case 10: {
            uint64_t mask = is64 ? 63 : 31;
            uint64_t shift = b & mask;
            if (is64) result = (uint64_t)((int64_t)a >> shift);
            else result = (uint64_t)(uint32_t)((int32_t)(uint32_t)a >> shift);
            break;
        }
        case 11: {
            uint64_t bits = is64 ? 64 : 32;
            uint64_t shift = b % bits;
            if (shift == 0) result = a;
            else result = (a >> shift) | (a << (bits - shift));
            break;
        }
        default: return fail(inst, "unhandled DP-2-source");
    }
    if (!is64) result &= 0xFFFFFFFFULL;
    cpu_set_reg(c, rd, result);
    c->pc += 4;
    return 0;
}

static int exec_dp_1src(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t opcode = (inst >> 10) & 0x3F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t val = cpu_reg(c, rn);
    uint64_t result;
    switch (opcode) {
        case 0: result = is64 ? fp_rbit64(val) : (uint64_t)fp_rbit32((uint32_t)val); break;
        case 1: result = is64 ? fp_rev16_64(val) : (uint64_t)fp_rev16_32((uint32_t)val); break;
        case 2:
            if (is64) {
                uint64_t lo = fp_rev32((uint32_t)val);
                uint64_t hi = fp_rev32((uint32_t)(val >> 32));
                result = lo | (hi << 32);
            } else {
                result = (uint64_t)fp_rev32((uint32_t)val);
            }
            break;
        case 3: result = fp_rev64(val); break;
        case 4: result = is64 ? (uint64_t)fp_clz64(val) : (uint64_t)fp_clz32((uint32_t)val); break;
        default: return fail(inst, "unhandled DP-1-source");
    }
    if (!is64) result &= 0xFFFFFFFFULL;
    cpu_set_reg(c, rd, result);
    c->pc += 4;
    return 0;
}

static int exec_dp_3src(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op31 = (inst >> 21) & 0x7;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t o0 = (inst >> 15) & 1;
    uint32_t ra = (inst >> 10) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    bool is64 = sf != 0;
    uint64_t a = cpu_reg(c, rn);
    uint64_t b = cpu_reg(c, rm);
    uint64_t addend = cpu_reg(c, ra);
    uint64_t result;
    switch (op31) {
        case 0: {
            if (!is64) { a &= 0xFFFFFFFFULL; b &= 0xFFFFFFFFULL; }
            uint64_t prod = a * b;
            uint64_t r = o0 == 0 ? (addend + prod) : (addend - prod);
            if (!is64) r &= 0xFFFFFFFFULL;
            result = r;
            break;
        }
        case 1: { /* SMADDL/SMSUBL */
            uint64_t prod = (uint64_t)((int64_t)(int32_t)(uint32_t)a * (int64_t)(int32_t)(uint32_t)b);
            result = o0 == 0 ? (addend + prod) : (addend - prod);
            break;
        }
        case 2: result = fp_smulhi64(a, b); break;
        case 5: { /* UMADDL/UMSUBL */
            uint64_t prod = (uint64_t)(uint32_t)a * (uint64_t)(uint32_t)b;
            result = o0 == 0 ? (addend + prod) : (addend - prod);
            break;
        }
        case 6: result = fp_mulhi64(a, b); break;
        default: return fail(inst, "unhandled DP-3");
    }
    cpu_set_reg(c, rd, result);
    c->pc += 4;
    return 0;
}

static int exec_dp_11010(fp_cpu *c, uint32_t inst) {
    switch ((inst >> 21) & 7) {
        case 2: case 3: return exec_cond_compare(c, inst);
        case 4: return exec_cond_select(c, inst);
        case 6:
            if ((inst >> 30) & 1) return exec_dp_1src(c, inst);
            return exec_dp_2src(c, inst);
        default: return fail(inst, "unhandled 11010 sub");
    }
}

static int exec_dpreg(fp_cpu *c, uint32_t inst) {
    uint32_t top5 = (inst >> 24) & 0x1F;
    switch (top5) {
        case 0x0A: return exec_log_shift_reg(c, inst);
        case 0x0B:
            if (((inst >> 21) & 1) == 0) return exec_add_sub_shift_reg(c, inst);
            return exec_add_sub_ext_reg(c, inst);
        case 0x1A: return exec_dp_11010(c, inst);
        case 0x1B: return exec_dp_3src(c, inst);
        default: return fail(inst, "unhandled DP-Reg");
    }
}

/* ============================================================
 * Branches
 * ============================================================ */

static int exec_b_uncond(fp_cpu *c, uint32_t inst, bool link) {
    uint64_t imm26 = fp_sign_extend(inst & 0x3FFFFFF, 26);
    if (link) c->x[30] = c->pc + 4;
    c->pc = c->pc + imm26 * 4;
    return 0;
}

static int exec_b_cond(fp_cpu *c, uint32_t inst) {
    uint64_t imm19 = fp_sign_extend((inst >> 5) & 0x7FFFF, 19);
    uint32_t cond = inst & 0xF;
    if (cpu_cond_holds(c, cond)) c->pc = c->pc + imm19 * 4;
    else c->pc += 4;
    return 0;
}

static int exec_cbx(fp_cpu *c, uint32_t inst) {
    uint32_t sf = inst >> 31;
    uint32_t op = (inst >> 24) & 1;
    uint64_t imm19 = fp_sign_extend((inst >> 5) & 0x7FFFF, 19);
    uint32_t rt = inst & 0x1F;
    uint64_t val = cpu_reg(c, rt);
    if (sf == 0) val &= 0xFFFFFFFFULL;
    bool take = op == 0 ? (val == 0) : (val != 0);
    if (take) c->pc = c->pc + imm19 * 4;
    else c->pc += 4;
    return 0;
}

static int exec_branch_reg(fp_cpu *c, uint32_t inst) {
    uint32_t opc = (inst >> 21) & 0xF;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint64_t target = cpu_reg(c, rn);
    if (rn == 31) target = 0;
    switch (opc) {
        case 0: c->pc = target; break;
        case 1: c->x[30] = c->pc + 4; c->pc = target; break;
        case 2:
            c->pc = c->x[30];
            if (rn != 30) c->pc = cpu_reg(c, rn);
            break;
        default: return fail(inst, "unhandled branch-reg");
    }
    return 0;
}

static int exec_test_branch(fp_cpu *c, uint32_t inst) {
    uint32_t op = (inst >> 24) & 1; /* 0=TBZ, 1=TBNZ */
    uint32_t b5 = (inst >> 31) & 1;
    uint32_t b40 = (inst >> 19) & 0x1F;
    uint32_t bit = (b5 << 5) | b40;
    uint64_t imm14 = fp_sign_extend((inst >> 5) & 0x3FFF, 14);
    uint32_t rt = inst & 0x1F;
    uint64_t val = cpu_reg(c, rt);
    bool bit_set = ((val >> bit) & 1) != 0;
    bool take = op == 0 ? !bit_set : bit_set;
    if (take) c->pc = c->pc + imm14 * 4;
    else c->pc += 4;
    return 0;
}

static int exec_branch(fp_cpu *c, uint32_t inst) {
    uint32_t top6 = (inst >> 26) & 0x3F;
    if (top6 == 0x05) return exec_b_uncond(c, inst, false);
    if (top6 == 0x25) return exec_b_uncond(c, inst, true);
    if (((inst >> 25) & 0x3F) == 0x1A) return exec_cbx(c, inst);
    if (((inst >> 25) & 0x7F) == 0x2A) return exec_b_cond(c, inst);
    if (((inst >> 25) & 0x7F) == 0x6B) return exec_branch_reg(c, inst);
    if (((inst >> 25) & 0x3F) == 0x1B) return exec_test_branch(c, inst);
    return fail(inst, "unhandled branch");
}

/* ============================================================
 * Loads and Stores
 * ============================================================ */

static int do_load_store(fp_cpu *c, fp_mem *m, uint32_t size, uint32_t opc,
                         uint64_t addr, uint32_t rt) {
    switch (opc) {
        case 0: /* STR */
            switch (size) {
                case 0: mem_write8(m, addr, (uint8_t)cpu_reg(c, rt)); break;
                case 1: mem_write16(m, addr, (uint16_t)cpu_reg(c, rt)); break;
                case 2: mem_write32(m, addr, (uint32_t)cpu_reg(c, rt)); break;
                case 3: mem_write64(m, addr, cpu_reg(c, rt)); break;
                default: break;
            }
            break;
        case 1: { /* LDR zero-extend */
            uint64_t val;
            switch (size) {
                case 0: val = mem_read8(m, addr); break;
                case 1: val = mem_read16(m, addr); break;
                case 2: val = mem_read32(m, addr); break;
                case 3: val = mem_read64(m, addr); break;
                default: val = 0; break;
            }
            cpu_set_reg(c, rt, val);
            break;
        }
        case 2: /* LDRS 64-bit sign-extend */
            switch (size) {
                case 0: cpu_set_reg(c, rt, fp_sign_extend(mem_read8(m, addr), 8)); break;
                case 1: cpu_set_reg(c, rt, fp_sign_extend(mem_read16(m, addr), 16)); break;
                case 2: cpu_set_reg(c, rt, fp_sign_extend(mem_read32(m, addr), 32)); break;
                default: break; /* PRFM nop */
            }
            break;
        case 3: /* LDRS 32-bit */
            switch (size) {
                case 0: cpu_set_reg(c, rt, (uint64_t)(uint32_t)(int32_t)(int8_t)mem_read8(m, addr)); break;
                case 1: cpu_set_reg(c, rt, (uint64_t)(uint32_t)(int32_t)(int16_t)mem_read16(m, addr)); break;
                default: break;
            }
            break;
        default: break;
    }
    c->pc += 4;
    return 0;
}

static int exec_ldst_unsigned(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t size = (inst >> 30) & 3;
    uint32_t opc = (inst >> 22) & 3;
    uint64_t imm12 = (inst >> 10) & 0xFFF;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    uint64_t offset = imm12 * (1ULL << size);
    uint64_t addr = cpu_reg_sp(c, rn) + offset;
    return do_load_store(c, m, size, opc, addr, rt);
}

static int exec_ldst_imm9(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t size = (inst >> 30) & 3;
    uint32_t opc = (inst >> 22) & 3;
    uint64_t imm9 = fp_sign_extend((inst >> 12) & 0x1FF, 9);
    uint32_t idx_type = (inst >> 10) & 3;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    uint64_t base = cpu_reg_sp(c, rn);
    uint64_t addr;
    switch (idx_type) {
        case 0: addr = base + imm9; break;
        case 1: cpu_set_reg_sp(c, rn, base + imm9); addr = base; break;
        case 3: addr = base + imm9; cpu_set_reg_sp(c, rn, addr); break;
        default: return fail(inst, "reserved ldst idxType");
    }
    return do_load_store(c, m, size, opc, addr, rt);
}

static int exec_ldst_reg_off(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t size = (inst >> 30) & 3;
    uint32_t opc = (inst >> 22) & 3;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t option = (inst >> 13) & 7;
    uint32_t s = (inst >> 12) & 1;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    uint64_t base = cpu_reg_sp(c, rn);
    uint64_t offset = cpu_reg(c, rm);
    switch (option) {
        case 2: offset &= 0xFFFFFFFFULL; break;
        case 6: offset = fp_sign_extend(offset & 0xFFFFFFFFULL, 32); break;
        default: break; /* 3=LSL, 7=SXTX */
    }
    if (s) offset <<= size;
    return do_load_store(c, m, size, opc, base + offset, rt);
}

static int exec_ldst_pair(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t opc = (inst >> 30) & 3;
    uint32_t pair_type = (inst >> 23) & 7;
    uint32_t load = (inst >> 22) & 1;
    uint64_t imm7 = fp_sign_extend((inst >> 15) & 0x7F, 7);
    uint32_t rt2 = (inst >> 10) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    uint64_t scale;
    switch (opc) {
        case 0: scale = 4; break;
        case 1: scale = 4; break;
        case 2: scale = 8; break;
        default: return fail(inst, "reserved LDP/STP opc");
    }
    uint64_t offset = imm7 * scale;
    uint64_t base = cpu_reg_sp(c, rn);
    uint64_t addr;
    switch (pair_type) {
        case 1: cpu_set_reg_sp(c, rn, base + offset); addr = base; break;
        case 2: addr = base + offset; break;
        case 3: addr = base + offset; cpu_set_reg_sp(c, rn, addr); break;
        default: return fail(inst, "reserved LDP/STP type");
    }
    if (load) {
        switch (opc) {
            case 0:
                cpu_set_reg(c, rt, mem_read32(m, addr));
                cpu_set_reg(c, rt2, mem_read32(m, addr + 4));
                break;
            case 1:
                cpu_set_reg(c, rt, fp_sign_extend(mem_read32(m, addr), 32));
                cpu_set_reg(c, rt2, fp_sign_extend(mem_read32(m, addr + 4), 32));
                break;
            case 2:
                cpu_set_reg(c, rt, mem_read64(m, addr));
                cpu_set_reg(c, rt2, mem_read64(m, addr + 8));
                break;
            default: break;
        }
    } else {
        switch (opc) {
            case 0:
                mem_write32(m, addr, (uint32_t)cpu_reg(c, rt));
                mem_write32(m, addr + 4, (uint32_t)cpu_reg(c, rt2));
                break;
            case 2:
                mem_write64(m, addr, cpu_reg(c, rt));
                mem_write64(m, addr + 8, cpu_reg(c, rt2));
                break;
            default: break;
        }
    }
    c->pc += 4;
    return 0;
}

static int exec_ldr_literal(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t opc = (inst >> 30) & 3;
    uint64_t imm19 = fp_sign_extend((inst >> 5) & 0x7FFFF, 19);
    uint32_t rt = inst & 0x1F;
    uint64_t addr = c->pc + imm19 * 4;
    switch (opc) {
        case 0: cpu_set_reg(c, rt, mem_read32(m, addr)); break;
        case 1: cpu_set_reg(c, rt, mem_read64(m, addr)); break;
        case 2: cpu_set_reg(c, rt, fp_sign_extend(mem_read32(m, addr), 32)); break;
        default: break;
    }
    c->pc += 4;
    return 0;
}

/* ---- SIMD load/store helpers ---- */

static size_t simd_access_size(uint32_t size, uint32_t opc) {
    if (size == 0 && opc >= 2) return 16;
    if (size == 0) return 1;
    if (size == 1) return 2;
    if (size == 2) return 4;
    return 8;
}

static void do_simd_store(fp_cpu *c, fp_mem *m, uint64_t addr, uint32_t rt, size_t n) {
    switch (n) {
        case 1: mem_write8(m, addr, (uint8_t)c->vreg[rt][0]); break;
        case 2: mem_write16(m, addr, (uint16_t)c->vreg[rt][0]); break;
        case 4: mem_write32(m, addr, (uint32_t)c->vreg[rt][0]); break;
        case 8: mem_write64(m, addr, c->vreg[rt][0]); break;
        case 16:
            mem_write64(m, addr, c->vreg[rt][0]);
            mem_write64(m, addr + 8, c->vreg[rt][1]);
            break;
        default: break;
    }
}

static void do_simd_load(fp_cpu *c, fp_mem *m, uint64_t addr, uint32_t rt, size_t n) {
    c->vreg[rt][0] = 0;
    c->vreg[rt][1] = 0;
    switch (n) {
        case 1: c->vreg[rt][0] = mem_read8(m, addr); break;
        case 2: c->vreg[rt][0] = mem_read16(m, addr); break;
        case 4: c->vreg[rt][0] = mem_read32(m, addr); break;
        case 8: c->vreg[rt][0] = mem_read64(m, addr); break;
        case 16:
            c->vreg[rt][0] = mem_read64(m, addr);
            c->vreg[rt][1] = mem_read64(m, addr + 8);
            break;
        default: break;
    }
}

static int exec_ldst_simd_unsigned(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t size = (inst >> 30) & 3;
    uint32_t opc = (inst >> 22) & 3;
    uint64_t imm12 = (inst >> 10) & 0xFFF;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    size_t n = simd_access_size(size, opc);
    uint64_t offset = imm12 * (uint64_t)n;
    uint64_t addr = cpu_reg_sp(c, rn) + offset;
    if ((opc & 1) == 0) do_simd_store(c, m, addr, rt, n);
    else do_simd_load(c, m, addr, rt, n);
    c->pc += 4;
    return 0;
}

static int exec_ldst_simd_imm9(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t size = (inst >> 30) & 3;
    uint32_t opc = (inst >> 22) & 3;
    uint64_t imm9 = fp_sign_extend((inst >> 12) & 0x1FF, 9);
    uint32_t idx_type = (inst >> 10) & 3;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    size_t n = simd_access_size(size, opc);
    uint64_t base = cpu_reg_sp(c, rn);
    uint64_t addr;
    switch (idx_type) {
        case 0: addr = base + imm9; break;
        case 1: cpu_set_reg_sp(c, rn, base + imm9); addr = base; break;
        case 3: addr = base + imm9; cpu_set_reg_sp(c, rn, addr); break;
        default: return fail(inst, "reserved SIMD ldst idxType");
    }
    if ((opc & 1) == 0) do_simd_store(c, m, addr, rt, n);
    else do_simd_load(c, m, addr, rt, n);
    c->pc += 4;
    return 0;
}

static int exec_ldst_pair_simd(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t opc = (inst >> 30) & 3;
    uint32_t pair_type = (inst >> 23) & 7;
    uint32_t load = (inst >> 22) & 1;
    uint64_t imm7 = fp_sign_extend((inst >> 15) & 0x7F, 7);
    uint32_t rt2 = (inst >> 10) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rt = inst & 0x1F;
    uint64_t scale;
    switch (opc) {
        case 0: scale = 4; break;
        case 1: scale = 8; break;
        case 2: scale = 16; break;
        default: return fail(inst, "reserved SIMD LDP/STP opc");
    }
    uint64_t offset = imm7 * scale;
    uint64_t base = cpu_reg_sp(c, rn);
    uint64_t addr;
    switch (pair_type) {
        case 1: cpu_set_reg_sp(c, rn, base + offset); addr = base; break;
        case 2: addr = base + offset; break;
        case 3: addr = base + offset; cpu_set_reg_sp(c, rn, addr); break;
        default: return fail(inst, "reserved SIMD LDP/STP type");
    }
    size_t elem_size = (size_t)scale;
    if (load) {
        do_simd_load(c, m, addr, rt, elem_size);
        do_simd_load(c, m, addr + elem_size, rt2, elem_size);
    } else {
        do_simd_store(c, m, addr, rt, elem_size);
        do_simd_store(c, m, addr + elem_size, rt2, elem_size);
    }
    c->pc += 4;
    return 0;
}

static int exec_ldr_simd_literal(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t opc = (inst >> 30) & 3;
    uint64_t imm19 = fp_sign_extend((inst >> 5) & 0x7FFFF, 19);
    uint32_t rt = inst & 0x1F;
    uint64_t addr = c->pc + imm19 * 4;
    size_t n;
    switch (opc) {
        case 0: n = 4; break;
        case 1: n = 8; break;
        case 2: n = 16; break;
        default: n = 0; break;
    }
    do_simd_load(c, m, addr, rt, n);
    c->pc += 4;
    return 0;
}

static int exec_load_store(fp_cpu *c, fp_mem *m, uint32_t inst) {
    uint32_t op1 = (inst >> 27) & 7;
    uint32_t v = (inst >> 26) & 1;
    if (op1 == 5 && v == 0) return exec_ldst_pair(c, m, inst);
    if (op1 == 5 && v == 1) return exec_ldst_pair_simd(c, m, inst);
    if (op1 == 7 && v == 0) {
        if ((inst >> 24) & 1) return exec_ldst_unsigned(c, m, inst);
        if ((inst >> 21) & 1) return exec_ldst_reg_off(c, m, inst);
        return exec_ldst_imm9(c, m, inst);
    }
    if (op1 == 7 && v == 1) {
        if ((inst >> 24) & 1) return exec_ldst_simd_unsigned(c, m, inst);
        return exec_ldst_simd_imm9(c, m, inst);
    }
    if (op1 == 3 && v == 0) return exec_ldr_literal(c, m, inst);
    if (op1 == 3 && v == 1) return exec_ldr_simd_literal(c, m, inst);
    return fail(inst, "unhandled load/store");
}

/* ============================================================
 * SIMD / Floating-Point
 * ============================================================ */

static int exec_dup(fp_cpu *c, uint32_t inst) {
    uint32_t q = (inst >> 30) & 1;
    uint32_t imm5 = (inst >> 16) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint64_t val = cpu_reg(c, rn);
    uint64_t result[2] = {0, 0};
    if ((imm5 & 1) == 1) {
        uint64_t b = (uint8_t)val;
        for (int i = 0; i < 8; i++) result[0] |= b << (i * 8);
        if (q) result[1] = result[0];
    } else if ((imm5 & 3) == 2) {
        uint64_t h = (uint16_t)val;
        for (int i = 0; i < 4; i++) result[0] |= h << (i * 16);
        if (q) result[1] = result[0];
    } else if ((imm5 & 7) == 4) {
        uint64_t s = (uint32_t)val;
        result[0] = s | (s << 32);
        if (q) result[1] = result[0];
    } else if ((imm5 & 15) == 8) {
        result[0] = val;
        if (q) result[1] = val;
    }
    c->vreg[rd][0] = result[0];
    c->vreg[rd][1] = result[1];
    c->pc += 4;
    return 0;
}

static int exec_umov(fp_cpu *c, uint32_t inst) {
    uint32_t imm5 = (inst >> 16) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint64_t lo = c->vreg[rn][0];
    uint64_t hi = c->vreg[rn][1];
    uint64_t val;
    if ((imm5 & 1) == 1) {
        uint32_t idx = imm5 >> 1;
        val = idx < 8 ? ((lo >> (idx * 8)) & 0xFF) : ((hi >> ((idx - 8) * 8)) & 0xFF);
    } else if ((imm5 & 3) == 2) {
        uint32_t idx = imm5 >> 2;
        val = idx < 4 ? ((lo >> (idx * 16)) & 0xFFFF) : ((hi >> ((idx - 4) * 16)) & 0xFFFF);
    } else if ((imm5 & 7) == 4) {
        uint32_t idx = imm5 >> 3;
        switch (idx) {
            case 0: val = lo & 0xFFFFFFFFULL; break;
            case 1: val = lo >> 32; break;
            case 2: val = hi & 0xFFFFFFFFULL; break;
            default: val = hi >> 32; break;
        }
    } else if ((imm5 & 15) == 8) {
        uint32_t idx = imm5 >> 4;
        val = idx == 0 ? lo : hi;
    } else {
        val = 0;
    }
    cpu_set_reg(c, rd, val);
    c->pc += 4;
    return 0;
}

static int exec_ins(fp_cpu *c, uint32_t inst) {
    uint32_t imm5 = (inst >> 16) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint64_t val = cpu_reg(c, rn);
    uint64_t lo = c->vreg[rd][0];
    uint64_t hi = c->vreg[rd][1];
    if ((imm5 & 1) == 1) {
        uint32_t idx = imm5 >> 1;
        if (idx < 8) { uint32_t sh = idx * 8; lo = (lo & ~(0xFFULL << sh)) | ((val & 0xFF) << sh); }
        else { uint32_t sh = (idx - 8) * 8; hi = (hi & ~(0xFFULL << sh)) | ((val & 0xFF) << sh); }
    } else if ((imm5 & 3) == 2) {
        uint32_t idx = imm5 >> 2;
        if (idx < 4) { uint32_t sh = idx * 16; lo = (lo & ~(0xFFFFULL << sh)) | ((val & 0xFFFF) << sh); }
        else { uint32_t sh = (idx - 4) * 16; hi = (hi & ~(0xFFFFULL << sh)) | ((val & 0xFFFF) << sh); }
    } else if ((imm5 & 7) == 4) {
        uint32_t idx = imm5 >> 3;
        if (idx < 2) { uint32_t sh = idx * 32; lo = (lo & ~(0xFFFFFFFFULL << sh)) | ((val & 0xFFFFFFFFULL) << sh); }
        else { uint32_t sh = (idx - 2) * 32; hi = (hi & ~(0xFFFFFFFFULL << sh)) | ((val & 0xFFFFFFFFULL) << sh); }
    } else if ((imm5 & 15) == 8) {
        uint32_t idx = imm5 >> 4;
        if (idx == 0) lo = val;
        else hi = val;
    }
    c->vreg[rd][0] = lo;
    c->vreg[rd][1] = hi;
    c->pc += 4;
    return 0;
}

static int exec_shl(fp_cpu *c, uint32_t inst) {
    uint32_t q = (inst >> 30) & 1;
    uint32_t immh = (inst >> 19) & 0xF;
    uint32_t immb = (inst >> 16) & 0x7;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint32_t immhb = (immh << 3) | immb;
    uint64_t src_lo = c->vreg[rn][0];
    uint64_t src_hi = c->vreg[rn][1];
    uint64_t dst_lo = 0, dst_hi = 0;
    if (immh & 0x8) {
        uint32_t shift = immhb - 64;
        dst_lo = src_lo << shift;
        if (q) dst_hi = src_hi << shift;
    } else if ((immh & 0xC) == 0x4) {
        uint32_t shift = immhb - 32;
        uint64_t lo0 = (src_lo & 0xFFFFFFFFULL) << shift;
        uint64_t lo1 = ((src_lo >> 32) & 0xFFFFFFFFULL) << shift;
        dst_lo = (lo0 & 0xFFFFFFFFULL) | ((lo1 & 0xFFFFFFFFULL) << 32);
        if (q) {
            uint64_t hi0 = (src_hi & 0xFFFFFFFFULL) << shift;
            uint64_t hi1 = ((src_hi >> 32) & 0xFFFFFFFFULL) << shift;
            dst_hi = (hi0 & 0xFFFFFFFFULL) | ((hi1 & 0xFFFFFFFFULL) << 32);
        }
    } else if ((immh & 0xE) == 0x2) {
        uint32_t shift = immhb - 16;
        for (uint32_t i = 0; i < 4; i++) {
            uint64_t elem = (src_lo >> (i * 16)) & 0xFFFF;
            dst_lo |= ((elem << shift) & 0xFFFF) << (i * 16);
        }
        if (q) for (uint32_t i = 0; i < 4; i++) {
            uint64_t elem = (src_hi >> (i * 16)) & 0xFFFF;
            dst_hi |= ((elem << shift) & 0xFFFF) << (i * 16);
        }
    } else if ((immh & 0xF) == 0x1) {
        uint32_t shift = immhb - 8;
        for (uint32_t i = 0; i < 8; i++) {
            uint64_t elem = (src_lo >> (i * 8)) & 0xFF;
            dst_lo |= ((elem << shift) & 0xFF) << (i * 8);
        }
        if (q) for (uint32_t i = 0; i < 8; i++) {
            uint64_t elem = (src_hi >> (i * 8)) & 0xFF;
            dst_hi |= ((elem << shift) & 0xFF) << (i * 8);
        }
    }
    c->vreg[rd][0] = dst_lo;
    c->vreg[rd][1] = dst_hi;
    c->pc += 4;
    return 0;
}

static int exec_movi(fp_cpu *c, uint32_t inst) {
    uint32_t q = (inst >> 30) & 1;
    uint32_t op = (inst >> 29) & 1;
    uint32_t cmode = (inst >> 12) & 0xF;
    uint32_t rd = inst & 0x1F;
    uint32_t a = (inst >> 18) & 1;
    uint32_t b = (inst >> 17) & 1;
    uint32_t cc = (inst >> 16) & 1;
    uint32_t d = (inst >> 9) & 1;
    uint32_t e = (inst >> 8) & 1;
    uint32_t f = (inst >> 7) & 1;
    uint32_t g = (inst >> 6) & 1;
    uint32_t h = (inst >> 5) & 1;
    uint32_t imm8 = (a << 7) | (b << 6) | (cc << 5) | (d << 4) | (e << 3) | (f << 2) | (g << 1) | h;
    uint64_t imm64 = 0;
    if (cmode <= 7) {
        uint32_t shift = (cmode / 2) * 8;
        uint64_t elem = (uint64_t)imm8 << shift;
        if (op == 1) elem = ~elem & 0xFFFFFFFFULL;
        imm64 = elem | (elem << 32);
    } else if (cmode == 0x8 || cmode == 0x9) {
        uint32_t shift = (cmode & 1) * 8;
        uint64_t elem = (uint64_t)imm8 << shift;
        if (op == 1) elem = ~elem & 0xFFFF;
        for (int i = 0; i < 4; i++) imm64 |= (elem & 0xFFFF) << (i * 16);
    } else if (cmode == 0xA || cmode == 0xB || cmode == 0xC || cmode == 0xD) {
        uint32_t shift = (cmode & 1) * 8;
        uint64_t elem = shift == 0 ? (((uint64_t)imm8 << 8) | 0xFF)
                                   : (((uint64_t)imm8 << 16) | 0xFFFF);
        if (op == 1) elem = ~elem & 0xFFFFFFFFULL;
        imm64 = elem | (elem << 32);
    } else if (cmode == 0xE) {
        if (op == 0) {
            for (int i = 0; i < 8; i++) imm64 |= (uint64_t)imm8 << (i * 8);
        } else {
            for (int i = 0; i < 8; i++)
                if ((imm8 >> i) & 1) imm64 |= 0xFFULL << (i * 8);
        }
    } else if (cmode == 0xF) {
        if (op == 0) {
            imm64 = (uint64_t)fp_vfp_expand_imm32(imm8);
            imm64 = imm64 | (imm64 << 32);
        } else {
            imm64 = fp_vfp_expand_imm64(imm8);
        }
    }
    c->vreg[rd][0] = imm64;
    c->vreg[rd][1] = q ? imm64 : 0;
    c->pc += 4;
    return 0;
}

static int exec_xtn(fp_cpu *c, uint32_t inst) {
    uint32_t q = (inst >> 30) & 1;
    uint32_t size = (inst >> 22) & 3;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint64_t src_lo = c->vreg[rn][0];
    uint64_t src_hi = c->vreg[rn][1];
    uint64_t narrow = 0;
    switch (size) {
        case 0:
            for (uint32_t i = 0; i < 4; i++) narrow |= ((src_lo >> (i * 16)) & 0xFF) << (i * 8);
            for (uint32_t i = 0; i < 4; i++) narrow |= ((src_hi >> (i * 16)) & 0xFF) << ((i + 4) * 8);
            break;
        case 1:
            for (uint32_t i = 0; i < 2; i++) narrow |= ((src_lo >> (i * 32)) & 0xFFFF) << (i * 16);
            for (uint32_t i = 0; i < 2; i++) narrow |= ((src_hi >> (i * 32)) & 0xFFFF) << ((i + 2) * 16);
            break;
        case 2:
            narrow = (src_lo & 0xFFFFFFFFULL) | ((src_hi & 0xFFFFFFFFULL) << 32);
            break;
        default: break;
    }
    if (q == 0) {
        c->vreg[rd][0] = narrow;
        c->vreg[rd][1] = 0;
    } else {
        c->vreg[rd][1] = narrow;
    }
    c->pc += 4;
    return 0;
}

static int exec_ext(fp_cpu *c, uint32_t inst) {
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t imm4 = (inst >> 11) & 0xF;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint8_t src[32];
    uint64_t lo = c->vreg[rn][0], hi = c->vreg[rn][1];
    for (int i = 0; i < 8; i++) { src[i] = (uint8_t)(lo >> (i * 8)); src[i + 8] = (uint8_t)(hi >> (i * 8)); }
    uint64_t lo2 = c->vreg[rm][0], hi2 = c->vreg[rm][1];
    for (int i = 0; i < 8; i++) { src[i + 16] = (uint8_t)(lo2 >> (i * 8)); src[i + 24] = (uint8_t)(hi2 >> (i * 8)); }
    uint64_t dst_lo = 0, dst_hi = 0;
    for (int i = 0; i < 8; i++) {
        dst_lo |= (uint64_t)src[imm4 + i] << (i * 8);
        dst_hi |= (uint64_t)src[imm4 + i + 8] << (i * 8);
    }
    c->vreg[rd][0] = dst_lo;
    c->vreg[rd][1] = dst_hi;
    c->pc += 4;
    return 0;
}

static uint64_t rev64_lane(uint64_t v, uint32_t size) {
    switch (size) {
        case 0:
            return ((v & 0xFF) << 56) | ((v & 0xFF00) << 40) | ((v & 0xFF0000) << 24) |
                   ((v & 0xFF000000) << 8) | ((v >> 8) & 0xFF000000) | ((v >> 24) & 0xFF0000) |
                   ((v >> 40) & 0xFF00) | ((v >> 56) & 0xFF);
        case 1:
            return ((v & 0xFFFF) << 48) | (((v >> 16) & 0xFFFF) << 32) |
                   (((v >> 32) & 0xFFFF) << 16) | (v >> 48);
        case 2:
            return (v << 32) | (v >> 32);
        default:
            return v;
    }
}

static int exec_rev64_vec(fp_cpu *c, uint32_t inst) {
    uint32_t q = (inst >> 30) & 1;
    uint32_t size = (inst >> 22) & 3;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint64_t dst_lo = rev64_lane(c->vreg[rn][0], size);
    uint64_t dst_hi = q ? rev64_lane(c->vreg[rn][1], size) : 0;
    c->vreg[rd][0] = dst_lo;
    c->vreg[rd][1] = dst_hi;
    c->pc += 4;
    return 0;
}

static void simd3_same_arith(uint64_t a_lo, uint64_t a_hi, uint64_t b_lo, uint64_t b_hi,
                             uint32_t size, bool is_sub, uint64_t *out_lo, uint64_t *out_hi) {
    uint64_t lo_r = 0, hi_r = 0;
#define OP(a, b, mask) (is_sub ? (((a) - (b)) & (mask)) : (((a) + (b)) & (mask)))
    switch (size) {
        case 0:
            for (uint32_t i = 0; i < 8; i++) {
                uint32_t s = i * 8;
                lo_r |= OP((a_lo >> s) & 0xFF, (b_lo >> s) & 0xFF, 0xFF) << s;
                hi_r |= OP((a_hi >> s) & 0xFF, (b_hi >> s) & 0xFF, 0xFF) << s;
            }
            break;
        case 1:
            for (uint32_t i = 0; i < 4; i++) {
                uint32_t s = i * 16;
                lo_r |= OP((a_lo >> s) & 0xFFFF, (b_lo >> s) & 0xFFFF, 0xFFFF) << s;
                hi_r |= OP((a_hi >> s) & 0xFFFF, (b_hi >> s) & 0xFFFF, 0xFFFF) << s;
            }
            break;
        case 2:
            for (uint32_t i = 0; i < 2; i++) {
                uint32_t s = i * 32;
                lo_r |= OP((a_lo >> s) & 0xFFFFFFFFULL, (b_lo >> s) & 0xFFFFFFFFULL, 0xFFFFFFFFULL) << s;
                hi_r |= OP((a_hi >> s) & 0xFFFFFFFFULL, (b_hi >> s) & 0xFFFFFFFFULL, 0xFFFFFFFFULL) << s;
            }
            break;
        case 3:
            lo_r = OP(a_lo, b_lo, ~0ULL);
            hi_r = OP(a_hi, b_hi, ~0ULL);
            break;
        default: break;
    }
#undef OP
    *out_lo = lo_r;
    *out_hi = hi_r;
}

static int exec_adv_simd_3same(fp_cpu *c, uint32_t inst) {
    uint32_t q = (inst >> 30) & 1;
    uint32_t u = (inst >> 29) & 1;
    uint32_t size = (inst >> 22) & 3;
    uint32_t rm = (inst >> 16) & 0x1F;
    uint32_t opcode = (inst >> 11) & 0x1F;
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    uint64_t a_lo = c->vreg[rn][0], a_hi = c->vreg[rn][1];
    uint64_t b_lo = c->vreg[rm][0], b_hi = c->vreg[rm][1];
    uint64_t lo_r, hi_r;
    switch (opcode) {
        case 3:
            switch ((u << 2) | size) {
                case 0: lo_r = a_lo & b_lo; hi_r = a_hi & b_hi; break;
                case 1: lo_r = a_lo & ~b_lo; hi_r = a_hi & ~b_hi; break;
                case 2: lo_r = a_lo | b_lo; hi_r = a_hi | b_hi; break;
                case 3: lo_r = a_lo | ~b_lo; hi_r = a_hi | ~b_hi; break;
                case 4: lo_r = a_lo ^ b_lo; hi_r = a_hi ^ b_hi; break;
                case 5: {
                    uint64_t d_lo = c->vreg[rd][0], d_hi = c->vreg[rd][1];
                    lo_r = (a_lo & d_lo) | (b_lo & ~d_lo);
                    hi_r = (a_hi & d_hi) | (b_hi & ~d_hi);
                    break;
                }
                case 6: {
                    uint64_t d_lo = c->vreg[rd][0], d_hi = c->vreg[rd][1];
                    lo_r = (a_lo & b_lo) | (d_lo & ~b_lo);
                    hi_r = (a_hi & b_hi) | (d_hi & ~b_hi);
                    break;
                }
                case 7: {
                    uint64_t d_lo = c->vreg[rd][0], d_hi = c->vreg[rd][1];
                    lo_r = (a_lo & ~b_lo) | (d_lo & b_lo);
                    hi_r = (a_hi & ~b_hi) | (d_hi & b_hi);
                    break;
                }
                default: lo_r = 0; hi_r = 0; break;
            }
            break;
        case 16:
            simd3_same_arith(a_lo, a_hi, b_lo, b_hi, size, u == 1, &lo_r, &hi_r);
            break;
        default:
            return fail(inst, "unhandled AdvSIMD3Same");
    }
    c->vreg[rd][0] = lo_r;
    c->vreg[rd][1] = q ? hi_r : 0;
    c->pc += 4;
    return 0;
}

static int exec_simd(fp_cpu *c, uint32_t inst) {
    uint32_t rn = (inst >> 5) & 0x1F;
    uint32_t rd = inst & 0x1F;
    /* FMOV Dd, Xn */
    if ((inst & 0xFFFFFC00) == 0x9E670000) { c->vreg[rd][0] = cpu_reg(c, rn); c->vreg[rd][1] = 0; c->pc += 4; return 0; }
    /* FMOV Xd, Dn */
    if ((inst & 0xFFFFFC00) == 0x9E660000) { cpu_set_reg(c, rd, c->vreg[rn][0]); c->pc += 4; return 0; }
    /* FMOV Vd.D[1], Xn */
    if ((inst & 0xFFFFFC00) == 0x9EAF0000) { c->vreg[rd][1] = cpu_reg(c, rn); c->pc += 4; return 0; }
    /* FMOV Xd, Vn.D[1] */
    if ((inst & 0xFFFFFC00) == 0x9EAE0000) { cpu_set_reg(c, rd, c->vreg[rn][1]); c->pc += 4; return 0; }
    /* FMOV Sd, Wn */
    if ((inst & 0xFFFFFC00) == 0x1E270000) { c->vreg[rd][0] = (uint32_t)cpu_reg(c, rn); c->vreg[rd][1] = 0; c->pc += 4; return 0; }
    /* FMOV Wd, Sn */
    if ((inst & 0xFFFFFC00) == 0x1E260000) { cpu_set_reg(c, rd, (uint32_t)c->vreg[rn][0]); c->pc += 4; return 0; }
    if ((inst & 0xBFE0FC00) == 0x0E000C00) return exec_dup(c, inst);
    if ((inst & 0xBFE0FC00) == 0x0E003C00) return exec_umov(c, inst);
    if ((inst & 0xBFE0FC00) == 0x0E001C00) return exec_ins(c, inst);
    if ((inst & 0xBF80FC00) == 0x0F005400) return exec_shl(c, inst);
    if ((inst & 0x9FF80400) == 0x0F000400) return exec_movi(c, inst);
    if ((inst & 0xBF3FFC00) == 0x0E212800) return exec_xtn(c, inst);
    if ((inst & 0xBFE08400) == 0x2E000000) return exec_ext(c, inst);
    if ((inst & 0xBF3FFC00) == 0x0E200800) return exec_rev64_vec(c, inst);
    if ((inst & 0x9F200400) == 0x0E200400) return exec_adv_simd_3same(c, inst);
    /* FMOV scalar imm */
    if ((inst & 0x9F01FC00) == 0x1E201000) {
        uint32_t imm8 = (inst >> 13) & 0xFF;
        c->vreg[rd][0] = fp_vfp_expand_imm64(imm8);
        c->vreg[rd][1] = 0;
        c->pc += 4;
        return 0;
    }
    return fail(inst, "unhandled SIMD");
}

/* ============================================================
 * Main step / run
 * ============================================================ */

int fp_step(fp_state *s, uint32_t inst) {
    /* BRK -> dynamic stub. */
    if ((inst & 0xFFE0001F) == 0xD4200000) {
        const char *name = state_dyn_stub_classify(s, s->cpu.pc);
        char *dup = strdup(name);
        u64map_put(&s->stubs, s->cpu.pc, dup);
        int rc = state_handle_stub(s, name);
        s->cpu.pc = s->cpu.x[30];
        return rc;
    }
    uint32_t op0 = (inst >> 25) & 0xF;
    if ((op0 >> 1) == 4) return exec_dpimm(&s->cpu, inst);
    if ((op0 >> 1) == 5) return exec_branch(&s->cpu, inst);
    if ((op0 & 5) == 4) return exec_load_store(&s->cpu, &s->mem, inst);
    if ((op0 & 7) == 5) return exec_dpreg(&s->cpu, inst);
    if ((op0 & 7) == 7) return exec_simd(&s->cpu, inst);
    return fail(inst, "unhandled op0");
}

int fp_run(fp_state *s, uint64_t halt_pc) {
    uint64_t count = 0;
    while (s->cpu.pc != halt_pc) {
        uint64_t pc = s->cpu.pc;
        void *nm = NULL;
        if (u64map_get(&s->stubs, pc, &nm)) {
            int rc = state_handle_stub(s, (const char *)nm);
            s->cpu.pc = s->cpu.x[30];
            count++;
            if (rc) return rc;
            continue;
        }
        uint32_t inst = mem_fetch_inst(&s->mem, pc);
        if (inst == 0) {
            const char *name = state_dyn_stub_classify(s, pc);
            char *dup = strdup(name);
            u64map_put(&s->stubs, pc, dup);
            int rc = state_handle_stub(s, name);
            s->cpu.pc = s->cpu.x[30];
            count++;
            if (rc) return rc;
            continue;
        }
        int rc = fp_step(s, inst);
        if (rc) {
            fprintf(stderr, "fpemu: at PC=0x%llx (inst #%llu)\n",
                    (unsigned long long)pc, (unsigned long long)count);
            return rc;
        }
        count++;
        if (count > 100000000ULL) {
            fprintf(stderr, "fpemu: exceeded 100M instructions at PC=0x%llx\n",
                    (unsigned long long)s->cpu.pc);
            return -1;
        }
    }
    return 0;
}
