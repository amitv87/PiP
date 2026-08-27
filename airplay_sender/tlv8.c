/*  TLV8 encoding/decoding. See tlv8.h. */
#include "tlv8.h"

#include <string.h>

size_t tlv8_encode(const tlv8_item_t *items, int count, uint8_t *out, size_t out_cap) {
  size_t off = 0;
  for (int i = 0; i < count; i++) {
    const uint8_t *val = items[i].val;
    size_t remaining = items[i].len;

    if (remaining == 0) {
      if (off + 2 > out_cap) return 0;
      out[off++] = items[i].tag;
      out[off++] = 0;
      continue;
    }
    while (remaining > 0) {
      size_t chunk = remaining > 255 ? 255 : remaining;
      if (off + 2 + chunk > out_cap) return 0;
      out[off++] = items[i].tag;
      out[off++] = (uint8_t)chunk;
      memcpy(out + off, val, chunk);
      off += chunk;
      val += chunk;
      remaining -= chunk;
    }
  }
  return off;
}

int tlv8_get(const uint8_t *data, size_t data_len, uint8_t tag,
             uint8_t *out, size_t out_cap) {
  size_t off = 0;
  size_t written = 0;
  int found = 0;

  while (off + 2 <= data_len) {
    uint8_t t = data[off];
    size_t len = data[off + 1];
    off += 2;
    if (off + len > data_len) break;

    if (t == tag) {
      found = 1;
      if (written + len > out_cap) return -2;
      memcpy(out + written, data + off, len);
      written += len;
    }
    off += len;
  }

  if (!found) return -1;
  return (int)written;
}

int tlv8_get_error(const uint8_t *data, size_t data_len, uint8_t *err) {
  uint8_t buf[1];
  int n = tlv8_get(data, data_len, TLV_ERROR, buf, sizeof(buf));
  if (n == 1) {
    if (err) *err = buf[0];
    return 1;
  }
  return 0;
}
