#pragma once

#include "sco/environment.hpp"

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace sco {

struct InstalledApp {
    std::string name;
    std::string version;
    std::string source;
    std::string updated;
    std::string info;
    bool global = false;
};

struct AppStatus {
    std::string name;
    std::string installed_version;
    std::string latest_version;
    std::vector<std::string> missing_dependencies;
    std::string info;
    bool global = false;
    bool outdated = false;
    bool held = false;
    bool deprecated = false;
    bool removed = false;
    bool failed = false;
};

struct HoldResult {
    std::string app;
    bool installed = false;
    bool changed = false;
    bool held = false;
};

std::filesystem::path app_dir(const Environment& environment, const std::string& app, bool global);
std::filesystem::path current_dir_for_version(const Environment& environment, const std::string& app, const std::string& version, bool global);
std::filesystem::path current_dir(const Environment& environment, const std::string& app, bool global);
std::string select_current_version(const Environment& environment, const std::string& app, bool global);
bool app_install_failed(const Environment& environment, const std::string& app, bool global = false);
std::vector<std::string> installed_versions(const Environment& environment, const std::string& app, bool global = false);
std::optional<std::filesystem::path> find_app_prefix(const Environment& environment, const std::string& app);
bool has_installed_apps(const Environment& environment);
std::vector<InstalledApp> list_installed_apps(const Environment& environment, const std::string& query = {});
std::vector<AppStatus> list_app_statuses(const Environment& environment, bool local_only = false);
std::optional<std::string> installed_app_architecture(const Environment& environment, const std::string& app, bool global = false);
std::optional<std::filesystem::path> installed_app_manifest_path(const Environment& environment, const std::string& app, bool global = false);
std::optional<std::string> installed_app_manifest_url(const Environment& environment, const std::string& app, bool global = false);
std::optional<std::filesystem::path> deprecated_manifest_path(const Environment& environment, const std::string& app, const std::string& bucket_name);
bool is_app_held(const Environment& environment, const std::string& app, bool global = false);
HoldResult set_app_hold(const Environment& environment, const std::string& app, bool hold, bool global = false);

} // namespace sco
