#pragma once

#include <string>
#include <string_view>

namespace sco {

bool is_gzip_data(std::string_view data);
std::string decompress_gzip_if_needed(const std::string& data);

} // namespace sco
