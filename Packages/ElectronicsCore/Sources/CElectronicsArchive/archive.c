#include "CElectronicsArchive.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

int electronics_inflate_raw(const uint8_t *input, size_t input_size,
                            uint8_t *output, size_t expected_size) {
    if (input_size > UINT_MAX || expected_size >= UINT_MAX || !output) return 0;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_size;
    stream.next_out = output;
    stream.avail_out = (uInt)(expected_size + 1);
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
    int result = inflate(&stream, Z_FINISH);
    int valid = result == Z_STREAM_END && stream.total_in == input_size &&
                stream.total_out == expected_size;
    inflateEnd(&stream);
    return valid;
}

uint32_t electronics_crc32(const uint8_t *bytes, size_t size) {
    uLong result = crc32(0L, Z_NULL, 0);
    while (size) {
        uInt chunk = size > UINT_MAX ? UINT_MAX : (uInt)size;
        result = crc32(result, bytes, chunk);
        bytes += chunk;
        size -= chunk;
    }
    return (uint32_t)result;
}
