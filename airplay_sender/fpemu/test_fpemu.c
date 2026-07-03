/* Golden-vector test for the C fpemu port. Vectors come from doubletake's
 * internal/fpemu/standalone_test.go — the same values airfry validates against. */
#include <stdio.h>
#include <string.h>

#include "fpemu.h"

extern const uint8_t fpemu_blob[];
extern const uint8_t fpemu_blob_end[];

/* Real m2 captured from an Apple TV (doubletake captured_m2_test.go). */
static const char *CAPTURED_M2_HEX =
    "46504c59030102000000008202034a114c26b77d4e2eec2c8f89fdb653b5b32d"
    "3576bc176816d110a14c3f53c08dbb936183bfdfe0a4f3c12e85216003b46f73"
    "8c40c54da6c436d29d1b342d63c7b314309ae79a33bb1787709ef077cbfe4190"
    "117a3423e270fd1a2eac44da1a7934f59dc681d1b70783f228c4d077c2d495f52"
    "85c3bf8df586fc2ebfe17fb5b65";

static int hexbyte(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static size_t hexdecode(const char *hex, uint8_t *out, size_t out_cap) {
    size_t n = 0;
    for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) {
        if (n >= out_cap) break;
        out[n++] = (uint8_t)((hexbyte(hex[i]) << 4) | hexbyte(hex[i + 1]));
    }
    return n;
}

static void tohex(const uint8_t *b, size_t n, char *out) {
    static const char *H = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[i * 2] = H[b[i] >> 4];
        out[i * 2 + 1] = H[b[i] & 0xF];
    }
    out[n * 2] = '\0';
}

static int failures = 0;

static void check_standalone(const char *name, const uint8_t payload[128], const char *want) {
    uint8_t hash[20];
    char got[41];
    if (fpsap_exchange_standalone(payload, hash) != 0) {
        printf("  [FAIL] %-12s interpreter error\n", name);
        failures++;
        return;
    }
    tohex(hash, 20, got);
    if (strcmp(got, want) == 0) {
        printf("  [ ok ] %-12s %s\n", name, got);
    } else {
        printf("  [FAIL] %-12s got  %s\n         %-12s want %s\n", name, got, "", want);
        failures++;
    }
}

int main(void) {
    uint8_t m2[142];
    size_t m2n = hexdecode(CAPTURED_M2_HEX, m2, sizeof(m2));

    printf("fpemu golden-vector test\n");
    printf("blob: %ld bytes\n", (long)(fpemu_blob_end - fpemu_blob));

    uint8_t p[128];

    memset(p, 0x00, 128);
    check_standalone("all-zeros", p, "6f627565f3e77f5b5ede91beee7baf92e4241e0b");

    memset(p, 0xFF, 128);
    check_standalone("all-0xFF", p, "dc2cc74f2ed55484f59f95b96082f0f5c017dd17");

    if (m2n == 142) {
        memcpy(p, m2 + 14, 128);
        check_standalone("capturedM2", p, "4b911e48af23d8406368aeafbb61bfcd569e3e55");
    } else {
        printf("  [FAIL] capturedM2   hex decode gave %zu bytes (want 142)\n", m2n);
        failures++;
    }

    memset(p, 0x00, 128); p[0] = 0x42;
    check_standalone("0x42-at-0", p, "9bfb9556b8659c2ac94b7ef9e587d71e159ea624");

    memset(p, 0x00, 128); p[63] = 0x42;
    check_standalone("0x42-at-63", p, "150d9fa4eb456e73ba48de5779c5c996b16b3b23");

    memset(p, 0x00, 128); p[64] = 0x42;
    check_standalone("0x42-at-64", p, "a167db30424ff8890d085c0f1c92b2c5cc06fc45");

    memset(p, 0x00, 128); p[127] = 0x42;
    check_standalone("0x42-at-127", p, "d246ec5e7adc8118994b8df77146529486ac7caf");

    /* Full m2 -> m3 path. */
    if (m2n == 142) {
        uint8_t m3[164];
        if (fpsap_exchange_m3(m2, 142, m3) != 0) {
            printf("  [FAIL] m3           exchange error\n");
            failures++;
        } else {
            char h[41];
            tohex(m3 + 144, 20, h);
            int hdr_ok = memcmp(m3, "FPLY", 4) == 0;
            int hash_ok = strcmp(h, "4b911e48af23d8406368aeafbb61bfcd569e3e55") == 0;
            if (hdr_ok && hash_ok)
                printf("  [ ok ] m3           FPLY header + hash %s\n", h);
            else {
                printf("  [FAIL] m3           hdr_ok=%d hash=%s\n", hdr_ok, h);
                failures++;
            }
        }
    }

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "PASSED",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
