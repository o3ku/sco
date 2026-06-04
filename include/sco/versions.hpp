#pragma once

#include <string>

namespace sco {

int compare_versions(const std::string& reference, const std::string& difference);
int compare_versions(const std::string& reference, const std::string& difference, bool update_nightly);
bool is_version_newer(const std::string& current, const std::string& latest);
std::string nightly_version();

} // namespace sco
