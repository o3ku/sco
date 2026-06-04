#include "sco/envvars.hpp"

#include "sco/config.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace sco {

namespace {

std::filesystem::path env_file_path() {
    if (const char* value = std::getenv("SCOOP_ENV_FILE"); value != nullptr && value[0] != '\0') {
        return std::filesystem::path(value);
    }
    return {};
}

std::string normalize_separator(std::string value) {
    std::replace(value.begin(), value.end(), '/', '\\');
    return value;
}

bool ascii_equals_ci(std::string_view lhs, std::string_view rhs) {
    if (lhs.size() != rhs.size()) {
        return false;
    }
    for (std::size_t i = 0; i < lhs.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(lhs[i])) != std::tolower(static_cast<unsigned char>(rhs[i]))) {
            return false;
        }
    }
    return true;
}

bool starts_with_ascii_ci_at(const std::string& value, std::size_t pos, std::string_view prefix) {
    if (pos + prefix.size() > value.size()) {
        return false;
    }
    return ascii_equals_ci(std::string_view(value.data() + pos, prefix.size()), prefix);
}

std::optional<std::string> braced_variable_name_at(const std::string& value, std::size_t pos) {
    constexpr std::string_view prefix = "${";
    if (value.rfind(prefix, pos) != pos) {
        return std::nullopt;
    }
    const auto end = value.find('}', pos + prefix.size());
    if (end == std::string::npos) {
        return std::nullopt;
    }
    return value.substr(pos + prefix.size(), end - pos - prefix.size());
}

std::size_t env_name_length_at(const std::string& value, std::size_t pos) {
    std::size_t length = 0;
    while (pos + length < value.size()) {
        const unsigned char ch = static_cast<unsigned char>(value[pos + length]);
        if (std::isalnum(ch) == 0 && ch != '_') {
            break;
        }
        ++length;
    }
    return length;
}

std::string process_env_value(const std::string& name) {
    if (const char* value = std::getenv(name.c_str()); value != nullptr) {
        return value;
    }
    return {};
}

std::string local_variable_value(const std::string& name, const std::map<std::string, std::string>& local_variables) {
    for (const auto& [local_name, value] : local_variables) {
        if (ascii_equals_ci(local_name, name)) {
            return value;
        }
    }
    return {};
}

std::string powershell_variable_value(const std::string& name, const std::map<std::string, std::string>& local_variables) {
    constexpr std::string_view env_prefix = "env:";
    if (name.size() >= env_prefix.size() && ascii_equals_ci(std::string_view(name.data(), env_prefix.size()), env_prefix)) {
        return process_env_value(name.substr(env_prefix.size()));
    }
    return local_variable_value(name, local_variables);
}

std::string expand_manifest_value(
    std::string value,
    const std::filesystem::path& install_dir,
    const std::filesystem::path& original_dir,
    const Environment& environment,
    const Manifest& manifest,
    bool global) {
    const std::map<std::string, std::string> local_variables{
        {"app", manifest.name},
        {"architecture", manifest.architecture},
        {"dir", normalize_separator(install_dir.string())},
        {"global", global ? "True" : "False"},
        {"original_dir", normalize_separator(original_dir.string())},
        {"persist_dir", normalize_separator((environment.persist_dir(global) / manifest.name).string())},
        {"version", original_dir.filename().string()},
    };

    std::size_t pos = 0;
    while (pos < value.size()) {
        if (value[pos] == '`' && pos + 1 < value.size() && value[pos + 1] == '$') {
            value.erase(pos, 1);
            ++pos;
            continue;
        }

        if (auto variable_name = braced_variable_name_at(value, pos)) {
            const auto replacement = powershell_variable_value(*variable_name, local_variables);
            value.replace(pos, variable_name->size() + 3, replacement);
            pos += replacement.size();
            continue;
        }

        if (starts_with_ascii_ci_at(value, pos, "$env:")) {
            const auto name_start = pos + 5;
            const auto name_length = env_name_length_at(value, name_start);
            if (name_length > 0) {
                const auto replacement = process_env_value(value.substr(name_start, name_length));
                value.replace(pos, name_length + 5, replacement);
                pos += replacement.size();
                continue;
            }
        }

        if (value[pos] == '$') {
            const auto name_start = pos + 1;
            const auto name_length = env_name_length_at(value, name_start);
            if (name_length > 0) {
                const auto replacement = powershell_variable_value(value.substr(name_start, name_length), local_variables);
                value.replace(pos, name_length + 1, replacement);
                pos += replacement.size();
                continue;
            }
        }
        ++pos;
    }
    return value;
}

nlohmann::json read_env_file(const std::filesystem::path& path) {
    std::ifstream stream(path);
    if (!stream) {
        return nlohmann::json::object();
    }
    try {
        nlohmann::json value;
        stream >> value;
        return value.is_object() ? value : nlohmann::json::object();
    } catch (const nlohmann::json::exception&) {
        return nlohmann::json::object();
    }
}

void write_env_file(const std::filesystem::path& path, const nlohmann::json& value) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write environment file " + path.string());
    }
    stream << value.dump(4) << '\n';
}

std::vector<std::string> split_path_list(const std::string& value) {
    std::vector<std::string> parts;
    std::string current;
    for (const auto ch : value) {
        if (ch == ';') {
            if (!current.empty()) {
                parts.push_back(current);
            }
            current.clear();
        } else {
            current.push_back(ch);
        }
    }
    if (!current.empty()) {
        parts.push_back(current);
    }
    return parts;
}

std::string join_path_list(const std::vector<std::string>& parts) {
    std::string value;
    for (const auto& part : parts) {
        if (part.empty()) {
            continue;
        }
        if (!value.empty()) {
            value.push_back(';');
        }
        value += part;
    }
    return value;
}

bool path_equals(const std::string& lhs, const std::string& rhs) {
#ifdef _WIN32
    return _stricmp(lhs.c_str(), rhs.c_str()) == 0;
#else
    return lhs == rhs;
#endif
}

std::string trim_trailing_separators(std::string value) {
    while (!value.empty() && (value.back() == '\\' || value.back() == '/')) {
        value.pop_back();
    }
    return value;
}

bool path_is_same_or_child(const std::string& path, const std::string& root) {
    const auto normalized_path = trim_trailing_separators(normalize_separator(path));
    const auto normalized_root = trim_trailing_separators(normalize_separator(root));
    if (path_equals(normalized_path, normalized_root)) {
        return true;
    }
    if (normalized_path.size() <= normalized_root.size() || normalized_path[normalized_root.size()] != '\\') {
        return false;
    }
#ifdef _WIN32
    return _strnicmp(normalized_path.c_str(), normalized_root.c_str(), normalized_root.size()) == 0;
#else
    return normalized_path.rfind(normalized_root, 0) == 0;
#endif
}

std::string add_paths(std::string current, const std::vector<std::string>& additions) {
    auto parts = split_path_list(current);
    for (auto it = additions.rbegin(); it != additions.rend(); ++it) {
        const auto& addition = *it;
        if (addition.empty()) {
            continue;
        }
        parts.erase(std::remove_if(parts.begin(), parts.end(), [&](const auto& part) {
            return path_equals(part, addition);
        }), parts.end());
        parts.insert(parts.begin(), addition);
    }
    return join_path_list(parts);
}

bool path_list_contains(const std::string& current, const std::string& path) {
    const auto parts = split_path_list(current);
    return std::any_of(parts.begin(), parts.end(), [&](const auto& part) {
        return path_equals(part, path);
    });
}

struct PathTreeRemoval {
    std::string value;
    std::vector<std::string> removed;
};

PathTreeRemoval remove_path_tree(std::string current, const std::string& root) {
    auto parts = split_path_list(current);
    std::vector<std::string> kept;
    std::vector<std::string> removed;
    for (auto& part : parts) {
        if (path_is_same_or_child(part, root)) {
            removed.push_back(std::move(part));
        } else {
            kept.push_back(std::move(part));
        }
    }
    return PathTreeRemoval{.value = join_path_list(kept), .removed = std::move(removed)};
}

std::string remove_paths(std::string current, const std::vector<std::string>& removals) {
    auto parts = split_path_list(current);
    parts.erase(std::remove_if(parts.begin(), parts.end(), [&](const auto& part) {
        return std::any_of(removals.begin(), removals.end(), [&](const auto& removal) {
            return path_equals(part, removal);
        });
    }), parts.end());
    return join_path_list(parts);
}

std::vector<std::string> manifest_paths(const Manifest& manifest, const std::filesystem::path& install_dir) {
    std::vector<std::string> paths;
    const auto absolute_install = std::filesystem::absolute(install_dir).lexically_normal();
    for (const auto& item : manifest.env_add_path) {
        if (item.empty()) {
            continue;
        }
        const auto candidate = std::filesystem::absolute(install_dir / item).lexically_normal();
        const auto relative = candidate.lexically_relative(absolute_install);
        if (relative.empty() || relative.is_absolute() || *relative.begin() == std::filesystem::path("..")) {
            continue;
        }
        paths.push_back(normalize_separator(candidate.string()));
    }
    return paths;
}

std::optional<std::string> isolated_path_variable_from_value(const nlohmann::json* value) {
    if (!value) {
        return std::nullopt;
    }
    if (value->is_boolean()) {
        return value->get<bool>() ? std::optional<std::string>{"SCOOP_PATH"} : std::nullopt;
    }
    if (value->is_string()) {
        auto name = value->get<std::string>();
        if (!name.empty()) {
            std::transform(name.begin(), name.end(), name.begin(), [](unsigned char ch) {
                return static_cast<char>(std::toupper(ch));
            });
            return name;
        }
    }
    return std::nullopt;
}

std::optional<std::string> isolated_path_variable(const Environment& environment) {
    const ConfigStore config(environment.config_file);
    const auto value = config.get("use_isolated_path");
    return isolated_path_variable_from_value(value ? &*value : nullptr);
}

std::string target_path_var(const Environment& environment) {
    return isolated_path_variable(environment).value_or("PATH");
}

std::string path_var_reference(const std::string& name) {
    return "%" + name + "%";
}

std::string get_user_env(const std::string& name, bool global) {
#ifdef _WIN32
    HKEY root = global ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER;
    const char* subkey = global ? "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" : "Environment";
    HKEY key = nullptr;
    if (RegOpenKeyExA(root, subkey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
        return {};
    }

    DWORD type = 0;
    DWORD size = 0;
    const auto query = RegQueryValueExA(key, name.c_str(), nullptr, &type, nullptr, &size);
    if (query != ERROR_SUCCESS || size == 0) {
        RegCloseKey(key);
        return {};
    }

    std::string value(size, '\0');
    if (RegQueryValueExA(key, name.c_str(), nullptr, &type, reinterpret_cast<LPBYTE>(value.data()), &size) != ERROR_SUCCESS) {
        RegCloseKey(key);
        return {};
    }
    RegCloseKey(key);
    while (!value.empty() && value.back() == '\0') {
        value.pop_back();
    }
    return value;
#else
    (void)global;
    if (const char* value = std::getenv(name.c_str()); value != nullptr) {
        return value;
    }
    return {};
#endif
}

void set_user_env(const std::string& name, const std::string& value, bool global) {
#ifdef _WIN32
    HKEY root = global ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER;
    const char* subkey = global ? "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" : "Environment";
    HKEY key = nullptr;
    if (RegOpenKeyExA(root, subkey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
        throw std::runtime_error("cannot open environment registry key");
    }

    if (value.empty()) {
        RegDeleteValueA(key, name.c_str());
    } else {
        const auto kind = value.find('%') == std::string::npos ? REG_SZ : REG_EXPAND_SZ;
        if (RegSetValueExA(key, name.c_str(), 0, kind, reinterpret_cast<const BYTE*>(value.c_str()), static_cast<DWORD>(value.size() + 1)) != ERROR_SUCCESS) {
            RegCloseKey(key);
            throw std::runtime_error("cannot set environment variable " + name);
        }
    }
    RegCloseKey(key);
#else
    (void)global;
    if (value.empty()) {
        unsetenv(name.c_str());
    } else {
        setenv(name.c_str(), value.c_str(), 1);
    }
#endif
}

void apply_to_file(
    const std::filesystem::path& file,
    const std::string& path_var,
    const std::vector<std::string>& paths,
    const Manifest& manifest,
    const std::filesystem::path& install_dir,
    const std::filesystem::path& original_dir,
    const Environment& environment,
    bool global) {
    auto env = read_env_file(file);
    if (path_var != "PATH" && !paths.empty()) {
        env["PATH"] = add_paths(env.value("PATH", std::string{}), {path_var_reference(path_var)});
    }
    env[path_var] = add_paths(env.value(path_var, std::string{}), paths);
    for (const auto& item : manifest.env_set) {
        env[item.first] = expand_manifest_value(item.second, install_dir, original_dir, environment, manifest, global);
    }
    write_env_file(file, env);
}

void remove_from_file(const std::filesystem::path& file, const std::string& path_var, const std::vector<std::string>& paths, const Manifest& manifest) {
    auto env = read_env_file(file);
    if (path_var != "PATH" && !paths.empty()) {
        env["PATH"] = remove_paths(env.value("PATH", std::string{}), paths);
    }
    env[path_var] = remove_paths(env.value(path_var, std::string{}), paths);
    for (const auto& item : manifest.env_set) {
        env.erase(item.first);
    }
    write_env_file(file, env);
}

bool add_path_to_environment(const std::string& name, const std::string& path, bool global) {
    if (const auto file = env_file_path(); !file.empty()) {
        auto env = read_env_file(file);
        const auto current = env.value(name, std::string{});
        if (path_list_contains(current, path)) {
            return false;
        }
        env[name] = add_paths(current, {path});
        write_env_file(file, env);
        return true;
    }

    const auto current = get_user_env(name, global);
    if (path_list_contains(current, path)) {
        return false;
    }
    set_user_env(name, add_paths(current, {path}), global);
    return true;
}

bool add_path_to_environment_with_default(const std::string& name, const std::string& path, bool global, const std::string& default_value) {
    if (const auto file = env_file_path(); !file.empty()) {
        auto env = read_env_file(file);
        auto current = env.value(name, std::string{});
        if (current.empty()) {
            current = default_value;
        }
        if (path_list_contains(current, path)) {
            return false;
        }
        env[name] = add_paths(current, {path});
        write_env_file(file, env);
        return true;
    }

    auto current = get_user_env(name, global);
    if (current.empty()) {
        current = default_value;
    }
    if (path_list_contains(current, path)) {
        return false;
    }
    set_user_env(name, add_paths(current, {path}), global);
    return true;
}

void remove_path_from_environment(const std::string& name, const std::string& path, bool global) {
    if (const auto file = env_file_path(); !file.empty()) {
        auto env = read_env_file(file);
        env[name] = remove_paths(env.value(name, std::string{}), {path});
        write_env_file(file, env);
        return;
    }

    set_user_env(name, remove_paths(get_user_env(name, global), {path}), global);
}

std::vector<std::string> remove_path_tree_from_environment(const std::string& name, const std::string& root, bool global) {
    if (const auto file = env_file_path(); !file.empty()) {
        auto env = read_env_file(file);
        auto removal = remove_path_tree(env.value(name, std::string{}), root);
        env[name] = removal.value;
        write_env_file(file, env);
        return removal.removed;
    }

    auto removal = remove_path_tree(get_user_env(name, global), root);
    set_user_env(name, removal.value, global);
    return removal.removed;
}

std::string environment_value(const std::string& name, bool global) {
    if (const auto file = env_file_path(); !file.empty()) {
        return read_env_file(file).value(name, std::string{});
    }
    return get_user_env(name, global);
}

void set_environment_value(const std::string& name, const std::string& value, bool global) {
    if (const auto file = env_file_path(); !file.empty()) {
        auto env = read_env_file(file);
        if (value.empty()) {
            env.erase(name);
        } else {
            env[name] = value;
        }
        write_env_file(file, env);
        return;
    }
    set_user_env(name, value, global);
}

} // namespace

void apply_manifest_environment(
    const Environment& environment,
    const Manifest& manifest,
    const std::filesystem::path& install_dir,
    const std::filesystem::path& original_dir,
    bool global) {
    const auto paths = manifest_paths(manifest, install_dir);
    if (paths.empty() && manifest.env_set.empty()) {
        return;
    }

    const auto path_var = target_path_var(environment);
    if (const auto file = env_file_path(); !file.empty()) {
        apply_to_file(file, path_var, paths, manifest, install_dir, original_dir, environment, global);
        return;
    }

    if (!paths.empty()) {
        if (path_var != "PATH") {
            set_user_env("PATH", add_paths(get_user_env("PATH", global), {path_var_reference(path_var)}), global);
        }
        set_user_env(path_var, add_paths(get_user_env(path_var, global), paths), global);
    }
    for (const auto& item : manifest.env_set) {
        set_user_env(item.first, expand_manifest_value(item.second, install_dir, original_dir, environment, manifest, global), global);
    }
}

void remove_manifest_environment(
    const Environment& environment,
    const Manifest& manifest,
    const std::filesystem::path& install_dir,
    bool global) {
    const auto paths = manifest_paths(manifest, install_dir);
    if (paths.empty() && manifest.env_set.empty()) {
        return;
    }

    const auto path_var = target_path_var(environment);
    if (const auto file = env_file_path(); !file.empty()) {
        remove_from_file(file, path_var, paths, manifest);
        return;
    }

    if (!paths.empty()) {
        if (path_var != "PATH") {
            set_user_env("PATH", remove_paths(get_user_env("PATH", global), paths), global);
        }
        set_user_env(path_var, remove_paths(get_user_env(path_var, global), paths), global);
    }
    for (const auto& item : manifest.env_set) {
        set_user_env(item.first, {}, global);
    }
}

bool add_environment_path(
    const Environment&,
    const std::string& name,
    const std::filesystem::path& path,
    bool global) {
    return add_path_to_environment(name, normalize_separator(std::filesystem::absolute(path).lexically_normal().string()), global);
}

bool add_environment_path_with_default(
    const Environment&,
    const std::string& name,
    const std::filesystem::path& path,
    bool global,
    const std::string& default_value) {
    return add_path_to_environment_with_default(
        name,
        normalize_separator(std::filesystem::absolute(path).lexically_normal().string()),
        global,
        default_value);
}

void remove_environment_path(
    const Environment&,
    const std::string& name,
    const std::filesystem::path& path,
    bool global) {
    remove_path_from_environment(name, normalize_separator(std::filesystem::absolute(path).lexically_normal().string()), global);
}

std::vector<std::string> remove_environment_path_tree(
    const Environment&,
    const std::string& name,
    const std::filesystem::path& root,
    bool global) {
    return remove_path_tree_from_environment(name, normalize_separator(std::filesystem::absolute(root).lexically_normal().string()), global);
}

std::string environment_variable_value(const std::string& name, bool global) {
    return environment_value(name, global);
}

void set_environment_variable_value(const std::string& name, const std::string& value, bool global) {
    set_environment_value(name, value, global);
}

void migrate_isolated_path_setting(
    const Environment& environment,
    const std::optional<nlohmann::json>& previous,
    const nlohmann::json& next,
    bool global) {
    const auto old_var = isolated_path_variable_from_value(previous ? &*previous : nullptr).value_or("PATH");
    const auto new_var = isolated_path_variable_from_value(&next).value_or("PATH");
    if (old_var == new_var) {
        return;
    }

    if (new_var == "PATH") {
        const auto moved = environment_value(old_var, global);
        if (!moved.empty()) {
            set_environment_value("PATH", add_paths(environment_value("PATH", global), split_path_list(moved)), global);
            remove_path_from_environment("PATH", path_var_reference(old_var), global);
            set_environment_value(old_var, {}, global);
        }
        return;
    }

    const auto moved = remove_path_tree_from_environment(old_var, normalize_separator(std::filesystem::absolute(environment.apps_dir(global)).lexically_normal().string()), global);
    if (moved.empty()) {
        return;
    }

    set_environment_value(new_var, add_paths(environment_value(new_var, global), moved), global);
    add_path_to_environment("PATH", path_var_reference(new_var), global);
    if (old_var != "PATH") {
        remove_path_from_environment("PATH", path_var_reference(old_var), global);
        set_environment_value(old_var, {}, global);
    }
}

} // namespace sco
