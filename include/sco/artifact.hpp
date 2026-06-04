#pragma once

#include "sco/environment.hpp"

#include <filesystem>
#include <string>
#include <utility>
#include <vector>

namespace sco {

struct FetchedArtifact {
    std::filesystem::path cache_path;
    std::filesystem::path install_path;
    std::string filename;
};

std::filesystem::path cache_path(const Environment& environment, const std::string& app, const std::string& version, const std::string& url);
std::string hash_file(const std::filesystem::path& path, const std::string& algorithm);
bool file_hash_matches(const std::filesystem::path& path, const std::string& manifest_hash);
std::string sha256_file(const std::filesystem::path& path);
std::string sha256_text(const std::string& text);
std::string url_filename(const std::string& url);
std::string url_remote_filename(const std::string& url);

std::filesystem::path fetch_artifact_to_cache(
    const Environment& environment,
    const std::string& app,
    const std::string& version,
    const std::string& url,
    const std::filesystem::path& manifest_dir,
    bool use_cache,
    const std::vector<std::pair<std::string, std::string>>& cookies);

FetchedArtifact fetch_artifact(
    const Environment& environment,
    const std::string& app,
    const std::string& version,
    const std::string& url,
    const std::filesystem::path& manifest_dir,
    const std::filesystem::path& destination_dir,
    bool use_cache,
    const std::vector<std::pair<std::string, std::string>>& cookies);

} // namespace sco
