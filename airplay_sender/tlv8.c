/* TLV8 (HAP) encode/decode with 255-byte fragmentation. See tlv8.h. */
#include <string.h>

#include "tlv8.h"

size_t
tlv8_encode(const tlv8_item *items, size_t n_items, uint8_t *out, size_t out_cap)
{
    size_t pos = 0;
    for (size_t i = 0; i < n_items; i++) {
        const tlv8_item *it = &items[i];
        size_t off = 0;
        /* A zero-length value still emits one empty item. */
        do {
            size_t chunk = it->len - off;
            if (chunk > 255) chunk = 255;
            if (pos + 2 + chunk > out_cap) return 0;
            out[pos++] = it->type;
            out[pos++] = (uint8_t)chunk;
            if (chunk) {
                memcpy(out + pos, it->data + off, chunk);
                pos += chunk;
            }
            off += chunk;
        } while (off < it->len);
    }
    return pos;
}

int
tlv8_get(const uint8_t *buf, size_t buf_len, uint8_t type,
         uint8_t *out, size_t out_cap, size_t *out_len)
{
    size_t total = 0;
    int found = 0;
    size_t i = 0;
    while (i + 2 <= buf_len) {
        uint8_t t = buf[i];
        uint8_t l = buf[i + 1];
        if (i + 2 + l > buf_len) break; /* truncated */
        const uint8_t *v = buf + i + 2;
        if (t == type) {
            found = 1;
            if (out && total < out_cap) {
                size_t n = l;
                if (total + n > out_cap) n = out_cap - total;
                memcpy(out + total, v, n);
            }
            total += l;
        } else if (found) {
            /* A different type ends the (possibly fragmented) value. */
            break;
        }
        i += 2 + l;
    }
    if (out_len) *out_len = total;
    return found;
}
