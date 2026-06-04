#pragma once

#include "sco/environment.hpp"
#include "sco/manifest.hpp"

#include <filesystem>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <vector>

namespace sco {

void apply_manifest_environment(
    const Environment& environment,
    const Manifest& manifest,
    const std::filesystem::path& install_dir,
    const std::filesystem::path& original_dir,
    bool global);

void remove_manifest_environment(
    const Environment& environment,
    const Manifest& manifest,
    const std::filesystem::path& install_dir,
    bool global);

bool add_environment_path(
    const Environment& environment,
    const std::string& name,
    const std::filesystem::path& path,
    bool global);

bool add_environment_path_with_default(
    const Environment& environment,
    const std::string& name,
    const std::filesystem::path& path,
    bool global,
    const std::string& default_value);

void remove_environment_path(
    const Environment& environment,
    const std::string& name,
    const std::filesystem::path& path,
    bool global);

std::vector<std::string> remove_environment_path_tree(
    const Environment& environment,
    const std::string& name,
    const std::filesystem::path& root,
    bool global);

std::string environment_variable_value(const std::string& name, bool global);
void set_environment_variable_value(const std::string& name, const std::string& value, bool global);

void migrate_isolated_path_setting(
    const Environment& environment,
    const std::optional<nlohmann::json>& previous,
    const nlohmann::json& next,
    bool global);

} // namespace sco
