#pragma once

#include <filesystem>
#include <optional>
#include <string>

namespace sco {

struct Environment;

std::optional<std::string> resolve_checkver_version(const Environment& environment, const std::filesystem::path& manifest_path);

} // namespace sco
