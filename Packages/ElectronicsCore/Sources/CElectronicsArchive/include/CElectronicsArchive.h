#ifndef C_ELECTRONICS_ARCHIVE_H
#define C_ELECTRONICS_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>

/* ZIP method 8 is raw DEFLATE. Requires an output buffer of expected_size + 1. */
int electronics_inflate_raw(const uint8_t *input, size_t input_size,
                            uint8_t *output, size_t expected_size);
uint32_t electronics_crc32(const uint8_t *bytes, size_t size);
#endif
