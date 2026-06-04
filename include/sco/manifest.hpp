#pragma once

#include <filesystem>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace sco {

struct ManifestBin {
    std::string target;
    std::string name;
    std::string args;
};

struct ManifestPersist {
    std::string source;
    std::string target;
};

struct ManifestShortcut {
    std::string target;
    std::string name;
    std::string args;
    std::string icon;
    bool has_icon = false;
};

struct ManifestCommand {
    std::vector<std::string> script;
    std::string file;
    std::vector<std::string> args;
    bool keep = false;
};

struct Manifest {
    std::string name;
    std::string version;
    std::string architecture;
    bool supports_current_architecture = false;
    std::string description;
    std::string homepage;
    std::string license;
    std::string license_url;
    bool innosetup = false;
    std::vector<std::pair<std::string, std::string>> cookies;
    std::vector<std::string> urls;
    std::vector<std::string> hashes;
    std::vector<std::string> extract_dirs;
    std::vector<std::string> extract_tos;
    std::vector<std::string> depends;
    std::vector<std::string> env_add_path;
    std::map<std::string, std::string> env_set;
    std::vector<std::string> pre_install;
    std::vector<std::string> post_install;
    ManifestCommand installer;
    std::vector<std::string> pre_uninstall;
    std::vector<std::string> post_uninstall;
    ManifestCommand uninstaller;
    std::vector<std::string> notes;
    std::string psmodule_name;
    std::map<std::string, std::vector<std::string>> suggestions;
    std::vector<ManifestShortcut> shortcuts;
    std::vector<ManifestPersist> persists;
    std::vector<ManifestBin> bins;
};

class ManifestError : public std::runtime_error {
public:
    explicit ManifestError(const std::string& message);
};

Manifest load_manifest_file(
    const std::filesystem::path& path,
    std::optional<std::string> forced_name = std::nullopt,
    std::string architecture = "64bit");

} // namespace sco
