#include "sco/environment.hpp"

#include "sco/config.hpp"

#include <cstdlib>
#include <string>

namespace sco {

namespace {

std::filesystem::path env_path(const char* name) {
    if (const char* value = std::getenv(name); value != nullptr && value[0] != '\0') {
        return std::filesystem::path(value);
    }
    return {};
}

std::filesystem::path user_profile() {
    if (auto path = env_path("USERPROFILE"); !path.empty()) {
        return path;
    }
    if (auto drive = env_path("HOMEDRIVE"); !drive.empty()) {
        if (auto home = env_path("HOMEPATH"); !home.empty()) {
            return drive / home.relative_path();
        }
    }
    return std::filesystem::current_path();
}

std::filesystem::path program_data() {
    if (auto path = env_path("ProgramData"); !path.empty()) {
        return path;
    }
    return "C:/ProgramData";
}

std::filesystem::path config_file_path() {
    const auto config_home = [&] {
        if (auto path = env_path("XDG_CONFIG_HOME"); !path.empty()) {
            return path;
        }
        return user_profile() / ".config";
    }();
    return config_home / "scoop" / "config.json";
}

std::filesystem::path config_path_or(const ConfigStore& config, const std::string& key, std::filesystem::path fallback) {
    const auto value = config.get(key);
    if (value && value->is_string() && !value->get<std::string>().empty()) {
        return std::filesystem::path(value->get<std::string>());
    }
    return fallback;
}

} // namespace

std::filesystem::path Environment::apps_dir(bool global) const {
    return (global ? global_dir : root_dir) / "apps";
}

std::filesystem::path Environment::shims_dir(bool global) const {
    return (global ? global_dir : root_dir) / "shims";
}

std::filesystem::path Environment::modules_dir(bool global) const {
    return (global ? global_dir : root_dir) / "modules";
}

std::filesystem::path Environment::persist_dir(bool global) const {
    return (global ? global_dir : root_dir) / "persist";
}

std::filesystem::path Environment::buckets_dir() const {
    return root_dir / "buckets";
}

Environment load_environment() {
    Environment environment;
    environment.config_file = config_file_path();

    const ConfigStore config(environment.config_file);
    environment.root_dir = env_path("SCOOP");
    if (environment.root_dir.empty()) {
        environment.root_dir = config_path_or(config, "root_path", user_profile() / "scoop");
    }

    environment.global_dir = env_path("SCOOP_GLOBAL");
    if (environment.global_dir.empty()) {
        environment.global_dir = config_path_or(config, "global_path", program_data() / "scoop");
    }

    environment.cache_dir = env_path("SCOOP_CACHE");
    if (environment.cache_dir.empty()) {
        environment.cache_dir = config_path_or(config, "cache_path", environment.root_dir / "cache");
    }

    environment.config_file = std::filesystem::weakly_canonical(environment.config_file);
    environment.root_dir = std::filesystem::weakly_canonical(environment.root_dir);
    environment.global_dir = std::filesystem::weakly_canonical(environment.global_dir);
    environment.cache_dir = std::filesystem::weakly_canonical(environment.cache_dir);
    return environment;
}

} // namespace sco
