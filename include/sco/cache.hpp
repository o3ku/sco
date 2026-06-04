#pragma once

#include "sco/environment.hpp"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace sco {

struct CacheEntry {
    std::string name;
    std::string app;
    std::filesystem::path path;
    std::uintmax_t size = 0;
};

std::vector<CacheEntry> list_cache_entries(const Environment& environment, const std::string& app_filter = {});
std::vector<CacheEntry> list_cache_entries(const Environment& environment, const std::vector<std::string>& app_filters);
std::vector<CacheEntry> remove_cache_entries(const Environment& environment, const std::string& app_filter = {});
std::vector<CacheEntry> remove_cache_entries(const Environment& environment, const std::vector<std::string>& app_filters);
std::vector<CacheEntry> remove_cache_entries_for_app_except_version(
    const Environment& environment,
    const std::string& app,
    const std::string& keep_version);
std::vector<std::filesystem::path> remove_temporary_download_entries(const Environment& environment);

} // namespace sco
