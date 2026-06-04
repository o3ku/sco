#include "sco/compression.hpp"

#include <stdexcept>

#include <zlib.h>

namespace sco {

bool is_gzip_data(std::string_view data) {
    return data.size() >= 2 &&
        static_cast<unsigned char>(data[0]) == 0x1f &&
        static_cast<unsigned char>(data[1]) == 0x8b;
}

std::string decompress_gzip_if_needed(const std::string& data) {
    if (!is_gzip_data(data)) {
        return data;
    }

    z_stream stream{};
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(data.data()));
    stream.avail_in = static_cast<uInt>(data.size());

    constexpr auto window_bits_with_gzip_header = 16 + MAX_WBITS;
    if (inflateInit2(&stream, window_bits_with_gzip_header) != Z_OK) {
        throw std::runtime_error("cannot initialize gzip decompressor");
    }

    std::string output;
    char buffer[16384];
    int status = Z_OK;
    do {
        stream.next_out = reinterpret_cast<Bytef*>(buffer);
        stream.avail_out = sizeof(buffer);
        status = inflate(&stream, Z_NO_FLUSH);

        if (status != Z_OK && status != Z_STREAM_END) {
            inflateEnd(&stream);
            throw std::runtime_error("cannot decompress gzip response");
        }

        output.append(buffer, sizeof(buffer) - stream.avail_out);
    } while (status != Z_STREAM_END);

    inflateEnd(&stream);
    return output;
}

} // namespace sco
