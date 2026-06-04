#include "sco/installer.hpp"

#include "sco/apps.hpp"
#include "sco/artifact.hpp"
#include "sco/buckets.hpp"
#include "sco/config.hpp"
#include "sco/envvars.hpp"
#include "sco/manifest.hpp"
#include "sco/versions.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <iostream>
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

std::string quote_command_arg(const std::filesystem::path& path);
std::string quote_command_string_arg(const std::string& value);
std::wstring quote_windows_process_arg(const std::wstring& value);
std::wstring widen_utf8(const std::string& value);
std::wstring join_forwarded_args(int argc, wchar_t** argv);
int run_shim_child(const std::filesystem::path& target, const std::string& configured_args, int argc, wchar_t** argv);
std::string escape_ps_single_quoted(std::string value);
bool is_safe_relative_path(const std::filesystem::path& path);
bool is_directory_link(const std::filesystem::path& path);
void remove_all_force(const std::filesystem::path& path);
void remove_current_link_or_copy(const std::filesystem::path& current);
void move_directory_contents(const std::filesystem::path& source, const std::filesystem::path& destination);
std::string title_case_hook_name(const std::string& value);
std::filesystem::path current_executable_path_impl();

std::filesystem::path user_profile_path() {
    if (const char* value = std::getenv("USERPROFILE"); value != nullptr && value[0] != '\0') {
        return std::filesystem::path(value);
    }
    if (const char* drive = std::getenv("HOMEDRIVE"); drive != nullptr && drive[0] != '\0') {
        if (const char* home = std::getenv("HOMEPATH"); home != nullptr && home[0] != '\0') {
            return std::filesystem::path(drive) / std::filesystem::path(home).relative_path();
        }
    }
    return {};
}

std::string default_user_psmodule_path() {
    const auto profile = user_profile_path();
    if (profile.empty()) {
        return {};
    }
    return (profile / "Documents" / "WindowsPowerShell" / "Modules").string();
}

nlohmann::json read_json_file(const std::filesystem::path& path) {
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

const nlohmann::json* json_property(const nlohmann::json& object, const char* key) {
    if (!object.is_object()) {
        return nullptr;
    }
    if (const auto exact = object.find(key); exact != object.end()) {
        return &*exact;
    }

    std::string normalized = key;
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    for (auto it = object.begin(); it != object.end(); ++it) {
        auto actual = it.key();
        std::transform(actual.begin(), actual.end(), actual.begin(), [](unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
        if (actual == normalized) {
            return &*it;
        }
    }
    return nullptr;
}

std::string install_architecture_for_dir(const std::filesystem::path& install_dir) {
    const auto install = read_json_file(install_dir / "install.json");
    const auto* architecture_value = json_property(install, "architecture");
    if (architecture_value != nullptr && architecture_value->is_string()) {
        const auto architecture = architecture_value->get<std::string>();
        if (!architecture.empty()) {
            return architecture;
        }
    }
    return "64bit";
}

void write_json_file(const std::filesystem::path& path, const nlohmann::json& value) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write " + path.string());
    }
    stream << value.dump(4) << '\n';
}

void create_current_link_or_copy(
    const std::filesystem::path& target,
    const std::filesystem::path& current,
    std::vector<std::string>* messages = nullptr,
    bool force = false) {
    std::error_code equivalent_error;
    if (std::filesystem::absolute(target).lexically_normal() == std::filesystem::absolute(current).lexically_normal()) {
        return;
    }

    if (messages != nullptr) {
        messages->push_back("Linking " + current.string() + " => " + target.string());
    }

    if (std::filesystem::exists(current) || is_directory_link(current)) {
        remove_current_link_or_copy(current);
    }

    const auto junction = "cmd /c mklink /J " + quote_command_arg(current) + " " + quote_command_arg(target) + " >nul";
    if (std::system(junction.c_str()) == 0) {
        return;
    }

    equivalent_error.clear();
    if (std::filesystem::equivalent(target, current, equivalent_error)) {
        return;
    }
    if (std::filesystem::exists(current) || is_directory_link(current)) {
        remove_current_link_or_copy(current);
    }

    try {
        std::filesystem::create_directory_symlink(target, current);
        return;
    } catch (const std::filesystem::filesystem_error&) {
    }

    equivalent_error.clear();
    if (std::filesystem::equivalent(target, current, equivalent_error)) {
        return;
    }
    if (std::filesystem::exists(current) || is_directory_link(current)) {
        remove_current_link_or_copy(current);
    }

    std::filesystem::copy(target, current, std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing);
}

void remove_current_link_or_copy(const std::filesystem::path& current) {
    std::error_code status_error;
    const auto status = std::filesystem::symlink_status(current, status_error);
    if ((status_error || !std::filesystem::exists(status)) && !is_directory_link(current)) {
        return;
    }

    if (is_directory_link(current)) {
#ifdef _WIN32
        if (RemoveDirectoryW(current.wstring().c_str())) {
            return;
        }
        const auto remove_link = "cmd /c rmdir /s /q " + quote_command_arg(current) + " >nul 2>nul";
        if (std::system(remove_link.c_str()) == 0 && !std::filesystem::exists(current)) {
            return;
        }
#endif
        std::error_code remove_error;
        std::filesystem::remove(current, remove_error);
        if (!std::filesystem::exists(current)) {
            return;
        }
    }

    remove_all_force(current);
}

std::filesystem::path forced_backup_path(const std::filesystem::path& version_dir) {
    const auto parent = version_dir.parent_path();
    const auto base = "_" + version_dir.filename().string() + ".old";
    auto candidate = parent / base;
    for (int i = 1; std::filesystem::exists(candidate); ++i) {
        candidate = parent / (base + "(" + std::to_string(i) + ")");
    }
    return candidate;
}

std::filesystem::path staged_version_path(const std::filesystem::path& version_dir) {
    const auto parent = version_dir.parent_path();
    const auto base = "_" + version_dir.filename().string() + ".new";
    auto candidate = parent / base;
    for (int i = 1; std::filesystem::exists(candidate); ++i) {
        candidate = parent / (base + "(" + std::to_string(i) + ")");
    }
    return candidate;
}

std::string bucket_name_for_manifest(const Environment& environment, const std::filesystem::path& manifest_path) {
    const auto canonical_manifest = std::filesystem::weakly_canonical(manifest_path);
    for (const auto& bucket : list_local_buckets(environment)) {
        const auto bucket_root = std::filesystem::weakly_canonical(bucket.path);
        const auto relative = std::filesystem::relative(canonical_manifest, bucket_root);
        if (!relative.empty() && *relative.begin() != std::filesystem::path("..")) {
            return bucket.name;
        }
    }
    return {};
}

std::string installed_bucket_for_dir(const std::filesystem::path& install_dir) {
    const auto install = read_json_file(install_dir / "install.json");
    const auto* bucket = json_property(install, "bucket");
    if (bucket != nullptr && bucket->is_string()) {
        return bucket->get<std::string>();
    }
    return {};
}

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::optional<std::filesystem::path> resolve_path_command(const std::string& command) {
    if (command.empty() || command.find_first_of("/\\") != std::string::npos) {
        return std::nullopt;
    }

    std::vector<std::string> extensions;
    if (!std::filesystem::path(command).extension().empty()) {
        extensions.push_back("");
    } else {
        extensions = {".com", ".exe", ".bat", ".cmd", ".ps1"};
    }

    const char* path_env = std::getenv("PATH");
    if (path_env == nullptr || path_env[0] == '\0') {
        return std::nullopt;
    }

    const std::string paths = path_env;
    std::size_t start = 0;
    while (start <= paths.size()) {
        const auto end = paths.find(';', start);
        auto entry = paths.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (entry.size() >= 2 && entry.front() == '"' && entry.back() == '"') {
            entry = entry.substr(1, entry.size() - 2);
        }
        if (!entry.empty()) {
            for (const auto& extension : extensions) {
                const auto candidate = std::filesystem::path(entry) / (command + extension);
                const auto candidate_extension = lower_ascii(candidate.extension().string());
                if (candidate_extension != ".com" && candidate_extension != ".exe" && candidate_extension != ".bat" && candidate_extension != ".cmd" &&
                    candidate_extension != ".ps1") {
                    continue;
                }

                std::error_code error;
                if (std::filesystem::is_regular_file(candidate, error)) {
                    const auto canonical = std::filesystem::weakly_canonical(candidate, error);
                    return error ? candidate : canonical;
                }
            }
        }

        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return std::nullopt;
}

std::filesystem::path resolve_bin_target(const std::filesystem::path& install_dir, const ManifestBin& bin) {
    auto target = install_dir / bin.target;
    if (std::filesystem::is_regular_file(target)) {
        return target;
    }

    target = std::filesystem::path(bin.target);
    if (std::filesystem::is_regular_file(target)) {
        return target;
    }

    if (const auto command = resolve_path_command(bin.target)) {
        return *command;
    }

    throw std::runtime_error("cannot create shim for missing bin target: " + bin.target);
}

std::string shim_source_from_cmd(const std::filesystem::path& shim) {
    std::ifstream stream(shim);
    if (!stream) {
        return {};
    }

    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        constexpr std::string_view prefix = "rem source ";
        if (line.rfind(prefix, 0) == 0) {
            return line.substr(prefix.size());
        }
    }
    return {};
}

std::filesystem::path shim_alternative_path(const std::filesystem::path& shim_path, const std::string& source) {
    return std::filesystem::path(shim_path.string() + "." + source);
}

std::string trim_ascii(std::string value) {
    const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    });
    const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }).base();
    if (first >= last) {
        return {};
    }
    return std::string(first, last);
}

std::string strip_utf8_bom(std::string value) {
    if (value.size() >= 3
        && static_cast<unsigned char>(value[0]) == 0xEF
        && static_cast<unsigned char>(value[1]) == 0xBB
        && static_cast<unsigned char>(value[2]) == 0xBF) {
        value.erase(0, 3);
    }
    return value;
}

std::string unquote_shim_value(std::string value) {
    value = trim_ascii(std::move(value));
    if (value.size() >= 2 && ((value.front() == '"' && value.back() == '"') || (value.front() == '\'' && value.back() == '\''))) {
        value = value.substr(1, value.size() - 2);
    }
    return value;
}

std::optional<std::string> read_shim_metadata_value(const std::filesystem::path& shim, const std::string& key) {
    std::ifstream stream(shim, std::ios::binary);
    if (!stream) {
        return std::nullopt;
    }

    std::string line;
    while (std::getline(stream, line)) {
        line = strip_utf8_bom(std::move(line));
        const auto equals = line.find('=');
        if (equals == std::string::npos) {
            continue;
        }
        if (lower_ascii(trim_ascii(line.substr(0, equals))) == key) {
            return unquote_shim_value(line.substr(equals + 1));
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> read_target_from_comment_shim(const std::filesystem::path& shim) {
    std::ifstream stream(shim, std::ios::binary);
    if (!stream) {
        return std::nullopt;
    }

    std::string line;
    while (std::getline(stream, line)) {
        line = strip_utf8_bom(std::move(line));
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }

        std::string target;
        if (line.rfind("@rem ", 0) == 0) {
            if (line.rfind("@rem source ", 0) == 0) {
                continue;
            }
            target = line.substr(5);
        } else if (line.rfind("rem ", 0) == 0) {
            if (line.rfind("rem source ", 0) == 0) {
                continue;
            }
            target = line.substr(4);
        } else if (line.rfind("# ", 0) == 0) {
            target = line.substr(2);
        }

        target = trim_ascii(std::move(target));
        if (!target.empty()) {
            return std::filesystem::path(target);
        }
    }
    return std::nullopt;
}

std::string app_name_from_target_path(const std::filesystem::path& target) {
    auto value = lower_ascii(target.generic_string());
    const std::string marker = "/apps/";
    const auto marker_pos = value.find(marker);
    if (marker_pos == std::string::npos) {
        return {};
    }
    auto remainder = value.substr(marker_pos + marker.size());
    const auto separator = remainder.find('/');
    if (separator != std::string::npos) {
        remainder = remainder.substr(0, separator);
    }
    return remainder;
}

std::string shim_source(const std::filesystem::path& shim) {
    if (lower_ascii(shim.extension().string()) == ".cmd") {
        if (auto source = shim_source_from_cmd(shim); !source.empty()) {
            return source;
        }
    }

    std::optional<std::filesystem::path> target;
    if (lower_ascii(shim.extension().string()) == ".shim") {
        if (const auto path = read_shim_metadata_value(shim, "path")) {
            target = std::filesystem::path(*path);
        }
    } else {
        target = read_target_from_comment_shim(shim);
    }
    if (target) {
        return app_name_from_target_path(*target);
    }
    return {};
}

void preserve_existing_shim_as_alternative(const std::filesystem::path& shim_path, const std::string& source) {
    if (!std::filesystem::is_regular_file(shim_path)) {
        return;
    }

    auto existing_source = shim_source(shim_path);
    if (existing_source.empty()) {
        existing_source = "External";
    }
    if (existing_source == source) {
        return;
    }

    const auto alternative = shim_alternative_path(shim_path, existing_source);
    if (std::filesystem::exists(alternative)) {
        std::filesystem::remove(alternative);
    }
    std::filesystem::rename(shim_path, alternative);
}

void preserve_existing_native_shim_as_alternative(const std::filesystem::path& shim_path, const std::string& source) {
    if (!std::filesystem::is_regular_file(shim_path)) {
        return;
    }

    auto existing_source = shim_source(shim_path);
    if (existing_source.empty()) {
        existing_source = "External";
    }
    if (existing_source == source) {
        return;
    }

    const auto exe_path = shim_path.parent_path() / (shim_path.stem().string() + ".exe");
    for (const auto& path : {shim_path, exe_path}) {
        if (!std::filesystem::is_regular_file(path)) {
            continue;
        }
        const auto alternative = shim_alternative_path(path, existing_source);
        if (std::filesystem::exists(alternative)) {
            std::filesystem::remove(alternative);
        }
        std::filesystem::rename(path, alternative);
    }
}

void preserve_existing_powershell_shim_as_alternative(const std::filesystem::path& ps1_path, const std::string& source) {
    const auto cmd_path = ps1_path.parent_path() / (ps1_path.stem().string() + ".cmd");
    const auto shell_path = ps1_path.parent_path() / ps1_path.stem();
    if (!std::filesystem::is_regular_file(ps1_path) && !std::filesystem::is_regular_file(cmd_path) && !std::filesystem::is_regular_file(shell_path)) {
        return;
    }

    auto existing_source = std::filesystem::is_regular_file(ps1_path)
        ? shim_source(ps1_path)
        : (std::filesystem::is_regular_file(cmd_path) ? shim_source(cmd_path) : shim_source(shell_path));
    if (existing_source.empty()) {
        existing_source = "External";
    }
    if (existing_source == source) {
        return;
    }

    for (const auto& path : {ps1_path, cmd_path, shell_path}) {
        if (!std::filesystem::is_regular_file(path)) {
            continue;
        }
        const auto alternative = shim_alternative_path(path, existing_source);
        if (std::filesystem::exists(alternative)) {
            std::filesystem::remove(alternative);
        }
        std::filesystem::rename(path, alternative);
    }
}

std::optional<std::string> latest_shim_alternative_source(const std::filesystem::path& shim_path) {
    if (std::filesystem::exists(shim_path)) {
        return std::nullopt;
    }

    const auto prefix = shim_path.filename().string() + ".";
    const auto directory = shim_path.parent_path();
    if (!std::filesystem::is_directory(directory)) {
        return std::nullopt;
    }

    std::vector<std::pair<std::filesystem::file_time_type, std::filesystem::path>> alternatives;
    for (const auto& entry : std::filesystem::directory_iterator(directory)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const auto filename = entry.path().filename().string();
        if (filename.rfind(prefix, 0) == 0) {
            std::error_code error;
            const auto write_time = entry.last_write_time(error);
            alternatives.emplace_back(error ? (std::filesystem::file_time_type::min)() : write_time, entry.path());
        }
    }
    std::sort(alternatives.begin(), alternatives.end());
    if (!alternatives.empty()) {
        return alternatives.back().second.filename().string().substr(prefix.size());
    }
    return std::nullopt;
}

bool promote_shim_alternative_source(const std::filesystem::path& shim_path, const std::string& source) {
    if (std::filesystem::exists(shim_path)) {
        return false;
    }
    const auto alternative = shim_alternative_path(shim_path, source);
    if (!std::filesystem::is_regular_file(alternative)) {
        return false;
    }
    std::filesystem::rename(alternative, shim_path);
    return true;
}

std::optional<std::string> promote_latest_shim_alternative(const std::filesystem::path& shim_path) {
    const auto source = latest_shim_alternative_source(shim_path);
    if (!source) {
        return std::nullopt;
    }
    if (!promote_shim_alternative_source(shim_path, *source)) {
        return std::nullopt;
    }
    return source;
}

void write_shell_shim(
    const std::filesystem::path& shell_path,
    const std::filesystem::path& target,
    const std::string& source,
    const std::string& args) {
    std::ofstream stream(shell_path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write shim " + shell_path.string());
    }

    const auto target_extension = lower_ascii(target.extension().string());
    stream << "#!/bin/sh\n"
           << "# " << target.string() << "\n"
           << "# source " << source << "\n";

    if (target_extension == ".bat" || target_extension == ".cmd") {
        stream << "MSYS2_ARG_CONV_EXCL=/C cmd.exe /C \"" << target.string() << "\"";
    } else if (target_extension == ".ps1") {
        stream << "if command -v pwsh.exe > /dev/null 2>&1; then\n"
               << "    pwsh.exe -noprofile -ex unrestricted -file \"" << target.string() << "\"";
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " \"$@\"\n"
               << "else\n"
               << "    powershell.exe -noprofile -ex unrestricted -file \"" << target.string() << "\"";
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " \"$@\"\n"
               << "fi\n";
        return;
    } else if (target_extension == ".jar") {
        stream << "cd \"" << target.parent_path().string() << "\"\n"
               << "java.exe -jar \"" << target.string() << "\"";
    } else if (target_extension == ".py") {
        stream << "python.exe \"" << target.string() << "\"";
    } else {
        stream << "\"" << target.string() << "\"";
    }

    if (!args.empty()) {
        stream << ' ' << args;
    }
    stream << " \"$@\"\n";
}

void create_cmd_shim(
    const std::filesystem::path& shim_dir,
    const std::filesystem::path& target,
    const ManifestBin& bin,
    const std::string& source,
    const std::string& args) {
    std::filesystem::create_directories(shim_dir);
    const auto name = bin.name.empty() ? std::filesystem::path(bin.target).stem().string() : bin.name;
    const auto shim_path = shim_dir / (name + ".cmd");
    const auto shell_path = shim_dir / name;

    preserve_existing_shim_as_alternative(shim_path, source);
    preserve_existing_shim_as_alternative(shell_path, source);
    for (const auto& path : {shim_path, shell_path}) {
        const auto previous_alternative = shim_alternative_path(path, source);
        if (std::filesystem::exists(previous_alternative)) {
            std::filesystem::remove(previous_alternative);
        }
    }

    std::ofstream stream(shim_path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write shim " + shim_path.string());
    }

    stream << "@echo off\r\n"
           << "rem " << target.string() << "\r\n"
           << "rem source " << source << "\r\n";
    const auto target_extension = lower_ascii(target.extension().string());
    if (target_extension == ".ps1") {
        stream << "where /q pwsh.exe\r\n"
               << "if %errorlevel% equ 0 (\r\n"
               << "    pwsh -noprofile -ex unrestricted -file " << quote_command_arg(target);
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " %*\r\n"
               << ") else (\r\n"
               << "    powershell -noprofile -ex unrestricted -file " << quote_command_arg(target);
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " %*\r\n"
               << ")\r\n";
    } else if (target_extension == ".jar") {
        stream << "pushd " << quote_command_arg(target.parent_path()) << "\r\n"
               << "java -jar " << quote_command_arg(target);
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " %*\r\n"
               << "popd\r\n";
    } else if (target_extension == ".py") {
        stream << "python " << quote_command_arg(target);
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " %*\r\n";
    } else {
        stream << "\"" << target.string() << "\"";
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " %*\r\n";
    }

    write_shell_shim(shell_path, target, source, args);
}

std::filesystem::path shim_runner_path() {
    return current_executable_path_impl();
}

void create_native_shim(
    const std::filesystem::path& shim_dir,
    const std::filesystem::path& target,
    const ManifestBin& bin,
    const std::string& source,
    const std::string& args) {
    std::filesystem::create_directories(shim_dir);
    const auto name = bin.name.empty() ? std::filesystem::path(bin.target).stem().string() : bin.name;
    const auto shim_path = shim_dir / (name + ".shim");
    const auto exe_path = shim_dir / (name + ".exe");

    preserve_existing_native_shim_as_alternative(shim_path, source);
    for (const auto& path : {shim_path, exe_path}) {
        const auto previous_alternative = shim_alternative_path(path, source);
        if (std::filesystem::exists(previous_alternative)) {
            std::filesystem::remove(previous_alternative);
        }
    }

    std::filesystem::copy_file(shim_runner_path(), exe_path, std::filesystem::copy_options::overwrite_existing);

    std::ofstream stream(shim_path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write shim " + shim_path.string());
    }
    stream << "path = \"" << target.string() << "\"\r\n";
    if (!args.empty()) {
        stream << "args = " << args << "\r\n";
    }
}

void create_powershell_shim(
    const std::filesystem::path& shim_dir,
    const std::filesystem::path& target,
    const ManifestBin& bin,
    const std::string& source,
    const std::string& args) {
    std::filesystem::create_directories(shim_dir);
    const auto name = bin.name.empty() ? std::filesystem::path(bin.target).stem().string() : bin.name;
    const auto ps1_path = shim_dir / (name + ".ps1");
    const auto cmd_path = shim_dir / (name + ".cmd");
    const auto shell_path = shim_dir / name;

    preserve_existing_powershell_shim_as_alternative(ps1_path, source);
    for (const auto& path : {ps1_path, cmd_path, shell_path}) {
        const auto previous_alternative = shim_alternative_path(path, source);
        if (std::filesystem::exists(previous_alternative)) {
            std::filesystem::remove(previous_alternative);
        }
    }

    {
        std::ofstream stream(ps1_path, std::ios::binary);
        if (!stream) {
            throw std::runtime_error("cannot write shim " + ps1_path.string());
        }
        stream << "# " << target.string() << "\r\n"
               << "# source " << source << "\r\n"
               << "$path = \"" << target.string() << "\"\r\n"
               << "if ($MyInvocation.ExpectingInput) { $input | & $path";
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " @args } else { & $path";
        if (!args.empty()) {
            stream << ' ' << args;
        }
        stream << " @args }\r\n"
               << "exit $LASTEXITCODE\r\n";
    }

    create_cmd_shim(shim_dir, target, bin, source, args);
}

void create_manifest_shim(
    const std::filesystem::path& shim_dir,
    const std::filesystem::path& target,
    const ManifestBin& bin,
    const std::string& source,
    const std::string& args) {
    const auto target_extension = lower_ascii(target.extension().string());
    if (target_extension == ".exe" || target_extension == ".com") {
        create_native_shim(shim_dir, target, bin, source, args);
        return;
    }
    if (target_extension == ".ps1") {
        create_powershell_shim(shim_dir, target, bin, source, args);
        return;
    }
    create_cmd_shim(shim_dir, target, bin, source, args);
}

std::string env_string(const char* name) {
    if (const char* value = std::getenv(name); value != nullptr && value[0] != '\0') {
        return value;
    }
    return {};
}

std::filesystem::path shortcut_root(bool global) {
    if (auto override_path = env_string("SCOOP_SHORTCUT_DIR"); !override_path.empty()) {
        return std::filesystem::path(override_path);
    }
#ifdef _WIN32
    char buffer[MAX_PATH]{};
    const auto variable = global ? "ProgramData" : "APPDATA";
    if (const auto base = env_string(variable); !base.empty()) {
        return std::filesystem::path(base) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Scoop Apps";
    }
    if (GetEnvironmentVariableA(variable, buffer, static_cast<DWORD>(std::size(buffer))) > 0) {
        return std::filesystem::path(buffer) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Scoop Apps";
    }
#endif
    return std::filesystem::current_path() / "Scoop Apps";
}

std::string replace_all(std::string value, const std::string& from, const std::string& to) {
    if (from.empty()) {
        return value;
    }
    std::size_t pos = 0;
    while ((pos = value.find(from, pos)) != std::string::npos) {
        value.replace(pos, from.size(), to);
        pos += to.size();
    }
    return value;
}

std::string expand_shortcut_value(std::string value, const std::filesystem::path& install_dir, const Environment& environment, const Manifest& manifest, bool global) {
    value = replace_all(std::move(value), "$dir", install_dir.string());
    value = replace_all(std::move(value), "$original_dir", install_dir.string());
    value = replace_all(std::move(value), "$persist_dir", (environment.persist_dir(global) / manifest.name).string());
    return value;
}

std::filesystem::path safe_shortcut_name(const std::string& name) {
    auto path = std::filesystem::path(name);
    if (path.empty() || path.is_absolute()) {
        throw std::runtime_error("shortcut name must be relative: " + name);
    }
    for (const auto& part : path) {
        if (part == "..") {
            throw std::runtime_error("shortcut name must not contain '..': " + name);
        }
    }
    path += ".lnk";
    return path;
}

void create_shortcut_file(
    const std::filesystem::path& shortcut_path,
    const std::filesystem::path& target,
    const std::string& arguments,
    const std::filesystem::path& icon) {
    std::filesystem::create_directories(shortcut_path.parent_path());
    const auto script = shortcut_path.parent_path() / (shortcut_path.stem().string() + ".create-shortcut.ps1");
    std::ofstream stream(script, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write shortcut helper " + script.string());
    }
    stream << "$ErrorActionPreference = 'Stop'\r\n"
           << "$shell = New-Object -ComObject WScript.Shell\r\n"
           << "$shortcut = $shell.CreateShortcut('" << escape_ps_single_quoted(shortcut_path.string()) << "')\r\n"
           << "$shortcut.TargetPath = '" << escape_ps_single_quoted(target.string()) << "'\r\n"
           << "$shortcut.WorkingDirectory = '" << escape_ps_single_quoted(target.parent_path().string()) << "'\r\n";
    if (!arguments.empty()) {
        stream << "$shortcut.Arguments = '" << escape_ps_single_quoted(arguments) << "'\r\n";
    }
    if (!icon.empty()) {
        stream << "$shortcut.IconLocation = '" << escape_ps_single_quoted(icon.string()) << "'\r\n";
    }
    stream << "$shortcut.Save()\r\n";
    stream.close();
    const auto command = "powershell -NoProfile -ExecutionPolicy Bypass -File " + quote_command_arg(script);
    const int exit_code = std::system(command.c_str());
    std::filesystem::remove(script);
    if (exit_code != 0) {
        throw std::runtime_error("shortcut creation failed: " + shortcut_path.string());
    }
}

void create_shortcuts(
    const Environment& environment,
    const std::filesystem::path& install_dir,
    const Manifest& manifest,
    bool global,
    std::vector<std::string>* messages = nullptr) {
    for (const auto& shortcut : manifest.shortcuts) {
        const auto target = install_dir / shortcut.target;
        if (!std::filesystem::is_regular_file(target)) {
            if (messages != nullptr) {
                messages->push_back(
                    "Creating shortcut for " + shortcut.name + " (" + target.filename().string() + ") failed: Couldn't find " + target.string());
            }
            continue;
        }
        const auto icon = shortcut.has_icon ? install_dir / shortcut.icon : std::filesystem::path{};
        if (shortcut.has_icon && !std::filesystem::is_regular_file(icon)) {
            if (messages != nullptr) {
                messages->push_back(
                    "Creating shortcut for " + shortcut.name + " (" + target.filename().string() + ") failed: Couldn't find icon " + icon.string());
            }
            continue;
        }
        const auto shortcut_path = shortcut_root(global) / safe_shortcut_name(shortcut.name);
        const auto args = expand_shortcut_value(shortcut.args, install_dir, environment, manifest, global);
        create_shortcut_file(shortcut_path, target, args, icon);
        if (messages != nullptr) {
            messages->push_back("Creating shortcut for " + shortcut.name + " (" + target.filename().string() + ")");
        }
    }
}

void remove_shortcuts(const Manifest& manifest, bool global, std::vector<std::string>* messages = nullptr) {
    for (const auto& shortcut : manifest.shortcuts) {
        try {
            const auto shortcut_path = shortcut_root(global) / safe_shortcut_name(shortcut.name);
            if (messages != nullptr) {
                messages->push_back("Removing shortcut " + shortcut_path.string());
            }
            if (std::filesystem::exists(shortcut_path)) {
                std::filesystem::remove(shortcut_path);
            }
        } catch (const std::exception&) {
        }
    }
}

void create_shims(
    const Environment& environment,
    const std::filesystem::path& install_dir,
    const Manifest& manifest,
    bool global,
    std::vector<std::string>* messages = nullptr) {
    for (const auto& bin : manifest.bins) {
        const auto args = expand_shortcut_value(bin.args, install_dir, environment, manifest, global);
        if (messages != nullptr) {
            messages->push_back("Creating shim for '" + bin.name + "'.");
        }
        create_manifest_shim(environment.shims_dir(global), resolve_bin_target(install_dir, bin), bin, manifest.name, args);
    }
}

void install_psmodule(
    const Environment& environment,
    const std::filesystem::path& install_dir,
    const Manifest& manifest,
    bool global,
    std::vector<std::string>* messages = nullptr,
    std::vector<std::string>* warnings = nullptr) {
    if (manifest.psmodule_name.empty()) {
        return;
    }

    const auto modules_dir = environment.modules_dir(global);
    std::filesystem::create_directories(modules_dir);
    const auto added_module_path = global
        ? add_environment_path(environment, "PSModulePath", modules_dir, global)
        : add_environment_path_with_default(environment, "PSModulePath", modules_dir, global, default_user_psmodule_path());

    const auto link = modules_dir / manifest.psmodule_name;
    if (messages != nullptr) {
        if (added_module_path) {
            messages->push_back("Adding " + modules_dir.string() + " to " + (global ? "global" : "your") + " PowerShell module path.");
        }
        messages->push_back("Installing PowerShell module '" + manifest.psmodule_name + "'");
        messages->push_back("Linking " + link.string() + " => " + install_dir.string());
    }
    if (std::filesystem::exists(link)) {
        if (warnings != nullptr) {
            warnings->push_back(link.string() + " already exists. It will be replaced.");
        }
        std::filesystem::remove_all(link);
    }

    const auto junction = "cmd /c mklink /J " + quote_command_arg(link) + " " + quote_command_arg(install_dir);
    if (std::system(junction.c_str()) == 0) {
        return;
    }

    try {
        std::filesystem::create_directory_symlink(install_dir, link);
        return;
    } catch (const std::filesystem::filesystem_error&) {
    }

    std::filesystem::copy(install_dir, link, std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing);
}

void uninstall_psmodule(
    const Environment& environment,
    const Manifest& manifest,
    bool global,
    std::vector<std::string>* messages = nullptr) {
    if (manifest.psmodule_name.empty()) {
        return;
    }

    const auto link = environment.modules_dir(global) / manifest.psmodule_name;
    if (messages != nullptr) {
        messages->push_back("Uninstalling PowerShell module '" + manifest.psmodule_name + "'.");
    }
    if (std::filesystem::exists(link) || is_directory_link(link)) {
        if (messages != nullptr) {
            messages->push_back("Removing " + link.string());
        }
        try {
            std::filesystem::remove(link);
        } catch (const std::filesystem::filesystem_error&) {
            std::filesystem::remove_all(link);
        }
    }
}

void remove_shims(const Environment& environment, const Manifest& manifest, bool global) {
    const auto shim_dir = environment.shims_dir(global);
    for (const auto& bin : manifest.bins) {
        const auto name = bin.name.empty() ? std::filesystem::path(bin.target).stem().string() : bin.name;
        for (const auto extension : {std::string_view{".shim"}, std::string_view{".exe"}, std::string_view{".cmd"}, std::string_view{".ps1"}, std::string_view{""}}) {
            const auto shim = shim_dir / (name + std::string(extension));
            const auto alternative = shim_alternative_path(shim, manifest.name);
            if (std::filesystem::exists(alternative)) {
                std::filesystem::remove(alternative);
            }
        }

        const auto primary_candidates = {
            shim_dir / (name + ".shim"),
            shim_dir / (name + ".ps1"),
            shim_dir / (name + ".cmd"),
        };
        for (const auto& shim : primary_candidates) {
            if (!std::filesystem::exists(shim) || shim_source(shim) != manifest.name) {
                continue;
            }

            std::filesystem::remove(shim);
            const auto extension = lower_ascii(shim.extension().string());
            if (extension == ".shim") {
                const auto executable = shim_dir / (name + ".exe");
                if (std::filesystem::exists(executable)) {
                    std::filesystem::remove(executable);
                }
            } else if (extension == ".ps1") {
                const auto cmd = shim_dir / (name + ".cmd");
                if (std::filesystem::exists(cmd) && shim_source(cmd) == manifest.name) {
                    std::filesystem::remove(cmd);
                }
                const auto shell = shim_dir / name;
                if (std::filesystem::exists(shell) && shim_source(shell) == manifest.name) {
                    std::filesystem::remove(shell);
                }
            } else if (extension == ".cmd") {
                const auto shell = shim_dir / name;
                if (std::filesystem::exists(shell) && shim_source(shell) == manifest.name) {
                    std::filesystem::remove(shell);
                }
            }
            if (extension == ".shim") {
                if (const auto promoted_source = promote_latest_shim_alternative(shim)) {
                    promote_shim_alternative_source(shim_dir / (name + ".exe"), *promoted_source);
                }
            } else if (extension == ".ps1") {
                if (const auto promoted_source = promote_latest_shim_alternative(shim)) {
                    promote_shim_alternative_source(shim_dir / (name + ".cmd"), *promoted_source);
                    promote_shim_alternative_source(shim_dir / name, *promoted_source);
                }
            } else if (extension == ".cmd") {
                if (const auto promoted_source = promote_latest_shim_alternative(shim)) {
                    promote_shim_alternative_source(shim_dir / name, *promoted_source);
                }
            } else {
                promote_latest_shim_alternative(shim);
            }
            break;
        }
    }
}

std::string lower_extension_chain(std::filesystem::path path) {
    std::string name = path.filename().string();
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return name;
}

bool is_archive(const std::filesystem::path& path) {
    const auto name = lower_extension_chain(path);
    return name.ends_with(".zip") ||
        name.ends_with(".tar") ||
        name.ends_with(".tar.gz") ||
        name.ends_with(".tgz") ||
        name.ends_with(".tar.bz2") ||
        name.ends_with(".tbz2") ||
        name.ends_with(".tar.xz") ||
        name.ends_with(".txz") ||
        name.ends_with(".nupkg") ||
        name.ends_with(".msi") ||
        name.ends_with(".7z") ||
        name.ends_with(".001") ||
        name.ends_with(".rar") ||
        name.ends_with(".part01.rar") ||
        name.ends_with(".gz") ||
        name.ends_with(".bz2") ||
        name.ends_with(".xz") ||
        name.ends_with(".lzma") ||
        name.ends_with(".zst") ||
        name.ends_with(".tzst") ||
        name.ends_with(".iso") ||
        name.ends_with(".img");
}

bool archive_requires_7zip(const std::filesystem::path& path) {
    const auto name = lower_extension_chain(path);
    if (name.ends_with(".zip") ||
        name.ends_with(".tar") ||
        name.ends_with(".tar.gz") ||
        name.ends_with(".tgz") ||
        name.ends_with(".tar.bz2") ||
        name.ends_with(".tbz2") ||
        name.ends_with(".tar.xz") ||
        name.ends_with(".txz") ||
        name.ends_with(".nupkg")) {
        return false;
    }
    return name.ends_with(".7z") ||
        name.ends_with(".001") ||
        name.ends_with(".rar") ||
        name.ends_with(".part01.rar") ||
        name.ends_with(".gz") ||
        name.ends_with(".bz2") ||
        name.ends_with(".xz") ||
        name.ends_with(".lzma") ||
        name.ends_with(".zst") ||
        name.ends_with(".tzst") ||
        name.ends_with(".iso") ||
        name.ends_with(".img");
}

bool archive_is_msi(const std::filesystem::path& path) {
    return lower_extension_chain(path).ends_with(".msi");
}

std::vector<std::string> split_env_paths(const char* value) {
    std::vector<std::string> paths;
    if (value == nullptr) {
        return paths;
    }

    const std::string input(value);
    std::size_t start = 0;
    while (start <= input.size()) {
        const auto separator = input.find(';', start);
        auto part = input.substr(start, separator == std::string::npos ? std::string::npos : separator - start);
        if (!part.empty()) {
            paths.push_back(std::move(part));
        }
        if (separator == std::string::npos) {
            break;
        }
        start = separator + 1;
    }
    return paths;
}

std::optional<std::filesystem::path> find_executable_on_path(const std::string& name) {
    std::vector<std::string> extensions;
    if (std::filesystem::path(name).has_extension()) {
        extensions.push_back({});
    } else {
        extensions = {".exe", ".cmd", ".bat", ".com"};
    }

    for (const auto& directory : split_env_paths(std::getenv("PATH"))) {
        for (const auto& extension : extensions) {
            const auto candidate = std::filesystem::path(directory) / (name + extension);
            std::error_code error;
            if (std::filesystem::is_regular_file(candidate, error)) {
                return candidate;
            }
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> find_file_under(const std::filesystem::path& root, std::string_view filename) {
    std::error_code error;
    if (!std::filesystem::is_directory(root, error)) {
        return std::nullopt;
    }

    const auto direct = root / std::string(filename);
    if (std::filesystem::is_regular_file(direct, error)) {
        return direct;
    }

    for (const auto& entry : std::filesystem::recursive_directory_iterator(root, error)) {
        if (error) {
            break;
        }
        if (entry.is_regular_file(error) && entry.path().filename().string() == filename) {
            return entry.path();
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> find_7zip_public(const Environment& environment) {
    const auto use_external_7zip = ConfigStore(environment.config_file).get("use_external_7zip");
    if (use_external_7zip && use_external_7zip->is_boolean() && use_external_7zip->get<bool>()) {
        return find_executable_on_path("7z");
    }

    if (const auto installed = find_file_under(app_dir(environment, "7zip", false) / "current", "7z.exe")) {
        return installed;
    }
    return find_executable_on_path("7z");
}

std::optional<std::filesystem::path> find_lessmsi(const Environment& environment) {
    if (const auto installed = find_file_under(app_dir(environment, "lessmsi", false) / "current", "lessmsi.exe")) {
        return installed;
    }
    return find_executable_on_path("lessmsi");
}

std::optional<std::filesystem::path> find_innounp(const Environment& environment) {
    if (const auto installed = find_file_under(app_dir(environment, "innounp-unicode", false) / "current", "innounp.exe")) {
        return installed;
    }
    if (const auto installed = find_file_under(app_dir(environment, "innounp", false) / "current", "innounp.exe")) {
        return installed;
    }
    return find_executable_on_path("innounp");
}

std::string quote_command_arg(const std::filesystem::path& path) {
    return quote_command_string_arg(path.string());
}

std::string command_invocation(const std::filesystem::path& executable) {
    auto extension = executable.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    if (extension == ".cmd" || extension == ".bat") {
        return "call " + quote_command_arg(executable);
    }
    return quote_command_arg(executable);
}

void debug_external_command(const std::string& command) {
    if (std::getenv("SCO_DEBUG_COMMANDS") != nullptr) {
        std::cerr << "DEBUG command: " << command << '\n';
    }
}

int run_external_command(const std::filesystem::path& executable, const std::vector<std::string>& args, const std::string& debug_command) {
    debug_external_command(debug_command);
    std::cout.flush();
    std::cerr.flush();

    auto extension = executable.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    if (extension == ".cmd" || extension == ".bat") {
        return std::system(debug_command.c_str());
    }

#ifdef _WIN32
    auto command_line = quote_windows_process_arg(executable.wstring());
    for (const auto& arg : args) {
        command_line += L" ";
        command_line += quote_windows_process_arg(std::filesystem::path(arg).wstring());
    }

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    auto mutable_command_line = std::vector<wchar_t>(command_line.begin(), command_line.end());
    mutable_command_line.push_back(L'\0');
    if (CreateProcessW(executable.wstring().c_str(), mutable_command_line.data(), nullptr, nullptr, TRUE, 0, nullptr, nullptr, &startup, &process) == 0) {
        return 1;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return static_cast<int>(exit_code);
#else
    return std::system(debug_command.c_str());
#endif
}

bool config_enabled(const Environment& environment, const std::string& name) {
    const auto value = ConfigStore(environment.config_file).get(name);
    return value && value->is_boolean() && value->get<bool>();
}

std::string quote_command_string_arg(const std::string& value) {
    std::string quoted = "\"";
    for (const char ch : value) {
        if (ch == '"') {
            quoted += "\\\"";
        } else {
            quoted.push_back(ch);
        }
    }
    quoted += '"';
    return quoted;
}

std::wstring quote_windows_process_arg(const std::wstring& value) {
    std::wstring quoted = L"\"";
    std::size_t backslashes = 0;
    for (const auto ch : value) {
        if (ch == L'\\') {
            ++backslashes;
            continue;
        }
        if (ch == L'\"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(ch);
        } else {
            quoted.append(backslashes, L'\\');
            quoted.push_back(ch);
        }
        backslashes = 0;
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'\"');
    return quoted;
}

std::wstring widen_utf8(const std::string& value) {
    if (value.empty()) {
        return {};
    }
    auto size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (size == 0) {
        size = MultiByteToWideChar(CP_ACP, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
        if (size == 0) {
            return {};
        }
        std::wstring wide(size, L'\0');
        MultiByteToWideChar(CP_ACP, 0, value.data(), static_cast<int>(value.size()), wide.data(), size);
        return wide;
    }
    std::wstring wide(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), wide.data(), size);
    return wide;
}

std::wstring join_forwarded_args(int argc, wchar_t** argv) {
    std::wstring result;
    for (int i = 1; i < argc; ++i) {
        if (!result.empty()) {
            result.push_back(L' ');
        }
        result += quote_windows_process_arg(argv[i]);
    }
    return result;
}

int run_shim_child(const std::filesystem::path& target, const std::string& configured_args, int argc, wchar_t** argv) {
    auto command_line = quote_windows_process_arg(target.wstring());
    if (!configured_args.empty()) {
        command_line.push_back(L' ');
        command_line += widen_utf8(configured_args);
    }
    const auto forwarded = join_forwarded_args(argc, argv);
    if (!forwarded.empty()) {
        command_line.push_back(L' ');
        command_line += forwarded;
    }

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, command_line.data(), nullptr, nullptr, TRUE, 0, nullptr, nullptr, &startup, &process)) {
        std::wcerr << L"sco-shim: failed to launch " << target.wstring() << L"\n";
        return 1;
    }

    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return static_cast<int>(exit_code);
}

std::filesystem::path current_executable_path_impl() {
#ifdef _WIN32
    std::vector<wchar_t> buffer(MAX_PATH);
    while (true) {
        const auto length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (length == 0) {
            break;
        }
        if (length < buffer.size() - 1) {
            return std::filesystem::path(std::wstring(buffer.data(), length));
        }
        buffer.resize(buffer.size() * 2);
    }
#endif
    return std::filesystem::current_path() / "sco.exe";
}

bool is_powershell_script(const std::filesystem::path& file) {
    auto extension = file.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return extension == ".ps1";
}

void normalize_msi_source_dir(const std::filesystem::path& destination) {
    const auto source_dir = destination / "SourceDir";
    if (std::filesystem::is_directory(source_dir)) {
        move_directory_contents(source_dir, destination);
        std::error_code error;
        std::filesystem::remove(source_dir, error);
    }
}

void extract_msi_archive(const Environment& environment, const std::filesystem::path& archive, const std::filesystem::path& destination) {
    std::filesystem::create_directories(destination);

    auto command = std::string{};
    if (config_enabled(environment, "use_lessmsi")) {
        const auto lessmsi = find_lessmsi(environment);
        if (!lessmsi) {
            throw std::runtime_error("cannot find lessmsi to extract " + archive.string());
        }
        command = command_invocation(*lessmsi) + " x " + quote_command_arg(archive) + " " + quote_command_arg(destination);
    } else {
        const auto msiexec = find_executable_on_path("msiexec");
        if (!msiexec) {
            throw std::runtime_error("cannot find msiexec to extract " + archive.string());
        }
        const auto target_dir = destination / "SourceDir";
        command = command_invocation(*msiexec) + " /a " + quote_command_arg(archive) + " /qn " +
            quote_command_string_arg("TARGETDIR=" + target_dir.string());
    }

    const int exit_code = std::system(command.c_str());
    if (exit_code != 0) {
        throw std::runtime_error("archive extraction failed for " + archive.string());
    }
    normalize_msi_source_dir(destination);
}

void extract_inno_archive(const Environment& environment, const std::filesystem::path& archive, const std::filesystem::path& destination, const std::string& extract_dir) {
    std::filesystem::create_directories(destination);
    const auto innounp = find_innounp(environment);
    if (!innounp) {
        throw std::runtime_error("cannot find innounp to extract " + archive.string());
    }

    auto component = std::string{"{app}"};
    if (!extract_dir.empty()) {
        if (extract_dir.front() == '{') {
            component = extract_dir;
        } else {
            component += "\\" + extract_dir;
        }
    }

    const auto command = command_invocation(*innounp) + " -x -d" + quote_command_arg(destination) + " " +
        quote_command_arg(archive) + " -y " + quote_command_string_arg("-c" + component);
    const int exit_code = std::system(command.c_str());
    if (exit_code != 0) {
        throw std::runtime_error("archive extraction failed for " + archive.string());
    }
}

void extract_archive(const Environment& environment, const std::filesystem::path& archive, const std::filesystem::path& destination) {
    std::filesystem::create_directories(destination);
    auto command = std::string{};
    if (archive_is_msi(archive)) {
        extract_msi_archive(environment, archive, destination);
        return;
    } else if (archive_requires_7zip(archive)) {
        const auto seven_zip = find_7zip_public(environment);
        if (!seven_zip) {
            throw std::runtime_error("cannot find 7-Zip to extract " + archive.string());
        }
        std::vector<std::string> args{"x", archive.string(), "-o" + destination.string(), "-xr!*.nsis", "-y"};
        command = command_invocation(*seven_zip) + " x " + quote_command_arg(archive) + " -o" + quote_command_arg(destination) + " -xr!*.nsis -y";
        const int exit_code = run_external_command(*seven_zip, args, command);
        if (exit_code != 0) {
            throw std::runtime_error("archive extraction failed for " + archive.string());
        }
        return;
    } else {
        command = "tar -xf " + quote_command_arg(archive) + " -C " + quote_command_arg(destination);
    }
    debug_external_command(command);
    const int exit_code = std::system(command.c_str());
    if (exit_code != 0) {
        throw std::runtime_error("archive extraction failed for " + archive.string());
    }
}

bool should_extract_artifact(const Manifest& manifest, const std::filesystem::path& path) {
    return is_archive(path) || (manifest.innosetup && lower_extension_chain(path).ends_with(".exe"));
}

std::string escape_ps_single_quoted(std::string value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (const auto ch : value) {
        if (ch == '\'') {
            escaped += "''";
        } else {
            escaped.push_back(ch);
        }
    }
    return escaped;
}

void run_hook_script(
    const Manifest& manifest,
    const std::filesystem::path& dir,
    const Environment& environment,
    bool global,
    const std::vector<std::string>& lines,
    const std::string& hook_name,
    const std::filesystem::path& original_dir = {},
    const std::string& hook_version = {},
    const std::string& source_bucket = {}) {
    if (lines.empty()) {
        return;
    }

    const auto hook_dir = std::filesystem::exists(dir)
        ? dir / "_hooks"
        : std::filesystem::temp_directory_path() /
            ("sco-" + manifest.name + "-" + hook_name + "-" +
#ifdef _WIN32
             std::to_string(GetCurrentProcessId()) +
#else
             std::to_string(std::rand()) +
#endif
             "-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(hook_dir);
    const auto script_path = hook_dir / (hook_name + ".ps1");
    std::ofstream stream(script_path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write hook script " + script_path.string());
    }

    stream << R"ps1(function warn($msg) { Write-Host "WARN  $msg" -ForegroundColor DarkYellow }
function info($msg) { Write-Host "INFO  $msg" -ForegroundColor DarkGray }
function success($msg) { Write-Host $msg -ForegroundColor DarkGreen }

function Move-ScoExtractedDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [String]$Source,
        [Parameter(Mandatory = $true)]
        [String]$Destination
    )

    if (!(Test-Path -LiteralPath $Source -PathType Container)) {
        throw "extract_dir does not exist after extraction: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        $target = Join-Path $Destination $_.Name
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Move-Item -LiteralPath $_.FullName -Destination $target
    }
}

function Expand-7zipArchive {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Path,
        [Parameter(Position = 1)]
        [String]$DestinationPath = (Split-Path -Parent $Path),
        [String]$ExtractDir,
        [Parameter(ValueFromRemainingArguments = $true)]
        [String[]]$Switches,
        [ValidateSet('All', 'Skip', 'Rename')]
        [String]$Overwrite,
        [Switch]$Removal
    )

    $tool = Get-Command 7z -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $toolPath = if ($tool) { $tool.Source } else { $null }
    if (!$toolPath -and $env:SCOOP) {
        $candidate = Join-Path $env:SCOOP 'apps\7zip\current\7z.exe'
        if (Test-Path -LiteralPath $candidate) {
            $toolPath = $candidate
        }
    }
    if (!$toolPath) {
        throw "Cannot find 7-Zip to extract $Path"
    }

    $DestinationPath = $DestinationPath.TrimEnd('\')
    $arguments = @('x', $Path, "-o$DestinationPath", '-xr!*.nsis', '-y')
    if ($ExtractDir) {
        $arguments += "-ir!$ExtractDir\*"
    }
    if ($Switches) {
        $arguments += $Switches
    }
    switch ($Overwrite) {
        'All' { $arguments += '-aoa' }
        'Skip' { $arguments += '-aos' }
        'Rename' { $arguments += '-aou' }
    }

    & $toolPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract files from $Path."
    }

    if ($ExtractDir) {
        Move-ScoExtractedDirectory -Source (Join-Path $DestinationPath $ExtractDir) -Destination $DestinationPath
    }
    if ($Removal) {
        Remove-Item $Path -Force
    }
}

function Expand-MsiArchive {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Path,
        [Parameter(Position = 1)]
        [String]$DestinationPath = (Split-Path -Parent $Path),
        [String]$ExtractDir,
        [Parameter(ValueFromRemainingArguments = $true)]
        [String[]]$Switches,
        [Switch]$Removal
    )

    $DestinationPath = $DestinationPath.TrimEnd('\')
    $originalDestination = $DestinationPath
    if ($ExtractDir) {
        $DestinationPath = Join-Path $DestinationPath '_tmp'
    }

    if ($script:sco_use_lessmsi) {
        $tool = Get-Command lessmsi -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $toolPath = if ($tool) { $tool.Source } else { $null }
        if (!$toolPath -and $env:SCOOP) {
            $candidate = Join-Path $env:SCOOP 'apps\lessmsi\current\lessmsi.exe'
            if (Test-Path -LiteralPath $candidate) {
                $toolPath = $candidate
            }
        }
        if (!$toolPath) {
            throw "Cannot find lessmsi to extract $Path"
        }
        $arguments = @('x', $Path, "$DestinationPath\")
    } else {
        $tool = Get-Command msiexec -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (!$tool) {
            throw "Cannot find msiexec to extract $Path"
        }
        $toolPath = $tool.Source
        $arguments = @('/a', $Path, '/qn', "TARGETDIR=$(Join-Path $DestinationPath 'SourceDir')")
    }
    if ($Switches) {
        $arguments += $Switches
    }

    & $toolPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract files from $Path."
    }

    $sourceDir = Join-Path $DestinationPath 'SourceDir'
    if (Test-Path -LiteralPath $sourceDir -PathType Container) {
        Move-ScoExtractedDirectory -Source $sourceDir -Destination $DestinationPath
        Remove-Item -LiteralPath $sourceDir -Force -ErrorAction SilentlyContinue
    }
    if ($ExtractDir) {
        Move-ScoExtractedDirectory -Source (Join-Path $DestinationPath $ExtractDir) -Destination $originalDestination
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    if ($Removal) {
        Remove-Item $Path -Force
    }
}

function Expand-InnoArchive {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Path,
        [Parameter(Position = 1)]
        [String]$DestinationPath = (Split-Path -Parent $Path),
        [String]$ExtractDir,
        [Parameter(ValueFromRemainingArguments = $true)]
        [String[]]$Switches,
        [Switch]$Removal
    )

    $tool = Get-Command innounp -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $toolPath = if ($tool) { $tool.Source } else { $null }
    if (!$toolPath -and $env:SCOOP) {
        foreach ($candidateApp in @('innounp-unicode', 'innounp')) {
            $candidate = Join-Path $env:SCOOP "apps\$candidateApp\current\innounp.exe"
            if (Test-Path -LiteralPath $candidate) {
                $toolPath = $candidate
                break
            }
        }
    }
    if (!$toolPath) {
        throw "Cannot find innounp to extract $Path"
    }

    $component = '{app}'
    if ($ExtractDir) {
        if ($ExtractDir.StartsWith('{')) {
            $component = $ExtractDir
        } else {
            $component = "{app}\$ExtractDir"
        }
    }

    $arguments = @('-x', "-d$DestinationPath", $Path, '-y', "-c$component")
    if ($Switches) {
        $arguments += $Switches
    }

    & $toolPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract files from $Path."
    }
    if ($Removal) {
        Remove-Item $Path -Force
    }
}

function Expand-DarkArchive {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [String]$Path,
        [Parameter(Position = 1)]
        [String]$DestinationPath = (Split-Path -Parent $Path),
        [Parameter(ValueFromRemainingArguments = $true)]
        [String[]]$Switches,
        [Switch]$Removal
    )

    $tool = Get-Command wix -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $useWix = $null -ne $tool
    if (!$tool) {
        $tool = Get-Command dark -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (!$tool) {
        throw "Cannot find dark or wix to extract $Path"
    }

    if ($useWix) {
        $arguments = @('burn', 'extract', $Path, '-out', $DestinationPath, '-outba', (Join-Path $DestinationPath 'UX'))
    } else {
        $arguments = @('-nologo', '-x', $DestinationPath, $Path)
    }
    if ($Switches) {
        $arguments += $Switches
    }

    & $tool.Source @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract files from $Path."
    }

    $wixAttached = Join-Path $DestinationPath 'WixAttachedContainer'
    if (Test-Path $wixAttached) {
        Rename-Item $wixAttached 'AttachedContainer' -ErrorAction Ignore
    }
    if ($Removal) {
        Remove-Item $Path -Force
    }
}

)ps1";

    const auto dir_string = dir.string();
    const auto original = original_dir.empty() ? dir : original_dir;
    const auto persist = (environment.persist_dir(global) / manifest.name).string();
    const auto version = hook_version.empty() ? manifest.version : hook_version;
    stream << "$dir = '" << escape_ps_single_quoted(dir_string) << "'\r\n"
           << "$original_dir = '" << escape_ps_single_quoted(original.string()) << "'\r\n"
           << "$persist_dir = '" << escape_ps_single_quoted(persist) << "'\r\n"
           << "$architecture = '" << escape_ps_single_quoted(manifest.architecture) << "'\r\n"
           << "$app = '" << escape_ps_single_quoted(manifest.name) << "'\r\n"
           << "$bucket = '" << escape_ps_single_quoted(source_bucket) << "'\r\n"
           << "$bucketsdir = '" << escape_ps_single_quoted(environment.buckets_dir().string()) << "'\r\n"
           << "$scoopdir = '" << escape_ps_single_quoted(environment.root_dir.string()) << "'\r\n"
           << "$cachedir = '" << escape_ps_single_quoted(environment.cache_dir.string()) << "'\r\n"
           << "$version = '" << escape_ps_single_quoted(version) << "'\r\n"
           << "$global = $" << (global ? "true" : "false") << "\r\n"
           << "$script:sco_use_lessmsi = $" << (config_enabled(environment, "use_lessmsi") ? "true" : "false") << "\r\n";
    for (const auto& line : lines) {
        stream << line << "\r\n";
    }
    stream.close();

    const auto command = "powershell -NoProfile -ExecutionPolicy Bypass -File " + quote_command_arg(script_path);
    const int exit_code = std::system(command.c_str());
    std::error_code cleanup_error;
    std::filesystem::remove(script_path, cleanup_error);
    if (std::filesystem::is_directory(hook_dir, cleanup_error) && std::filesystem::is_empty(hook_dir, cleanup_error)) {
        std::filesystem::remove(hook_dir, cleanup_error);
    }
    if (exit_code != 0) {
        throw std::runtime_error(hook_name + " script failed for " + manifest.name);
    }
}

std::string title_case_hook_name(const std::string& value) {
    if (value.empty()) {
        return value;
    }
    auto result = value;
    result[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(result[0])));
    return result;
}

std::filesystem::path resolve_command_file(const std::filesystem::path& version_dir, const std::string& file, const std::string& hook_name) {
    auto path = std::filesystem::path(file);
    if (!is_safe_relative_path(path)) {
        throw std::runtime_error("Error in manifest: " + title_case_hook_name(hook_name) + " " + file + " is outside the app directory.");
    }
    return version_dir / path;
}

void run_manifest_command(
    const Manifest& manifest,
    const std::filesystem::path& version_dir,
    const Environment& environment,
    bool global,
    const ManifestCommand& command,
    const std::string& hook_name,
    const std::string& default_file = {},
    const std::string& hook_version = {},
    const std::string& source_bucket = {}) {
    const auto command_file = command.file.empty() && !command.args.empty() ? default_file : command.file;
    if (command_file.empty()) {
        run_hook_script(manifest, version_dir, environment, global, command.script, hook_name, version_dir, hook_version, source_bucket);
        return;
    }

    const auto file = resolve_command_file(version_dir, command_file, hook_name);
    if (!std::filesystem::is_regular_file(file)) {
        throw std::runtime_error(hook_name + " file does not exist: " + file.string());
    }

    const auto powershell_script = is_powershell_script(file);
    const auto helper_dir = version_dir / "_hooks";
    std::filesystem::create_directories(helper_dir);
    const auto helper_path = helper_dir / (hook_name + "_file.ps1");
    std::ofstream stream(helper_path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write command helper " + helper_path.string());
    }

    const auto persist = (environment.persist_dir(global) / manifest.name).string();
    const auto version = hook_version.empty() ? manifest.version : hook_version;
    stream << "$ErrorActionPreference = 'Stop'\r\n"
           << "Set-Location -LiteralPath '" << escape_ps_single_quoted(version_dir.string()) << "'\r\n"
           << "$dir = '" << escape_ps_single_quoted(version_dir.string()) << "'\r\n"
           << "$original_dir = $dir\r\n"
           << "$persist_dir = '" << escape_ps_single_quoted(persist) << "'\r\n"
           << "$architecture = '" << escape_ps_single_quoted(manifest.architecture) << "'\r\n"
           << "$app = '" << escape_ps_single_quoted(manifest.name) << "'\r\n"
           << "$bucket = '" << escape_ps_single_quoted(source_bucket) << "'\r\n"
           << "$bucketsdir = '" << escape_ps_single_quoted(environment.buckets_dir().string()) << "'\r\n"
           << "$scoopdir = '" << escape_ps_single_quoted(environment.root_dir.string()) << "'\r\n"
           << "$cachedir = '" << escape_ps_single_quoted(environment.cache_dir.string()) << "'\r\n"
           << "$version = '" << escape_ps_single_quoted(version) << "'\r\n"
           << "$global = $" << (global ? "true" : "false") << "\r\n"
           << "$arguments = @(\r\n";
    for (const auto& arg : command.args) {
        auto substituted = replace_all(arg, "$dir", version_dir.string());
        substituted = replace_all(std::move(substituted), "$global", global ? "True" : "False");
        substituted = replace_all(std::move(substituted), "$version", manifest.version);
        stream << "    '" << escape_ps_single_quoted(substituted) << "'\r\n";
    }
    stream << ")\r\n"
           << "& '" << escape_ps_single_quoted(file.string()) << "' @arguments\r\n"
           << "if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\r\n";
    stream.close();

    const auto command_line = "powershell -NoProfile -ExecutionPolicy Bypass -File " + quote_command_arg(helper_path);

    const auto previous = std::filesystem::current_path();
    std::filesystem::current_path(version_dir);
    const int exit_code = std::system(command_line.c_str());
    std::filesystem::current_path(previous);
    std::error_code cleanup_error;
    std::filesystem::remove(helper_path, cleanup_error);
    if (std::filesystem::is_directory(helper_dir, cleanup_error) && std::filesystem::is_empty(helper_dir, cleanup_error)) {
        std::filesystem::remove(helper_dir, cleanup_error);
    }
    if (exit_code != 0) {
        throw std::runtime_error(hook_name + " file failed for " + manifest.name);
    }

    if ((hook_name == "installer" || hook_name == "uninstaller") && !command.keep && !powershell_script) {
        std::filesystem::remove(file);
    }
    run_hook_script(manifest, version_dir, environment, global, command.script, hook_name, version_dir, hook_version, source_bucket);
}

bool is_safe_relative_path(const std::filesystem::path& path) {
    if (path.empty() || path.is_absolute() || path.has_root_name() || path.has_root_directory()) {
        return false;
    }
    for (const auto& part : path) {
        if (part == "..") {
            return false;
        }
    }
    return true;
}

std::filesystem::path checked_relative_path(const std::string& value, const std::string& field) {
    const auto path = std::filesystem::path(value);
    if (!is_safe_relative_path(path)) {
        throw std::runtime_error(field + " must be a relative path inside the app directory: " + value);
    }
    return path;
}

void move_directory_contents(const std::filesystem::path& source, const std::filesystem::path& destination) {
    if (!std::filesystem::is_directory(source)) {
        throw std::runtime_error("extract_dir does not exist after extraction: " + source.string());
    }

    std::filesystem::create_directories(destination);
    for (const auto& entry : std::filesystem::directory_iterator(source)) {
        const auto target = destination / entry.path().filename();
        if (std::filesystem::exists(target)) {
            std::filesystem::remove_all(target);
        }
        std::filesystem::rename(entry.path(), target);
    }
}

void remove_empty_parents_until(const std::filesystem::path& path, const std::filesystem::path& stop) {
    auto current = path;
    const auto canonical_stop = std::filesystem::weakly_canonical(stop);
    while (!current.empty() && std::filesystem::exists(current)) {
        const auto canonical_current = std::filesystem::weakly_canonical(current);
        if (canonical_current == canonical_stop) {
            break;
        }
        if (!std::filesystem::is_directory(current) || !std::filesystem::is_empty(current)) {
            break;
        }
        std::filesystem::remove(current);
        current = current.parent_path();
    }
}

void apply_extract_dir(
    const std::filesystem::path& temporary_dir,
    const std::filesystem::path& version_dir,
    const std::string& extract_dir,
    const std::string& extract_to) {
    const auto source_relative = std::filesystem::path(extract_dir);
    const auto target_relative = extract_to.empty() ? std::filesystem::path{} : std::filesystem::path(extract_to);
    if (!is_safe_relative_path(source_relative)) {
        throw std::runtime_error("extract_dir must be a relative path inside the archive: " + extract_dir);
    }
    if (!target_relative.empty() && !is_safe_relative_path(target_relative)) {
        throw std::runtime_error("extract_to must be a relative path inside the app directory: " + extract_to);
    }

    const auto source = temporary_dir / source_relative;
    const auto destination = target_relative.empty() ? version_dir : version_dir / target_relative;
    move_directory_contents(source, destination);
    remove_empty_parents_until(source, temporary_dir);
}

void link_or_copy_persist(const std::filesystem::path& persisted, const std::filesystem::path& source) {
    if (std::filesystem::is_directory(persisted)) {
        const auto command = "cmd /c mklink /J " + quote_command_arg(source) + " " + quote_command_arg(persisted);
        if (std::system(command.c_str()) == 0) {
            return;
        }
        try {
            std::filesystem::create_directory_symlink(persisted, source);
            return;
        } catch (const std::filesystem::filesystem_error&) {
        }
        std::filesystem::copy(persisted, source, std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing);
        return;
    }

    std::filesystem::create_directories(source.parent_path());
    try {
        std::filesystem::create_hard_link(persisted, source);
        return;
    } catch (const std::filesystem::filesystem_error&) {
    }
    std::filesystem::copy_file(persisted, source, std::filesystem::copy_options::overwrite_existing);
}

bool is_directory_link(const std::filesystem::path& path) {
    std::error_code error;
    const auto status = std::filesystem::symlink_status(path, error);
    if (error || std::filesystem::is_symlink(status)) {
        return !error;
    }
#ifdef _WIN32
    const auto attributes = GetFileAttributesA(path.string().c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
#else
    return false;
#endif
}

bool is_hard_linked_file(const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error) && std::filesystem::hard_link_count(path, error) > 1 && !error;
}

void make_writable_for_removal(const std::filesystem::path& path) {
#ifdef _WIN32
    const auto attributes = GetFileAttributesW(path.wstring().c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_READONLY) == 0) {
        return;
    }
    SetFileAttributesW(path.wstring().c_str(), attributes & ~FILE_ATTRIBUTE_READONLY);
#else
    (void)path;
#endif
}

void remove_all_force(const std::filesystem::path& path) {
    std::error_code status_error;
    const auto status = std::filesystem::symlink_status(path, status_error);
    if (status_error || !std::filesystem::exists(status)) {
        return;
    }

    make_writable_for_removal(path);
    if (is_directory_link(path) || !std::filesystem::is_directory(status)) {
        std::filesystem::remove(path);
        return;
    }

    for (const auto& entry : std::filesystem::directory_iterator(path)) {
        remove_all_force(entry.path());
    }
    make_writable_for_removal(path);
    std::filesystem::remove(path);
}

void apply_persist_data(
    const Environment& environment,
    const std::filesystem::path& version_dir,
    const Manifest& manifest,
    bool global,
    std::vector<std::string>* messages = nullptr) {
    if (manifest.persists.empty()) {
        return;
    }

    const auto app_persist_dir = environment.persist_dir(global) / manifest.name;
    std::filesystem::create_directories(app_persist_dir);

    for (const auto& persist : manifest.persists) {
        if (messages != nullptr) {
            messages->push_back("Persisting " + persist.source);
        }
        const auto source_relative = checked_relative_path(persist.source, "persist source");
        const auto target_relative = checked_relative_path(persist.target.empty() ? persist.source : persist.target, "persist target");
        const auto source = version_dir / source_relative;
        const auto target = app_persist_dir / target_relative;

        if (std::filesystem::exists(target)) {
            if (std::filesystem::exists(source)) {
                const auto backup = source.parent_path() / (source.filename().string() + ".original");
                if (std::filesystem::exists(backup)) {
                    std::filesystem::remove_all(backup);
                }
                std::filesystem::rename(source, backup);
            }
        } else if (std::filesystem::exists(source)) {
            std::filesystem::create_directories(target.parent_path());
            std::filesystem::rename(source, target);
        } else {
            std::filesystem::create_directories(target);
        }

        if (std::filesystem::exists(source)) {
            std::filesystem::remove_all(source);
        }
        std::filesystem::create_directories(source.parent_path());
        link_or_copy_persist(target, source);
    }
}

void unlink_persist_data(const std::filesystem::path& version_dir, const Manifest& manifest) {
    for (const auto& persist : manifest.persists) {
        try {
            const auto source_relative = checked_relative_path(persist.source, "persist source");
            const auto source = version_dir / source_relative;
            if (is_directory_link(source) || is_hard_linked_file(source)) {
                try {
                    std::filesystem::remove(source);
                } catch (const std::filesystem::filesystem_error&) {
                    std::filesystem::remove_all(source);
                }
            }
        } catch (const std::exception&) {
        }
    }
}

bool no_junction_enabled(const Environment& environment) {
    const auto value = ConfigStore(environment.config_file).get("no_junction");
    return value && value->is_boolean() && value->get<bool>();
}

void remove_no_junction_version_environments(const Environment& environment, const std::string& app, const Manifest& manifest, bool global) {
    if (!no_junction_enabled(environment)) {
        return;
    }

    const auto root = app_dir(environment, app, global);
    if (!std::filesystem::is_directory(root)) {
        return;
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_directory()) {
            continue;
        }
        const auto name = entry.path().filename().string();
        if (name == "current" || name.rfind("_", 0) == 0 || !std::filesystem::exists(entry.path() / "install.json")) {
            continue;
        }
        remove_manifest_environment(environment, manifest, entry.path(), global);
    }
}

std::vector<std::string> fetch_and_validate_artifacts(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const std::filesystem::path& version_dir,
    const Manifest& manifest,
    const InstallOptions& options,
    const std::string& cache_version,
    std::vector<std::string>& messages,
    std::vector<std::string>& warnings) {
    std::vector<std::string> filenames;
    std::size_t extracted = 0;
    for (std::size_t i = 0; i < manifest.urls.size(); ++i) {
        const auto& url = manifest.urls[i];
        const auto loaded_from_cache = options.use_cache && std::filesystem::exists(cache_path(environment, manifest.name, cache_version, url));
        FetchedArtifact artifact;
        try {
            artifact = fetch_artifact(
                environment,
                manifest.name,
                cache_version,
                url,
                manifest_path.parent_path(),
                version_dir,
                options.use_cache,
                manifest.cookies);
        } catch (const std::exception& error) {
            throw ArtifactFetchError(url, error.what());
        }
        if (loaded_from_cache) {
            messages.push_back("Loading " + url_remote_filename(url) + " from cache");
        }
        filenames.push_back(artifact.filename);

        if (options.check_hash) {
            const auto manifest_hash = i < manifest.hashes.size() ? manifest.hashes[i] : std::string{};
            if (manifest_hash.empty()) {
                warnings.push_back("Warning: No hash in manifest. SHA256 for '" + artifact.install_path.filename().string() + "' is:\n    " + sha256_file(artifact.install_path));
            } else {
                auto hash_matches = false;
                try {
                    hash_matches = file_hash_matches(artifact.cache_path, manifest_hash);
                } catch (const std::exception&) {
                    hash_matches = false;
                }
                if (!hash_matches) {
                    throw HashCheckError(
                        manifest.name,
                        cache_version,
                        manifest_path,
                        url,
                        artifact.cache_path,
                        artifact.install_path,
                        version_dir,
                        manifest_hash);
                }
            }
        }

        if (should_extract_artifact(manifest, artifact.install_path)) {
            const auto extract_dir = extracted < manifest.extract_dirs.size() ? manifest.extract_dirs[extracted] : std::string{};
            const auto extract_to = extracted < manifest.extract_tos.size() ? manifest.extract_tos[extracted] : std::string{};
            ++extracted;
            if (extract_dir.empty()) {
                const auto destination = extract_to.empty() ? version_dir : version_dir / extract_to;
                if (!extract_to.empty() && !is_safe_relative_path(std::filesystem::path(extract_to))) {
                    throw std::runtime_error("extract_to must be a relative path inside the app directory: " + extract_to);
                }
                if (manifest.innosetup && lower_extension_chain(artifact.install_path).ends_with(".exe")) {
                    extract_inno_archive(environment, artifact.install_path, destination, {});
                } else {
                    extract_archive(environment, artifact.install_path, destination);
                }
            } else {
                const auto temporary_dir = version_dir / ("_extract_" + std::to_string(i));
                if (std::filesystem::exists(temporary_dir)) {
                    std::filesystem::remove_all(temporary_dir);
                }
                if (manifest.innosetup && lower_extension_chain(artifact.install_path).ends_with(".exe")) {
                    const auto destination = extract_to.empty() ? version_dir : version_dir / extract_to;
                    if (!extract_to.empty() && !is_safe_relative_path(std::filesystem::path(extract_to))) {
                        throw std::runtime_error("extract_to must be a relative path inside the app directory: " + extract_to);
                    }
                    extract_inno_archive(environment, artifact.install_path, destination, extract_dir);
                } else {
                    extract_archive(environment, artifact.install_path, temporary_dir);
                    apply_extract_dir(temporary_dir, version_dir, extract_dir, extract_to);
                    if (std::filesystem::exists(temporary_dir)) {
                        std::filesystem::remove_all(temporary_dir);
                    }
                }
            }
            std::filesystem::remove(artifact.install_path);
        }
    }
    return filenames;
}

} // namespace

std::optional<std::filesystem::path> find_7zip(const Environment& environment) {
    return find_7zip_public(environment);
}

std::filesystem::path current_executable_path() {
    return current_executable_path_impl();
}

int try_run_as_shim(int argc, wchar_t** argv) {
#ifdef _WIN32
    const auto exe_path = current_executable_path_impl();
    auto stem = lower_ascii(exe_path.stem().string());

    if (stem == "sco") {
        return -1;
    }

    auto shim_path = exe_path;
    shim_path.replace_extension(".shim");
    if (!std::filesystem::is_regular_file(shim_path)) {
        return -1;
    }

    const auto target = read_shim_metadata_value(shim_path, "path");
    if (!target || target->empty()) {
        std::wcerr << L"sco-shim: missing target metadata in " << shim_path.wstring() << L"\n";
        return 1;
    }

    const auto args = read_shim_metadata_value(shim_path, "args").value_or(std::string{});
    return run_shim_child(std::filesystem::path(*target), args, argc, argv);
#else
    (void)argc;
    (void)argv;
    return -1;
#endif
}

HashCheckError::HashCheckError(
    std::string app,
    std::string version,
    std::filesystem::path manifest_path,
    std::string url,
    std::filesystem::path cached,
    std::filesystem::path install_path,
    std::filesystem::path install_dir,
    std::string manifest_hash)
    : std::runtime_error("hash check failed for " + cached.string()),
      app(std::move(app)),
      version(std::move(version)),
      manifest_path(std::move(manifest_path)),
      url(std::move(url)),
      cached(std::move(cached)),
      install_path(std::move(install_path)),
      install_dir(std::move(install_dir)),
      manifest_hash(std::move(manifest_hash)) {}

ArtifactFetchError::ArtifactFetchError(std::string url, std::string message)
    : std::runtime_error(message),
      url(std::move(url)),
      message(std::move(message)) {}

InstallResult install_manifest_file(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const InstallOptions& options) {
    const auto manifest = load_manifest_file(manifest_path, std::nullopt, options.architecture);
    if (!manifest.supports_current_architecture) {
        throw std::runtime_error("'" + manifest.name + "' doesn't support current architecture!");
    }
    const auto effective_version = manifest.version == "nightly" ? nightly_version() : manifest.version;
    auto effective_options = options;
    if (manifest.version == "nightly") {
        effective_options.check_hash = false;
    }
    const auto root = app_dir(environment, manifest.name, options.global);
    const auto version_dir = root / effective_version;
    const auto current = current_dir_for_version(environment, manifest.name, effective_version, options.global);
    const auto selected_version = select_current_version(environment, manifest.name, options.global);
    const auto old_reference = current_dir_for_version(environment, manifest.name, selected_version, options.global);
    const auto old_version_dir = selected_version.empty() ? std::filesystem::path{} : root / selected_version;
    const auto absolute_manifest = std::filesystem::absolute(manifest_path).generic_string();
    auto source_bucket = bucket_name_for_manifest(environment, manifest_path);
    if (source_bucket.empty()) {
        source_bucket = options.source_bucket;
    }
    const auto source_url = options.source_url.empty() ? absolute_manifest : options.source_url;

    if (std::filesystem::exists(version_dir) && std::filesystem::is_regular_file(version_dir / "install.json") && !options.force) {
        return InstallResult{
            .app = manifest.name,
            .version = effective_version,
            .already_installed = true,
            .install_dir = version_dir,
            .current_dir = current,
        };
    }

    if (std::filesystem::exists(root) && selected_version.empty()) {
        std::filesystem::remove_all(root);
    }

    std::vector<std::string> messages;
    std::vector<std::string> warnings;
    auto version_dir_exists = std::filesystem::exists(version_dir);
    const auto work_dir = version_dir_exists ? staged_version_path(version_dir) : version_dir;
    std::filesystem::create_directories(work_dir);
    std::vector<std::string> artifact_filenames;
    try {
        artifact_filenames = fetch_and_validate_artifacts(
            environment,
            manifest_path,
            work_dir,
            manifest,
            effective_options,
            effective_version,
            messages,
            warnings);
    } catch (const HashCheckError&) {
        throw;
    } catch (...) {
        if (work_dir != version_dir || !version_dir_exists) {
            std::filesystem::remove_all(work_dir);
        }
        throw;
    }

    if (!selected_version.empty() && std::filesystem::exists(old_reference / "manifest.json")) {
        const auto old_manifest = load_manifest_file(old_reference / "manifest.json", manifest.name, install_architecture_for_dir(old_version_dir));
        const auto old_source_bucket = installed_bucket_for_dir(old_version_dir);
        run_hook_script(old_manifest, old_version_dir, environment, options.global, old_manifest.pre_uninstall, "pre_uninstall", old_version_dir, selected_version, old_source_bucket);
        if (options.report_old_uninstall) {
            messages.push_back("Uninstalling '" + manifest.name + "' (" + selected_version + ")");
        }
        const auto default_uninstaller_file = old_manifest.urls.empty() ? std::string{} : url_filename(old_manifest.urls.front());
        run_manifest_command(old_manifest, old_version_dir, environment, options.global, old_manifest.uninstaller, "uninstaller", default_uninstaller_file, selected_version, old_source_bucket);
        remove_shims(environment, old_manifest, options.global);
        if (old_reference.filename() == "current" && std::filesystem::exists(old_reference)) {
            remove_current_link_or_copy(old_reference);
        }
        uninstall_psmodule(environment, old_manifest, options.global);
        remove_manifest_environment(environment, old_manifest, old_reference, options.global);
        remove_no_junction_version_environments(environment, manifest.name, old_manifest, options.global);
        remove_shortcuts(old_manifest, options.global);
        if (selected_version == effective_version) {
            unlink_persist_data(old_version_dir, old_manifest);
        }
        if (selected_version != effective_version) {
            run_hook_script(old_manifest, old_version_dir, environment, options.global, old_manifest.post_uninstall, "post_uninstall", old_version_dir, selected_version, old_source_bucket);
        } else {
            try {
                const auto backup = forced_backup_path(old_version_dir);
                if (!std::filesystem::exists(backup)) {
                    std::filesystem::rename(old_version_dir, backup);
                    version_dir_exists = false;
                }
            } catch (const std::exception&) {
            }
            run_hook_script(old_manifest, old_version_dir, environment, options.global, old_manifest.post_uninstall, "post_uninstall", old_version_dir, selected_version, old_source_bucket);
        }
    }

    if (version_dir_exists) {
        std::filesystem::rename(version_dir, forced_backup_path(version_dir));
    }
    if (work_dir != version_dir) {
        std::filesystem::rename(work_dir, version_dir);
    }

    run_hook_script(manifest, version_dir, environment, options.global, manifest.pre_install, "pre_install", version_dir, effective_version, source_bucket);
    run_manifest_command(
        manifest,
        version_dir,
        environment,
        options.global,
        manifest.installer,
        "installer",
        artifact_filenames.empty() ? std::string{} : artifact_filenames.front(),
        effective_version,
        source_bucket);
    for (const auto& removed : remove_environment_path_tree(environment, "PATH", version_dir, options.global)) {
        warnings.push_back("Installer added '" + removed + "' to path. Removing.");
    }

    auto install_info = nlohmann::json{
        {"architecture", manifest.architecture},
        {"bucket", source_bucket.empty() ? nlohmann::json(nullptr) : nlohmann::json(source_bucket)},
        {"url", source_bucket.empty() ? nlohmann::json(source_url) : nlohmann::json(nullptr)},
        {"manifest", absolute_manifest},
        {"installed_by", "sco"},
        {"downloaded", !manifest.urls.empty()},
        {"artifact_count", manifest.urls.size()},
        {"use_cache", options.use_cache},
        {"check_hash", effective_options.check_hash},
        {"independent", options.independent},
        {"force", options.force},
    };
    for (auto item = install_info.begin(); item != install_info.end();) {
        if (item.value().is_null()) {
            item = install_info.erase(item);
        } else {
            ++item;
        }
    }
    create_current_link_or_copy(version_dir, current, &messages);
    create_shims(environment, current, manifest, options.global);
    create_shortcuts(environment, current, manifest, options.global, &messages);
    install_psmodule(environment, current, manifest, options.global, &messages, &warnings);
    apply_manifest_environment(environment, manifest, current, version_dir, options.global);
    apply_persist_data(environment, version_dir, manifest, options.global, &messages);
    run_hook_script(manifest, current, environment, options.global, manifest.post_install, "post_install", version_dir, effective_version, source_bucket);

    std::filesystem::copy_file(manifest_path, version_dir / "manifest.json", std::filesystem::copy_options::overwrite_existing);
    write_json_file(version_dir / "install.json", install_info);
    std::error_code equivalent_error;
    if (std::filesystem::exists(current) && !std::filesystem::equivalent(current, version_dir, equivalent_error)) {
        std::filesystem::copy_file(manifest_path, current / "manifest.json", std::filesystem::copy_options::overwrite_existing);
        write_json_file(current / "install.json", install_info);
    }

    return InstallResult{
        .app = manifest.name,
        .version = effective_version,
        .already_installed = false,
        .install_dir = version_dir,
        .current_dir = current,
        .messages = std::move(messages),
        .warnings = std::move(warnings),
    };
}

UninstallResult uninstall_app(
    const Environment& environment,
    const std::string& app,
    bool global,
    bool purge,
    const std::function<bool()>& should_skip_after_pre_uninstall) {
    const auto root = app_dir(environment, app, global);
    if (!std::filesystem::exists(root)) {
        return UninstallResult{
            .app = app,
            .removed = false,
            .app_dir = root,
        };
    }

    const auto selected_version = select_current_version(environment, app, global);
    const auto current = current_dir_for_version(environment, app, selected_version, global);
    auto manifest_path = current / "manifest.json";
    const auto active_dir = selected_version.empty() ? current : root / selected_version;
    if (!std::filesystem::is_regular_file(manifest_path)) {
        const auto version_manifest_path = active_dir / "manifest.json";
        if (std::filesystem::is_regular_file(version_manifest_path)) {
            manifest_path = version_manifest_path;
        }
    }
    std::vector<std::string> messages;
    std::vector<std::string> warnings;
    if (std::filesystem::is_regular_file(manifest_path)) {
        std::optional<Manifest> manifest;
        try {
            manifest = load_manifest_file(manifest_path, app, install_architecture_for_dir(active_dir));
        } catch (const std::exception&) {
            // A broken manifest should not prevent removing the app directory.
        }
        if (manifest) {
            const auto reference_dir = std::filesystem::exists(current) ? current : active_dir;
            const auto source_bucket = installed_bucket_for_dir(active_dir);
            run_hook_script(*manifest, active_dir, environment, global, manifest->pre_uninstall, "pre_uninstall", active_dir, selected_version, source_bucket);
            if (should_skip_after_pre_uninstall && should_skip_after_pre_uninstall()) {
                return UninstallResult{
                    .app = app,
                    .removed = false,
                    .skipped = true,
                    .app_dir = root,
                    .messages = std::move(messages),
                    .warnings = std::move(warnings),
                };
            }
            const auto default_uninstaller_file = manifest->urls.empty() ? std::string{} : url_filename(manifest->urls.front());
            run_manifest_command(*manifest, active_dir, environment, global, manifest->uninstaller, "uninstaller", default_uninstaller_file, selected_version, source_bucket);
            remove_manifest_environment(environment, *manifest, reference_dir, global);
            remove_no_junction_version_environments(environment, app, *manifest, global);
            remove_shortcuts(*manifest, global, &messages);
            uninstall_psmodule(environment, *manifest, global, &messages);
            if (current.filename() == "current" && (std::filesystem::exists(current) || is_directory_link(current))) {
                messages.push_back("Unlinking " + current.string());
            }
            unlink_persist_data(active_dir, *manifest);
            remove_shims(environment, *manifest, global);
            if (current.filename() == "current" && (std::filesystem::exists(current) || is_directory_link(current))) {
                remove_current_link_or_copy(current);
            }
            if (std::filesystem::exists(active_dir)) {
                remove_all_force(active_dir);
            }
            run_hook_script(*manifest, active_dir, environment, global, manifest->post_uninstall, "post_uninstall", active_dir, selected_version, source_bucket);
        }
    }

    if (std::filesystem::is_directory(root)) {
        for (const auto& entry : std::filesystem::directory_iterator(root)) {
            if (!entry.is_directory()) {
                continue;
            }
            const auto version = entry.path().filename().string();
            if (version == "current" || version == selected_version) {
                continue;
            }
            messages.push_back("Removing older version (" + version + ").");
        }
    }

    remove_all_force(root);
    if (purge) {
        remove_all_force(environment.persist_dir(global) / app);
    }
    return UninstallResult{
        .app = app,
        .removed = true,
        .app_dir = root,
        .messages = std::move(messages),
        .warnings = std::move(warnings),
    };
}

CleanupResult cleanup_app(const Environment& environment, const std::string& app, bool global) {
    const auto root = app_dir(environment, app, global);
    const auto current_version = select_current_version(environment, app, global);
    const auto root_exists = std::filesystem::is_directory(root);
    CleanupResult result{
        .app = app,
        .current_version = current_version,
        .app_dir_exists = root_exists,
    };

    if (!root_exists) {
        return result;
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_directory()) {
            continue;
        }

        const auto name = entry.path().filename().string();
        if (name == "current" || (!current_version.empty() && name == current_version)) {
            continue;
        }

        const auto manifest_path = entry.path() / "manifest.json";
        if (std::filesystem::is_regular_file(manifest_path)) {
            try {
                const auto manifest = load_manifest_file(manifest_path, app, install_architecture_for_dir(entry.path()));
                unlink_persist_data(entry.path(), manifest);
            } catch (const std::exception&) {
            }
        }

        result.removed_versions.push_back(entry.path());
        remove_all_force(entry.path());
    }

    std::error_code error;
    if (std::filesystem::is_directory(root, error) && std::filesystem::is_empty(root, error)) {
        std::filesystem::remove(root, error);
    }

    return result;
}

ResetResult reset_app(const Environment& environment, const std::string& app, const std::string& version, bool global) {
    const auto selected_version = version.empty() ? select_current_version(environment, app, global) : version;
    ResetResult result{
        .app = app,
        .version = selected_version,
    };

    if (selected_version.empty()) {
        return result;
    }

    const auto target_dir = app_dir(environment, app, global) / selected_version;
    const auto manifest_path = target_dir / "manifest.json";
    if (!std::filesystem::is_directory(target_dir) || !std::filesystem::is_regular_file(manifest_path)) {
        return result;
    }

    const auto manifest = load_manifest_file(manifest_path, app);
    const auto current = current_dir(environment, app, global);
    const auto selected_reference = current_dir_for_version(environment, app, selected_version, global);

    if (std::filesystem::exists(current / "manifest.json")) {
        try {
            const auto old_manifest = load_manifest_file(current / "manifest.json", app);
            remove_manifest_environment(environment, old_manifest, current, global);
            remove_no_junction_version_environments(environment, app, old_manifest, global);
        } catch (const std::exception&) {
        }
    }

    create_current_link_or_copy(target_dir, selected_reference, &result.messages, true);
    create_shims(environment, selected_reference, manifest, global, &result.messages);
    create_shortcuts(environment, selected_reference, manifest, global, &result.messages);
    apply_manifest_environment(environment, manifest, selected_reference, target_dir, global);
    unlink_persist_data(target_dir, manifest);
    apply_persist_data(environment, target_dir, manifest, global, &result.messages);

    result.reset = true;
    result.install_dir = target_dir;
    result.current_dir = selected_reference;
    return result;
}

} // namespace sco
