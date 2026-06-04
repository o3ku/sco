#pragma once

#include "sco/environment.hpp"

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace sco {

struct SearchResult {
    std::string bucket;
    std::string name;
    std::string version;
    std::string description;
    std::vector<std::string> bins;
    std::vector<std::string> shortcuts;
    std::filesystem::path path;
};

struct LocalBucket {
    std::string name;
    std::filesystem::path path;
    std::string source;
    std::string updated;
    std::size_t manifests = 0;
};

enum class BucketChangeReason {
    None,
    NameAlreadyExists,
    RepositoryAlreadyExists,
};

struct BucketChangeResult {
    std::string name;
    std::filesystem::path path;
    bool changed = false;
    BucketChangeReason reason = BucketChangeReason::None;
};

struct BucketUpdateResult {
    std::string name;
    std::filesystem::path path;
    bool updated = false;
    bool changed = false;
    std::string message;
};

struct KnownBucket {
    std::string name;
    std::string repository;
};

std::vector<KnownBucket> list_known_buckets(const std::filesystem::path& start = std::filesystem::current_path());
std::vector<LocalBucket> list_local_buckets(const Environment& environment);
bool git_available();
BucketChangeResult add_local_bucket(const Environment& environment, const std::string& name, const std::filesystem::path& source);
BucketChangeResult add_git_bucket(const Environment& environment, const std::string& name, const std::string& repository);
BucketChangeResult add_bucket_from_zip(const Environment& environment, const std::string& name, const std::string& repository);
BucketChangeResult remove_bucket(const Environment& environment, const std::string& name);
std::vector<BucketUpdateResult> update_buckets(const Environment& environment, const std::string& name = {});
std::optional<std::filesystem::path> find_manifest_in_buckets(const Environment& environment, const std::string& app);
std::vector<std::string> find_manifest_bucket_names(const Environment& environment, const std::string& app);
std::vector<SearchResult> list_bucket_manifest_index(const Environment& environment);
std::vector<SearchResult> search_bucket_manifests(const Environment& environment, const std::string& query, bool sqlite_cache_mode = false);
std::vector<SearchResult> search_known_bucket_manifests(const Environment& environment, const std::string& query);

} // namespace sco
