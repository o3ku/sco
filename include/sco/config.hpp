#pragma once

#include <filesystem>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace sco {

class ConfigStore {
public:
    explicit ConfigStore(std::filesystem::path path);

    const std::filesystem::path& path() const;
    const nlohmann::json& values() const;
    std::optional<nlohmann::json> get(const std::string& name) const;
    void set(const std::string& name, nlohmann::json value);
    void remove(const std::string& name);
    void save() const;

private:
    std::filesystem::path path_;
    nlohmann::json values_;
};

std::string normalize_config_name(std::string name);
nlohmann::json parse_config_value(const std::string& value);
std::string format_config_values(const nlohmann::json& values);
std::string format_config_value(const nlohmann::json& value);
void apply_private_host_headers(
    const ConfigStore& config,
    const std::string& url,
    std::vector<std::pair<std::string, std::string>>& headers);

} // namespace sco
