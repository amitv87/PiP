/*
 *  TLV8 encoding/decoding for HomeKit-style AirPlay pairing (pair-setup /
 *  pair-verify). Values longer than 255 bytes are split into consecutive runs
 *  of the same tag; decoding concatenates runs of a tag back together.
 */
#ifndef TLV8_H
#define TLV8_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* HAP TLV8 tag types used by AirPlay pairing. */
#define TLV_METHOD         0x00
#define TLV_IDENTIFIER     0x01
#define TLV_SALT           0x02
#define TLV_PUBLIC_KEY     0x03
#define TLV_PROOF          0x04
#define TLV_ENCRYPTED_DATA 0x05
#define TLV_STATE          0x06
#define TLV_ERROR          0x07
#define TLV_SIGNATURE      0x0A
#define TLV_ACL            0x12
#define TLV_FLAGS          0x13

typedef struct {
  uint8_t tag;
  const uint8_t *val;
  size_t len;
} tlv8_item_t;

/*
 * Encode items in order into out. Returns the number of bytes written, or 0 if
 * out_cap is too small.
 */
size_t tlv8_encode(const tlv8_item_t *items, int count, uint8_t *out, size_t out_cap);

/*
 * Copy the concatenated value of the first-seen tag (merging split runs) into
 * out. Returns the value length (>=0) if present, or -1 if the tag is absent.
 * A present tag with an empty value returns 0. If out_cap is too small returns
 * -2.
 */
int tlv8_get(const uint8_t *data, size_t data_len, uint8_t tag,
             uint8_t *out, size_t out_cap);

/* Returns 1 and sets *err if a TLV_ERROR entry is present, else 0. */
int tlv8_get_error(const uint8_t *data, size_t data_len, uint8_t *err);

#ifdef __cplusplus
}
#endif

#endif /* TLV8_H */
