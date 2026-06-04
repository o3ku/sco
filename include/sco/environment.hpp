#pragma once

#include <filesystem>

namespace sco {

class ConfigStore;

struct Environment {
    std::filesystem::path config_file;
    std::filesystem::path root_dir;
    std::filesystem::path global_dir;
    std::filesystem::path cache_dir;

    std::filesystem::path apps_dir(bool global = false) const;
    std::filesystem::path shims_dir(bool global = false) const;
    std::filesystem::path modules_dir(bool global = false) const;
    std::filesystem::path persist_dir(bool global = false) const;
    std::filesystem::path buckets_dir() const;
};

Environment load_environment();

} // namespace sco
