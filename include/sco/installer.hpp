#pragma once

#include "sco/environment.hpp"

#include <filesystem>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace sco {

struct InstallOptions {
    bool global = false;
    bool independent = false;
    bool use_cache = true;
    bool check_hash = true;
    bool update_scoop = true;
    bool force = false;
    bool report_old_uninstall = false;
    std::string architecture = "64bit";
    std::string source_bucket;
    std::string source_url;
};

struct InstallResult {
    std::string app;
    std::string version;
    bool already_installed = false;
    std::filesystem::path install_dir;
    std::filesystem::path current_dir;
    std::vector<std::string> messages;
    std::vector<std::string> warnings;
};

class HashCheckError : public std::runtime_error {
public:
    HashCheckError(
        std::string app,
        std::string version,
        std::filesystem::path manifest_path,
        std::string url,
        std::filesystem::path cached,
        std::filesystem::path install_path,
        std::filesystem::path install_dir,
        std::string manifest_hash);

    std::string app;
    std::string version;
    std::filesystem::path manifest_path;
    std::string url;
    std::filesystem::path cached;
    std::filesystem::path install_path;
    std::filesystem::path install_dir;
    std::string manifest_hash;
};

class ArtifactFetchError : public std::runtime_error {
public:
    ArtifactFetchError(std::string url, std::string message);

    std::string url;
    std::string message;
};

struct UninstallResult {
    std::string app;
    bool removed = false;
    bool skipped = false;
    std::filesystem::path app_dir;
    std::vector<std::string> messages;
    std::vector<std::string> warnings;
};

struct CleanupResult {
    std::string app;
    std::string current_version;
    bool app_dir_exists = false;
    std::vector<std::filesystem::path> removed_versions;
};

struct ResetResult {
    std::string app;
    std::string version;
    bool reset = false;
    std::filesystem::path install_dir;
    std::filesystem::path current_dir;
    std::vector<std::string> messages;
    std::vector<std::string> warnings;
};

InstallResult install_manifest_file(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const InstallOptions& options);

UninstallResult uninstall_app(
    const Environment& environment,
    const std::string& app,
    bool global = false,
    bool purge = false,
    const std::function<bool()>& should_skip_after_pre_uninstall = {});
CleanupResult cleanup_app(const Environment& environment, const std::string& app, bool global = false);
ResetResult reset_app(const Environment& environment, const std::string& app, const std::string& version = {}, bool global = false);
std::filesystem::path current_executable_path();
int try_run_as_shim(int argc, wchar_t** argv);

} // namespace sco
