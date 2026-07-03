/*
 * TLV8 — HomeKit/HAP type-length-value encoding used by AirPlay 2 pair-setup and
 * pair-verify. Each item is [type:1][len:1][value:len]; values longer than 255
 * bytes are split into consecutive items of the same type (the decoder
 * concatenates them). See airfry src/tlv8.rs.
 */
#ifndef TLV8_H
#define TLV8_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* HAP TLV types. */
#define TLV_METHOD          0x00
#define TLV_IDENTIFIER      0x01
#define TLV_SALT            0x02
#define TLV_PUBLIC_KEY      0x03
#define TLV_PROOF           0x04
#define TLV_ENCRYPTED_DATA  0x05
#define TLV_STATE           0x06
#define TLV_ERROR           0x07
#define TLV_SIGNATURE       0x0A
#define TLV_FLAGS           0x13

typedef struct {
    uint8_t type;
    const uint8_t *data;
    size_t len;
} tlv8_item;

/*
 * Encode items into out (handling >255-byte fragmentation). Returns the number
 * of bytes written, or 0 if out_cap is too small.
 */
size_t tlv8_encode(const tlv8_item *items, size_t n_items, uint8_t *out, size_t out_cap);

/*
 * Find the (defragmented) value for a type in a TLV8 buffer. On success returns
 * 1, writes up to out_cap bytes to out, and sets *out_len to the full value
 * length. Returns 0 if the type is absent.
 */
int tlv8_get(const uint8_t *buf, size_t buf_len, uint8_t type,
             uint8_t *out, size_t out_cap, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* TLV8_H */
