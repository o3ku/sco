#include "sco/cli.hpp"

#include "sco/apps.hpp"
#include "sco/artifact.hpp"
#include "sco/buckets.hpp"
#include "sco/cache.hpp"
#include "sco/checkver.hpp"
#include "sco/compression.hpp"
#include "sco/config.hpp"
#include "sco/environment.hpp"
#include "sco/envvars.hpp"
#include "sco/http_client.hpp"
#include "sco/installer.hpp"
#include "sco/manifest.hpp"
#include "sco/table.hpp"
#include "sco/versions.hpp"
#include "sco/xml.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <regex>
#include <set>
#include <iomanip>
#include <sstream>
#include <string_view>
#include <unordered_set>
#include <vector>

#include <pugixml.hpp>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>

#ifndef SCO_VERSION
#define SCO_VERSION "0.5.1"
#endif

namespace sco {

namespace {

bool is_supported_architecture(const std::string& architecture) {
    return architecture == "64bit" || architecture == "32bit" || architecture == "arm64";
}

std::optional<std::string> normalize_architecture(std::string architecture) {
    std::transform(architecture.begin(), architecture.end(), architecture.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    if (architecture == "64bit" || architecture == "64" || architecture == "x64" || architecture == "amd64" || architecture == "x86_64" || architecture == "x86-64") {
        return "64bit";
    }
    if (architecture == "32bit" || architecture == "32" || architecture == "x86" || architecture == "i386" || architecture == "386" || architecture == "i686") {
        return "32bit";
    }
    if (architecture == "arm64" || architecture == "arm" || architecture == "aarch64") {
        return "arm64";
    }
    return std::nullopt;
}

std::string default_architecture(const ConfigStore& config) {
    const auto configured = config.get("default_architecture");
    if (configured && configured->is_string()) {
        if (const auto normalized = normalize_architecture(configured->get<std::string>())) {
            return *normalized;
        }
    }
    return "64bit";
}

std::string default_architecture(const Environment& environment) {
    return default_architecture(ConfigStore(environment.config_file));
}

void apply_default_architecture(InstallOptions& options, const Environment& environment, const std::string& explicit_architecture = {}) {
    const auto selected = explicit_architecture.empty() ? default_architecture(environment) : explicit_architecture;
    if (const auto normalized = normalize_architecture(selected)) {
        options.architecture = *normalized;
    } else {
        options.architecture = selected;
    }
}

std::string iso_utc_time_after_days(int days) {
    const auto target = std::chrono::system_clock::now() + std::chrono::hours(24 * days);
    const auto time = std::chrono::system_clock::to_time_t(target);
    std::tm utc{};
    gmtime_s(&utc, &time);

    std::ostringstream stream;
    stream << std::put_time(&utc, "%Y-%m-%dT%H:%M:%SZ");
    return stream.str();
}

std::time_t utc_time_from_tm(std::tm value) {
#if defined(_WIN32)
    return _mkgmtime(&value);
#else
    return timegm(&value);
#endif
}

std::optional<std::chrono::system_clock::time_point> parse_scoop_datetime(const std::string& value) {
    static const std::regex pattern(
        R"(^\s*(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T\s](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?(?:\.\d+)?(?:\s*(Z|[+-]\d{2}:?\d{2}))?)?\s*$)",
        std::regex::icase);

    std::smatch match;
    if (!std::regex_match(value, match, pattern)) {
        return std::nullopt;
    }

    auto integer = [&](std::size_t index, int fallback = 0) {
        return match[index].matched ? std::stoi(match[index].str()) : fallback;
    };

    const auto year = integer(1);
    const auto month = integer(2);
    const auto day = integer(3);
    const auto hour = integer(4);
    const auto minute = integer(5);
    const auto second = integer(6);
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour < 0 || hour > 23 ||
        minute < 0 || minute > 59 || second < 0 || second > 60) {
        return std::nullopt;
    }

    std::tm parsed{};
    parsed.tm_year = year - 1900;
    parsed.tm_mon = month - 1;
    parsed.tm_mday = day;
    parsed.tm_hour = hour;
    parsed.tm_min = minute;
    parsed.tm_sec = second;
    parsed.tm_isdst = -1;

    std::time_t timestamp{};
    if (match[7].matched) {
        timestamp = utc_time_from_tm(parsed);
        if (timestamp == static_cast<std::time_t>(-1)) {
            return std::nullopt;
        }

        auto zone = match[7].str();
        if (zone != "Z" && zone != "z") {
            const auto sign = zone.front();
            zone.erase(zone.begin());
            zone.erase(std::remove(zone.begin(), zone.end(), ':'), zone.end());
            if (zone.size() != 4) {
                return std::nullopt;
            }
            const auto offset_hours = std::stoi(zone.substr(0, 2));
            const auto offset_minutes = std::stoi(zone.substr(2, 2));
            if (offset_hours > 23 || offset_minutes > 59) {
                return std::nullopt;
            }
            const auto offset = offset_hours * 3600 + offset_minutes * 60;
            timestamp += sign == '+' ? -offset : offset;
        }
    } else {
        timestamp = std::mktime(&parsed);
        if (timestamp == static_cast<std::time_t>(-1)) {
            return std::nullopt;
        }
    }

    return std::chrono::system_clock::from_time_t(timestamp);
}

bool is_scoop_outdated(const Environment& environment) {
    ConfigStore config(environment.config_file);
    std::optional<std::chrono::system_clock::time_point> last_update;
    if (const auto value = config.get("last_update"); value && value->is_string()) {
        last_update = parse_scoop_datetime(value->get<std::string>());
    }

    if (!last_update) {
        return true;
    }

    return std::chrono::system_clock::now() - *last_update >= std::chrono::hours(3);
}

void report_scoop_core_hold_state(const Environment& environment, std::ostream& out) {
    ConfigStore config(environment.config_file);
    const auto value = config.get("hold_update_until");
    if (!value || !value->is_string()) {
        return;
    }

    const auto raw = value->get<std::string>();
    const auto parsed = parse_scoop_datetime(raw);
    if (!parsed) {
        out << "ERROR 'hold_update_until' has been set in the wrong format and was removed.\n"
            << "ERROR If you want to disable self-update of Scoop Core for a moment,\n"
            << "ERROR use 'scoop hold scoop' or 'scoop config hold_update_until <YYYY-MM-DD>/<YYYY/MM/DD>'.\n";
        config.remove("hold_update_until");
        config.save();
        return;
    }

    if (std::chrono::system_clock::now() < *parsed) {
        out << "WARN  Skipping self-update of Scoop Core until " << raw << "...\n"
            << "WARN  If you want to update Scoop Core immediately, use 'scoop unhold scoop; scoop update'.\n";
        return;
    }

    out << "WARN  Self-update of Scoop Core is enabled again!\n";
    config.remove("hold_update_until");
    config.save();
}

std::filesystem::path generate_autoupdate_manifest(
    const Environment& environment,
    const std::filesystem::path& source_manifest,
    const std::string& app,
    const std::string& version,
    bool reuse_current_version = false);
std::filesystem::path materialize_manifest_url(
    const Environment& environment,
    const std::string& url,
    std::ostream& err,
    std::string_view command = "install");
bool looks_like_http_url(const std::string& value);
std::string run_command_capture(const std::string& command);
int run_command_capture_raw(const std::string& command, std::string& output);
std::string quote_process_argument(const std::string& value);
std::string quote_process_argument(const std::filesystem::path& path);

std::vector<KnownBucket> list_known_buckets_for_environment(const Environment& environment) {
    if (std::filesystem::is_regular_file(environment.root_dir / "buckets.json")) {
        return list_known_buckets(environment.root_dir);
    }
    auto buckets = list_known_buckets(environment.root_dir);
    if (!buckets.empty()) {
        return buckets;
    }
    return list_known_buckets();
}

struct StatusRemoteCheck {
    bool needs_update = false;
    bool network_failure = false;
};

StatusRemoteCheck status_bucket_update_check(const LocalBucket& bucket) {
    if (!std::filesystem::is_directory(bucket.path / ".git")) {
        return {.needs_update = true};
    }

    std::string output;
    const auto fetch_status = run_command_capture_raw("git -C " + quote_process_argument(bucket.path) + " fetch -q origin 2>NUL", output);
    const auto branch = run_command_capture("git -C " + quote_process_argument(bucket.path) + " branch --show-current 2>NUL");
    if (branch.empty()) {
        return {.network_failure = fetch_status != 0};
    }
    const auto commits = run_command_capture("git -C " + quote_process_argument(bucket.path) + " log HEAD..origin/" + quote_process_argument(std::string{branch}) + " --oneline 2>NUL");
    return {
        .needs_update = !commits.empty(),
        .network_failure = fetch_status != 0,
    };
}

StatusRemoteCheck status_scoop_update_check(const Environment& environment) {
    const auto current = app_dir(environment, "scoop", false) / "current";
    if (!std::filesystem::exists(current)) {
        return {};
    }
    if (!std::filesystem::is_directory(current / ".git")) {
        return {.needs_update = true};
    }

    std::string output;
    const auto fetch_status = run_command_capture_raw("git -C " + quote_process_argument(current) + " fetch -q origin 2>NUL", output);
    const auto branch = run_command_capture("git -C " + quote_process_argument(current) + " branch --show-current 2>NUL");
    if (branch.empty()) {
        return {.network_failure = fetch_status != 0};
    }
    const auto commits = run_command_capture("git -C " + quote_process_argument(current) + " log HEAD..origin/" + quote_process_argument(std::string{branch}) + " --oneline 2>NUL");
    return {
        .needs_update = !commits.empty(),
        .network_failure = fetch_status != 0,
    };
}

StatusRemoteCheck status_bucket_update_check(const Environment& environment) {
    StatusRemoteCheck check;
    for (const auto& bucket : list_local_buckets(environment)) {
        const auto bucket_check = status_bucket_update_check(bucket);
        check.needs_update = check.needs_update || bucket_check.needs_update;
        check.network_failure = check.network_failure || bucket_check.network_failure;
    }
    return check;
}

bool scoop_update_should_refresh(const Environment& environment) {
    return is_scoop_outdated(environment);
}

bool config_bool(const Environment& environment, const std::string& name) {
    const auto value = ConfigStore(environment.config_file).get(name);
    return value && value->is_boolean() && value->get<bool>();
}

void ensure_update_channel_config_defaults(const Environment& environment) {
    ConfigStore config(environment.config_file);
    auto changed = false;
    if (!config.get("scoop_repo")) {
        config.set("scoop_repo", "https://github.com/ScoopInstaller/Scoop");
        changed = true;
    }
    if (!config.get("scoop_branch")) {
        config.set("scoop_branch", "master");
        changed = true;
    }
    if (changed) {
        config.save();
    }
}

void complete_config_change(
    const Environment& environment,
    const ConfigStore& config,
    const std::string& name,
    const nlohmann::json* value,
    std::ostream& out) {
    const auto normalized = normalize_config_name(name);
    if (normalized == "use_isolated_path") {
        const auto next = value != nullptr ? *value : nlohmann::json(nullptr);
        migrate_isolated_path_setting(environment, config.get(name), next, false);
    } else if (normalized == "use_sqlite_cache" && value != nullptr && value->is_boolean() && value->get<bool>()) {
        if (default_architecture(config) == "arm64") {
            throw std::runtime_error("SQLite cache is not supported on ARM64 platform.");
        }
        out << "INFO  Initializing SQLite cache in progress... This may take a while, please wait.\n";
        (void)list_bucket_manifest_index(environment);
    }
}

struct RunningProcessInfo {
    DWORD pid = 0;
    std::filesystem::path path;
};

std::wstring lowercase_path(std::wstring value) {
    std::replace(value.begin(), value.end(), L'/', L'\\');
    while (value.size() > 3 && (value.back() == L'\\' || value.back() == L'/')) {
        value.pop_back();
    }
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
        return static_cast<wchar_t>(std::towlower(ch));
    });
    return value;
}

std::wstring comparable_path(const std::filesystem::path& path) {
    std::error_code error;
    auto resolved = std::filesystem::weakly_canonical(path, error);
    if (error) {
        resolved = std::filesystem::absolute(path, error);
    }
    if (error) {
        resolved = path;
    }
    return lowercase_path(resolved.lexically_normal().wstring());
}

bool path_is_in_tree(const std::filesystem::path& path, const std::wstring& root) {
    const auto candidate = comparable_path(path);
    if (candidate == root) {
        return true;
    }
    return candidate.size() > root.size() &&
        candidate.rfind(root, 0) == 0 &&
        candidate[root.size()] == L'\\';
}

std::vector<RunningProcessInfo> running_processes_under_app(const Environment& environment, const std::string& app, bool global) {
    std::vector<RunningProcessInfo> processes;
    const auto root_path = app_dir(environment, app, global);
    if (!std::filesystem::exists(root_path)) {
        return processes;
    }

    const auto root = comparable_path(root_path);
    const auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return processes;
    }

    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (!Process32FirstW(snapshot, &entry)) {
        CloseHandle(snapshot);
        return processes;
    }

    do {
        if (entry.th32ProcessID == GetCurrentProcessId()) {
            continue;
        }

        const auto process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
        if (process == nullptr) {
            continue;
        }

        std::wstring image(MAX_PATH * 4, L'\0');
        DWORD size = static_cast<DWORD>(image.size());
        if (QueryFullProcessImageNameW(process, 0, image.data(), &size) != 0) {
            image.resize(size);
            const auto path = std::filesystem::path(image);
            if (path_is_in_tree(path, root)) {
                processes.push_back(RunningProcessInfo{entry.th32ProcessID, path});
            }
        }
        CloseHandle(process);
    } while (Process32NextW(snapshot, &entry));

    CloseHandle(snapshot);
    return processes;
}

bool should_skip_for_running_processes(const Environment& environment, const std::string& app, bool global, std::ostream& out) {
    const auto processes = running_processes_under_app(environment, app, global);
    if (processes.empty()) {
        return false;
    }

    const auto ignore = config_bool(environment, "IGNORE_RUNNING_PROCESSES");
    if (ignore) {
        out << "WARN  The following instances of \"" << app << "\" are still running. Scoop is configured to ignore this condition.\n";
    } else {
        out << "ERROR The following instances of \"" << app << "\" are still running. Close them and try again.\n";
    }
    for (const auto& process : processes) {
        out << "    " << process.pid << ' ' << process.path.string() << '\n';
    }
    return !ignore;
}

std::string cookie_header_from(const std::vector<std::pair<std::string, std::string>>& cookies) {
    std::string header;
    for (const auto& [name, value] : cookies) {
        if (!header.empty()) {
            header += ';';
        }
        header += name;
        header += '=';
        header += value;
    }
    return header;
}

struct OptionSpec {
    char short_name = '\0';
    std::string_view long_name;
    bool requires_value = false;
};

struct ParsedOptions {
    std::set<std::string> flags;
    std::map<std::string, std::string> values;
    std::vector<std::string> positional;
    std::string error;
};

std::string option_key(const OptionSpec& spec) {
    if (!spec.long_name.empty()) {
        return std::string(spec.long_name);
    }
    return std::string(1, spec.short_name);
}

bool option_name_equal(std::string_view lhs, std::string_view rhs) {
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

const OptionSpec* find_long_option(const std::vector<OptionSpec>& specs, std::string_view name) {
    for (const auto& spec : specs) {
        if (option_name_equal(spec.long_name, name)) {
            return &spec;
        }
    }
    return nullptr;
}

const OptionSpec* find_short_option(const std::vector<OptionSpec>& specs, char name) {
    for (const auto& spec : specs) {
        if (std::tolower(static_cast<unsigned char>(spec.short_name)) == std::tolower(static_cast<unsigned char>(name))) {
            return &spec;
        }
    }
    return nullptr;
}

ParsedOptions parse_scoop_options(const std::vector<std::string>& args, const std::vector<OptionSpec>& specs) {
    ParsedOptions parsed;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        if (arg == "--") {
            for (++i; i < args.size(); ++i) {
                parsed.positional.push_back(args[i]);
            }
            break;
        }
        if (arg.rfind("--", 0) == 0) {
            const auto name = std::string_view(arg).substr(2);
            const auto* spec = find_long_option(specs, name);
            if (spec == nullptr) {
                parsed.error = "Option --" + std::string(name) + " not recognized.";
                return parsed;
            }
            if (spec->requires_value) {
                if (i + 1 >= args.size()) {
                    parsed.error = "Option --" + std::string(name) + " requires an argument.";
                    return parsed;
                }
                parsed.values[option_key(*spec)] = args[++i];
            } else {
                parsed.flags.insert(option_key(*spec));
            }
            continue;
        }
        if (arg.size() > 1 && arg[0] == '-') {
            for (std::size_t j = 1; j < arg.size(); ++j) {
                const auto name = arg[j];
                const auto* spec = find_short_option(specs, name);
                if (spec == nullptr) {
                    parsed.error = std::string("Option -") + name + " not recognized.";
                    return parsed;
                }
                if (spec->requires_value) {
                    if (j + 1 != arg.size() || i + 1 >= args.size()) {
                        parsed.error = std::string("Option -") + name + " requires an argument.";
                        return parsed;
                    }
                    parsed.values[option_key(*spec)] = args[++i];
                } else {
                    parsed.flags.insert(option_key(*spec));
                }
            }
            continue;
        }
        parsed.positional.push_back(arg);
    }
    return parsed;
}

bool has_option(const ParsedOptions& options, const std::string& name) {
    return options.flags.contains(name);
}

std::string option_value(const ParsedOptions& options, const std::string& name) {
    const auto value = options.values.find(name);
    return value == options.values.end() ? std::string{} : value->second;
}

void write_invalid_architecture_error(const std::string& architecture, std::ostream& err) {
    err << "ERROR: Invalid architecture: '" << architecture << "'\n";
}

void write_nightly_install_warning(const Manifest& manifest, std::ostream& out, bool quiet = false) {
    if (!quiet && manifest.version == "nightly") {
        out << "WARN  This is a nightly version. Downloaded files won't be verified.\n";
    }
}

void write_install_hash_failure(const Environment& environment, const HashCheckError& error, std::ostream& out);
void write_install_artifact_fetch_failure(const ArtifactFetchError& error, std::ostream& out);
std::string bucket_name_for_manifest(const Environment& environment, const std::filesystem::path& manifest_path);
bool install_missing_update_dependencies(
    const Environment& environment,
    const Manifest& manifest,
    const InstallOptions& options,
    std::ostream& out,
    std::ostream& err);
void repair_failed_installations_for_app(
    const Environment& environment,
    const std::string& app,
    std::set<std::string>& checked,
    std::ostream& out);

int update_one_app(
    const Environment& environment,
    const std::string& app,
    const InstallOptions& options,
    std::ostream& out,
    std::ostream& err,
    bool quiet_up_to_date = false,
    bool print_outdated_prelude = false) {
    const auto current = select_current_version(environment, app, options.global);
    if (current.empty()) {
        err << "'" << app << "' isn't installed.\n";
        return 1;
    }
    std::set<std::string> failed_install_checks;
    repair_failed_installations_for_app(environment, app, failed_install_checks, out);

    if (is_app_held(environment, app, options.global)) {
        out << "'" << app << "' is held to version " << current << ".\n";
        return 0;
    }

    auto app_options = options;
    if (app_options.architecture.empty()) {
        app_options.architecture = installed_app_architecture(environment, app, options.global).value_or(default_architecture(environment));
    }
    if (const auto normalized = normalize_architecture(app_options.architecture)) {
        app_options.architecture = *normalized;
    }
    if (!is_supported_architecture(app_options.architecture)) {
        err << "sco update: invalid architecture '" << app_options.architecture << "'\n";
        return 1;
    }

    std::optional<std::filesystem::path> manifest_path;
    if (const auto manifest_url = installed_app_manifest_url(environment, app, options.global)) {
        manifest_path = materialize_manifest_url(environment, *manifest_url, err, "update");
        if (!manifest_path) {
            return 1;
        }
        app_options.source_url = *manifest_url;
    } else {
        manifest_path = installed_app_manifest_path(environment, app, options.global);
    }
    if (!manifest_path) {
        manifest_path = find_manifest_in_buckets(environment, app);
    }
    if (!manifest_path) {
        err << "sco update: couldn't find manifest for '" << app << "'\n";
        return 1;
    }
    if (const auto source_bucket = bucket_name_for_manifest(environment, *manifest_path); !source_bucket.empty()) {
        app_options.source_bucket = source_bucket;
    } else if (app_options.source_url.empty()) {
        app_options.source_url = std::filesystem::absolute(*manifest_path).generic_string();
    }

    const auto latest = load_manifest_file(*manifest_path, std::nullopt, app_options.architecture);
    auto latest_version = resolve_checkver_version(environment, *manifest_path).value_or(latest.version);
    if (latest_version == "nightly") {
        latest_version = nightly_version();
    }
    const auto update_nightly = config_bool(environment, "update_nightly");
    const auto version_comparison = compare_versions(current, latest_version, update_nightly);
    const auto update_available = config_bool(environment, "force_update") ? version_comparison != 0 : version_comparison > 0;
    if (!update_available && !app_options.force) {
        if (!quiet_up_to_date) {
            out << latest.name << ": " << current << " (latest version)\n";
        }
        return 0;
    }

    auto install_path = *manifest_path;
    if (latest.version != "nightly" && latest_version != latest.version) {
        try {
            install_path = generate_autoupdate_manifest(environment, *manifest_path, latest.name, latest_version);
        } catch (const std::exception& error) {
            err << "sco update: " << error.what() << '\n';
            return 1;
        }
    }

    if (latest.version == "nightly" && update_available && latest_version == nightly_version()) {
        app_options.force = true;
    }

    if (print_outdated_prelude) {
        out << app << ": " << current << " -> " << latest_version << '\n';
        out << "Updating one outdated app:\n";
    }
    out << "Updating '" << app << "' (" << current << " -> " << latest_version << ")\n";

    if (should_skip_for_running_processes(environment, app, options.global, out)) {
        out << "Running process detected, skip updating.\n";
        return 0;
    }

    const auto install_manifest = load_manifest_file(install_path, std::nullopt, app_options.architecture);
    if (!install_missing_update_dependencies(environment, install_manifest, app_options, out, err)) {
        return 1;
    }

    write_nightly_install_warning(latest, out, quiet_up_to_date);
    out << "Downloading new version\n";
    app_options.report_old_uninstall = true;
    InstallResult result;
    try {
        result = install_manifest_file(environment, install_path, app_options);
    } catch (const HashCheckError& error) {
        write_install_hash_failure(environment, error, out);
        return 1;
    } catch (const ArtifactFetchError& error) {
        write_install_artifact_fetch_failure(error, out);
        return 1;
    }
    auto wrote_install_start = false;
    const auto write_install_start_after_uninstall = [&] {
        if (!wrote_install_start && !result.already_installed) {
            out << "Installing '" << result.app << "' (" << result.version << ") [" << install_manifest.architecture << "]";
            auto display_bucket = bucket_name_for_manifest(environment, install_path);
            if (display_bucket.empty()) {
                display_bucket = app_options.source_bucket;
            }
            if (!display_bucket.empty()) {
                out << " from '" << display_bucket << "' bucket";
            } else if (!app_options.source_url.empty()) {
                out << " from '" << app_options.source_url << "'";
            }
            out << '\n';
            wrote_install_start = true;
        }
    };
    for (const auto& message : result.messages) {
        out << message << '\n';
        if (message.rfind("Uninstalling '" + result.app + "'", 0) == 0) {
            write_install_start_after_uninstall();
        }
    }
    write_install_start_after_uninstall();
    for (const auto& warning : result.warnings) {
        out << "WARN  " << warning << '\n';
    }
    if (result.already_installed) {
        out << "'" << result.app << "' (" << result.version << ") is already installed.\n";
    } else if (version_comparison == 0 && app_options.force) {
        out << "'" << result.app << "' (" << result.version << ") was installed successfully!\n";
        out << "Reinstalled '" << result.app << "' (" << result.version << ").\n";
    } else {
        out << "'" << result.app << "' (" << result.version << ") was installed successfully!\n";
        out << "Updated '" << result.app << "' from " << current << " to " << result.version << ".\n";
    }
    return 0;
}

int update_scoop_and_buckets(const Environment& environment, std::ostream& out, std::ostream& err) {
    report_scoop_core_hold_state(environment, out);

    const auto results = update_buckets(environment);
    if (results.empty()) {
        out << "No buckets are installed.\n";
    } else {
        auto failed = false;
        auto updated_bucket_cache = false;
        for (const auto& result : results) {
            if (result.updated) {
                out << "Updated '" << result.name << "' bucket.\n";
                updated_bucket_cache = updated_bucket_cache || result.changed;
            } else if (result.message == "not a git bucket") {
                out << "'" << result.name << "' is not a git repository. Skipped.\n";
            } else {
                failed = true;
                err << "Could not update '" << result.name << "' bucket: " << result.message << "\n";
            }
        }
        if (failed) {
            return 1;
        }
        if (updated_bucket_cache && config_bool(environment, "use_sqlite_cache")) {
            out << "INFO  Updating cache...\n";
            (void)list_bucket_manifest_index(environment);
        }
    }

    ConfigStore config(environment.config_file);
    config.set("last_update", iso_utc_time_after_days(0));
    config.save();
    out << "Scoop buckets were updated successfully.\n";
    return 0;
}

int update_scoop_if_outdated(const Environment& environment, bool update_scoop, std::ostream& out, std::ostream& err) {
    if (!scoop_update_should_refresh(environment)) {
        return 0;
    }
    if (!update_scoop) {
        out << "WARN  Scoop is out of date.\n";
        return 0;
    }
    return update_scoop_and_buckets(environment, out, err);
}

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

const std::vector<KnownBucket>& builtin_known_buckets() {
    static const std::vector<KnownBucket> buckets = {
        {"main", "https://github.com/ScoopInstaller/Main"},
        {"extras", "https://github.com/ScoopInstaller/Extras"},
        {"versions", "https://github.com/ScoopInstaller/Versions"},
        {"nirsoft", "https://github.com/ScoopInstaller/Nirsoft"},
        {"sysinternals", "https://github.com/ScoopInstaller/Sysinternals"},
        {"php", "https://github.com/ScoopInstaller/PHP"},
        {"nerd-fonts", "https://github.com/ScoopInstaller/Nerd-Fonts"},
        {"nonportable", "https://github.com/ScoopInstaller/Nonportable"},
        {"java", "https://github.com/ScoopInstaller/Java"},
        {"games", "https://github.com/ScoopInstaller/Games"},
    };
    return buckets;
}

std::optional<std::string> builtin_known_bucket_repository(const std::string& name) {
    const auto normalized = lower_ascii(name);
    for (const auto& bucket : builtin_known_buckets()) {
        if (lower_ascii(bucket.name) == normalized) {
            return bucket.repository;
        }
    }
    return std::nullopt;
}

const nlohmann::json* json_property(const nlohmann::json& object, const char* key) {
    if (!object.is_object()) {
        return nullptr;
    }

    if (const auto exact = object.find(key); exact != object.end()) {
        return &*exact;
    }

    const auto normalized = lower_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            return &*it;
        }
    }
    return nullptr;
}

const nlohmann::json* json_property(const nlohmann::json& object, const std::string& key) {
    return json_property(object, key.c_str());
}

nlohmann::json* mutable_json_property(nlohmann::json& object, const char* key) {
    if (!object.is_object()) {
        return nullptr;
    }

    if (auto exact = object.find(key); exact != object.end()) {
        return &*exact;
    }

    const auto normalized = lower_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            return &*it;
        }
    }
    return nullptr;
}

nlohmann::json* mutable_json_property(nlohmann::json& object, const std::string& key) {
    return mutable_json_property(object, key.c_str());
}

void set_json_property(nlohmann::json& object, const std::string& key, const nlohmann::json& value) {
    if (const auto exact = object.find(key); exact != object.end()) {
        exact.value() = value;
        return;
    }

    const auto normalized = lower_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            it.value() = value;
            return;
        }
    }
    object[key] = value;
}

const nlohmann::ordered_json* ordered_json_property(const nlohmann::ordered_json& object, const char* key) {
    if (!object.is_object()) {
        return nullptr;
    }

    if (const auto exact = object.find(key); exact != object.end()) {
        return &*exact;
    }

    const auto normalized = lower_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            return &*it;
        }
    }
    return nullptr;
}

const nlohmann::ordered_json* ordered_json_property(const nlohmann::ordered_json& object, const std::string& key) {
    return ordered_json_property(object, key.c_str());
}

nlohmann::ordered_json* mutable_ordered_json_property(nlohmann::ordered_json& object, const char* key) {
    if (!object.is_object()) {
        return nullptr;
    }

    if (auto exact = object.find(key); exact != object.end()) {
        return &*exact;
    }

    const auto normalized = lower_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            return &*it;
        }
    }
    return nullptr;
}

nlohmann::ordered_json* mutable_ordered_json_property(nlohmann::ordered_json& object, const std::string& key) {
    return mutable_ordered_json_property(object, key.c_str());
}

void set_ordered_json_property(nlohmann::ordered_json& object, const std::string& key, const nlohmann::ordered_json& value) {
    if (const auto exact = object.find(key); exact != object.end()) {
        exact.value() = value;
        return;
    }

    const auto normalized = lower_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            it.value() = value;
            return;
        }
    }
    object[key] = value;
}

bool powershell_truthy_ordered_json(const nlohmann::ordered_json& value) {
    if (value.is_null()) {
        return false;
    }
    if (value.is_boolean()) {
        return value.get<bool>();
    }
    if (value.is_number_unsigned()) {
        return value.get<unsigned long long>() != 0;
    }
    if (value.is_number_integer()) {
        return value.get<long long>() != 0;
    }
    if (value.is_number_float()) {
        return value.get<double>() != 0.0;
    }
    if (value.is_string()) {
        return !value.get<std::string>().empty();
    }
    if (value.is_array()) {
        if (value.empty()) {
            return false;
        }
        if (value.size() == 1) {
            return powershell_truthy_ordered_json(value.front());
        }
        return true;
    }
    return true;
}

std::string app_name_from_reference(const std::string& reference) {
    const auto slash = reference.find_last_of("/\\");
    auto name = slash == std::string::npos ? reference : reference.substr(slash + 1);
    if (lower_ascii(std::filesystem::path(name).extension().string()) == ".json") {
        name = std::filesystem::path(name).stem().string();
    }
    return name;
}

bool ascii_equal_ignore_case(const std::string& lhs, const std::string& rhs) {
    return lower_ascii(lhs) == lower_ascii(rhs);
}

struct HelperOptionToken {
    std::string name;
    std::optional<std::string> inline_value;
};

std::optional<HelperOptionToken> parse_helper_option_token(const std::string& argument) {
    if (argument.empty() || argument[0] != '-') {
        return std::nullopt;
    }

    auto name = argument;
    while (!name.empty() && name.front() == '-') {
        name.erase(name.begin());
    }

    std::optional<std::string> inline_value;
    if (const auto separator = name.find_first_of(":="); separator != std::string::npos) {
        inline_value = name.substr(separator + 1);
        name.erase(separator);
    }

    name = lower_ascii(std::move(name));
    return HelperOptionToken{.name = std::move(name), .inline_value = std::move(inline_value)};
}

bool helper_option_name_matches(const std::string& name, std::initializer_list<std::string_view> names) {
    for (const auto expected : names) {
        if (name == expected) {
            return true;
        }
    }
    return false;
}

bool is_helper_option(const std::string& argument, std::initializer_list<std::string_view> names) {
    const auto parsed = parse_helper_option_token(argument);
    return parsed && helper_option_name_matches(parsed->name, names);
}

enum class HelperSwitchParse {
    NotMatched,
    Parsed,
    Error,
};

std::optional<bool> parse_helper_bool_value(std::string value) {
    value = lower_ascii(std::move(value));
    if (!value.empty() && value.front() == '$') {
        value.erase(value.begin());
    }

    if (value == "true" || value == "1") {
        return true;
    }
    if (value == "false" || value == "0") {
        return false;
    }
    return std::nullopt;
}

HelperSwitchParse parse_helper_switch_option(
    const std::string& argument,
    std::initializer_list<std::string_view> names,
    const std::string& command,
    bool& enabled,
    std::ostream& err) {
    const auto parsed = parse_helper_option_token(argument);
    if (!parsed || !helper_option_name_matches(parsed->name, names)) {
        return HelperSwitchParse::NotMatched;
    }

    if (!parsed->inline_value) {
        enabled = true;
        return HelperSwitchParse::Parsed;
    }

    const auto bool_value = parse_helper_bool_value(*parsed->inline_value);
    if (!bool_value) {
        err << "sco " << command << ": " << argument << " must be a boolean value.\n";
        return HelperSwitchParse::Error;
    }

    enabled = *bool_value;
    return HelperSwitchParse::Parsed;
}

struct HelperAppDirBinding {
    std::string app_pattern = "*";
    bool app_set = false;
    std::filesystem::path dir;
    bool dir_set = false;
    std::vector<std::string> positionals;
};

void bind_helper_app_dir_positionals(HelperAppDirBinding& binding) {
    for (const auto& positional : binding.positionals) {
        if (!binding.app_set) {
            binding.app_pattern = positional;
            binding.app_set = true;
            continue;
        }
        if (!binding.dir_set) {
            binding.dir = positional;
            binding.dir_set = true;
            continue;
        }
        break;
    }
}

bool take_helper_option_value(
    const std::vector<std::string>& args,
    std::size_t& index,
    const std::string& command,
    const std::string& option,
    std::string& value,
    std::ostream& err) {
    if (const auto parsed = parse_helper_option_token(option); parsed && parsed->inline_value) {
        value = *parsed->inline_value;
        return true;
    }

    if (index + 1 >= args.size()) {
        err << "sco " << command << ": " << option << " requires an argument.\n";
        return false;
    }
    value = args[++index];
    return true;
}

bool require_helper_dir(const std::string& command, const std::filesystem::path& dir, std::ostream& err) {
    if (!dir.empty()) {
        return true;
    }
    err << "sco " << command << ": Cannot process command because of one or more missing mandatory parameters: Dir.\n";
    return false;
}

enum class HelperOptionParse {
    NotMatched,
    Parsed,
    Error,
};

HelperOptionParse parse_helper_app_dir_option(
    const std::vector<std::string>& args,
    std::size_t& index,
    const std::string& command,
    HelperAppDirBinding& binding,
    std::ostream& err) {
    const auto& arg = args[index];
    std::string value;
    if (is_helper_option(arg, {"app"})) {
        if (!take_helper_option_value(args, index, command, arg, value, err)) {
            return HelperOptionParse::Error;
        }
        binding.app_pattern = value;
        binding.app_set = true;
        return HelperOptionParse::Parsed;
    }
    if (is_helper_option(arg, {"dir"})) {
        if (!take_helper_option_value(args, index, command, arg, value, err)) {
            return HelperOptionParse::Error;
        }
        binding.dir = value;
        binding.dir_set = true;
        return HelperOptionParse::Parsed;
    }
    return HelperOptionParse::NotMatched;
}

struct ParsedCreateUrl {
    std::string scheme;
    std::string host;
    std::vector<std::string> segments;
    std::string filename;
};

std::optional<ParsedCreateUrl> parse_create_url(const std::string& url) {
    static const std::regex pattern(R"(^([a-zA-Z][a-zA-Z0-9+.-]*):(?://([^/?#]*))?([^?#]*).*$)");
    std::smatch match;
    if (!std::regex_match(url, match, pattern)) {
        return std::nullopt;
    }

    ParsedCreateUrl parsed;
    parsed.scheme = match[1].str();
    parsed.host = match[2].str();
    if (url.substr(parsed.scheme.size() + 1, 2) == "//" && parsed.host.empty()) {
        return std::nullopt;
    }
    auto path = match[3].str();
    std::replace(path.begin(), path.end(), '\\', '/');
    std::stringstream stream(path);
    std::string segment;
    while (std::getline(stream, segment, '/')) {
        if (!segment.empty()) {
            parsed.segments.push_back(segment);
        }
    }
    if (!parsed.segments.empty()) {
        parsed.filename = parsed.segments.back();
    }
    return parsed;
}

std::string strip_known_archive_extensions(std::string name) {
    const auto lower = lower_ascii(name);
    for (const auto& extension : {".tar.gz", ".tar.bz2", ".tar.xz", ".zip", ".7z", ".gz", ".bz2", ".xz", ".exe", ".msi"}) {
        if (lower.ends_with(extension)) {
            name.erase(name.size() - std::string_view(extension).size());
            break;
        }
    }
    return name;
}

std::string strip_final_extension(std::string name) {
    const auto dot = name.find_last_of('.');
    if (dot != std::string::npos) {
        name.erase(dot);
    }
    return name;
}

std::string strip_create_filename_extension(std::string name) {
    auto stripped = strip_known_archive_extensions(name);
    if (stripped != name) {
        return stripped;
    }
    return strip_final_extension(std::move(name));
}

std::string sanitize_manifest_name(std::string value) {
    value = strip_known_archive_extensions(std::filesystem::path(value).filename().string());
    std::string name;
    for (const unsigned char ch : value) {
        if (std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.') {
            name.push_back(static_cast<char>(std::tolower(ch)));
        } else if (ch == ' ') {
            name.push_back('-');
        }
    }
    while (!name.empty() && (name.back() == '-' || name.back() == '_' || name.back() == '.')) {
        name.pop_back();
    }
    return name.empty() ? std::string{"app"} : name;
}

bool looks_like_version(const std::string& value) {
    static const std::regex version_pattern(R"((?:v|version-)?[0-9]+(?:[._-][0-9A-Za-z]+)+)", std::regex_constants::icase);
    return std::regex_search(value, version_pattern);
}

std::string clean_version_token(std::string value) {
    value = strip_known_archive_extensions(value);
    const auto lower = lower_ascii(value);
    if (lower.rfind("version-", 0) == 0) {
        value.erase(0, 8);
    } else if (lower.rfind('v', 0) == 0 && value.size() > 1 && std::isdigit(static_cast<unsigned char>(value[1]))) {
        value.erase(0, 1);
    }
    return value;
}

std::string infer_version_from_url(const ParsedCreateUrl& parsed) {
    for (auto it = parsed.segments.rbegin(); it != parsed.segments.rend(); ++it) {
        auto candidate = strip_known_archive_extensions(*it);
        if (!looks_like_version(candidate)) {
            continue;
        }

        std::smatch match;
        static const std::regex embedded(R"((?:v|version-)?[0-9]+(?:[._-][0-9A-Za-z]+)+)", std::regex_constants::icase);
        if (std::regex_search(candidate, match, embedded)) {
            return clean_version_token(match.str());
        }
    }
    return {};
}

std::string infer_name_from_url(const ParsedCreateUrl& parsed) {
    auto base = strip_create_filename_extension(parsed.filename.empty() ? parsed.host : parsed.filename);
    const auto version = infer_version_from_url(parsed);
    if (!version.empty()) {
        const auto lower_base = lower_ascii(base);
        const auto lower_version = lower_ascii(version);
        const auto pos = lower_base.rfind(lower_version);
        if (pos != std::string::npos) {
            base.erase(pos, version.size());
        }
        if (!base.empty() && (base.back() == '-' || base.back() == '_' || base.back() == '.')) {
            base.pop_back();
        }
    }
    return sanitize_manifest_name(base);
}

struct AppVersionReference {
    std::string app;
    std::string version;
};

AppVersionReference parse_app_version_reference(const std::string& reference) {
    static const std::regex scoop_app_pattern(R"(^(?:([a-zA-Z0-9\-_.]+)/)?(.*\.json|[a-zA-Z0-9\-_.]+)(?:@(.*))?$)", std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_match(reference, match, scoop_app_pattern) || !match[3].matched) {
        return {.app = reference, .version = {}};
    }

    const auto version_start = static_cast<std::size_t>(match.position(3));
    return {.app = reference.substr(0, version_start - 1), .version = match[3].str()};
}

std::string version_substitution_value(const std::string& version, const std::string& key) {
    auto first_part = version;
    if (const auto dash = first_part.find('-'); dash != std::string::npos) {
        first_part.erase(dash);
    }

    std::vector<std::string> parts;
    std::stringstream stream(first_part);
    std::string part;
    while (std::getline(stream, part, '.')) {
        parts.push_back(part);
    }

    if (key == "$version") {
        return version;
    }
    if (key == "$dotVersion") {
        auto value = version;
        std::replace(value.begin(), value.end(), '_', '.');
        std::replace(value.begin(), value.end(), '-', '.');
        return value;
    }
    if (key == "$underscoreVersion") {
        auto value = version;
        std::replace(value.begin(), value.end(), '.', '_');
        std::replace(value.begin(), value.end(), '-', '_');
        return value;
    }
    if (key == "$dashVersion") {
        auto value = version;
        std::replace(value.begin(), value.end(), '.', '-');
        std::replace(value.begin(), value.end(), '_', '-');
        return value;
    }
    if (key == "$cleanVersion") {
        auto value = version;
        value.erase(std::remove_if(value.begin(), value.end(), [](char ch) {
            return ch == '.' || ch == '_' || ch == '-';
        }), value.end());
        return value;
    }
    if (key == "$majorVersion") {
        return parts.size() > 0 ? parts[0] : std::string{};
    }
    if (key == "$minorVersion") {
        return parts.size() > 1 ? parts[1] : std::string{};
    }
    if (key == "$patchVersion") {
        return parts.size() > 2 ? parts[2] : std::string{};
    }
    if (key == "$buildVersion") {
        return parts.size() > 3 ? parts[3] : std::string{};
    }
    if (key == "$preReleaseVersion") {
        if (const auto dash = version.find('-'); dash != std::string::npos && dash + 1 < version.size()) {
            return version.substr(dash + 1);
        }
        return version;
    }
    if (key == "$matchHead") {
        std::smatch match;
        static const std::regex pattern(R"((\d+\.\d+(?:\.\d+)?)(.*))");
        return std::regex_match(version, match, pattern) ? match[1].str() : std::string{};
    }
    if (key == "$matchTail") {
        std::smatch match;
        static const std::regex pattern(R"((\d+\.\d+(?:\.\d+)?)(.*))");
        return std::regex_match(version, match, pattern) ? match[2].str() : std::string{};
    }
    return {};
}

std::string substitute_version_tokens(std::string value, const std::string& version) {
    for (const auto& key : {
             "$underscoreVersion", "$majorVersion", "$minorVersion", "$patchVersion", "$buildVersion",
             "$preReleaseVersion", "$cleanVersion", "$dashVersion", "$dotVersion", "$matchHead", "$matchTail", "$version"}) {
        std::string token = key;
        const auto replacement = version_substitution_value(version, token);
        std::size_t pos = 0;
        while ((pos = value.find(token, pos)) != std::string::npos) {
            value.replace(pos, token.size(), replacement);
            pos += replacement.size();
        }
    }
    return value;
}

std::string strip_url_fragment(std::string url) {
    if (const auto fragment = url.find('#'); fragment != std::string::npos) {
        url.erase(fragment);
    }
    return url;
}

std::string strip_url_filename_for_header(const std::string& url) {
    const auto clean = strip_url_fragment(url);
    const auto slash = clean.find_last_of('/');
    return slash == std::string::npos ? std::string{} : clean.substr(0, slash);
}

std::string strip_url_query_and_fragment(std::string url) {
    url = strip_url_fragment(std::move(url));
    if (const auto query = url.find('?'); query != std::string::npos) {
        url.erase(query);
    }
    return url;
}

std::string strip_url_filename(const std::string& url) {
    const auto clean = strip_url_fragment(url);
    const auto slash = clean.find_last_of("/\\");
    return slash == std::string::npos ? std::string{} : clean.substr(0, slash);
}

std::string strip_url_extension(const std::string& url) {
    auto clean = strip_url_query_and_fragment(url);
    const auto slash = clean.find_last_of("/\\");
    const auto dot = clean.find_last_of('.');
    if (dot != std::string::npos && (slash == std::string::npos || dot > slash)) {
        clean.erase(dot);
    }
    return clean;
}

std::string remote_filename_from_url(const std::string& url) {
    const auto clean = strip_url_query_and_fragment(url);
    const auto slash = clean.find_last_of("/\\");
    return slash == std::string::npos ? clean : clean.substr(slash + 1);
}

std::string substitute_autoupdate_tokens(std::string value, const std::string& version, const std::string& url = {}) {
    value = substitute_version_tokens(std::move(value), version);
    if (url.empty()) {
        return value;
    }

    const auto basename = remote_filename_from_url(url);
    const std::vector<std::pair<std::string, std::string>> substitutions{
        {"$urlNoExt", strip_url_extension(url)},
        {"$basenameNoExt", std::filesystem::path(basename).stem().string()},
        {"$baseurl", strip_url_filename(url)},
        {"$basename", basename},
        {"$url", strip_url_fragment(url)},
    };
    for (const auto& [token, replacement] : substitutions) {
        std::size_t pos = 0;
        while ((pos = value.find(token, pos)) != std::string::npos) {
            value.replace(pos, token.size(), replacement);
            pos += replacement.size();
        }
    }
    return value;
}

std::string substitute_hash_regex_templates(std::string value) {
    const std::vector<std::pair<std::string, std::string>> templates{
        {"$sha512", "([A-Fa-f0-9]{128})"},
        {"$sha256", "([A-Fa-f0-9]{64})"},
        {"$sha1", "([A-Fa-f0-9]{40})"},
        {"$md5", "([A-Fa-f0-9]{32})"},
        {"$base64", "([A-Za-z0-9+/=]{24,88})"},
    };

    for (const auto& [token, replacement] : templates) {
        std::size_t pos = 0;
        while ((pos = value.find(token, pos)) != std::string::npos) {
            value.replace(pos, token.size(), replacement);
            pos += replacement.size();
        }
    }
    return value;
}

std::string regex_escape(const std::string& value) {
    static constexpr std::string_view metacharacters = R"(\.^$|()[]{}*+?)";
    std::string escaped;
    escaped.reserve(value.size());
    for (const auto ch : value) {
        if (metacharacters.find(ch) != std::string_view::npos) {
            escaped.push_back('\\');
        }
        escaped.push_back(ch);
    }
    return escaped;
}

std::string extract_hash_from_text(const std::string& text, const std::string& regex_pattern) {
    const auto pattern = regex_pattern.empty()
        ? std::regex(R"(([A-Fa-f0-9]{128}|[A-Fa-f0-9]{64}|[A-Fa-f0-9]{40}|[A-Fa-f0-9]{32}))")
        : std::regex(regex_pattern, std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_search(text, match, pattern)) {
        return {};
    }
    return match.size() > 1 ? match[1].str() : match[0].str();
}

std::optional<int> base64_value(char ch) {
    if (ch >= 'A' && ch <= 'Z') {
        return ch - 'A';
    }
    if (ch >= 'a' && ch <= 'z') {
        return ch - 'a' + 26;
    }
    if (ch >= '0' && ch <= '9') {
        return ch - '0' + 52;
    }
    if (ch == '+') {
        return 62;
    }
    if (ch == '/') {
        return 63;
    }
    return std::nullopt;
}

std::optional<std::vector<unsigned char>> decode_base64_hash(std::string value) {
    value.erase(std::remove_if(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), value.end());
    if (value.empty() || value.size() % 4 != 0) {
        return std::nullopt;
    }

    std::vector<unsigned char> bytes;
    bytes.reserve((value.size() / 4) * 3);
    for (std::size_t i = 0; i < value.size(); i += 4) {
        const auto a = base64_value(value[i]);
        const auto b = base64_value(value[i + 1]);
        if (!a || !b) {
            return std::nullopt;
        }

        const auto padding_c = value[i + 2] == '=';
        const auto padding_d = value[i + 3] == '=';
        if (padding_c && !padding_d) {
            return std::nullopt;
        }
        const auto c = padding_c ? std::optional<int>{0} : base64_value(value[i + 2]);
        const auto d = padding_d ? std::optional<int>{0} : base64_value(value[i + 3]);
        if (!c || !d) {
            return std::nullopt;
        }
        if ((padding_c || padding_d) && i + 4 != value.size()) {
            return std::nullopt;
        }

        const auto triple = (*a << 18) | (*b << 12) | (*c << 6) | *d;
        bytes.push_back(static_cast<unsigned char>((triple >> 16) & 0xff));
        if (!padding_c) {
            bytes.push_back(static_cast<unsigned char>((triple >> 8) & 0xff));
        }
        if (!padding_d) {
            bytes.push_back(static_cast<unsigned char>(triple & 0xff));
        }
    }

    return bytes;
}

std::string bytes_to_hex(const std::vector<unsigned char>& bytes) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        out.push_back(hex[(byte >> 4) & 0xf]);
        out.push_back(hex[byte & 0xf]);
    }
    return out;
}

std::string normalize_autoupdate_hash(std::string hash) {
    if (const auto colon = hash.find(':'); colon != std::string::npos) {
        hash = hash.substr(colon + 1);
    }
    hash.erase(std::remove_if(hash.begin(), hash.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), hash.end());
    const auto is_hex = std::all_of(hash.begin(), hash.end(), [](unsigned char ch) {
        return std::isxdigit(ch) != 0;
    });
    if (is_hex && (hash.size() == 32 || hash.size() == 40 || hash.size() == 64 || hash.size() == 128)) {
        std::transform(hash.begin(), hash.end(), hash.begin(), [](unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
    } else if (const auto decoded = decode_base64_hash(hash)) {
        hash = bytes_to_hex(*decoded);
    } else {
        std::transform(hash.begin(), hash.end(), hash.begin(), [](unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
    }
    if (hash.size() == 32) {
        return "md5:" + hash;
    }
    if (hash.size() == 40) {
        return "sha1:" + hash;
    }
    if (hash.size() == 128) {
        return "sha512:" + hash;
    }
    return hash;
}

void collect_json_field_values(const nlohmann::json& value, const std::string& field, std::vector<std::string>& values) {
    if (value.is_object()) {
        if (value.contains(field) && value.at(field).is_string()) {
            values.push_back(value.at(field).get<std::string>());
        }
        for (const auto& item : value.items()) {
            collect_json_field_values(item.value(), field, values);
        }
    } else if (value.is_array()) {
        for (const auto& item : value) {
            collect_json_field_values(item, field, values);
        }
    }
}

std::optional<std::string> json_pointer_like_value(const nlohmann::json& root, std::string path) {
    if (path.rfind("$.", 0) == 0) {
        path.erase(0, 2);
    } else if (path == "$") {
        return root.is_string() ? std::optional<std::string>{root.get<std::string>()} : std::nullopt;
    } else {
        return std::nullopt;
    }

    const nlohmann::json* current = &root;
    std::stringstream stream(path);
    std::string segment;
    while (std::getline(stream, segment, '.')) {
        if (segment.empty()) {
            return std::nullopt;
        }

        std::optional<std::size_t> index;
        if (const auto open = segment.find('['); open != std::string::npos && segment.ends_with(']')) {
            const auto text = segment.substr(open + 1, segment.size() - open - 2);
            segment.erase(open);
            if (!text.empty() && std::all_of(text.begin(), text.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; })) {
                index = static_cast<std::size_t>(std::stoull(text));
            }
        }

        if (!segment.empty()) {
            if (!current->is_object() || !current->contains(segment)) {
                return std::nullopt;
            }
            current = &current->at(segment);
        }
        if (index) {
            if (!current->is_array() || *index >= current->size()) {
                return std::nullopt;
            }
            current = &current->at(*index);
        }
    }

    if (current->is_string()) {
        return current->get<std::string>();
    }
    if (current->is_number_integer()) {
        return std::to_string(current->get<long long>());
    }
    return std::nullopt;
}

std::optional<std::string> json_scalar_text(const nlohmann::json& value) {
    if (value.is_string()) {
        return value.get<std::string>();
    }
    if (value.is_number_integer()) {
        return std::to_string(value.get<long long>());
    }
    return std::nullopt;
}

std::optional<std::string> json_filter_value(const nlohmann::json& root, const std::string& jsonpath) {
    static const std::regex filter_pattern(R"(^\$\.([A-Za-z0-9_]+)\[\?\(@\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'\)\]\.([A-Za-z0-9_]+)$)");
    std::smatch match;
    if (!std::regex_match(jsonpath, match, filter_pattern)) {
        return std::nullopt;
    }

    const auto array_field = match[1].str();
    const auto filter_field = match[2].str();
    const auto filter_value = match[3].str();
    const auto result_field = match[4].str();
    if (!root.is_object() || !root.contains(array_field) || !root.at(array_field).is_array()) {
        return std::nullopt;
    }

    for (const auto& item : root.at(array_field)) {
        if (!item.is_object() || !item.contains(filter_field) || !item.at(filter_field).is_string()) {
            continue;
        }
        if (item.at(filter_field).get<std::string>() == filter_value && item.contains(result_field)) {
            return json_scalar_text(item.at(result_field));
        }
    }
    return std::nullopt;
}

std::optional<std::string> recursive_json_filter_value(
    const nlohmann::json& value,
    const std::string& array_field,
    const std::string& filter_field,
    const std::string& filter_value,
    const std::string& result_field) {
    if (value.is_object()) {
        if (value.contains(array_field) && value.at(array_field).is_array()) {
            for (const auto& item : value.at(array_field)) {
                if (!item.is_object() || !item.contains(filter_field) || !item.at(filter_field).is_string()) {
                    continue;
                }
                if (item.at(filter_field).get<std::string>() == filter_value && item.contains(result_field)) {
                    if (const auto result = json_scalar_text(item.at(result_field))) {
                        return result;
                    }
                }
            }
        }
        for (const auto& item : value.items()) {
            if (const auto result = recursive_json_filter_value(item.value(), array_field, filter_field, filter_value, result_field)) {
                return result;
            }
        }
    } else if (value.is_array()) {
        for (const auto& item : value) {
            if (const auto result = recursive_json_filter_value(item, array_field, filter_field, filter_value, result_field)) {
                return result;
            }
        }
    }
    return std::nullopt;
}

std::optional<std::string> json_recursive_filter_value(const nlohmann::json& root, const std::string& jsonpath) {
    static const std::regex filter_pattern(R"(^\$\.\.([A-Za-z0-9_]+)\[\?\(@\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'\)\]\.([A-Za-z0-9_]+)$)");
    std::smatch match;
    if (!std::regex_match(jsonpath, match, filter_pattern)) {
        return std::nullopt;
    }
    return recursive_json_filter_value(root, match[1].str(), match[2].str(), match[3].str(), match[4].str());
}

std::optional<std::string> extract_jsonpath_value(const std::string& text, const std::string& jsonpath) {
    const auto root = nlohmann::json::parse(text);
    if (const auto filtered = json_filter_value(root, jsonpath)) {
        return *filtered;
    }
    if (const auto filtered = json_recursive_filter_value(root, jsonpath)) {
        return *filtered;
    }
    if (jsonpath.rfind("$..", 0) == 0 && jsonpath.find_first_of("[]()?") == std::string::npos) {
        std::vector<std::string> values;
        collect_json_field_values(root, jsonpath.substr(3), values);
        if (!values.empty()) {
            return values.front();
        }
        return std::nullopt;
    }
    return json_pointer_like_value(root, jsonpath);
}

std::optional<std::string> extract_xpath_value(const std::string& text, const std::string& xpath) {
    return select_xml_xpath_text(text, xpath, "autoupdate hash XML", "autoupdate hash xpath");
}

void set_request_header(std::vector<std::pair<std::string, std::string>>& headers, std::string name, std::string value) {
    const auto normalized = lower_ascii(name);
    for (auto& header : headers) {
        if (lower_ascii(header.first) == normalized) {
            header.second = std::move(value);
            return;
        }
    }
    headers.emplace_back(std::move(name), std::move(value));
}

std::optional<std::string> configured_github_token(const Environment& environment) {
    if (const char* token = std::getenv("SCOOP_GH_TOKEN"); token != nullptr && token[0] != '\0') {
        return std::string(token);
    }

    const auto configured = ConfigStore(environment.config_file).get("gh_token");
    if (configured && configured->is_string() && !configured->get<std::string>().empty()) {
        return configured->get<std::string>();
    }
    return std::nullopt;
}

std::vector<std::pair<std::string, std::string>> github_metadata_headers(const Environment& environment) {
    if (const auto token = configured_github_token(environment)) {
        return {{"Authorization", "token " + *token}};
    }
    return {};
}

std::string read_autoupdate_text_source(
    const Environment& environment,
    const std::string& source,
    const std::filesystem::path& manifest_dir,
    const std::vector<std::pair<std::string, std::string>>& extra_headers = {}) {
    if (looks_like_http_url(source)) {
        const HttpClient client;
        std::vector<std::pair<std::string, std::string>> headers{{"Referer", strip_url_filename_for_header(source)}, {"User-Agent", "sco"}};
        for (const auto& header : extra_headers) {
            set_request_header(headers, header.first, header.second);
        }
        apply_private_host_headers(ConfigStore(environment.config_file), source, headers);
        const auto response = client.get(source, headers);
        if (response.status < 200 || response.status >= 300) {
            throw std::runtime_error("hash extraction download failed for " + source + ": " + (response.error.empty() ? std::to_string(response.status) : response.error));
        }
        return decompress_gzip_if_needed(response.body);
    }

    auto path = std::filesystem::path(source);
    if (path.is_relative()) {
        path = manifest_dir / path;
    }
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("hash extraction file does not exist: " + path.string());
    }
    const std::string data{std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    return decompress_gzip_if_needed(data);
}

std::optional<std::string> resolve_autoupdate_metalink_hash(const Environment& environment, const std::string& url, const std::filesystem::path& manifest_dir) {
    if (looks_like_http_url(url)) {
        const HttpClient client;
        const auto response = client.head_no_redirect(strip_url_fragment(url), {{"User-Agent", "sco"}});
        if (response.status >= 300 && response.status < 400) {
            if (const auto digest = response.headers.find("digest"); digest != response.headers.end()) {
                static const std::regex digest_pattern(R"((?:SHA-256|SHA|MD5)=([^,]+))", std::regex_constants::icase);
                std::smatch match;
                if (std::regex_search(digest->second, match, digest_pattern)) {
                    return normalize_autoupdate_hash(match[1].str());
                }
            }
        }
    }

    const auto text = read_autoupdate_text_source(environment, url + ".meta4", manifest_dir);
    auto hash = extract_hash_from_text(text, R"(<hash[^>]*>\s*([A-Fa-f0-9]{64})\s*</hash>)");
    if (hash.empty()) {
        hash = extract_hash_from_text(text, {});
    }
    if (hash.empty()) {
        return std::nullopt;
    }
    return normalize_autoupdate_hash(std::move(hash));
}

std::optional<std::string> resolve_autoupdate_rdf_hash(const Environment& environment, const std::string& hash_url, const std::string& url, const std::filesystem::path& manifest_dir) {
    const auto text = read_autoupdate_text_source(environment, hash_url, manifest_dir);
    const auto basename = remote_filename_from_url(url);

    pugi::xml_document document;
    const auto result = document.load_buffer(text.data(), text.size());
    if (!result) {
        throw std::runtime_error("cannot parse autoupdate hash RDF: " + std::string(result.description()));
    }

    for (auto content : document.select_nodes("//*[local-name()='Content']")) {
        const auto node = content.node();
        const auto about = node.attribute("about") ? node.attribute("about").value() : node.attribute("rdf:about").value();
        if (basename != about) {
            continue;
        }
        for (auto child : node.children()) {
            if (std::string(child.name()).ends_with("sha256")) {
                const auto hash = std::string(child.text().as_string());
                if (!hash.empty()) {
                    return normalize_autoupdate_hash(hash);
                }
            }
        }
    }
    return std::nullopt;
}

std::optional<std::string> sourceforge_metadata_url(std::string url) {
    url = strip_url_fragment(std::move(url));
    std::replace(url.begin(), url.end(), '\\', '/');

    static const std::regex pattern(R"((?:https?://)?(?:downloads\.)?sourceforge\.net/projects?/([^/]+)/(?:files/)?([^?#]+))", std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_search(url, match, pattern)) {
        return std::nullopt;
    }

    auto file = match[2].str();
    if (const auto slash = file.find_last_of('/'); slash != std::string::npos) {
        file.erase(slash);
    } else {
        file.clear();
    }

    auto metadata = "https://sourceforge.net/projects/" + match[1].str() + "/files";
    if (!file.empty()) {
        metadata += "/" + file;
    }
    while (!metadata.empty() && metadata.back() == '/') {
        metadata.pop_back();
    }
    return metadata;
}

std::optional<std::string> resolve_autoupdate_sourceforge_hash(const Environment& environment, const std::string& hash_url, const std::string& url, const std::filesystem::path& manifest_dir) {
    const auto metadata_url = hash_url.empty() ? sourceforge_metadata_url(url) : std::optional<std::string>{hash_url};
    if (!metadata_url || metadata_url->empty()) {
        return std::nullopt;
    }

    const auto text = read_autoupdate_text_source(environment, *metadata_url, manifest_dir);
    const auto pattern = "\\\"" + regex_escape(remote_filename_from_url(url)) + "\\\"[\\s\\S]*?\\\"sha1\\\"\\s*:\\s*\\\"([A-Fa-f0-9]{40})\\\"";
    auto hash = extract_hash_from_text(text, pattern);
    if (hash.empty()) {
        return std::nullopt;
    }
    return normalize_autoupdate_hash(std::move(hash));
}

std::optional<std::string> fosshub_filename_from_url(std::string url) {
    url = strip_url_fragment(std::move(url));
    std::replace(url.begin(), url.end(), '\\', '/');

    const auto lower = lower_ascii(url);
    if (lower.find("fosshub.com/") == std::string::npos) {
        return std::nullopt;
    }

    if (const auto marker = lower.find("?dwl="); marker != std::string::npos) {
        auto filename = url.substr(marker + 5);
        if (const auto separator = filename.find('&'); separator != std::string::npos) {
            filename.erase(separator);
        }
        return filename.empty() ? std::nullopt : std::optional<std::string>{filename};
    }

    const auto clean = strip_url_query_and_fragment(url);
    const auto slash = clean.find_last_of('/');
    if (slash == std::string::npos || slash + 1 >= clean.size()) {
        return std::nullopt;
    }
    return clean.substr(slash + 1);
}

std::optional<std::string> resolve_autoupdate_fosshub_hash(const Environment& environment, const std::string& hash_url, const std::string& url, const std::filesystem::path& manifest_dir) {
    const auto filename = fosshub_filename_from_url(url);
    if (!filename || filename->empty()) {
        return std::nullopt;
    }

    const auto source = hash_url.empty() ? url : hash_url;
    const auto text = read_autoupdate_text_source(environment, source, manifest_dir);
    const auto pattern = regex_escape(*filename) + "[\\s\\S]*?\\\"sha256\\\"\\s*:\\s*\\\"([A-Fa-f0-9]{64})\\\"";
    auto hash = extract_hash_from_text(text, pattern);
    if (hash.empty()) {
        return std::nullopt;
    }
    return normalize_autoupdate_hash(std::move(hash));
}

std::optional<std::string> github_releases_api_url(const std::string& url) {
    static const std::regex pattern(R"(^https://github\.com/([^/]+)/([^/]+)/releases/download/[^/]+/[^/?#]+)", std::regex_constants::icase);
    std::smatch match;
    const auto clean = strip_url_fragment(url);
    if (!std::regex_search(clean, match, pattern)) {
        return std::nullopt;
    }
    return "https://api.github.com/repos/" + match[1].str() + "/" + match[2].str() + "/releases";
}

std::optional<std::string> resolve_autoupdate_github_hash(const Environment& environment, const std::string& hash_url, const std::string& url, const std::filesystem::path& manifest_dir) {
    const auto metadata_url = hash_url.empty() ? github_releases_api_url(url) : std::optional<std::string>{hash_url};
    if (!metadata_url || metadata_url->empty()) {
        return std::nullopt;
    }

    const auto text = read_autoupdate_text_source(environment, *metadata_url, manifest_dir, github_metadata_headers(environment));
    const auto jsonpath = "$..assets[?(@.browser_download_url == '" + strip_url_fragment(url) + "')].digest";
    auto hash = extract_jsonpath_value(text, jsonpath).value_or(std::string{});
    if (hash.empty()) {
        return std::nullopt;
    }
    return normalize_autoupdate_hash(std::move(hash));
}

std::optional<std::string> resolve_autoupdate_hash_object(
    const Environment& environment,
    const nlohmann::json& hash_config,
    const std::string& version,
    const std::string& url,
    const std::filesystem::path& manifest_dir) {
    if (!hash_config.is_object()) {
        return std::nullopt;
    }

    const auto* mode_value = json_property(hash_config, "mode");
    const auto* hash_url_value = json_property(hash_config, "url");
    const auto mode = mode_value != nullptr && mode_value->is_string()
        ? lower_ascii(mode_value->get<std::string>())
        : std::string{};
    const auto hash_url = hash_url_value != nullptr && hash_url_value->is_string()
        ? substitute_autoupdate_tokens(hash_url_value->get<std::string>(), version, url)
        : std::string{};
    if (mode == "sourceforge") {
        return resolve_autoupdate_sourceforge_hash(environment, hash_url, url, manifest_dir);
    }
    if (mode == "fosshub") {
        return resolve_autoupdate_fosshub_hash(environment, hash_url, url, manifest_dir);
    }
    if (mode == "github") {
        return resolve_autoupdate_github_hash(environment, hash_url, url, manifest_dir);
    }
    if (hash_url.empty()) {
        return std::nullopt;
    }

    const auto* find_value = json_property(hash_config, "find");
    const auto* regex_value = json_property(hash_config, "regex");
    const auto* jsonpath_value = json_property(hash_config, "jsonpath");
    const auto* jp_value = json_property(hash_config, "jp");
    const auto* xpath_value = json_property(hash_config, "xpath");
    const auto regex_pattern = find_value != nullptr && find_value->is_string()
        ? substitute_hash_regex_templates(substitute_autoupdate_tokens(find_value->get<std::string>(), version, url))
        : regex_value != nullptr && regex_value->is_string()
        ? substitute_hash_regex_templates(substitute_autoupdate_tokens(regex_value->get<std::string>(), version, url))
        : std::string{};
    const auto jsonpath = jsonpath_value != nullptr && jsonpath_value->is_string()
        ? substitute_autoupdate_tokens(jsonpath_value->get<std::string>(), version, url)
        : jp_value != nullptr && jp_value->is_string()
        ? substitute_autoupdate_tokens(jp_value->get<std::string>(), version, url)
        : std::string{};
    const auto xpath = xpath_value != nullptr && xpath_value->is_string()
        ? substitute_autoupdate_tokens(xpath_value->get<std::string>(), version, url)
        : std::string{};

    if (mode == "rdf") {
        return resolve_autoupdate_rdf_hash(environment, hash_url, url, manifest_dir);
    }

    const auto text = read_autoupdate_text_source(environment, hash_url, manifest_dir);

    auto hash = std::string{};
    if (!jsonpath.empty()) {
        hash = extract_jsonpath_value(text, jsonpath).value_or(std::string{});
    } else if (!xpath.empty()) {
        hash = extract_xpath_value(text, xpath).value_or(std::string{});
    } else {
        hash = extract_hash_from_text(text, regex_pattern);
    }
    if (hash.empty()) {
        throw std::runtime_error("could not find hash in " + hash_url);
    }
    return normalize_autoupdate_hash(std::move(hash));
}

const nlohmann::json* hash_config_for_url(const nlohmann::json& hash_config, std::size_t index) {
    if (hash_config.is_object()) {
        return &hash_config;
    }
    if (!hash_config.is_array() || hash_config.empty()) {
        return nullptr;
    }

    const auto selected = index < hash_config.size() ? index : hash_config.size() - 1;
    return &hash_config.at(selected);
}

bool autoupdate_hash_mode_is_download(const nlohmann::json* hash_config, std::size_t index) {
    if (hash_config == nullptr) {
        return false;
    }
    const auto* config = hash_config_for_url(*hash_config, index);
    const auto* mode = config != nullptr && config->is_object() ? json_property(*config, "mode") : nullptr;
    if (mode == nullptr || !mode->is_string()) {
        return false;
    }
    return lower_ascii(mode->get<std::string>()) == "download";
}

bool autoupdate_hash_mode_is_metalink(const nlohmann::json* hash_config, std::size_t index) {
    if (hash_config == nullptr) {
        return false;
    }
    const auto* config = hash_config_for_url(*hash_config, index);
    const auto* mode = config != nullptr && config->is_object() ? json_property(*config, "mode") : nullptr;
    if (mode == nullptr || !mode->is_string()) {
        return false;
    }
    return lower_ascii(mode->get<std::string>()) == "metalink";
}

bool is_sourceforge_url(const std::string& url) {
    return sourceforge_metadata_url(url).has_value();
}

bool is_fosshub_url(const std::string& url) {
    return fosshub_filename_from_url(url).has_value();
}

bool is_github_release_url(const std::string& url) {
    return github_releases_api_url(url).has_value();
}

bool has_non_null_property(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    return value != nullptr && !value->is_null();
}

bool hash_property_requests_update(const nlohmann::json& object) {
    const auto* value = json_property(object, "hash");
    if (value == nullptr || value->is_null()) {
        return false;
    }
    if (value->is_string()) {
        return !value->get<std::string>().empty();
    }
    if (value->is_array() || value->is_object()) {
        return !value->empty();
    }
    return true;
}

bool is_autoupdate_hash_config_value(const nlohmann::json& value) {
    return value.is_object() || value.is_array();
}

bool is_autoupdate_hash_literal_value(const nlohmann::json& value) {
    return !value.is_null() && !is_autoupdate_hash_config_value(value);
}

std::set<std::string> architectures_with_hash(const nlohmann::json& manifest) {
    std::set<std::string> architectures;
    const auto* architecture = json_property(manifest, "architecture");
    if (architecture == nullptr || !architecture->is_object()) {
        return architectures;
    }

    for (const auto& arch : architecture->items()) {
        if (hash_property_requests_update(arch.value())) {
            architectures.insert(lower_ascii(arch.key()));
        }
    }
    return architectures;
}

nlohmann::json resolve_autoupdate_hash_value(
    const Environment& environment,
    const std::string& app,
    const nlohmann::json* hash_config,
    const nlohmann::json& urls,
    const std::string& version,
    const std::filesystem::path& manifest_dir,
    bool allow_download_fallback) {
    if (urls.is_string()) {
        try {
            if (autoupdate_hash_mode_is_metalink(hash_config, 0)) {
                if (const auto hash = resolve_autoupdate_metalink_hash(environment, urls.get<std::string>(), manifest_dir)) {
                    return *hash;
                }
            }
            if (hash_config != nullptr && !autoupdate_hash_mode_is_download(hash_config, 0)) {
                if (const auto* config = hash_config_for_url(*hash_config, 0)) {
                    if (const auto hash = resolve_autoupdate_hash_object(environment, *config, version, urls.get<std::string>(), manifest_dir)) {
                        return *hash;
                    }
                }
            } else if (hash_config == nullptr && is_sourceforge_url(urls.get<std::string>())) {
                if (const auto hash = resolve_autoupdate_sourceforge_hash(environment, {}, urls.get<std::string>(), manifest_dir)) {
                    return *hash;
                }
            } else if (hash_config == nullptr && is_fosshub_url(urls.get<std::string>())) {
                if (const auto hash = resolve_autoupdate_fosshub_hash(environment, {}, urls.get<std::string>(), manifest_dir)) {
                    return *hash;
                }
            } else if (hash_config == nullptr && is_github_release_url(urls.get<std::string>())) {
                if (const auto hash = resolve_autoupdate_github_hash(environment, {}, urls.get<std::string>(), manifest_dir)) {
                    return *hash;
                }
            }
        } catch (const std::exception&) {
            if (!allow_download_fallback) {
                throw;
            }
        }
        if (allow_download_fallback) {
            const auto cached = fetch_artifact_to_cache(environment, app, version, urls.get<std::string>(), manifest_dir, true, {});
            return sha256_file(cached);
        }
        return nullptr;
    }

    if (!urls.is_array()) {
        return nullptr;
    }

    nlohmann::json hashes = nlohmann::json::array();
    for (std::size_t i = 0; i < urls.size(); ++i) {
        if (!urls.at(i).is_string()) {
            continue;
        }
        try {
            if (autoupdate_hash_mode_is_metalink(hash_config, i)) {
                if (const auto hash = resolve_autoupdate_metalink_hash(environment, urls.at(i).get<std::string>(), manifest_dir)) {
                    hashes.push_back(*hash);
                    continue;
                }
            }
            if (hash_config != nullptr && !autoupdate_hash_mode_is_download(hash_config, i)) {
                if (const auto* config = hash_config_for_url(*hash_config, i)) {
                    if (const auto hash = resolve_autoupdate_hash_object(environment, *config, version, urls.at(i).get<std::string>(), manifest_dir)) {
                        hashes.push_back(*hash);
                        continue;
                    }
                }
            } else if (hash_config == nullptr && is_sourceforge_url(urls.at(i).get<std::string>())) {
                if (const auto hash = resolve_autoupdate_sourceforge_hash(environment, {}, urls.at(i).get<std::string>(), manifest_dir)) {
                    hashes.push_back(*hash);
                    continue;
                }
            } else if (hash_config == nullptr && is_fosshub_url(urls.at(i).get<std::string>())) {
                if (const auto hash = resolve_autoupdate_fosshub_hash(environment, {}, urls.at(i).get<std::string>(), manifest_dir)) {
                    hashes.push_back(*hash);
                    continue;
                }
            } else if (hash_config == nullptr && is_github_release_url(urls.at(i).get<std::string>())) {
                if (const auto hash = resolve_autoupdate_github_hash(environment, {}, urls.at(i).get<std::string>(), manifest_dir)) {
                    hashes.push_back(*hash);
                    continue;
                }
            }
        } catch (const std::exception&) {
            if (!allow_download_fallback) {
                throw;
            }
        }
        if (allow_download_fallback) {
            const auto cached = fetch_artifact_to_cache(environment, app, version, urls.at(i).get<std::string>(), manifest_dir, true, {});
            hashes.push_back(sha256_file(cached));
        }
    }
    return hashes.empty() ? nlohmann::json(nullptr) : hashes;
}

nlohmann::json substitute_version_tokens_json(const nlohmann::json& value, const std::string& version) {
    if (value.is_string()) {
        return substitute_autoupdate_tokens(value.get<std::string>(), version);
    }
    if (value.is_array()) {
        nlohmann::json result = nlohmann::json::array();
        for (const auto& item : value) {
            result.push_back(substitute_version_tokens_json(item, version));
        }
        return result;
    }
    if (value.is_object()) {
        nlohmann::json result = nlohmann::json::object();
        for (const auto& item : value.items()) {
            result[item.key()] = substitute_version_tokens_json(item.value(), version);
        }
        return result;
    }
    return value;
}

void resolve_autoupdate_hashes(
    const Environment& environment,
    const std::string& app,
    nlohmann::json& manifest,
    const nlohmann::json& autoupdate,
    const std::string& version,
    const std::filesystem::path& manifest_dir,
    bool original_manifest_had_hash,
    const std::set<std::string>& original_architectures_with_hash) {
    const auto* autoupdate_hash = json_property(autoupdate, "hash");
    const auto* top_hash_config = autoupdate_hash != nullptr && is_autoupdate_hash_config_value(*autoupdate_hash) ? autoupdate_hash : nullptr;
    const auto top_hash_is_literal = autoupdate_hash != nullptr && is_autoupdate_hash_literal_value(*autoupdate_hash);
    const auto* manifest_url = json_property(manifest, "url");
    if (!top_hash_is_literal && (top_hash_config != nullptr || original_manifest_had_hash) && manifest_url != nullptr) {
        if (const auto hash = resolve_autoupdate_hash_value(
                environment,
                app,
                top_hash_config,
                *manifest_url,
                version,
                manifest_dir,
                top_hash_config != nullptr || original_manifest_had_hash);
            !hash.is_null()) {
            set_json_property(manifest, "hash", hash);
        }
    }

    const auto* autoupdate_architecture = json_property(autoupdate, "architecture");
    auto* manifest_architecture = mutable_json_property(manifest, "architecture");
    if (autoupdate_architecture == nullptr || !autoupdate_architecture->is_object() || manifest_architecture == nullptr || !manifest_architecture->is_object()) {
        return;
    }

    for (const auto& arch : autoupdate_architecture->items()) {
        if (!arch.value().is_object()) {
            continue;
        }
        auto* arch_manifest = mutable_json_property(*manifest_architecture, arch.key());
        if (arch_manifest == nullptr || !arch_manifest->is_object()) {
            continue;
        }
        const auto* arch_url = json_property(*arch_manifest, "url");
        if (arch_url == nullptr) {
            continue;
        }
        const auto* arch_hash = json_property(arch.value(), "hash");
        const auto arch_hash_is_literal = arch_hash != nullptr && is_autoupdate_hash_literal_value(*arch_hash);
        if (arch_hash_is_literal || (top_hash_is_literal && arch_hash == nullptr)) {
            continue;
        }
        const auto* arch_hash_config = arch_hash != nullptr && is_autoupdate_hash_config_value(*arch_hash) ? arch_hash : top_hash_config;
        const auto original_architecture_had_hash = original_architectures_with_hash.contains(lower_ascii(arch.key()));
        if (arch_hash_config == nullptr && !original_architecture_had_hash) {
            continue;
        }
        if (const auto hash = resolve_autoupdate_hash_value(
                environment,
                app,
                arch_hash_config,
                *arch_url,
                version,
                manifest_dir,
                arch_hash_config != nullptr || original_architecture_had_hash);
            !hash.is_null()) {
            set_json_property(*arch_manifest, "hash", hash);
        }
    }
}

void apply_autoupdate_properties(
    const Environment& environment,
    const std::string& app,
    nlohmann::json& manifest,
    const nlohmann::json& autoupdate,
    const std::string& version,
    const std::filesystem::path& manifest_dir) {
    const auto original_manifest_had_hash = hash_property_requests_update(manifest);
    const auto original_architectures_with_hash = architectures_with_hash(manifest);

    for (const auto& item : autoupdate.items()) {
        const auto key = lower_ascii(item.key());
        if (key == "architecture" || key == "note") {
            continue;
        }
        if (key == "hash" && is_autoupdate_hash_config_value(item.value())) {
            continue;
        }
        set_json_property(manifest, item.key(), substitute_version_tokens_json(item.value(), version));
    }

    if (const auto* autoupdate_architecture = json_property(autoupdate, "architecture"); autoupdate_architecture != nullptr && autoupdate_architecture->is_object()) {
        auto* manifest_architecture = mutable_json_property(manifest, "architecture");
        if (manifest_architecture == nullptr || !manifest_architecture->is_object()) {
            manifest_architecture = nullptr;
        }
        if (manifest_architecture != nullptr) {
            for (const auto& arch : autoupdate_architecture->items()) {
                auto* arch_manifest = mutable_json_property(*manifest_architecture, arch.key());
                if (arch_manifest == nullptr || !arch_manifest->is_object()) {
                    continue;
                }
                if (!arch.value().is_object()) {
                    continue;
                }
                for (const auto& item : autoupdate.items()) {
                    const auto key = lower_ascii(item.key());
                    if (key == "architecture" || key == "note") {
                        continue;
                    }
                    if (json_property(arch.value(), item.key()) != nullptr) {
                        continue;
                    }
                    if (key == "hash" && !is_autoupdate_hash_literal_value(item.value())) {
                        continue;
                    }
                    set_json_property(*arch_manifest, item.key(), substitute_version_tokens_json(item.value(), version));
                }
                for (const auto& property : arch.value().items()) {
                    const auto key = lower_ascii(property.key());
                    if (key == "note") {
                        continue;
                    }
                    if (key == "hash" && is_autoupdate_hash_config_value(property.value())) {
                        continue;
                    }
                    set_json_property(*arch_manifest, property.key(), substitute_version_tokens_json(property.value(), version));
                }
            }
        }
    }
    resolve_autoupdate_hashes(
        environment,
        app,
        manifest,
        autoupdate,
        version,
        manifest_dir,
        original_manifest_had_hash,
        original_architectures_with_hash);
}

std::filesystem::path generate_autoupdate_manifest(
    const Environment& environment,
    const std::filesystem::path& source_manifest,
    const std::string& app,
    const std::string& version,
    bool reuse_current_version) {
    std::ifstream stream(source_manifest);
    if (!stream) {
        throw std::runtime_error("cannot read manifest for autoupdate: " + source_manifest.string());
    }

    nlohmann::json manifest;
    stream >> manifest;
    const auto* current_version = json_property(manifest, "version");
    if (reuse_current_version && manifest.is_object() && current_version != nullptr && current_version->is_string() && current_version->get<std::string>() == version) {
        return source_manifest;
    }

    const auto* autoupdate = json_property(manifest, "autoupdate");
    if (!manifest.is_object() || autoupdate == nullptr || !autoupdate->is_object()) {
        throw std::runtime_error("'" + app + "' does not have autoupdate capability");
    }

    apply_autoupdate_properties(environment, app, manifest, *autoupdate, version, source_manifest.parent_path());
    set_json_property(manifest, "version", version);

    const auto output = environment.cache_dir / "generated-manifests" / app / version / (app + ".json");
    std::filesystem::create_directories(output.parent_path());
    std::ofstream out(output, std::ios::binary);
    if (!out) {
        throw std::runtime_error("cannot write generated manifest: " + output.string());
    }
    out << manifest.dump(4) << '\n';
    return output;
}

std::filesystem::path materialize_manifest_url(
    const Environment& environment,
    const std::string& url,
    std::ostream& err,
    std::string_view command) {
    const HttpClient client;
    const auto response = client.get(url);
    if (response.status < 200 || response.status >= 300) {
        err << "sco " << command << ": couldn't download manifest from '" << url << "'";
        if (!response.error.empty()) {
            err << ": " << response.error;
        } else if (response.status != 0) {
            err << ": HTTP " << response.status;
        }
        err << '\n';
        return {};
    }

    try {
        const auto parsed = nlohmann::json::parse(response.body);
        if (!parsed.is_object()) {
            err << "sco " << command << ": manifest URL did not return a JSON object: " << url << '\n';
            return {};
        }
    } catch (const nlohmann::json::exception& error) {
        err << "sco " << command << ": invalid manifest JSON from '" << url << "': " << error.what() << '\n';
        return {};
    }

    auto filename = remote_filename_from_url(url);
    if (filename.empty() || lower_ascii(std::filesystem::path(filename).extension().string()) != ".json") {
        filename = sanitize_manifest_name(filename.empty() ? "manifest" : filename) + ".json";
    }
    const auto output = environment.cache_dir / "remote-manifests" / sha256_text(url).substr(0, 12) / filename;
    std::filesystem::create_directories(output.parent_path());
    std::ofstream stream(output, std::ios::binary);
    if (!stream) {
        err << "sco " << command << ": cannot write downloaded manifest: " << output.string() << '\n';
        return {};
    }
    stream << response.body;
    if (response.body.empty() || response.body.back() != '\n') {
        stream << '\n';
    }
    return output;
}

std::filesystem::path resolve_install_manifest(
    const Environment& environment,
    const std::string& app,
    std::ostream& err,
    std::string_view command = "install",
    bool* autoupdate_error = nullptr) {
    if (autoupdate_error != nullptr) {
        *autoupdate_error = false;
    }
    const auto reference = parse_app_version_reference(app);
    if (looks_like_http_url(reference.app)) {
        auto path = materialize_manifest_url(environment, reference.app, err, command);
        if (path.empty()) {
            return {};
        }
        if (!reference.version.empty()) {
            try {
                return generate_autoupdate_manifest(environment, path, path.stem().string(), reference.version, true);
            } catch (const std::exception& error) {
                if (autoupdate_error != nullptr) {
                    *autoupdate_error = true;
                }
                err << "sco " << command << ": " << error.what() << '\n';
                return {};
            }
        }
        return path;
    }

    auto path = std::filesystem::path(reference.app);
    if (lower_ascii(path.extension().string()) != ".json") {
        const auto installed_name = [&] {
            auto name = reference.app;
            if (const auto slash = name.find_last_of("/\\"); slash != std::string::npos) {
                name = name.substr(slash + 1);
            }
            return name;
        }();
        std::optional<std::filesystem::path> manifest;
        for (const bool global : {true, false}) {
            if (select_current_version(environment, installed_name, global).empty()) {
                continue;
            }
            manifest = installed_app_manifest_path(environment, installed_name, global);
            if (manifest) {
                break;
            }
        }
        if (!manifest) {
            manifest = find_manifest_in_buckets(environment, reference.app);
        }
        if (!manifest) {
            err << "sco " << command << ": couldn't find manifest for '" << app << "'\n";
            return {};
        }
        path = *manifest;
    }

    if (!std::filesystem::is_regular_file(path)) {
        err << "sco " << command << ": manifest does not exist: " << path.string() << '\n';
        return {};
    }

    if (!reference.version.empty()) {
        try {
            return generate_autoupdate_manifest(environment, path, path.stem().string(), reference.version, true);
        } catch (const std::exception& error) {
            if (autoupdate_error != nullptr) {
                *autoupdate_error = true;
            }
            err << "sco " << command << ": " << error.what() << '\n';
            return {};
        }
    }
    return path;
}

std::string install_reference_app_name(const std::string& reference) {
    const auto parsed = parse_app_version_reference(reference);
    auto app = parsed.app;
    if (looks_like_http_url(app)) {
        const auto filename = remote_filename_from_url(app);
        return lower_ascii(std::filesystem::path(filename).extension().string()) == ".json" ? std::filesystem::path(filename).stem().string() : filename;
    }
    const auto path = std::filesystem::path(app);
    if (lower_ascii(path.extension().string()) == ".json") {
        return path.stem().string();
    }
    if (const auto slash = app.find_last_of("/\\"); slash != std::string::npos) {
        return app.substr(slash + 1);
    }
    return app;
}

void write_already_installed_update_hint(
    std::ostream& out,
    const std::string& app,
    const std::string& version,
    bool global) {
    out << "WARN  '" << app << "' (" << version << ") is already installed.\n"
        << "WARN  Use 'sco update " << app;
    if (global) {
        out << " --global";
    }
    out << "' to install a new version.\n";
}

bool write_installed_skip_if_explicit(
    const Environment& environment,
    const std::set<std::string>& explicit_apps,
    const Manifest& manifest,
    bool global,
    std::ostream& out) {
    const auto installed_version = select_current_version(environment, manifest.name, global);
    if (installed_version.empty()) {
        return false;
    }

    if (explicit_apps.contains(lower_ascii(manifest.name))) {
        out << "WARN  '" << manifest.name << "' (" << installed_version << ") is already installed. Skipping.\n";
    }
    return true;
}

bool handle_single_installed_install_request(
    const Environment& environment,
    const std::vector<std::string>& apps,
    bool global,
    std::ostream& out) {
    if (apps.size() != 1) {
        return false;
    }

    const auto parsed = parse_app_version_reference(apps.front());
    const auto app = install_reference_app_name(apps.front());
    const auto installed_version = select_current_version(environment, app, global);
    if (installed_version.empty()) {
        return false;
    }

    if (parsed.version.empty()) {
        write_already_installed_update_hint(out, app, installed_version, global);
        return true;
    }
    if (std::filesystem::is_regular_file(app_dir(environment, app, global) / parsed.version / "manifest.json")) {
        write_already_installed_update_hint(out, app, parsed.version, global);
        return true;
    }
    return false;
}

void write_reset_result_messages(const ResetResult& result, std::ostream& out) {
    if (!result.reset) {
        return;
    }
    out << "Resetting " << result.app << " (" << result.version << ").\n";
    for (const auto& message : result.messages) {
        out << message << '\n';
    }
    for (const auto& warning : result.warnings) {
        out << "WARN  " << warning << '\n';
    }
}

void write_uninstall_result_messages(const UninstallResult& result, std::ostream& out) {
    if (!result.removed) {
        return;
    }
    for (const auto& message : result.messages) {
        out << message << '\n';
    }
    for (const auto& warning : result.warnings) {
        out << "WARN  " << warning << '\n';
    }
    out << "'" << result.app << "' was uninstalled.\n";
}

void repair_failed_installations_for_app(
    const Environment& environment,
    const std::string& app,
    std::set<std::string>& checked,
    std::ostream& out) {
    if (app.empty()) {
        return;
    }
    if (!checked.insert(lower_ascii(app)).second) {
        return;
    }

    for (const auto global : {true, false}) {
        if (!app_install_failed(environment, app, global)) {
            continue;
        }
        if (!select_current_version(environment, app, global).empty()) {
            out << "INFO  Repair previous failed installation of " << app << ".\n";
            write_reset_result_messages(reset_app(environment, app, {}, global), out);
        } else {
            out << "WARN  Purging previous failed installation of " << app << ".\n";
            write_uninstall_result_messages(uninstall_app(environment, app, global), out);
        }
    }
}

void write_incorrect_install_if_failed(
    const Environment& environment,
    const std::string& app,
    bool global,
    std::ostream& out) {
    if (app_install_failed(environment, app, global)) {
        out << "ERROR '" << app << "' isn't installed correctly.\n";
    }
}

std::string join_strings(const std::vector<std::string>& values, const std::string& separator) {
    std::ostringstream stream;
    for (const auto& value : values) {
        if (value.empty()) {
            continue;
        }
        if (stream.tellp() > 0) {
            stream << separator;
        }
        stream << value;
    }
    return stream.str();
}

std::string replace_all_copy(std::string value, const std::string& from, const std::string& to) {
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

std::vector<std::string> info_binary_names(const Manifest& manifest) {
    std::vector<std::string> names;
    for (const auto& bin : manifest.bins) {
        if (bin.target.empty()) {
            continue;
        }
        const auto target_path = std::filesystem::path(bin.target);
        const auto default_name = target_path.stem().string();
        if (bin.name.empty() || bin.name == default_name) {
            names.push_back(bin.target);
            continue;
        }

        auto extension = target_path.extension().string();
        names.push_back(bin.name + extension);
    }
    return names;
}

std::vector<std::string> info_shortcut_names(const Manifest& manifest) {
    std::vector<std::string> names;
    for (const auto& shortcut : manifest.shortcuts) {
        if (!shortcut.name.empty()) {
            names.push_back(shortcut.name);
        }
    }
    return names;
}

std::vector<std::string> info_environment_lines(const Manifest& manifest, const std::filesystem::path& dir) {
    std::vector<std::string> lines;
    const auto dir_value = dir.string();
    for (const auto& [name, value] : manifest.env_set) {
        lines.push_back(name + " = " + replace_all_copy(value, "$dir", dir_value));
    }
    return lines;
}

std::vector<std::string> info_path_added_lines(const Manifest& manifest, const std::filesystem::path& dir) {
    std::vector<std::string> lines;
    const auto dir_value = dir.string();
    for (const auto& item : manifest.env_add_path) {
        if (item.empty()) {
            continue;
        }
        if (item == ".") {
            lines.push_back(dir_value);
        } else {
            lines.push_back(dir_value + "\\" + item);
        }
    }
    return lines;
}

bool looks_like_license_url(const std::string& value) {
    const auto lower = lower_ascii(value);
    return lower.rfind("http://", 0) == 0 || lower.rfind("https://", 0) == 0 || lower.rfind("ftp://", 0) == 0;
}

std::string info_license_value(const Manifest& manifest, bool verbose) {
    if (manifest.license.empty()) {
        return {};
    }
    if (!manifest.license_url.empty()) {
        return verbose ? manifest.license + " (" + manifest.license_url + ")" : manifest.license;
    }
    if (!verbose || looks_like_license_url(manifest.license)) {
        return manifest.license;
    }

    std::vector<std::string> urls;
    std::string token;
    for (const char ch : manifest.license) {
        if (ch == '|' || ch == ',') {
            if (!token.empty()) {
                urls.push_back("https://spdx.org/licenses/" + token + ".html");
                token.clear();
            }
        } else if (ch != ' ' && ch != '\t') {
            token.push_back(ch);
        }
    }
    if (!token.empty()) {
        urls.push_back("https://spdx.org/licenses/" + token + ".html");
    }
    if (urls.empty()) {
        return manifest.license;
    }
    return manifest.license + " (" + join_strings(urls, ", ") + ")";
}

std::string info_suggestions_value(const Manifest& manifest) {
    std::vector<std::string> values;
    for (const auto& suggestion : manifest.suggestions) {
        if (!suggestion.second.empty()) {
            values.push_back(join_strings(suggestion.second, " | "));
        }
    }
    return join_strings(values, " | ");
}

struct ManifestUpdateInfo {
    std::string updated_at;
    std::string updated_by;
};

std::string local_timestamp(std::filesystem::file_time_type value) {
    const auto system_time = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        value - std::filesystem::file_time_type::clock::now() + std::chrono::system_clock::now());
    const auto time = std::chrono::system_clock::to_time_t(system_time);
    std::tm local{};
    localtime_s(&local, &time);

    std::ostringstream stream;
    stream << std::put_time(&local, "%Y-%m-%d %H:%M:%S");
    return stream.str();
}

std::string run_command_capture(const std::string& command) {
    std::array<char, 512> buffer{};
    std::string output;
    FILE* pipe = _popen(command.c_str(), "r");
    if (pipe == nullptr) {
        return {};
    }
    while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
        output += buffer.data();
    }
    const auto status = _pclose(pipe);
    if (status != 0) {
        return {};
    }
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r' || output.back() == ' ' || output.back() == '\t')) {
        output.pop_back();
    }
    return output;
}

int run_command_capture_raw(const std::string& command, std::string& output) {
    std::array<char, 512> buffer{};
    output.clear();
    FILE* pipe = _popen(command.c_str(), "r");
    if (pipe == nullptr) {
        return 1;
    }
    while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
        output += buffer.data();
    }
    return _pclose(pipe);
}

std::optional<std::string> read_pretty_manifest_json(
    const std::filesystem::path& manifest_path,
    std::string_view command,
    std::ostream& err) {
    std::ifstream stream(manifest_path, std::ios::binary);
    if (!stream) {
        err << "sco " << command << ": cannot read " << manifest_path.string() << '\n';
        return std::nullopt;
    }

    nlohmann::ordered_json root;
    try {
        stream >> root;
    } catch (const nlohmann::json::exception& error) {
        err << "sco " << command << ": invalid manifest JSON in '" << manifest_path.string() << "': " << error.what() << '\n';
        return std::nullopt;
    }
    return root.dump(4) + '\n';
}

std::optional<std::filesystem::path> enclosing_git_repository(std::filesystem::path path) {
    if (std::filesystem::is_regular_file(path)) {
        path = path.parent_path();
    }
    for (auto current = std::filesystem::weakly_canonical(path); !current.empty(); current = current.parent_path()) {
        if (std::filesystem::is_directory(current / ".git")) {
            return current;
        }
        if (current == current.root_path()) {
            break;
        }
    }
    return std::nullopt;
}

std::string current_user_name() {
    if (const char* user = std::getenv("USERNAME"); user != nullptr && user[0] != '\0') {
        return user;
    }
    if (const char* user = std::getenv("USER"); user != nullptr && user[0] != '\0') {
        return user;
    }
    return {};
}

ManifestUpdateInfo manifest_update_info(const std::filesystem::path& manifest_path) {
    ManifestUpdateInfo info;
    if (!std::filesystem::is_regular_file(manifest_path)) {
        return info;
    }

    if (const auto repository = enclosing_git_repository(manifest_path)) {
        const auto relative = std::filesystem::relative(std::filesystem::weakly_canonical(manifest_path), *repository).generic_string();
        const auto command = "git -C " + quote_process_argument(*repository) + " log -1 -s --format=%aI#%an -- " + quote_process_argument(relative) + " 2>NUL";
        const auto git_info = run_command_capture(command);
        const auto separator = git_info.find('#');
        if (separator != std::string::npos && separator > 0) {
            info.updated_at = git_info.substr(0, separator);
            info.updated_by = git_info.substr(separator + 1);
            return info;
        }
    }

    std::error_code error;
    const auto updated = std::filesystem::last_write_time(manifest_path, error);
    if (!error) {
        info.updated_at = local_timestamp(updated);
    }
    info.updated_by = current_user_name();
    return info;
}

std::uintmax_t directory_file_size(const std::filesystem::path& path) {
    std::error_code error;
    if (!std::filesystem::exists(path, error)) {
        return 0;
    }
    if (std::filesystem::is_regular_file(path, error)) {
        const auto size = std::filesystem::file_size(path, error);
        return error ? 0 : size;
    }
    if (!std::filesystem::is_directory(path, error)) {
        return 0;
    }

    std::uintmax_t total = 0;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(path, std::filesystem::directory_options::skip_permission_denied, error)) {
        if (error) {
            break;
        }
        if (!entry.is_regular_file(error)) {
            error.clear();
            continue;
        }
        const auto size = entry.file_size(error);
        if (!error) {
            total += size;
        }
        error.clear();
    }
    return total;
}

std::uintmax_t cache_size_for_app(const Environment& environment, const std::string& app) {
    std::uintmax_t total = 0;
    if (!std::filesystem::is_directory(environment.cache_dir)) {
        return total;
    }
    const auto prefix = app + "#";
    for (const auto& entry : std::filesystem::directory_iterator(environment.cache_dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const auto name = entry.path().filename().string();
        if (!name.starts_with(prefix) || name.ends_with(".download") || name.ends_with(".txt")) {
            continue;
        }
        std::error_code error;
        const auto size = entry.file_size(error);
        if (!error) {
            total += size;
        }
    }
    return total;
}

std::string human_size(std::uintmax_t bytes);

std::string strip_url_fragment_query(std::string value) {
    if (const auto fragment = value.find('#'); fragment != std::string::npos) {
        value.erase(fragment);
    }
    if (const auto query = value.find('?'); query != std::string::npos) {
        value.erase(query);
    }
    return value;
}

std::optional<std::filesystem::path> local_artifact_path(const std::string& url, const std::filesystem::path& manifest_dir) {
    if (looks_like_http_url(url)) {
        return std::nullopt;
    }

    auto value = strip_url_fragment_query(url);
    if (value.rfind("file:///", 0) == 0) {
        value = value.substr(8);
    } else if (value.rfind("file://", 0) == 0) {
        value = value.substr(7);
    }
    std::replace(value.begin(), value.end(), '/', '\\');

    auto path = std::filesystem::path(value);
    if (path.is_relative()) {
        path = manifest_dir / path;
    }
    return path;
}

std::string download_size_line(const Environment& environment, const Manifest& manifest, const std::filesystem::path& manifest_dir) {
    if (manifest.urls.empty()) {
        return {};
    }

    const auto effective_version = manifest.version == "nightly" ? nightly_version() : manifest.version;
    std::uintmax_t total = 0;
    auto cached = false;
    std::string package_error;
    for (const auto& url : manifest.urls) {
        const auto cached_path = cache_path(environment, manifest.name, effective_version, url);
        std::error_code error;
        if (std::filesystem::is_regular_file(cached_path, error)) {
            const auto size = std::filesystem::file_size(cached_path, error);
            if (!error) {
                total += size;
                cached = true;
                continue;
            }
        }

        if (const auto local = local_artifact_path(url, manifest_dir); local && std::filesystem::is_regular_file(*local, error)) {
            const auto size = std::filesystem::file_size(*local, error);
            if (!error) {
                total += size;
                continue;
            }
        }

        if (looks_like_http_url(url)) {
            const HttpClient client;
            const auto response = client.head(strip_url_fragment(url), {{"User-Agent", "sco"}});
            if (response.status >= 200 && response.status < 300) {
                if (const auto length = response.headers.find("content-length"); length != response.headers.end()) {
                    try {
                        total += static_cast<std::uintmax_t>(std::stoull(length->second));
                        continue;
                    } catch (const std::exception&) {
                        package_error = "the server did not send a Content-Length header";
                    }
                } else {
                    package_error = "the server did not send a Content-Length header";
                }
            } else {
                package_error = "the server is down";
            }
        }

        const auto suffix = cached ? " (latest version is cached)" : "";
        return "Unknown (" + (package_error.empty() ? std::string{"the server did not provide a local Content-Length equivalent"} : package_error) + ")" + std::string{suffix};
    }

    auto line = human_size(total);
    if (cached) {
        line += " (latest version is cached)";
    }
    return line;
}

std::string human_size(std::uintmax_t bytes) {
    constexpr auto kb = 1024.0;
    constexpr auto mb = kb * 1024.0;
    constexpr auto gb = mb * 1024.0;

    std::ostringstream stream;
    if (static_cast<double>(bytes) > gb) {
        stream << std::fixed << std::setprecision(1) << (static_cast<double>(bytes) / gb) << " GB";
    } else if (static_cast<double>(bytes) > mb) {
        stream << std::fixed << std::setprecision(1) << (static_cast<double>(bytes) / mb) << " MB";
    } else if (static_cast<double>(bytes) > kb) {
        stream << std::fixed << std::setprecision(1) << (static_cast<double>(bytes) / kb) << " KB";
    } else {
        stream << bytes << " B";
    }
    return stream.str();
}

std::vector<std::string> installed_size_lines(const Environment& environment, const std::string& app, const std::string& version, bool global) {
    if (version.empty()) {
        return {};
    }

    const auto app_root = app_dir(environment, app, global);
    const auto current = app_root / version;
    const auto app_total = directory_file_size(app_root);
    const auto current_size = directory_file_size(current);
    const auto persist_size = directory_file_size(environment.persist_dir(global) / app);
    const auto cache_size = cache_size_for_app(environment, app);
    const auto old_versions = app_total > current_size ? app_total - current_size : 0;

    if (persist_size + cache_size + old_versions == 0) {
        return {human_size(current_size)};
    }

    std::vector<std::string> lines;
    if (current_size != 0) {
        lines.push_back("Current version:  " + human_size(current_size));
    }
    if (old_versions != 0) {
        lines.push_back("Old versions:     " + human_size(old_versions));
    }
    if (persist_size != 0) {
        lines.push_back("Persisted data:   " + human_size(persist_size));
    }
    if (cache_size != 0) {
        lines.push_back("Cached downloads: " + human_size(cache_size));
    }
    lines.push_back("Total:            " + human_size(app_total + persist_size + cache_size));
    return lines;
}

std::vector<std::string> info_note_lines(
    const Manifest& manifest,
    const Environment& environment,
    const std::string& installed_version,
    bool installed_global,
    bool verbose) {
    std::vector<std::string> lines;
    const auto dir = verbose && !installed_version.empty()
        ? current_dir(environment, manifest.name, installed_global).string()
        : std::string{"<root>"};
    const auto original_dir = verbose && !installed_version.empty()
        ? (app_dir(environment, manifest.name, installed_global) / installed_version).string()
        : std::string{"<root>"};
    const auto persist = verbose ? (environment.persist_dir(installed_global) / manifest.name).string() : std::string{"<root>"};

    for (const auto& note : manifest.notes) {
        auto value = replace_all_copy(note, "$dir", dir);
        value = replace_all_copy(std::move(value), "$original_dir", original_dir);
        value = replace_all_copy(std::move(value), "$persist_dir", persist);
        if (!value.empty()) {
            lines.push_back(std::move(value));
        }
    }
    return lines;
}

std::vector<std::string> info_installed_lines(
    const Environment& environment,
    const std::string& app,
    bool global,
    bool verbose) {
    std::vector<std::string> lines;
    for (const auto& version : installed_versions(environment, app, global)) {
        if (verbose) {
            lines.push_back((app_dir(environment, app, global) / version).generic_string());
        } else {
            auto line = version;
            if (global) {
                line += " *global*";
            }
            lines.push_back(std::move(line));
        }
    }
    return lines;
}

std::string executable_stem(std::string name) {
    auto path = std::filesystem::path(std::move(name));
    auto file = path.filename().string();
    const auto extension = lower_ascii(std::filesystem::path(file).extension().string());
    if (extension == ".exe" || extension == ".com" || extension == ".cmd" || extension == ".bat" || extension == ".ps1" || extension == ".shim") {
        file = std::filesystem::path(file).stem().string();
    }
    return file;
}

constexpr std::array<std::string_view, 3> active_shim_extensions{ ".shim", ".ps1", ".cmd" };

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
    std::ifstream stream(shim);
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
        auto actual_key = trim_ascii(line.substr(0, equals));
        if (!actual_key.empty() && actual_key.front() == '$') {
            actual_key.erase(actual_key.begin());
        }
        if (lower_ascii(std::move(actual_key)) != key) {
            continue;
        }
        return unquote_shim_value(line.substr(equals + 1));
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> read_target_from_shim_metadata(const std::filesystem::path& shim) {
    if (const auto target = read_shim_metadata_value(shim, "path")) {
        if (!target->empty()) {
            return std::filesystem::path(*target);
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> read_target_from_comment_shim(const std::filesystem::path& shim) {
    std::ifstream stream(shim);
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

std::optional<std::filesystem::path> read_target_from_shim(const std::filesystem::path& shim) {
    const auto extension = lower_ascii(shim.extension().string());
    if (extension == ".shim") {
        return read_target_from_shim_metadata(shim);
    }
    return read_target_from_comment_shim(shim);
}

std::vector<std::string> path_executable_extensions() {
    std::vector<std::string> extensions;
    std::unordered_set<std::string> seen;
    if (const char* raw = std::getenv("PATHEXT"); raw != nullptr && raw[0] != '\0') {
        const std::string value = raw;
        std::size_t start = 0;
        while (start <= value.size()) {
            const auto end = value.find(';', start);
            auto extension = trim_ascii(value.substr(start, end == std::string::npos ? std::string::npos : end - start));
            if (!extension.empty() && extension.front() != '.') {
                extension.insert(extension.begin(), '.');
            }
            extension = lower_ascii(extension);
            if (!extension.empty() && seen.insert(extension).second) {
                extensions.push_back(std::move(extension));
            }
            if (end == std::string::npos) {
                break;
            }
            start = end + 1;
        }
    }
    if (extensions.empty()) {
        extensions = {".com", ".exe", ".bat", ".cmd"};
    }
    return extensions;
}

std::optional<std::filesystem::path> find_path_executable(const std::string& command) {
    if (command.find_first_of("/\\") != std::string::npos) {
        return std::nullopt;
    }

    const auto raw_extension = lower_ascii(std::filesystem::path(command).extension().string());
    std::vector<std::string> extensions;
    if (!raw_extension.empty()) {
        extensions.push_back("");
    } else {
        extensions = path_executable_extensions();
    }

    const char* path_env = std::getenv("PATH");
    if (path_env == nullptr || path_env[0] == '\0') {
        return std::nullopt;
    }

    std::string paths = path_env;
    std::size_t start = 0;
    while (start <= paths.size()) {
        const auto end = paths.find(';', start);
        auto entry = paths.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (!entry.empty() && entry.front() == '"' && entry.back() == '"' && entry.size() >= 2) {
            entry = entry.substr(1, entry.size() - 2);
        }
        if (!entry.empty()) {
            for (const auto& extension : extensions) {
                auto candidate = std::filesystem::path(entry) / (command + extension);
                if (lower_ascii(candidate.extension().string()) == ".ps1") {
                    continue;
                }
                std::error_code error;
                if (std::filesystem::is_regular_file(candidate, error)) {
                    return std::filesystem::weakly_canonical(candidate, error);
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

bool is_path_like_command(const std::string& command) {
    return command.find_first_of("/\\") != std::string::npos;
}

std::optional<std::filesystem::path> resolve_explicit_command_path(const std::string& command) {
    std::vector<std::filesystem::path> candidates;
    const auto command_path = std::filesystem::path(command);
    if (command_path.extension().empty()) {
        candidates.push_back(std::filesystem::path(command + ".ps1"));
        for (const auto& extension : path_executable_extensions()) {
            candidates.push_back(std::filesystem::path(command + extension));
        }
    } else {
        candidates.push_back(command_path);
    }

    for (const auto& candidate : candidates) {
        std::error_code error;
        if (std::filesystem::is_regular_file(candidate, error)) {
            auto resolved = std::filesystem::weakly_canonical(candidate, error);
            return error ? std::filesystem::absolute(candidate).lexically_normal() : resolved;
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> local_scoop_alias_script(const Environment& environment, const std::string& command) {
    auto path = std::filesystem::path(command);
    auto filename = path.filename().string();
    const auto extension = lower_ascii(std::filesystem::path(filename).extension().string());
    if (extension.empty()) {
        filename += ".ps1";
    } else if (extension != ".ps1") {
        return std::nullopt;
    }

    if (!lower_ascii(filename).starts_with("scoop-")) {
        return std::nullopt;
    }

    const auto alias_script = environment.shims_dir(false) / filename;
    if (!std::filesystem::is_regular_file(alias_script)) {
        return std::nullopt;
    }

    std::error_code error;
    auto resolved = std::filesystem::weakly_canonical(alias_script, error);
    return error ? std::filesystem::absolute(alias_script).lexically_normal() : resolved;
}

std::optional<std::filesystem::path> find_explicit_which_target(const Environment& environment, const std::string& command) {
    auto resolved = resolve_explicit_command_path(command);
    if (!resolved) {
        return std::nullopt;
    }

    const auto local_shims = comparable_path(environment.shims_dir(false));
    const auto global_shims = comparable_path(environment.shims_dir(true));
    const auto extension = lower_ascii(resolved->extension().string());
    const auto filename = lower_ascii(resolved->filename().string());

    if (extension == ".ps1" && filename.starts_with("scoop-") && path_is_in_tree(*resolved, local_shims)) {
        return std::filesystem::absolute(*resolved).lexically_normal();
    }

    if (path_is_in_tree(*resolved, local_shims) || path_is_in_tree(*resolved, global_shims)) {
        auto shim = *resolved;
        if (extension == ".exe") {
            auto native_shim = shim;
            native_shim.replace_extension(".shim");
            if (std::filesystem::is_regular_file(native_shim)) {
                shim = native_shim;
            }
        }
        if (const auto target = read_target_from_shim(shim)) {
            return std::filesystem::absolute(*target).lexically_normal();
        }
        return std::nullopt;
    }

    if (extension == ".ps1") {
        return std::nullopt;
    }
    return *resolved;
}

std::optional<std::filesystem::path> find_which_target(const Environment& environment, const std::string& command, bool global) {
    const auto name = executable_stem(command);
    if (!global) {
        if (const auto alias_script = local_scoop_alias_script(environment, command)) {
            return alias_script;
        }
    }

    for (const auto extension : active_shim_extensions) {
        const auto shim = environment.shims_dir(global) / (name + std::string(extension));
        if (std::filesystem::is_regular_file(shim)) {
            if (const auto target = read_target_from_shim(shim)) {
                return std::filesystem::absolute(*target).lexically_normal();
            }
        }
    }

    if (!global) {
        return find_path_executable(command);
    }
    return std::nullopt;
}

bool process_path_contains_directory(const std::filesystem::path& directory) {
    const char* raw_path = std::getenv("PATH");
    if (raw_path == nullptr || raw_path[0] == '\0') {
        return false;
    }

    const auto expected = comparable_path(directory);
    const std::string path_value = raw_path;
    std::size_t start = 0;
    while (start <= path_value.size()) {
        const auto end = path_value.find(';', start);
        auto entry = path_value.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (entry.size() >= 2 && entry.front() == '"' && entry.back() == '"') {
            entry = entry.substr(1, entry.size() - 2);
        }
        entry = trim_ascii(std::move(entry));
        if (!entry.empty() && comparable_path(std::filesystem::path(entry)) == expected) {
            return true;
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return false;
}

std::optional<std::filesystem::path> find_path_script_or_cmd_shim_target(const Environment& environment, const std::string& command, bool global) {
    const auto shim_dir = environment.shims_dir(global);
    if (!process_path_contains_directory(shim_dir)) {
        return std::nullopt;
    }

    const auto name = executable_stem(command);
    for (const auto extension : {std::string_view{".ps1"}, std::string_view{".cmd"}}) {
        const auto shim = shim_dir / (name + std::string(extension));
        if (!std::filesystem::is_regular_file(shim)) {
            continue;
        }
        if (const auto target = read_target_from_shim(shim)) {
            return std::filesystem::absolute(*target).lexically_normal();
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> find_path_which_target(const Environment& environment, const std::string& command, bool& command_found) {
    command_found = false;
    auto resolved = find_path_executable(command);
    if (!resolved) {
        if (const auto target = find_path_script_or_cmd_shim_target(environment, command, false)) {
            command_found = true;
            return target;
        }
        if (const auto target = find_path_script_or_cmd_shim_target(environment, command, true)) {
            command_found = true;
            return target;
        }
        return std::nullopt;
    }

    command_found = true;
    const auto local_shims = comparable_path(environment.shims_dir(false));
    const auto global_shims = comparable_path(environment.shims_dir(true));
    if (!path_is_in_tree(*resolved, local_shims) && !path_is_in_tree(*resolved, global_shims)) {
        return resolved;
    }

    auto shim = *resolved;
    if (lower_ascii(shim.extension().string()) == ".exe") {
        auto native_shim = shim;
        native_shim.replace_extension(".shim");
        if (std::filesystem::is_regular_file(native_shim)) {
            shim = native_shim;
        }
    }
    if (const auto target = read_target_from_shim(shim)) {
        return std::filesystem::absolute(*target).lexically_normal();
    }
    return std::nullopt;
}

std::string quote_process_argument(const std::string& value) {
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

std::string quote_process_argument(const std::filesystem::path& path) {
    return quote_process_argument(path.string());
}

bool valid_alias_name(const std::string& name) {
    if (name.empty()) {
        return false;
    }
    for (const unsigned char ch : name) {
        if (ch < 32 || ch == '<' || ch == '>' || ch == ':' || ch == '"' || ch == '/' || ch == '\\' || ch == '|' || ch == '?' || ch == '*') {
            return false;
        }
    }
    return true;
}

bool valid_shim_name(const std::string& name) {
    if (name.empty() || name.find_first_of("/\\") != std::string::npos) {
        return false;
    }
    return std::filesystem::path(name).filename().string() == name;
}

std::string cmd_shim_stem(std::string name) {
    const auto extension = lower_ascii(std::filesystem::path(name).extension().string());
    if (extension == ".cmd" || extension == ".exe" || extension == ".com" || extension == ".shim" || extension == ".ps1") {
        name = std::filesystem::path(name).stem().string();
    }
    return name;
}

std::string quote_cmd_shim_target(const std::filesystem::path& path) {
    auto value = path.string();
    std::string quoted = "\"";
    for (const char ch : value) {
        if (ch == '"') {
            quoted += "\"\"";
        } else {
            quoted.push_back(ch);
        }
    }
    quoted += "\"";
    return quoted;
}

void write_cmd_shim(const std::filesystem::path& shim_dir, const std::string& name, const std::filesystem::path& target, const std::vector<std::string>& command_args) {
    std::filesystem::create_directories(shim_dir);
    const auto shim_path = shim_dir / (cmd_shim_stem(name) + ".cmd");
    std::ofstream stream(shim_path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write shim " + shim_path.string());
    }

    stream << "@echo off\r\n"
           << "rem " << target.string() << "\r\n";
    const auto target_extension = lower_ascii(target.extension().string());
    if (target_extension == ".ps1") {
        stream << "where /q pwsh.exe\r\n"
               << "if %errorlevel% equ 0 (\r\n"
               << "    pwsh -noprofile -ex unrestricted -file " << quote_cmd_shim_target(target);
        for (const auto& arg : command_args) {
            stream << ' ' << arg;
        }
        stream << " %*\r\n"
               << ") else (\r\n"
               << "    powershell -noprofile -ex unrestricted -file " << quote_cmd_shim_target(target);
        for (const auto& arg : command_args) {
            stream << ' ' << arg;
        }
        stream << " %*\r\n"
               << ")\r\n";
    } else if (target_extension == ".jar") {
        stream << "pushd " << quote_cmd_shim_target(target.parent_path()) << "\r\n"
               << "java -jar " << quote_cmd_shim_target(target);
        for (const auto& arg : command_args) {
            stream << ' ' << arg;
        }
        stream << " %*\r\n"
               << "popd\r\n";
    } else if (target_extension == ".py") {
        stream << "python " << quote_cmd_shim_target(target);
        for (const auto& arg : command_args) {
            stream << ' ' << arg;
        }
        stream << " %*\r\n";
    } else {
        stream << quote_cmd_shim_target(target);
        for (const auto& arg : command_args) {
            stream << ' ' << arg;
        }
        stream << " %*\r\n";
    }
}

std::filesystem::path cmd_shim_path(const Environment& environment, const std::string& name, bool global) {
    return environment.shims_dir(global) / (cmd_shim_stem(name) + ".cmd");
}

std::optional<std::filesystem::path> active_shim_path(const Environment& environment, const std::string& name, bool global) {
    const auto stem = cmd_shim_stem(name);
    for (const auto extension : active_shim_extensions) {
        const auto shim = environment.shims_dir(global) / (stem + std::string(extension));
        if (std::filesystem::is_regular_file(shim)) {
            return shim;
        }
    }
    return std::nullopt;
}

std::filesystem::path shim_display_path(const std::filesystem::path& shim) {
    if (lower_ascii(shim.extension().string()) == ".shim") {
        auto executable = shim;
        executable.replace_extension(".exe");
        return executable;
    }
    return shim;
}

std::string shim_info_type(const std::filesystem::path& shim) {
    return lower_ascii(shim.extension().string()) == ".ps1" ? "ExternalScript" : "Application";
}

bool shim_is_hidden_from_path(const std::filesystem::path& shim) {
    const auto resolved = find_path_executable(shim.stem().string());
    if (!resolved) {
        return true;
    }
    return comparable_path(*resolved) != comparable_path(shim_display_path(shim));
}

std::string app_name_from_path(const Environment& environment, const std::filesystem::path& path) {
    std::error_code error;
    auto target = std::filesystem::weakly_canonical(path, error);
    if (error) {
        target = std::filesystem::absolute(path, error).lexically_normal();
        if (error) {
            target = path.lexically_normal();
        }
    }
    auto target_text = lower_ascii(target.generic_string());

    for (const auto global : {false, true}) {
        auto apps = std::filesystem::weakly_canonical(environment.apps_dir(global), error);
        if (error) {
            apps = std::filesystem::absolute(environment.apps_dir(global), error).lexically_normal();
            if (error) {
                apps = environment.apps_dir(global).lexically_normal();
            }
        }
        auto prefix = lower_ascii(apps.generic_string());
        if (!prefix.empty() && prefix.back() != '/') {
            prefix.push_back('/');
        }
        if (target_text.rfind(prefix, 0) != 0) {
            continue;
        }
        auto remainder = target_text.substr(prefix.size());
        const auto separator = remainder.find('/');
        if (separator != std::string::npos) {
            remainder = remainder.substr(0, separator);
        }
        if (!remainder.empty()) {
            return remainder;
        }
    }

    return {};
}

std::vector<std::filesystem::path> list_shims(const Environment& environment, bool global) {
    std::vector<std::filesystem::path> shims;
    const auto root = environment.shims_dir(global);
    if (!std::filesystem::is_directory(root)) {
        return shims;
    }

    std::map<std::string, std::pair<int, std::filesystem::path>> selected;
    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const auto extension = lower_ascii(entry.path().extension().string());
        int priority = -1;
        if (extension == ".shim") {
            priority = 0;
        } else if (extension == ".ps1") {
            priority = 1;
        } else if (extension == ".cmd") {
            priority = 2;
        }
        if (priority < 0) {
            continue;
        }

        const auto key = lower_ascii(entry.path().stem().string());
        const auto existing = selected.find(key);
        if (existing == selected.end() || priority < existing->second.first) {
            selected[key] = {priority, entry.path()};
        }
    }

    for (const auto& [key, value] : selected) {
        (void)key;
        shims.push_back(value.second);
    }
    std::sort(shims.begin(), shims.end());
    return shims;
}

bool any_pattern_matches(const std::string& value, const std::vector<std::regex>& patterns) {
    if (patterns.empty()) {
        return true;
    }
    return std::any_of(patterns.begin(), patterns.end(), [&](const auto& pattern) {
        return std::regex_search(value, pattern);
    });
}

std::string read_cmd_shim_command_line(const std::filesystem::path& shim) {
    std::ifstream stream(shim);
    if (!stream) {
        return {};
    }

    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty() || line.rfind("@echo", 0) == 0 || line.rfind("rem ", 0) == 0) {
            continue;
        }
        return line;
    }
    return {};
}

std::string read_cmd_shim_source(const std::filesystem::path& shim) {
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

std::string source_from_shim_or_external(const std::filesystem::path& shim) {
    auto source = read_cmd_shim_source(shim);
    if (source.empty()) {
        if (const auto target = read_target_from_shim(shim)) {
            source = app_name_from_path(load_environment(), *target);
        }
    }
    return source.empty() ? std::string{"External"} : source;
}

std::vector<std::string> shim_alternatives(const std::filesystem::path& shim) {
    std::vector<std::string> alternatives;
    if (std::filesystem::is_regular_file(shim)) {
        alternatives.push_back(source_from_shim_or_external(shim));
    }

    const auto directory = shim.parent_path();
    const auto prefix = shim.filename().string() + ".";
    if (std::filesystem::is_directory(directory)) {
        for (const auto& entry : std::filesystem::directory_iterator(directory)) {
            if (!entry.is_regular_file()) {
                continue;
            }
            const auto filename = entry.path().filename().string();
            if (filename.rfind(prefix, 0) == 0) {
                alternatives.push_back(filename.substr(prefix.size()));
            }
        }
    }

    std::sort(alternatives.begin(), alternatives.end());
    alternatives.erase(std::unique(alternatives.begin(), alternatives.end()), alternatives.end());
    return alternatives;
}

std::filesystem::path shim_file_for_source(const std::filesystem::path& active, const std::string& source) {
    if (std::filesystem::is_regular_file(active) && source_from_shim_or_external(active) == source) {
        return active;
    }
    return std::filesystem::path(active.string() + "." + source);
}

bool switch_single_shim_source(const std::filesystem::path& active, const std::string& source) {
    const auto current_source = std::filesystem::is_regular_file(active) ? source_from_shim_or_external(active) : std::string{};
    if (current_source == source) {
        return false;
    }

    const auto selected = shim_file_for_source(active, source);
    if (!std::filesystem::is_regular_file(selected)) {
        throw std::runtime_error("shim source not found: " + source);
    }

    if (std::filesystem::is_regular_file(active)) {
        const auto old = std::filesystem::path(active.string() + "." + current_source);
        if (std::filesystem::exists(old)) {
            std::filesystem::remove(old);
        }
        std::filesystem::rename(active, old);
    }
    std::filesystem::rename(selected, active);
    return true;
}

bool switch_cmd_shim_source(const std::filesystem::path& active, const std::string& source) {
    const auto current_source = std::filesystem::is_regular_file(active) ? source_from_shim_or_external(active) : std::string{};
    if (current_source == source) {
        return false;
    }

    const auto selected = shim_file_for_source(active, source);
    if (!std::filesystem::is_regular_file(selected)) {
        throw std::runtime_error("shim source not found: " + source);
    }

    const auto active_shell = active.parent_path() / active.stem();
    const auto selected_shell = std::filesystem::path(active_shell.string() + "." + source);
    const auto old_shell = std::filesystem::path(active_shell.string() + "." + current_source);

    if (std::filesystem::is_regular_file(active)) {
        const auto old = std::filesystem::path(active.string() + "." + current_source);
        if (std::filesystem::exists(old)) {
            std::filesystem::remove(old);
        }
        std::filesystem::rename(active, old);
    }
    std::filesystem::rename(selected, active);

    if (std::filesystem::is_regular_file(selected_shell)) {
        if (std::filesystem::is_regular_file(active_shell)) {
            if (std::filesystem::exists(old_shell)) {
                std::filesystem::remove(old_shell);
            }
            std::filesystem::rename(active_shell, old_shell);
        }
        std::filesystem::rename(selected_shell, active_shell);
    }
    return true;
}

bool switch_native_shim_source(const std::filesystem::path& active, const std::string& source) {
    const auto current_source = std::filesystem::is_regular_file(active) ? source_from_shim_or_external(active) : std::string{};
    if (current_source == source) {
        return false;
    }

    const auto selected = shim_file_for_source(active, source);
    if (!std::filesystem::is_regular_file(selected)) {
        throw std::runtime_error("shim source not found: " + source);
    }

    const auto active_exe = active.parent_path() / (active.stem().string() + ".exe");
    const auto selected_exe = std::filesystem::path(active_exe.string() + "." + source);
    const auto old_exe = std::filesystem::path(active_exe.string() + "." + current_source);

    if (std::filesystem::is_regular_file(active)) {
        const auto old = std::filesystem::path(active.string() + "." + current_source);
        if (std::filesystem::exists(old)) {
            std::filesystem::remove(old);
        }
        std::filesystem::rename(active, old);
    }
    std::filesystem::rename(selected, active);

    if (std::filesystem::is_regular_file(selected_exe)) {
        if (std::filesystem::is_regular_file(active_exe)) {
            if (std::filesystem::exists(old_exe)) {
                std::filesystem::remove(old_exe);
            }
            std::filesystem::rename(active_exe, old_exe);
        }
        std::filesystem::rename(selected_exe, active_exe);
    }
    return true;
}

bool switch_powershell_shim_source(const std::filesystem::path& active, const std::string& source) {
    const auto current_source = std::filesystem::is_regular_file(active) ? source_from_shim_or_external(active) : std::string{};
    if (current_source == source) {
        return false;
    }

    const auto selected = shim_file_for_source(active, source);
    if (!std::filesystem::is_regular_file(selected)) {
        throw std::runtime_error("shim source not found: " + source);
    }

    const auto active_cmd = active.parent_path() / (active.stem().string() + ".cmd");
    const auto active_shell = active.parent_path() / active.stem();
    const auto selected_cmd = std::filesystem::path(active_cmd.string() + "." + source);
    const auto old_cmd = std::filesystem::path(active_cmd.string() + "." + current_source);
    const auto selected_shell = std::filesystem::path(active_shell.string() + "." + source);
    const auto old_shell = std::filesystem::path(active_shell.string() + "." + current_source);

    if (std::filesystem::is_regular_file(active)) {
        const auto old = std::filesystem::path(active.string() + "." + current_source);
        if (std::filesystem::exists(old)) {
            std::filesystem::remove(old);
        }
        std::filesystem::rename(active, old);
    }
    std::filesystem::rename(selected, active);

    if (std::filesystem::is_regular_file(selected_cmd)) {
        if (std::filesystem::is_regular_file(active_cmd)) {
            if (std::filesystem::exists(old_cmd)) {
                std::filesystem::remove(old_cmd);
            }
            std::filesystem::rename(active_cmd, old_cmd);
        }
        std::filesystem::rename(selected_cmd, active_cmd);
    }
    if (std::filesystem::is_regular_file(selected_shell)) {
        if (std::filesystem::is_regular_file(active_shell)) {
            if (std::filesystem::exists(old_shell)) {
                std::filesystem::remove(old_shell);
            }
            std::filesystem::rename(active_shell, old_shell);
        }
        std::filesystem::rename(selected_shell, active_shell);
    }
    return true;
}

bool switch_shim_source(const std::filesystem::path& active, const std::string& source) {
    const auto extension = lower_ascii(active.extension().string());
    if (extension == ".shim") {
        return switch_native_shim_source(active, source);
    }
    if (extension == ".ps1") {
        return switch_powershell_shim_source(active, source);
    }
    if (extension == ".cmd") {
        return switch_cmd_shim_source(active, source);
    }
    return switch_single_shim_source(active, source);
}

std::optional<std::string> latest_shim_alternative_source(const std::filesystem::path& active) {
    const auto directory = active.parent_path();
    if (!std::filesystem::is_directory(directory)) {
        return std::nullopt;
    }

    const auto prefix = active.filename().string() + ".";
    std::optional<std::filesystem::file_time_type> latest_time;
    std::optional<std::string> latest_source;
    for (const auto& entry : std::filesystem::directory_iterator(directory)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const auto filename = entry.path().filename().string();
        if (filename.rfind(prefix, 0) != 0) {
            continue;
        }
        std::error_code error;
        const auto write_time = entry.last_write_time(error);
        if (error) {
            continue;
        }
        if (!latest_time || write_time > *latest_time) {
            latest_time = write_time;
            latest_source = filename.substr(prefix.size());
        }
    }
    return latest_source;
}

bool promote_shim_alternative_file(const std::filesystem::path& active, const std::string& source) {
    const auto alternative = std::filesystem::path(active.string() + "." + source);
    if (!std::filesystem::is_regular_file(alternative)) {
        return false;
    }
    if (std::filesystem::exists(active)) {
        std::filesystem::remove(active);
    }
    std::filesystem::rename(alternative, active);
    return true;
}

bool remove_active_shim_files(const Environment& environment, const std::string& name, bool global) {
    const auto active = active_shim_path(environment, name, global);
    if (!active) {
        return false;
    }

    const auto source_to_promote = latest_shim_alternative_source(*active);
    const auto extension = lower_ascii(active->extension().string());
    const auto stem = active->stem().string();
    const auto directory = active->parent_path();

    const auto remove_if_regular = [](const std::filesystem::path& path) {
        std::error_code error;
        if (std::filesystem::is_regular_file(path, error)) {
            std::filesystem::remove(path, error);
        }
    };

    remove_if_regular(*active);
    if (extension == ".shim") {
        const auto executable = directory / (stem + ".exe");
        if (source_to_promote) {
            promote_shim_alternative_file(*active, *source_to_promote);
            promote_shim_alternative_file(executable, *source_to_promote);
        } else {
            remove_if_regular(executable);
        }
    } else if (extension == ".ps1") {
        const auto cmd = directory / (stem + ".cmd");
        const auto shell = directory / stem;
        remove_if_regular(cmd);
        remove_if_regular(shell);
        if (source_to_promote) {
            promote_shim_alternative_file(*active, *source_to_promote);
            promote_shim_alternative_file(cmd, *source_to_promote);
            promote_shim_alternative_file(shell, *source_to_promote);
        }
    } else if (extension == ".cmd") {
        const auto shell = directory / stem;
        remove_if_regular(shell);
        if (source_to_promote) {
            promote_shim_alternative_file(*active, *source_to_promote);
            promote_shim_alternative_file(shell, *source_to_promote);
        }
    } else if (source_to_promote) {
        promote_shim_alternative_file(*active, *source_to_promote);
    }

    return true;
}

nlohmann::json alias_config_object(const ConfigStore& config) {
    const auto aliases = config.get("alias");
    if (aliases && aliases->is_object()) {
        return *aliases;
    }
    return nlohmann::json::object();
}

std::optional<std::string> alias_config_key(const nlohmann::json& aliases, const std::string& name) {
    if (!aliases.is_object()) {
        return std::nullopt;
    }
    if (aliases.contains(name)) {
        return name;
    }
    const auto normalized = lower_ascii(name);
    for (auto it = aliases.begin(); it != aliases.end(); ++it) {
        if (lower_ascii(it.key()) == normalized) {
            return it.key();
        }
    }
    return std::nullopt;
}

std::uintmax_t cache_entries_size(const std::vector<CacheEntry>& entries) {
    std::uintmax_t total = 0;
    for (const auto& entry : entries) {
        total += entry.size;
    }
    return total;
}

std::string cache_entry_version_label(const std::string& name) {
    const auto first = name.find('#');
    if (first == std::string::npos) {
        return {};
    }
    const auto second = name.find('#', first + 1);
    if (second == std::string::npos) {
        return name.substr(first + 1);
    }
    return name.substr(first + 1, second - first - 1);
}

void write_cache_entries_table(std::ostream& out, const std::vector<CacheEntry>& entries) {
    if (entries.empty()) {
        return;
    }

    struct Row {
        std::string name;
        std::string version;
        std::string length;
    };

    std::vector<Row> rows;
    rows.reserve(entries.size());
    std::size_t name_width = std::string_view("Name").size();
    std::size_t version_width = std::string_view("Version").size();
    std::size_t length_width = std::string_view("Length").size();

    for (const auto& entry : entries) {
        Row row{
            .name = entry.app,
            .version = cache_entry_version_label(entry.name),
            .length = std::to_string(entry.size),
        };
        name_width = row.name.size() > name_width ? row.name.size() : name_width;
        version_width = row.version.size() > version_width ? row.version.size() : version_width;
        length_width = row.length.size() > length_width ? row.length.size() : length_width;
        rows.push_back(std::move(row));
    }

    const auto write_left = [&](std::string_view value, std::size_t width) {
        out << value;
        if (value.size() < width) {
            out << std::string(width - value.size(), ' ');
        }
    };
    const auto write_right = [&](std::string_view value, std::size_t width) {
        if (value.size() < width) {
            out << std::string(width - value.size(), ' ');
        }
        out << value;
    };

    write_left("Name", name_width);
    out << ' ';
    write_left("Version", version_width);
    out << ' ';
    write_left("Length", length_width);
    out << '\n';
    write_left(std::string_view("----"), name_width);
    out << ' ';
    write_left(std::string_view("-------"), version_width);
    out << ' ';
    write_left(std::string_view("------"), length_width);
    out << '\n';

    for (const auto& row : rows) {
        write_left(row.name, name_width);
        out << ' ';
        write_left(row.version, version_width);
        out << ' ';
        write_right(row.length, length_width);
        out << '\n';
    }
}

std::string file_count_label(std::size_t count) {
    return std::to_string(count) + (count == 1 ? " file" : " files");
}

std::filesystem::path alias_script_path(const Environment& environment, const std::string& name) {
    return environment.shims_dir(false) / ("scoop-" + name + ".ps1");
}

std::filesystem::path shim_command_path(const Environment& environment, const std::string& name) {
    const auto shim = alias_script_path(environment, name);
    if (const auto target = read_target_from_shim_metadata(shim)) {
        return *target;
    }
    return shim;
}

std::string read_alias_summary(const std::filesystem::path& path) {
    std::ifstream stream(path);
    if (!stream) {
        return "<BROKEN>";
    }

    std::string line;
    while (std::getline(stream, line)) {
        line = strip_utf8_bom(std::move(line));
        constexpr std::string_view prefix = "# Summary:";
        if (line.rfind(prefix, 0) == 0) {
            auto summary = line.substr(prefix.size());
            while (!summary.empty() && (summary.front() == ' ' || summary.front() == '\t')) {
                summary.erase(summary.begin());
            }
            if (!summary.empty() && summary.back() == '\r') {
                summary.pop_back();
            }
            return summary;
        }
    }
    return {};
}

std::string read_alias_command(const std::filesystem::path& path) {
    std::ifstream stream(path);
    if (!stream) {
        return "<BROKEN>";
    }

    std::string line;
    std::string command;
    bool first = true;
    while (std::getline(stream, line)) {
        line = strip_utf8_bom(std::move(line));
        if (first) {
            first = false;
            if (line.rfind("# Summary:", 0) == 0) {
                continue;
            }
        }
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (!command.empty()) {
            command += " ";
        }
        command += line;
    }
    return command;
}

void print_scoop_script_help(const std::filesystem::path& path, std::ostream& out) {
    std::ifstream stream(path);
    if (!stream) {
        return;
    }

    bool in_help = false;
    std::string line;
    while (std::getline(stream, line)) {
        line = strip_utf8_bom(std::move(line));
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        constexpr std::string_view usage_prefix = "# Usage: ";
        if (line.rfind(usage_prefix, 0) == 0) {
            auto usage = line.substr(usage_prefix.size());
            if (usage.rfind("scoop ", 0) == 0) {
                usage.replace(0, 5, "sco");
            }
            out << "Usage: " << usage << "\n\n";
            continue;
        }

        constexpr std::string_view help_prefix = "# Help:";
        if (line.rfind(help_prefix, 0) == 0) {
            in_help = true;
            auto help = line.substr(help_prefix.size());
            if (!help.empty() && help.front() == ' ') {
                help.erase(help.begin());
            }
            if (!help.empty()) {
                out << help << '\n';
            }
            continue;
        }
        if (in_help) {
            if (line.rfind('#', 0) != 0) {
                break;
            }
            auto help = line.substr(1);
            if (!help.empty() && help.front() == ' ') {
                help.erase(help.begin());
            }
            out << help << '\n';
        }
    }
}

bool print_shim_command_help_if_known(const std::string& command, std::ostream& out) {
    try {
        const auto environment = load_environment();
        const auto script = alias_script_path(environment, command);
        if (!std::filesystem::is_regular_file(script)) {
            return false;
        }
        print_scoop_script_help(shim_command_path(environment, command), out);
        return true;
    } catch (const std::exception&) {
        return false;
    }
}

int execute_powershell_script(const std::filesystem::path& script, const std::vector<std::string>& args) {
    if (!std::filesystem::is_regular_file(script)) {
        return 1;
    }

    std::string command = "powershell -NoProfile -ExecutionPolicy Bypass -File " + quote_process_argument(script);
    for (const auto& arg : args) {
        command += " " + quote_process_argument(arg);
    }
    return std::system(command.c_str());
}

int execute_alias_script(const Environment& environment, const std::string& name, const std::vector<std::string>& args) {
    return execute_powershell_script(shim_command_path(environment, name), args);
}

void open_url(const std::string& url) {
    const auto command = "cmd /c start \"\" " + quote_process_argument(url);
    if (std::system(command.c_str()) != 0) {
        throw std::runtime_error("failed to open " + url);
    }
}

std::filesystem::path cat_temp_file_path(const Environment& environment) {
    auto root = environment.cache_dir.empty() ? environment.root_dir / "cache" : environment.cache_dir;
    std::filesystem::create_directories(root);
    for (int i = 0; i < 1000; ++i) {
        const auto candidate = root / ("cat-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(i) + ".json");
        if (!std::filesystem::exists(candidate)) {
            return candidate;
        }
    }
    throw std::runtime_error("cannot allocate temporary manifest path");
}

bool write_text_file(const std::filesystem::path& path, const std::string& content) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        return false;
    }
    stream << content;
    return static_cast<bool>(stream);
}

int write_cat_output(
    const Environment& environment,
    const std::string& pretty_json,
    std::ostream& out,
    std::ostream& err) {
    const auto style = ConfigStore(environment.config_file).get("cat_style");
    if (!style || !style->is_string() || style->get<std::string>().empty()) {
        out << pretty_json;
        return 0;
    }

    const auto temp = cat_temp_file_path(environment);
    if (!write_text_file(temp, pretty_json)) {
        err << "sco cat: cannot write temporary manifest " << temp.string() << '\n';
        return 1;
    }

    std::string bat_output;
    const auto command = "cmd /c type " + quote_process_argument(temp)
        + " | bat --no-paging --style " + quote_process_argument(style->get<std::string>())
        + " --language json 2>&1";
    const auto status = run_command_capture_raw(command, bat_output);

    std::error_code remove_error;
    std::filesystem::remove(temp, remove_error);

    if (!bat_output.empty()) {
        out << bat_output;
    }
    return status == 0 ? 0 : 1;
}

std::string normalize_prompt_answer(std::string answer) {
    if (answer.size() >= 3
        && static_cast<unsigned char>(answer[0]) == 0xef
        && static_cast<unsigned char>(answer[1]) == 0xbb
        && static_cast<unsigned char>(answer[2]) == 0xbf) {
        answer.erase(0, 3);
    }
    if (answer.size() >= 2
        && ((static_cast<unsigned char>(answer[0]) == 0xff && static_cast<unsigned char>(answer[1]) == 0xfe)
            || (static_cast<unsigned char>(answer[0]) == 0xfe && static_cast<unsigned char>(answer[1]) == 0xff))) {
        answer.erase(0, 2);
    }
    answer.erase(std::remove(answer.begin(), answer.end(), '\0'), answer.end());
    answer.erase(answer.begin(), std::find_if(answer.begin(), answer.end(), [](unsigned char ch) {
        return std::isspace(ch) == 0;
    }));
    return answer;
}

bool confirm_installation(std::istream& input, std::ostream& out) {
    out << "Continue installation? [Y/n]: ";

    std::string answer;
    if (!std::getline(input, answer)) {
        return true;
    }
    answer = normalize_prompt_answer(std::move(answer));
    return answer.empty() || (answer[0] != 'n' && answer[0] != 'N');
}

enum class InstallManifestDecision {
    Continue,
    Skip,
    Error,
};

InstallManifestDecision show_install_manifest_if_configured(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const Manifest& manifest,
    std::istream& input,
    std::ostream& out,
    std::ostream& err) {
    if (!config_bool(environment, "show_manifest")) {
        return InstallManifestDecision::Continue;
    }

    out << "Manifest: " << manifest.name << ".json\n";
    const auto pretty_json = read_pretty_manifest_json(manifest_path, "install", err);
    if (!pretty_json) {
        return InstallManifestDecision::Error;
    }
    if (write_cat_output(environment, *pretty_json, out, err) != 0) {
        return InstallManifestDecision::Error;
    }
    return confirm_installation(input, out) ? InstallManifestDecision::Continue : InstallManifestDecision::Skip;
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

std::string app_name_from_manifest_path(const std::filesystem::path& manifest_path) {
    return manifest_path.stem().string();
}

std::string install_source_label(const Environment& environment, const std::filesystem::path& manifest_path) {
    if (const auto bucket = bucket_name_for_manifest(environment, manifest_path); !bucket.empty()) {
        return " from '" + bucket + "' bucket";
    }
    return " from '" + std::filesystem::absolute(manifest_path).generic_string() + "'";
}

void write_install_start(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const Manifest& manifest,
    std::ostream& out) {
    const auto version = manifest.version == "nightly" ? nightly_version() : manifest.version;
    out << "Installing '" << manifest.name << "' (" << version << ") ["
        << manifest.architecture << "]" << install_source_label(environment, manifest_path) << '\n';
}

void write_install_result(
    const InstallResult& result,
    std::ostream& out) {
    if (result.already_installed) {
        out << "'" << result.app << "' (" << result.version << ") is already installed.\n";
    } else {
        out << "'" << result.app << "' (" << result.version << ") was installed successfully!\n";
    }
}

void write_install_messages(const InstallResult& result, std::ostream& out) {
    for (const auto& message : result.messages) {
        out << message << '\n';
    }
}

void write_install_warnings(const InstallResult& result, std::ostream& out) {
    for (const auto& warning : result.warnings) {
        out << "WARN  " << warning << '\n';
    }
}

void write_install_notes(
    const Environment& environment,
    const Manifest& manifest,
    const InstallResult& result,
    bool global,
    std::ostream& out) {
    if (result.already_installed || manifest.notes.empty()) {
        return;
    }

    out << "Notes\n-----\n";
    const auto notes = info_note_lines(manifest, environment, result.version, global, true);
    for (const auto& note : notes) {
        out << note << '\n';
    }
}

void remember_install_suggestions(
    std::map<std::string, std::map<std::string, std::vector<std::string>>>& suggestions,
    const Manifest& manifest) {
    if (!manifest.suggestions.empty()) {
        suggestions[manifest.name] = manifest.suggestions;
    }
}

std::string suggested_app_name(const std::string& suggestion) {
    const auto parsed = parse_app_version_reference(suggestion);
    auto app = parsed.app;
    if (looks_like_http_url(app)) {
        const auto filename = remote_filename_from_url(app);
        return lower_ascii(std::filesystem::path(filename).extension().string()) == ".json" ? std::filesystem::path(filename).stem().string() : filename;
    }
    if (const auto slash = app.find_last_of("/\\"); slash != std::string::npos) {
        app = app.substr(slash + 1);
    }
    if (lower_ascii(std::filesystem::path(app).extension().string()) == ".json") {
        app = std::filesystem::path(app).stem().string();
    }
    return app;
}

struct UpdateTarget {
    std::string app;
    bool global = false;
};


void write_install_suggestions(
    const Environment& environment,
    const std::map<std::string, std::map<std::string, std::vector<std::string>>>& suggestions,
    std::ostream& out) {
    if (suggestions.empty()) {
        return;
    }

    std::set<std::string> installed;
    for (const auto& app : list_installed_apps(environment)) {
        installed.insert(lower_ascii(app.name));
    }

    for (const auto& [app, features] : suggestions) {
        for (const auto& [feature, candidates] : features) {
            bool fulfilled = false;
            for (const auto& candidate : candidates) {
                if (installed.contains(lower_ascii(suggested_app_name(candidate)))) {
                    fulfilled = true;
                    break;
                }
            }
            if (!fulfilled && !candidates.empty()) {
                out << "'" << app << "' suggests installing '" << join_strings(candidates, "' or '") << "'.\n";
            }
        }
    }
}

nlohmann::json exportable_config(nlohmann::json config) {
    if (!config.is_object()) {
        return nlohmann::json::object();
    }
    for (const auto& key : {"last_update", "root_path", "global_path", "cache_path", "alias"}) {
        config.erase(key);
    }
    return config;
}

std::string bucket_source(const LocalBucket& bucket) {
    const auto git_config = bucket.path / ".git" / "config";
    std::ifstream stream(git_config);
    if (stream) {
        bool in_origin = false;
        std::string line;
        while (std::getline(stream, line)) {
            while (!line.empty() && (line.front() == ' ' || line.front() == '\t')) {
                line.erase(line.begin());
            }
            if (line.rfind("[remote ", 0) == 0) {
                in_origin = line.find("\"origin\"") != std::string::npos;
                continue;
            }
            if (in_origin && line.rfind("url", 0) == 0) {
                const auto equals = line.find('=');
                if (equals != std::string::npos) {
                    auto source = line.substr(equals + 1);
                    while (!source.empty() && (source.front() == ' ' || source.front() == '\t')) {
                        source.erase(source.begin());
                    }
                    while (!source.empty() && (source.back() == ' ' || source.back() == '\t' || source.back() == '\r')) {
                        source.pop_back();
                    }
                    if (!source.empty()) {
                        return source;
                    }
                }
            }
        }
    }
    return std::filesystem::absolute(bucket.path).generic_string();
}

std::string export_app_source(const Environment& environment, const InstalledApp& app) {
    if (!app.source.empty() && !looks_like_http_url(app.source)) {
        std::error_code error;
        const auto source_path = std::filesystem::weakly_canonical(std::filesystem::path(app.source), error);
        const auto generated_path = std::filesystem::weakly_canonical(
            environment.cache_dir / "generated-manifests" / app.name / app.version / (app.name + ".json"),
            error);
        if (!error && source_path == generated_path) {
            return "<auto-generated>";
        }
    }
    if (!app.source.empty()) {
        return app.source;
    }
    if (const auto manifest_path = find_manifest_in_buckets(environment, app.name)) {
        return bucket_name_for_manifest(environment, *manifest_path);
    }
    return {};
}

std::string json_string_field(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value != nullptr && value->is_string()) {
        return value->get<std::string>();
    }
    return {};
}

bool info_contains(const std::string& info, const std::string& marker) {
    return info.find(marker) != std::string::npos;
}

bool looks_like_http_url(const std::string& value) {
    const auto lower = lower_ascii(value);
    return lower.rfind("http://", 0) == 0 || lower.rfind("https://", 0) == 0;
}

std::optional<nlohmann::json> read_json_from_path_or_url(const std::string& source) {
    std::string content;
    if (looks_like_http_url(source)) {
        const HttpClient client;
        const auto response = client.get(source);
        if (response.status < 200 || response.status >= 300) {
            return std::nullopt;
        }
        content = response.body;
    } else {
        std::ifstream stream(std::filesystem::path(source), std::ios::binary);
        if (!stream) {
            return std::nullopt;
        }
        content.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
    }

    try {
        auto value = nlohmann::json::parse(content);
        if (value.is_object()) {
            return value;
        }
    } catch (const nlohmann::json::exception&) {
    }
    return std::nullopt;
}

struct CheckUrlResult {
    std::string url;
    bool ok = false;
    std::string error;
};

struct CheckUrlManifestView {
    std::vector<std::pair<std::string, std::string>> cookies;
    std::vector<std::string> urls;
};

struct CheckHashItem {
    std::string architecture;
    std::size_t index = 0;
    std::string url;
    std::string hash;
};

struct CheckHashResult {
    CheckHashItem item;
    std::filesystem::path cached;
    std::string expected;
    std::string actual;
    std::string algorithm = "sha256";
    std::string error;
    bool mismatch = false;
};

std::vector<std::string> json_string_or_array_values(const nlohmann::ordered_json& object, const char* key, bool require_truthy = false) {
    std::vector<std::string> values;
    const auto* value = ordered_json_property(object, key);
    if (value == nullptr || value->is_null()) {
        return values;
    }
    if (require_truthy && !powershell_truthy_ordered_json(*value)) {
        return values;
    }
    if (value->is_string()) {
        values.push_back(value->get<std::string>());
    } else if (value->is_array()) {
        for (const auto& item : *value) {
            if (item.is_string()) {
                values.push_back(item.get<std::string>());
            }
        }
    }
    return values;
}

std::string json_hash_at(const nlohmann::ordered_json& object, std::size_t index) {
    const auto hashes = json_string_or_array_values(object, "hash");
    return index < hashes.size() ? hashes[index] : std::string{};
}

std::vector<CheckHashItem> checkhash_items_from_manifest(const nlohmann::ordered_json& manifest) {
    std::vector<CheckHashItem> items;
    const auto top_urls = json_string_or_array_values(manifest, "url", true);
    if (!top_urls.empty()) {
        for (std::size_t i = 0; i < top_urls.size(); ++i) {
            items.push_back(CheckHashItem{.index = i, .url = top_urls[i], .hash = json_hash_at(manifest, i)});
        }
        return items;
    }

    const auto* architectures = ordered_json_property(manifest, "architecture");
    if (architectures == nullptr || !architectures->is_object()) {
        return items;
    }
    for (const auto& architecture : {"64bit", "32bit", "arm64"}) {
        const auto* arch_manifest = ordered_json_property(*architectures, architecture);
        if (arch_manifest == nullptr || !arch_manifest->is_object()) {
            continue;
        }
        const auto urls = json_string_or_array_values(*arch_manifest, "url", true);
        for (std::size_t i = 0; i < urls.size(); ++i) {
            items.push_back(CheckHashItem{.architecture = architecture, .index = i, .url = urls[i], .hash = json_hash_at(*arch_manifest, i)});
        }
    }
    return items;
}

std::optional<std::string> checkhash_manifest_validation_error(const nlohmann::ordered_json& manifest) {
    const auto top_urls = json_string_or_array_values(manifest, "url", true);
    if (!top_urls.empty()) {
        if (top_urls.size() != json_string_or_array_values(manifest, "hash").size()) {
            return "URLS and hashes count mismatch.";
        }
        return std::nullopt;
    }

    const auto* architectures = ordered_json_property(manifest, "architecture");
    if (architectures == nullptr || !architectures->is_object()) {
        return "Manifest does not contain URL property.";
    }

    std::size_t url_count = 0;
    std::size_t hash_count = 0;
    for (const auto& architecture : {"64bit", "32bit", "arm64"}) {
        const auto* arch_manifest = ordered_json_property(*architectures, architecture);
        if (arch_manifest == nullptr || !arch_manifest->is_object()) {
            continue;
        }
        url_count += json_string_or_array_values(*arch_manifest, "url", true).size();
        hash_count += json_string_or_array_values(*arch_manifest, "hash").size();
    }
    if (url_count != hash_count) {
        return "URLS and hashes count mismatch.";
    }
    if (url_count == 0) {
        return "Manifest does not contain URL property.";
    }
    return std::nullopt;
}

std::vector<std::string> checkurl_urls_from_manifest(const nlohmann::ordered_json& manifest) {
    const auto top_urls = json_string_or_array_values(manifest, "url", true);
    if (!top_urls.empty()) {
        return top_urls;
    }

    std::vector<std::string> urls;
    const auto* architectures = ordered_json_property(manifest, "architecture");
    if (architectures == nullptr || !architectures->is_object()) {
        return urls;
    }

    for (const auto& architecture : {"64bit", "32bit", "arm64"}) {
        const auto* arch_manifest = ordered_json_property(*architectures, architecture);
        if (arch_manifest == nullptr || !arch_manifest->is_object()) {
            continue;
        }
        const auto arch_urls = json_string_or_array_values(*arch_manifest, "url", true);
        urls.insert(urls.end(), arch_urls.begin(), arch_urls.end());
    }
    return urls;
}

std::string ordered_cookie_scalar_value(const nlohmann::ordered_json& value) {
    if (value.is_string()) {
        return value.get<std::string>();
    }
    if (value.is_boolean()) {
        return value.get<bool>() ? "True" : "False";
    }
    if (value.is_number()) {
        return value.dump();
    }
    if (value.is_null()) {
        return {};
    }
    throw std::runtime_error("cookie values must be scalar values");
}

std::vector<std::pair<std::string, std::string>> checkurl_cookie_values(const nlohmann::ordered_json& manifest) {
    std::vector<std::pair<std::string, std::string>> cookies;
    const auto* cookie = ordered_json_property(manifest, "cookie");
    if (cookie == nullptr || cookie->is_null()) {
        return cookies;
    }
    if (!powershell_truthy_ordered_json(*cookie)) {
        return cookies;
    }
    if (!cookie->is_object()) {
        throw std::runtime_error("cookie must be an object");
    }

    for (const auto& item : cookie->items()) {
        cookies.emplace_back(item.key(), ordered_cookie_scalar_value(item.value()));
    }
    return cookies;
}

void assign_hash_value(nlohmann::ordered_json& object, std::size_t index, const std::string& hash) {
    auto* hash_value = mutable_ordered_json_property(object, "hash");
    if (hash_value == nullptr || hash_value->is_null() || hash_value->is_string()) {
        set_ordered_json_property(object, "hash", hash);
        return;
    }
    if (!hash_value->is_array()) {
        set_ordered_json_property(object, "hash", hash);
        return;
    }
    auto& hashes = *hash_value;
    while (hashes.size() <= index) {
        hashes.push_back("");
    }
    hashes[index] = hash;
}

void assign_manifest_hash(nlohmann::ordered_json& manifest, const CheckHashItem& item, const std::string& hash) {
    if (item.architecture.empty()) {
        assign_hash_value(manifest, item.index, hash);
        return;
    }
    auto* architectures = mutable_ordered_json_property(manifest, "architecture");
    if (architectures == nullptr || !architectures->is_object()) {
        return;
    }
    auto* arch_manifest = mutable_ordered_json_property(*architectures, item.architecture);
    if (arch_manifest == nullptr || !arch_manifest->is_object()) {
        return;
    }
    assign_hash_value(*arch_manifest, item.index, hash);
}

std::string checkurl_request_url(std::string url) {
    if (const auto fragment = url.find("#/"); fragment != std::string::npos) {
        url.erase(fragment);
    } else {
        url = strip_url_fragment(std::move(url));
    }
    return url;
}

CheckUrlResult check_manifest_url(
    const Environment& environment,
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& cookies,
    const std::filesystem::path& manifest_dir,
    int timeout_seconds) {
    const auto request_url = checkurl_request_url(url);
    if (looks_like_http_url(request_url)) {
        std::vector<std::pair<std::string, std::string>> headers{{"User-Agent", "sco"}, {"Referer", strip_url_filename_for_header(request_url)}};
        if (const auto cookie = cookie_header_from(cookies); !cookie.empty()) {
            headers.emplace_back("Cookie", cookie);
        }
        apply_private_host_headers(ConfigStore(environment.config_file), request_url, headers);

        const HttpClient client;
        const auto response = client.get(request_url, headers, timeout_seconds);
        if (response.status >= 200 && response.status < 300) {
            return {.url = request_url, .ok = true};
        }
        return {.url = request_url, .ok = false, .error = response.error.empty() ? "HTTP " + std::to_string(response.status) : response.error};
    }

    auto path = std::filesystem::path(request_url);
    if (path.is_relative()) {
        path = manifest_dir / path;
    }
    if (std::filesystem::is_regular_file(path)) {
        return {.url = request_url, .ok = true};
    }
    return {.url = request_url, .ok = false, .error = "file does not exist"};
}

bool wildcard_match_text(std::string pattern, const std::string& value) {
    pattern = regex_escape(pattern);
    std::size_t pos = 0;
    while ((pos = pattern.find("\\*", pos)) != std::string::npos) {
        pattern.replace(pos, 2, ".*");
        pos += 2;
    }
    pos = 0;
    while ((pos = pattern.find("\\?", pos)) != std::string::npos) {
        pattern.replace(pos, 2, ".");
        pos += 1;
    }
    const auto regex = std::regex("^" + pattern + "$", std::regex_constants::icase);
    return std::regex_match(value, regex);
}

std::vector<std::filesystem::path> checkurls_manifest_paths(const std::filesystem::path& dir, const std::string& app_pattern) {
    std::vector<std::filesystem::path> manifests;
    if (!std::filesystem::is_directory(dir)) {
        return manifests;
    }
    for (const auto& entry : std::filesystem::recursive_directory_iterator(dir)) {
        if (!entry.is_regular_file() || lower_ascii(entry.path().extension().string()) != ".json") {
            continue;
        }
        const auto name = entry.path().stem().string();
        if (wildcard_match_text(app_pattern.empty() ? "*" : app_pattern, name)) {
            manifests.push_back(entry.path());
        }
    }
    std::sort(manifests.begin(), manifests.end());
    return manifests;
}

std::vector<std::filesystem::path> checkver_manifest_paths(const std::filesystem::path& dir, const std::string& app_pattern) {
    std::vector<std::filesystem::path> manifests;
    auto path = std::filesystem::path(app_pattern);
    if (std::filesystem::is_regular_file(path)) {
        manifests.push_back(std::filesystem::absolute(path));
        return manifests;
    }
    if (path.is_relative()) {
        auto candidate = dir / path;
        if (std::filesystem::is_regular_file(candidate)) {
            manifests.push_back(std::filesystem::absolute(candidate));
            return manifests;
        }
    }
    return checkurls_manifest_paths(dir, app_pattern);
}

std::optional<std::string> manifest_json_version(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return std::nullopt;
    }

    try {
        nlohmann::json manifest;
        stream >> manifest;
        const auto* version = json_property(manifest, "version");
        if (version != nullptr && version->is_string()) {
            return version->get<std::string>();
        }
    } catch (const nlohmann::json::exception&) {
    }
    return std::nullopt;
}

std::optional<nlohmann::ordered_json> read_ordered_json_object(const std::filesystem::path& path, std::string& error) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        error = "cannot read " + path.string();
        return std::nullopt;
    }
    try {
        nlohmann::ordered_json value;
        stream >> value;
        if (!value.is_object()) {
            error = "JSON root is not an object";
            return std::nullopt;
        }
        return value;
    } catch (const nlohmann::json::exception& parse_error) {
        error = parse_error.what();
        return std::nullopt;
    }
}

nlohmann::ordered_json read_ordered_json_file_or_throw(const std::filesystem::path& path) {
    std::string error;
    auto value = read_ordered_json_object(path, error);
    if (!value) {
        throw std::runtime_error(error.empty() ? "cannot parse " + path.string() : error);
    }
    return *value;
}

void write_ordered_json_file(const std::filesystem::path& path, const nlohmann::ordered_json& value) {
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write " + path.string());
    }
    stream << value.dump(4) << '\n';
}

bool json_value_truthy(const nlohmann::json& value) {
    if (value.is_null()) {
        return false;
    }
    if (value.is_boolean()) {
        return value.get<bool>();
    }
    if (value.is_number_unsigned()) {
        return value.get<unsigned long long>() != 0;
    }
    if (value.is_number_integer()) {
        return value.get<long long>() != 0;
    }
    if (value.is_number_float()) {
        return value.get<double>() != 0.0;
    }
    if (value.is_string()) {
        return !value.get<std::string>().empty();
    }
    if (value.is_array()) {
        if (value.empty()) {
            return false;
        }
        return value.size() > 1 || json_value_truthy(value.front());
    }
    return true;
}

bool json_property_truthy(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    return value != nullptr && json_value_truthy(*value);
}

bool manifest_has_checkver(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return false;
    }
    try {
        nlohmann::json manifest;
        stream >> manifest;
        return json_property_truthy(manifest, "checkver");
    } catch (const nlohmann::json::exception&) {
        return false;
    }
}

bool manifest_has_autoupdate(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return false;
    }
    try {
        nlohmann::json manifest;
        stream >> manifest;
        return json_property_truthy(manifest, "autoupdate");
    } catch (const nlohmann::json::exception&) {
        return false;
    }
}

struct HtmlMetaTag {
    std::map<std::string, std::string> attributes;
};

struct DescribeResult {
    std::string description;
    std::string method;
};

std::string trim_copy(std::string value) {
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

std::string collapse_spaces(std::string value) {
    std::string collapsed;
    auto previous_space = true;
    for (const unsigned char ch : value) {
        if (std::isspace(ch)) {
            if (!previous_space) {
                collapsed.push_back(' ');
                previous_space = true;
            }
            continue;
        }
        collapsed.push_back(static_cast<char>(ch));
        previous_space = false;
    }
    if (!collapsed.empty() && collapsed.back() == ' ') {
        collapsed.pop_back();
    }
    return collapsed;
}

std::string clean_description(std::string description) {
    for (auto& ch : description) {
        if (ch == '\r' || ch == '\n' || ch == '\t') {
            ch = ' ';
        }
    }
    return collapse_spaces(std::move(description));
}

std::string html_decode_entities(std::string value) {
    value = replace_all_copy(std::move(value), "&nbsp;", " ");
    value = replace_all_copy(std::move(value), "&nbsp", " ");
    value = replace_all_copy(std::move(value), "&gt;", ">");
    value = replace_all_copy(std::move(value), "&gt", ">");
    value = replace_all_copy(std::move(value), "&lt;", "<");
    value = replace_all_copy(std::move(value), "&lt", "<");
    value = replace_all_copy(std::move(value), "&quot;", "\"");
    value = replace_all_copy(std::move(value), "&quot", "\"");
    value = replace_all_copy(std::move(value), "&amp;", "&");
    value = replace_all_copy(std::move(value), "&amp", "&");

    static const std::regex decimal_entity(R"(&#(\d+);?)");
    std::string decoded;
    std::size_t cursor = 0;
    for (std::sregex_iterator it(value.begin(), value.end(), decimal_entity), end; it != end; ++it) {
        const auto& match = *it;
        decoded.append(value, cursor, static_cast<std::size_t>(match.position()) - cursor);
        try {
            const auto codepoint = std::stoul(match[1].str());
            if (codepoint > 0 && codepoint < 128) {
                decoded.push_back(static_cast<char>(codepoint));
            } else {
                decoded += match.str();
            }
        } catch (const std::exception&) {
            decoded += match.str();
        }
        cursor = static_cast<std::size_t>(match.position() + match.length());
    }
    decoded.append(value, cursor, std::string::npos);
    return decoded;
}

std::vector<HtmlMetaTag> describe_meta_tags(const std::string& html) {
    static const std::regex meta_pattern(R"(<meta\s+[^>]*>)", std::regex_constants::icase);
    static const std::regex attr_pattern(R"ATTR(([A-Za-z_][A-Za-z0-9_:-]*)\s*=\s*"([^"]*)")ATTR", std::regex_constants::icase);

    std::vector<HtmlMetaTag> tags;
    for (std::sregex_iterator meta(html.begin(), html.end(), meta_pattern), meta_end; meta != meta_end; ++meta) {
        HtmlMetaTag tag;
        const auto text = meta->str();
        for (std::sregex_iterator attr(text.begin(), text.end(), attr_pattern), attr_end; attr != attr_end; ++attr) {
            tag.attributes[lower_ascii((*attr)[1].str())] = html_decode_entities((*attr)[2].str());
        }
        tags.push_back(std::move(tag));
    }
    return tags;
}

std::string describe_meta_content(const std::vector<HtmlMetaTag>& tags, const std::string& attribute, const std::string& search) {
    const auto key = lower_ascii(attribute);
    for (const auto& tag : tags) {
        const auto attr = tag.attributes.find(key);
        const auto content = tag.attributes.find("content");
        if (attr != tag.attributes.end() && content != tag.attributes.end() && ascii_equal_ignore_case(attr->second, search)) {
            return content->second;
        }
    }
    return {};
}

std::optional<std::string> describe_url_origin(const std::string& url) {
    static const std::regex pattern(R"(^([a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]+))");
    std::smatch match;
    if (std::regex_search(url, match, pattern)) {
        return match[1].str();
    }
    return std::nullopt;
}

std::string describe_url_directory(const std::string& url) {
    auto clean = strip_url_fragment(url);
    if (const auto query = clean.find('?'); query != std::string::npos) {
        clean.erase(query);
    }
    const auto slash = clean.find_last_of('/');
    if (slash == std::string::npos || slash < clean.find("://") + 2) {
        return clean + "/";
    }
    return clean.substr(0, slash + 1);
}

std::string describe_resolve_url(const std::string& base_url, std::string target) {
    target = clean_description(std::move(target));
    if (looks_like_http_url(target)) {
        return target;
    }
    if (target.rfind("//", 0) == 0) {
        const auto scheme_end = base_url.find(':');
        return scheme_end == std::string::npos ? "http:" + target : base_url.substr(0, scheme_end + 1) + target;
    }
    if (!target.empty() && target.front() == '/') {
        if (const auto origin = describe_url_origin(base_url)) {
            return *origin + target;
        }
    }
    return describe_url_directory(base_url) + target;
}

std::optional<std::string> describe_meta_refresh(const std::vector<HtmlMetaTag>& tags, const std::string& url) {
    const auto refresh = describe_meta_content(tags, "http-equiv", "refresh");
    if (refresh.empty()) {
        return std::nullopt;
    }
    static const std::regex pattern(R"(\d+;\s*url\s*=\s*(.*))", std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_search(refresh, match, pattern)) {
        return std::nullopt;
    }
    auto target = trim_copy(match[1].str());
    while (!target.empty() && (target.front() == '\'' || target.front() == '"')) {
        target.erase(target.begin());
    }
    while (!target.empty() && (target.back() == '\'' || target.back() == '"')) {
        target.pop_back();
    }
    if (target.empty()) {
        return std::nullopt;
    }
    return describe_resolve_url(url, target);
}

std::optional<std::string> describe_html_body(const std::string& html) {
    static const std::regex body_pattern(R"(<body[^>]*>([\s\S]*?)</body>)", std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_search(html, match, body_pattern)) {
        return std::nullopt;
    }
    auto body = match[1].str();
    body = std::regex_replace(body, std::regex(R"(<script[^>]*>[\s\S]*?</script>)", std::regex_constants::icase), " ");
    body = std::regex_replace(body, std::regex(R"(<!--[\s\S]*?-->)"), " ");
    return body;
}

std::string strip_html_text(std::string html) {
    html = std::regex_replace(html, std::regex(R"(<[^>]*>)"), " ");
    html = html_decode_entities(std::move(html));
    html = std::regex_replace(html, std::regex(R"(\s+([\.,]))"), "$1");
    return clean_description(std::move(html));
}

std::string describe_text_from_html(const std::string& html) {
    if (const auto body = describe_html_body(html)) {
        return strip_html_text(*body);
    }
    return {};
}

std::optional<std::string> describe_find_is_text(const std::string& text) {
    static const std::regex pattern(R"((?:^|[\.\n])\s*([^\.\n]+? is .+?[\.!]))", std::regex_constants::icase);
    std::smatch match;
    if (std::regex_search(text, match, pattern)) {
        return clean_description(match[1].str());
    }
    return std::nullopt;
}

std::optional<std::string> describe_first_paragraph(const std::string& html) {
    const auto body = describe_html_body(html);
    if (!body) {
        return std::nullopt;
    }
    static const std::regex paragraph_pattern(R"(<p[^>]*>([\s\S]*?)</p>)", std::regex_constants::icase);
    std::smatch match;
    if (std::regex_search(*body, match, paragraph_pattern)) {
        const auto paragraph = strip_html_text(match[1].str());
        if (!paragraph.empty()) {
            return paragraph;
        }
    }
    return std::nullopt;
}

std::optional<DescribeResult> describe_find_description(const std::string& url, const std::string& html, bool redirected = false) {
    const auto meta = describe_meta_tags(html);

    if (const auto description = describe_meta_content(meta, "property", "og:description"); !description.empty()) {
        return DescribeResult{.description = clean_description(description), .method = "<meta property=\"og:description\">"};
    }

    if (const auto description = describe_meta_content(meta, "name", "description"); !description.empty()) {
        return DescribeResult{.description = clean_description(description), .method = "<meta name=\"description\">"};
    }

    if (!redirected) {
        if (const auto refresh = describe_meta_refresh(meta, url)) {
            const HttpClient client;
            const auto response = client.get(*refresh, {{"User-Agent", "sco"}});
            if (response.status >= 200 && response.status < 300) {
                return describe_find_description(*refresh, response.body, true);
            }
        }
    }

    if (const auto description = describe_find_is_text(describe_text_from_html(html))) {
        return DescribeResult{.description = clean_description(*description), .method = "text"};
    }

    if (const auto description = describe_first_paragraph(html)) {
        return DescribeResult{.description = clean_description(*description), .method = "first <p>"};
    }

    return std::nullopt;
}

std::vector<CheckUrlManifestView> checkurls_manifest_views(const std::filesystem::path& path) {
    std::vector<CheckUrlManifestView> manifests;
    try {
        const auto manifest = read_ordered_json_file_or_throw(path);
        CheckUrlManifestView view;
        view.cookies = checkurl_cookie_values(manifest);
        view.urls = checkurl_urls_from_manifest(manifest);
        if (!view.urls.empty()) {
            manifests.push_back(std::move(view));
        }
    } catch (const std::exception&) {
    }
    return manifests;
}

bool command_available(const std::string& command) {
    const auto probe = "where " + quote_process_argument(command) + " >nul 2>nul";
    return std::system(probe.c_str()) == 0;
}

std::string drive_root_for(const std::filesystem::path& path) {
    auto absolute = std::filesystem::absolute(path);
    auto root = absolute.root_name().string();
    if (root.empty()) {
        return {};
    }
    root += "\\";
    return root;
}

bool is_ntfs_volume(const std::filesystem::path& path) {
    const auto root = drive_root_for(path);
    if (root.empty()) {
        return true;
    }

    char filesystem_name[MAX_PATH + 1]{};
    if (GetVolumeInformationA(root.c_str(), nullptr, 0, nullptr, nullptr, nullptr, filesystem_name, MAX_PATH) == 0) {
        return true;
    }
    return std::string(filesystem_name) == "NTFS";
}

std::optional<DWORD> registry_dword(HKEY root, const char* path, const char* name) {
    HKEY key = nullptr;
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &key) != ERROR_SUCCESS) {
        return std::nullopt;
    }
    DWORD value = 0;
    DWORD size = sizeof(value);
    DWORD type = 0;
    const auto status = RegQueryValueExA(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(&value), &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS || type != REG_DWORD) {
        return std::nullopt;
    }
    return value;
}

bool long_paths_enabled() {
    const auto value = registry_dword(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\FileSystem", "LongPathsEnabled");
    return value && *value != 0;
}

bool developer_mode_enabled() {
    const auto value = registry_dword(HKEY_LOCAL_MACHINE, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AppModelUnlock", "AllowDevelopmentWithoutDevLicense");
    return value && *value == 1;
}

bool current_user_is_admin() {
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID administrators = nullptr;
    if (AllocateAndInitializeSid(
            &authority,
            2,
            SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_ADMINS,
            0,
            0,
            0,
            0,
            0,
            0,
            &administrators) == 0) {
        return false;
    }

    BOOL member = FALSE;
    const auto ok = CheckTokenMembership(nullptr, administrators, &member);
    FreeSid(administrators);
    return ok != 0 && member != FALSE;
}

std::string ps_single_quoted(std::string value) {
    std::string quoted = "'";
    for (const auto ch : value) {
        if (ch == '\'') {
            quoted += "''";
        } else {
            quoted += ch;
        }
    }
    quoted += "'";
    return quoted;
}

bool windows_defender_exclusion_ok(const std::filesystem::path& path) {
    const auto install_path = std::filesystem::absolute(path).lexically_normal().string();
    const auto script =
        "$ErrorActionPreference='SilentlyContinue';"
        "if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { 'pass'; exit 0 };"
        "$service=Get-Service -Name WinDefend -ErrorAction SilentlyContinue;"
        "$preference=Get-MpPreference;"
        "if ($preference.DisableRealtimeMonitoring) { 'pass'; exit 0 };"
        "if ($service -and $service.Status -eq 'Running' -and -not (@($preference.ExclusionPath) -contains " + ps_single_quoted(install_path) + ")) { 'missing'; exit 0 };"
        "'pass'";
    const auto output = trim_ascii(run_command_capture("powershell -NoProfile -ExecutionPolicy Bypass -Command " + quote_process_argument(script) + " 2>NUL"));
    return output != "missing";
}

bool should_check_windows_defender() {
    if (!current_user_is_admin()) {
        return false;
    }
    if (const auto username = std::getenv("USERNAME"); username != nullptr && std::string(username) == "WDAGUtilityAccount") {
        return false;
    }
    return true;
}

bool check_windows_defender_path(const std::filesystem::path& path, std::ostream& out) {
    if (windows_defender_exclusion_ok(path)) {
        return true;
    }
    out << "INFO  Windows Defender may slow down or disrupt installs with realtime scanning.\n"
        << "  Consider running:\n"
        << "    sudo Add-MpPreference -ExclusionPath '" << path.string() << "'\n"
        << "  (Requires 'sudo' command. Run 'sco install sudo' if you don't have it.)\n";
    return false;
}

std::vector<std::string> dependency_references_for_manifest(const Environment& environment, const Manifest& manifest);

struct InstallPlanItem {
    std::filesystem::path manifest_path;
    std::string source_url;
};

std::string dependency_identity_key(const std::string& source, const std::string& name) {
    if (source.empty()) {
        return lower_ascii(name);
    }
    return lower_ascii(source) + "/" + lower_ascii(name);
}

std::string install_source_url_for_reference(const std::string& app) {
    const auto reference = parse_app_version_reference(app);
    return looks_like_http_url(reference.app) ? reference.app : std::string{};
}

std::string installed_manifest_url_for_install_reference(const Environment& environment, const std::string& app) {
    const auto reference = parse_app_version_reference(app);
    if (looks_like_http_url(reference.app) || lower_ascii(std::filesystem::path(reference.app).extension().string()) == ".json") {
        return {};
    }

    auto name = reference.app;
    if (const auto slash = name.find_last_of("/\\"); slash != std::string::npos) {
        name = name.substr(slash + 1);
    }
    for (const bool global : {true, false}) {
        if (select_current_version(environment, name, global).empty()) {
            continue;
        }
        if (const auto url = installed_app_manifest_url(environment, name, global)) {
            return *url;
        }
    }
    return {};
}

bool collect_install_order(
    const Environment& environment,
    const std::string& app,
    const InstallOptions& options,
    std::ostream& err,
    std::set<std::string>& visiting,
    std::set<std::string>& visited,
    std::vector<std::string>& dependency_stack,
    std::vector<InstallPlanItem>& manifests) {
    const auto manifest_path = resolve_install_manifest(environment, app, err);
    if (manifest_path.empty()) {
        return false;
    }

    const auto manifest = load_manifest_file(manifest_path, std::nullopt, options.architecture);
    const auto key = dependency_identity_key(bucket_name_for_manifest(environment, manifest_path), manifest.name);
    if (visited.contains(key)) {
        return true;
    }
    if (visiting.contains(key)) {
        const auto parent = dependency_stack.empty() ? manifest.name : dependency_stack.back();
        err << "ERROR Circular dependency detected: '" << parent << "' -> '" << app << "'.\n";
        return false;
    }

    visiting.insert(key);
    dependency_stack.push_back(manifest.name);
    auto unwind = [&]() {
        dependency_stack.pop_back();
        visiting.erase(key);
    };
    if (!options.independent) {
        for (const auto& dependency : dependency_references_for_manifest(environment, manifest)) {
            if (!collect_install_order(environment, dependency, options, err, visiting, visited, dependency_stack, manifests)) {
                unwind();
                return false;
            }
        }
    }
    unwind();
    visited.insert(key);
    auto source_url = install_source_url_for_reference(app);
    if (source_url.empty()) {
        source_url = installed_manifest_url_for_install_reference(environment, app);
    }
    manifests.push_back(InstallPlanItem{
        .manifest_path = manifest_path,
        .source_url = std::move(source_url),
    });
    return true;
}

bool app_installed_in_any_scope(const Environment& environment, const std::string& app) {
    return !select_current_version(environment, app, false).empty()
        || !select_current_version(environment, app, true).empty();
}

bool install_missing_update_dependencies(
    const Environment& environment,
    const Manifest& manifest,
    const InstallOptions& options,
    std::ostream& out,
    std::ostream& err) {
    if (options.independent) {
        return true;
    }

    std::set<std::string> visiting;
    std::set<std::string> visited;
    std::vector<std::string> dependency_stack;
    std::vector<InstallPlanItem> install_order;
    for (const auto& dependency : dependency_references_for_manifest(environment, manifest)) {
        if (!collect_install_order(environment, dependency, options, err, visiting, visited, dependency_stack, install_order)) {
            return false;
        }
    }

    for (const auto& item : install_order) {
        const auto dependency_manifest = load_manifest_file(item.manifest_path, std::nullopt, options.architecture);
        if (app_installed_in_any_scope(environment, dependency_manifest.name)) {
            continue;
        }
        if (!dependency_manifest.supports_current_architecture) {
            throw std::runtime_error("'" + dependency_manifest.name + "' doesn't support current architecture!");
        }

        auto dependency_options = options;
        dependency_options.force = false;
        dependency_options.report_old_uninstall = false;
        dependency_options.source_bucket.clear();
        dependency_options.source_url = item.source_url;

        write_nightly_install_warning(dependency_manifest, out);
        write_install_start(environment, item.manifest_path, dependency_manifest, out);
        InstallResult result;
        try {
            result = install_manifest_file(environment, item.manifest_path, dependency_options);
        } catch (const HashCheckError& error) {
            write_install_hash_failure(environment, error, out);
            return false;
        } catch (const ArtifactFetchError& error) {
            write_install_artifact_fetch_failure(error, out);
            return false;
        }
        write_install_messages(result, out);
        write_install_warnings(result, out);
        write_install_result(result, out);
    }
    return true;
}

bool helper_app_file_exists(const Environment& environment, const std::string& app, const std::string& file) {
    for (const auto global : {false, true}) {
        if (std::filesystem::is_regular_file(current_dir(environment, app, global) / file)) {
            return true;
        }
    }
    return false;
}

bool installation_helper_installed(const Environment& environment, const std::string& helper) {
    if (helper == "7zip") {
        return helper_app_file_exists(environment, "7zip", "7z.exe");
    }
    if (helper == "lessmsi") {
        return helper_app_file_exists(environment, "lessmsi", "lessmsi.exe");
    }
    if (helper == "innounp") {
        return helper_app_file_exists(environment, "innounp-unicode", "innounp.exe") ||
            helper_app_file_exists(environment, "innounp", "innounp.exe");
    }
    if (helper == "dark") {
        return helper_app_file_exists(environment, "wixtoolset", "wix.exe") ||
            helper_app_file_exists(environment, "dark", "dark.exe");
    }
    return false;
}

bool url_requires_7zip(const std::string& url) {
    const auto filename = lower_ascii(url_filename(url));
    static const std::regex pattern(R"(\.(001|7z|bz(ip)?2?|gz|img|iso|lzma|lzh|nupkg|rar|tar|t[abgpx]z2?|t?zst|xz)(\.[^\d.]+)?$)");
    return std::regex_search(filename, pattern);
}

bool url_requires_lessmsi(const std::string& url) {
    return lower_ascii(url_filename(url)).ends_with(".msi");
}

bool any_url_matches(const std::vector<std::string>& urls, bool (*predicate)(const std::string&)) {
    return std::any_of(urls.begin(), urls.end(), predicate);
}

bool script_contains_helper_call(const std::vector<std::string>& lines, std::string_view call) {
    const auto needle = lower_ascii(std::string(call));
    for (const auto& line : lines) {
        if (lower_ascii(line).find(needle) != std::string::npos) {
            return true;
        }
    }
    return false;
}

bool manifest_script_contains_helper_call(const Manifest& manifest, std::string_view call) {
    return script_contains_helper_call(manifest.pre_install, call) ||
        script_contains_helper_call(manifest.installer.script, call) ||
        script_contains_helper_call(manifest.post_install, call);
}

void append_dependency_once(std::vector<std::string>& dependencies, const std::string& dependency) {
    if (!dependency.empty() && std::find(dependencies.begin(), dependencies.end(), dependency) == dependencies.end()) {
        dependencies.push_back(dependency);
    }
}

std::vector<std::string> installation_helpers_for_manifest(const Environment& environment, const Manifest& manifest) {
    std::vector<std::string> helpers;
    const auto append_helper_if_missing = [&](const std::string& helper) {
        if (!installation_helper_installed(environment, helper)) {
            append_dependency_once(helpers, helper);
        }
    };

    if ((any_url_matches(manifest.urls, url_requires_7zip) ||
            manifest_script_contains_helper_call(manifest, "Expand-7zipArchive ")) &&
        !config_bool(environment, "use_external_7zip")) {
        append_helper_if_missing("7zip");
    }
    if ((any_url_matches(manifest.urls, url_requires_lessmsi) ||
            manifest_script_contains_helper_call(manifest, "Expand-MsiArchive ")) &&
        config_bool(environment, "use_lessmsi")) {
        append_helper_if_missing("lessmsi");
    }
    if (manifest.innosetup || manifest_script_contains_helper_call(manifest, "Expand-InnoArchive ")) {
        append_helper_if_missing("innounp");
    }
    if (manifest_script_contains_helper_call(manifest, "Expand-DarkArchive ")) {
        append_helper_if_missing("dark");
    }
    return helpers;
}

std::vector<std::string> dependency_references_for_manifest(const Environment& environment, const Manifest& manifest) {
    auto dependencies = installation_helpers_for_manifest(environment, manifest);
    for (const auto& dependency : manifest.depends) {
        append_dependency_once(dependencies, dependency);
    }
    return dependencies;
}

struct ReadManifestTarget {
    std::filesystem::path path;
    std::string name;
    std::string source;
    bool installed = false;
    bool global = false;
};

enum class InstalledScopePreference {
    LocalFirst,
    GlobalFirst,
};

std::string app_name_for_manifest_reference(const std::string& reference) {
    const auto parsed = parse_app_version_reference(reference);
    const auto& app = parsed.app;
    if (looks_like_http_url(app)) {
        const auto filename = remote_filename_from_url(app);
        return lower_ascii(std::filesystem::path(filename).extension().string()) == ".json" ? std::filesystem::path(filename).stem().string() : filename;
    }

    auto path = std::filesystem::path(app);
    if (lower_ascii(path.extension().string()) == ".json") {
        return path.stem().string();
    }
    if (const auto slash = app.find_last_of("/\\"); slash != std::string::npos) {
        return app.substr(slash + 1);
    }
    return app;
}

std::optional<ReadManifestTarget> target_from_manifest_path(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const std::string& name,
    bool installed = false,
    bool global = false) {
    if (!std::filesystem::is_regular_file(manifest_path)) {
        return std::nullopt;
    }

    const auto canonical = std::filesystem::weakly_canonical(manifest_path);
    auto source = bucket_name_for_manifest(environment, canonical);
    if (source.empty()) {
        source = std::filesystem::absolute(canonical).generic_string();
    }
    return ReadManifestTarget{
        .path = canonical,
        .name = name.empty() ? canonical.stem().string() : name,
        .source = std::move(source),
        .installed = installed,
        .global = global,
    };
}

std::optional<ReadManifestTarget> installed_manifest_if_newer_than_source(
    const Environment& environment,
    const std::string& app,
    const std::string& version,
    bool global,
    const std::string& source,
    const std::filesystem::path& source_manifest_path) {
    if (version.empty()) {
        return std::nullopt;
    }

    try {
        auto source_version = load_manifest_file(source_manifest_path, app).version;
        if (source_version == "nightly") {
            source_version = nightly_version();
        }
        if (compare_versions(source_version, version, config_bool(environment, "update_nightly")) <= 0) {
            return std::nullopt;
        }
    } catch (const std::exception&) {
        return std::nullopt;
    }

    const auto version_dir = app_dir(environment, app, global) / version;
    for (const auto& manifest_path : {current_dir(environment, app, global) / "manifest.json", version_dir / "manifest.json"}) {
        if (auto target = target_from_manifest_path(environment, manifest_path, app, true, global)) {
            target->source = source;
            return target;
        }
    }
    return std::nullopt;
}

std::optional<ReadManifestTarget> installed_manifest_target(
    const Environment& environment,
    const std::string& app,
    bool global,
    std::string_view command) {
    const auto version = select_current_version(environment, app, global);
    if (version.empty()) {
        return std::nullopt;
    }

    const auto version_dir = app_dir(environment, app, global) / version;
    const auto install = read_json_from_path_or_url((version_dir / "install.json").string()).value_or(nlohmann::json::object());

    if (const auto bucket = json_string_field(install, "bucket"); !bucket.empty()) {
        if (const auto bucket_manifest = find_manifest_in_buckets(environment, bucket + "/" + app)) {
            if (auto installed_target = installed_manifest_if_newer_than_source(environment, app, version, global, bucket, *bucket_manifest)) {
                return installed_target;
            }
            auto target = target_from_manifest_path(environment, *bucket_manifest, app, true, global);
            if (target) {
                target->source = bucket;
                return target;
            }
        }
        if (const auto deprecated_manifest = deprecated_manifest_path(environment, app, bucket)) {
            if (auto installed_target = installed_manifest_if_newer_than_source(environment, app, version, global, bucket, *deprecated_manifest)) {
                return installed_target;
            }
            auto target = target_from_manifest_path(environment, *deprecated_manifest, app, true, global);
            if (target) {
                target->source = bucket;
                return target;
            }
        }
    }

    std::string install_source;
    for (const auto& key : {"url", "manifest"}) {
        const auto source = json_string_field(install, key);
        if (source.empty()) {
            continue;
        }
        if (install_source.empty()) {
            install_source = source;
        }

        if (looks_like_http_url(source)) {
            std::ostringstream ignored;
            const auto manifest_path = materialize_manifest_url(environment, source, ignored, command);
            if (!manifest_path.empty()) {
                return ReadManifestTarget{
                    .path = manifest_path,
                    .name = app,
                    .source = source,
                    .installed = true,
                    .global = global,
                };
            }
            continue;
        }

        if (auto target = target_from_manifest_path(environment, std::filesystem::path(source), app, true, global)) {
            return target;
        }
    }

    for (const auto& manifest_path : {current_dir(environment, app, global) / "manifest.json", version_dir / "manifest.json"}) {
        if (auto target = target_from_manifest_path(environment, manifest_path, app, true, global)) {
            if (!install_source.empty()) {
                target->source = install_source;
            }
            return target;
        }
    }

    return std::nullopt;
}

std::optional<ReadManifestTarget> resolve_app_manifest_target_for_read(
    const Environment& environment,
    const std::string& reference,
    std::string* error = nullptr,
    std::string_view command = "manifest",
    InstalledScopePreference scope_preference = InstalledScopePreference::LocalFirst) {
    if (error) {
        error->clear();
    }

    const auto parsed = parse_app_version_reference(reference);
    const auto& app = parsed.app;
    if (looks_like_http_url(app)) {
        std::ostringstream errors;
        const auto manifest_path = materialize_manifest_url(environment, app, errors, command);
        if (manifest_path.empty()) {
            if (error) {
                *error = errors.str();
            }
            return std::nullopt;
        }
        return ReadManifestTarget{
            .path = manifest_path,
            .name = app_name_for_manifest_reference(app),
            .source = app,
        };
    }

    auto path = std::filesystem::path(app);
    if (lower_ascii(path.extension().string()) == ".json" && std::filesystem::is_regular_file(path)) {
        return target_from_manifest_path(environment, path, path.stem().string());
    }

    const auto installed_name = app_name_for_manifest_reference(reference);
    const std::array<bool, 2> scope_order = scope_preference == InstalledScopePreference::GlobalFirst
        ? std::array<bool, 2>{true, false}
        : std::array<bool, 2>{false, true};
    for (const bool global : scope_order) {
        if (auto target = installed_manifest_target(environment, installed_name, global, command)) {
            return target;
        }
    }

    if (const auto bucket_manifest = find_manifest_in_buckets(environment, app)) {
        return target_from_manifest_path(environment, *bucket_manifest, app_name_for_manifest_reference(reference));
    }

    return std::nullopt;
}

std::optional<std::filesystem::path> resolve_app_manifest_for_read(
    const Environment& environment,
    const std::string& app,
    InstalledScopePreference scope_preference = InstalledScopePreference::LocalFirst) {
    const auto target = resolve_app_manifest_target_for_read(environment, app, nullptr, "manifest", scope_preference);
    if (!target) {
        return std::nullopt;
    }
    return target->path;
}

std::string source_path_key(const std::filesystem::path& path) {
    std::error_code error;
    auto normalized = std::filesystem::weakly_canonical(path, error);
    if (error) {
        normalized = std::filesystem::absolute(path, error);
    }
    auto key = error ? path.generic_string() : normalized.generic_string();
#ifdef _WIN32
    key = lower_ascii(std::move(key));
#endif
    return key;
}

bool equivalent_manifest_source(const std::string& lhs, const std::string& rhs) {
    if (lhs.empty() || rhs.empty()) {
        return false;
    }
    if (looks_like_http_url(lhs) || looks_like_http_url(rhs)) {
        return lhs == rhs;
    }
    return source_path_key(lhs) == source_path_key(rhs);
}

bool info_target_matches_installed_source(
    const Environment& environment,
    const ReadManifestTarget& target,
    const std::string& app,
    bool global) {
    if (target.installed) {
        return true;
    }

    const auto install = read_json_from_path_or_url((current_dir(environment, app, global) / "install.json").string())
        .value_or(nlohmann::json::object());
    if (const auto bucket = json_string_field(install, "bucket"); !bucket.empty() && bucket == target.source) {
        return true;
    }

    for (const auto& key : {"url", "manifest"}) {
        const auto source = json_string_field(install, key);
        if (equivalent_manifest_source(source, target.source) || equivalent_manifest_source(source, target.path.generic_string())) {
            return true;
        }
    }
    return false;
}

bool collect_dependency_order(
    const Environment& environment,
    const std::string& reference,
    const InstallOptions& options,
    InstalledScopePreference scope_preference,
    std::ostream& err,
    std::set<std::string>& visiting,
    std::set<std::string>& visited,
    std::vector<std::string>& dependency_stack,
    std::vector<ReadManifestTarget>& targets) {
    std::string resolve_error;
    auto target = resolve_app_manifest_target_for_read(environment, reference, &resolve_error, "depends", scope_preference);
    if (!target) {
        if (!resolve_error.empty()) {
            err << resolve_error;
        } else {
            const auto parsed = parse_app_version_reference(reference);
            const auto slash = parsed.app.find_first_of("/\\");
            if (slash != std::string::npos && slash > 0 && slash + 1 < parsed.app.size()) {
                const auto bucket = parsed.app.substr(0, slash);
                const auto app = parsed.app.substr(slash + 1);
                const auto local_buckets = list_local_buckets(environment);
                const auto local_bucket = std::any_of(local_buckets.begin(), local_buckets.end(), [&](const auto& candidate) {
                    return lower_ascii(candidate.name) == lower_ascii(bucket);
                });
                if (!local_bucket) {
                    const auto known_buckets = list_known_buckets_for_environment(environment);
                    const auto known_bucket = std::any_of(known_buckets.begin(), known_buckets.end(), [&](const auto& candidate) {
                        return lower_ascii(candidate.name) == lower_ascii(bucket);
                    });
                    err << "WARN  Bucket '" << bucket << "' not added. Add it with ";
                    if (known_bucket) {
                        err << "'sco bucket add " << bucket << "' or ";
                    }
                    err << "'sco bucket add " << bucket << " <repo>'.\n";
                }
                err << "ERROR Couldn't find manifest for '" << app << "' from '" << bucket << "' bucket.\n";
            } else {
                err << "ERROR Couldn't find manifest for '" << reference << "'.\n";
            }
        }
        return false;
    }

    const auto manifest = load_manifest_file(target->path, target->name, options.architecture);
    target->name = manifest.name;
    const auto key = dependency_identity_key(target->source, manifest.name);
    if (visited.contains(key)) {
        return true;
    }
    if (visiting.contains(key)) {
        const auto parent = dependency_stack.empty() ? manifest.name : dependency_stack.back();
        err << "ERROR Circular dependency detected: '" << parent << "' -> '" << reference << "'.\n";
        return false;
    }

    visiting.insert(key);
    dependency_stack.push_back(manifest.name);
    auto unwind = [&]() {
        dependency_stack.pop_back();
        visiting.erase(key);
    };
    for (const auto& dependency : dependency_references_for_manifest(environment, manifest)) {
        if (!collect_dependency_order(environment, dependency, options, scope_preference, err, visiting, visited, dependency_stack, targets)) {
            unwind();
            return false;
        }
    }
    unwind();
    visited.insert(key);
    targets.push_back(std::move(*target));
    return true;
}

struct ScopedAppTarget {
    std::string app;
    bool global = false;
};

std::string installed_app_argument_name(const std::string& app) {
    auto name = app;
    if (const auto at = name.rfind('@'); at != std::string::npos && at + 1 < name.size()) {
        name.erase(at);
    }
    if (const auto slash = name.find_last_of("/\\"); slash != std::string::npos) {
        name = name.substr(slash + 1);
    }
    return name;
}

std::vector<std::string> unique_installed_app_arguments(const std::vector<std::string>& apps) {
    std::vector<std::string> unique;
    std::set<std::string> seen;
    for (const auto& app : apps) {
        if (seen.insert(app).second) {
            unique.push_back(app);
        }
    }
    return unique;
}

std::optional<ScopedAppTarget> select_installed_app_target(
    const Environment& environment,
    const std::string& app,
    bool global,
    std::ostream& out) {
    const auto name = installed_app_argument_name(app);
    const auto requested = app_dir(environment, name, global);
    if (std::filesystem::exists(requested)) {
        write_incorrect_install_if_failed(environment, name, global, out);
        return ScopedAppTarget{.app = name, .global = global};
    }

    const auto other_scope = app_dir(environment, name, !global);
    if (std::filesystem::exists(other_scope)) {
        out << "ERROR '" << name << "' isn't installed " << (global ? "globally" : "locally")
            << ", but it may be installed " << (global ? "locally" : "globally") << ".\n"
            << "WARN  Try again " << (global ? "without" : "with") << " the --global (or -g) flag instead.\n";
    } else {
        out << "ERROR '" << name << "' isn't installed.\n";
    }
    return std::nullopt;
}

std::string normalize_hash_value(std::string hash) {
    if (const auto colon = hash.find(':'); colon != std::string::npos) {
        hash = hash.substr(colon + 1);
    }
    hash.erase(std::remove_if(hash.begin(), hash.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), hash.end());
    std::transform(hash.begin(), hash.end(), hash.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return hash;
}

struct VirusTotalHashCandidate {
    std::string algorithm;
    std::string value;
    bool present = false;
    bool unsupported_algorithm = false;
};

VirusTotalHashCandidate parse_virustotal_hash(std::string hash) {
    hash.erase(std::remove_if(hash.begin(), hash.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), hash.end());
    if (hash.empty()) {
        return {};
    }

    auto lower = [](std::string value) {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
        return value;
    };

    if (const auto colon = hash.find(':'); colon != std::string::npos) {
        auto algorithm = lower(hash.substr(0, colon));
        auto value = lower(hash.substr(colon + 1));
        const auto present = !value.empty();
        if (algorithm != "md5" && algorithm != "sha1" && algorithm != "sha256") {
            return {.algorithm = std::move(algorithm), .unsupported_algorithm = true};
        }
        return {.algorithm = std::move(algorithm), .value = std::move(value), .present = present};
    }

    auto value = lower(std::move(hash));
    const auto present = !value.empty();
    return {.algorithm = "sha256", .value = std::move(value), .present = present};
}

bool supported_virustotal_hash(const std::string& hash) {
    return hash.size() == 32 || hash.size() == 40 || hash.size() == 64;
}

std::string trim_trailing_slashes(std::string value) {
    while (!value.empty() && value.back() == '/') {
        value.pop_back();
    }
    return value;
}

std::string virustotal_api_base_url() {
    if (const char* override_url = std::getenv("SCO_VIRUSTOTAL_API_URL"); override_url != nullptr && override_url[0] != '\0') {
        return trim_trailing_slashes(override_url);
    }
    return "https://www.virustotal.com/api/v3";
}

std::string virustotal_file_report_url(const std::string& hash) {
    return "https://www.virustotal.com/gui/file/" + hash;
}

std::string virustotal_url_report_url(const std::string& id) {
    return "https://www.virustotal.com/gui/url/" + id;
}

std::string base64_url_without_padding(const std::string& value) {
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string encoded;
    std::uint32_t bits = 0;
    int bit_count = 0;
    for (const auto ch : value) {
        bits = (bits << 8) | static_cast<unsigned char>(ch);
        bit_count += 8;
        while (bit_count >= 6) {
            bit_count -= 6;
            auto out = alphabet[(bits >> bit_count) & 0x3f];
            if (out == '+') {
                out = '-';
            } else if (out == '/') {
                out = '_';
            }
            encoded.push_back(out);
        }
    }
    if (bit_count > 0) {
        auto out = alphabet[(bits << (6 - bit_count)) & 0x3f];
        if (out == '+') {
            out = '-';
        } else if (out == '/') {
            out = '_';
        }
        encoded.push_back(out);
    }
    return encoded;
}

std::string form_url_encode(const std::string& value) {
    static constexpr char hex[] = "0123456789ABCDEF";
    std::string encoded;
    for (const auto ch : value) {
        const auto byte = static_cast<unsigned char>(ch);
        if ((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.' || byte == '~') {
            encoded.push_back(static_cast<char>(byte));
        } else if (byte == ' ') {
            encoded.push_back('+');
        } else {
            encoded.push_back('%');
            encoded.push_back(hex[byte >> 4]);
            encoded.push_back(hex[byte & 0x0f]);
        }
    }
    return encoded;
}

struct DownloadHash {
    std::string algorithm;
    std::string expected;
};

DownloadHash parse_download_hash(std::string value) {
    value.erase(std::remove_if(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), value.end());
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });

    if (const auto colon = value.find(':'); colon != std::string::npos) {
        return DownloadHash{.algorithm = value.substr(0, colon), .expected = value.substr(colon + 1)};
    }
    return DownloadHash{.algorithm = "sha256", .expected = std::move(value)};
}

bool supported_download_hash_algorithm(const std::string& algorithm) {
    return algorithm == "md5" || algorithm == "sha1" || algorithm == "sha256" || algorithm == "sha512";
}

std::string first_file_bytes_hex(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return {};
    }

    std::array<unsigned char, 8> bytes{};
    stream.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    const auto count = stream.gcount();
    if (count <= 0) {
        return {};
    }

    std::ostringstream output;
    output << std::uppercase << std::hex << std::setfill('0');
    for (std::streamsize i = 0; i < count; ++i) {
        if (i > 0) {
            output << ' ';
        }
        output << std::setw(2) << static_cast<int>(bytes[static_cast<std::size_t>(i)]);
    }
    return output.str();
}

std::optional<std::string> github_repository_url(std::string repository) {
    while (!repository.empty() && (repository.back() == '\n' || repository.back() == '\r' || repository.back() == ' ' || repository.back() == '\t')) {
        repository.pop_back();
    }
    if (repository.ends_with(".git")) {
        repository.erase(repository.size() - 4);
    }

    static const std::regex ssh_pattern(R"(^git@([^:]+):(.+)$)", std::regex_constants::icase);
    std::smatch ssh_match;
    if (std::regex_match(repository, ssh_match, ssh_pattern)) {
        repository = "https://" + ssh_match[1].str() + "/" + ssh_match[2].str();
    }

    const auto lower = lower_ascii(repository);
    if (lower.find("github") == std::string::npos || lower.rfind("http://", 0) != 0 && lower.rfind("https://", 0) != 0) {
        return std::nullopt;
    }
    return repository;
}

std::optional<std::string> bucket_repository_for_issue(const Environment& environment, const std::string& bucket_name) {
    if (bucket_name.empty()) {
        return std::nullopt;
    }

    std::optional<std::string> local_source;
    for (const auto& bucket : list_local_buckets(environment)) {
        if (bucket.name == bucket_name) {
            if (github_repository_url(bucket.source)) {
                return bucket.source;
            }
            local_source = bucket.source;
            break;
        }
    }
    for (const auto& known : list_known_buckets_for_environment(environment)) {
        if (known.name == bucket_name) {
            return known.repository;
        }
    }
    return local_source;
}

std::string download_issue_message(
    const Environment& environment,
    const std::string& app,
    const std::string& bucket_name,
    const std::string& version) {
    const auto repository = bucket_repository_for_issue(environment, bucket_name);
    if (!repository) {
        return "Please contact the bucket maintainer!";
    }
    const auto github_url = github_repository_url(*repository);
    if (!github_url) {
        return "Please contact the bucket maintainer!";
    }

    const auto title = form_url_encode(app + "@" + version + ": hash check failed");
    return "\nPlease try again or create a new issue by using the following link and paste your console output:\n" +
        *github_url + "/issues/new?title=" + title;
}

void write_download_hash_failure(
    const Environment& environment,
    const std::filesystem::path& manifest_path,
    const Manifest& manifest,
    const std::string& effective_version,
    const std::string& url,
    const std::filesystem::path& cached,
    const std::string& manifest_hash,
    std::ostream& out) {
    const auto parsed_hash = parse_download_hash(manifest_hash);
    if (!supported_download_hash_algorithm(parsed_hash.algorithm)) {
        out << "ERROR Hash type '" << parsed_hash.algorithm << "' isn't supported.\n";
    } else {
        const auto actual = hash_file(cached, parsed_hash.algorithm);
        out << "ERROR Hash check failed!\n"
            << "App:         " << manifest.name << '\n'
            << "URL:         " << url << '\n';
        if (const auto first_bytes = first_file_bytes_hex(cached); !first_bytes.empty()) {
            out << "First bytes: " << first_bytes << '\n';
        }
        out << "Expected:    " << parsed_hash.expected << '\n'
            << "Actual:      " << actual << '\n';
    }

    std::error_code ignored;
    std::filesystem::remove(cached, ignored);
    std::filesystem::remove(std::filesystem::path(cached.string() + ".aria2"), ignored);

    if (lower_ascii(url).find("sourceforge.net") != std::string::npos) {
        out << "WARN  SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.\n";
    }
    const auto bucket = bucket_name_for_manifest(environment, manifest_path);
    out << "ERROR " << download_issue_message(environment, manifest.name, bucket, manifest.version == "nightly" ? effective_version : manifest.version) << '\n';
}

void write_install_hash_failure(const Environment& environment, const HashCheckError& error, std::ostream& out) {
    const auto parsed_hash = parse_download_hash(error.manifest_hash);
    if (!supported_download_hash_algorithm(parsed_hash.algorithm)) {
        out << "ERROR Hash type '" << parsed_hash.algorithm << "' isn't supported.\n";
    } else {
        const auto actual = hash_file(error.cached, parsed_hash.algorithm);
        out << "ERROR Hash check failed!\n"
            << "App:         " << error.app << '\n'
            << "URL:         " << error.url << '\n';
        if (const auto first_bytes = first_file_bytes_hex(error.cached); !first_bytes.empty()) {
            out << "First bytes: " << first_bytes << '\n';
        }
        out << "Expected:    " << parsed_hash.expected << '\n'
            << "Actual:      " << actual << '\n';
    }

    std::error_code ignored;
    std::filesystem::remove(error.cached, ignored);
    std::filesystem::remove(std::filesystem::path(error.cached.string() + ".aria2"), ignored);
    if (error.install_path != error.cached) {
        std::filesystem::remove(error.install_path, ignored);
    }
    if (!error.install_dir.empty() && !std::filesystem::exists(error.install_dir / "install.json")) {
        std::filesystem::remove_all(error.install_dir, ignored);
        const auto app_root = error.install_dir.parent_path();
        if (!app_root.empty() && std::filesystem::is_empty(app_root, ignored)) {
            std::filesystem::remove(app_root, ignored);
        }
    }

    if (lower_ascii(error.url).find("sourceforge.net") != std::string::npos) {
        out << "SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.\n";
    }
    const auto bucket = bucket_name_for_manifest(environment, error.manifest_path);
    out << download_issue_message(environment, error.app, bucket, error.version) << '\n';
}

void write_install_artifact_fetch_failure(const ArtifactFetchError& error, std::ostream& out) {
    out << error.message << '\n'
        << "ERROR URL " << error.url << " is not valid\n";
}

void write_download_missing_hash_warning(const std::filesystem::path& cached, std::ostream& out) {
    out << "WARN  Warning: No hash in manifest. SHA256 for '" << cached.filename().string() << "' is:\n"
        << "    " << sha256_file(cached) << '\n';
}

std::string virustotal_url_id(const std::string& url) {
    return base64_url_without_padding(url);
}

int virustotal_exit_code(bool unsafe, bool exception, bool no_info, bool missing_key) {
    int code = 0;
    if (unsafe) {
        code |= 2;
    }
    if (exception) {
        code |= 4;
    }
    if (no_info) {
        code |= 8;
    }
    if (missing_key) {
        code |= 16;
    }
    return code;
}

void keep_only_persist(const std::filesystem::path& root) {
    if (!std::filesystem::is_directory(root)) {
        return;
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (entry.path().filename() == "persist") {
            continue;
        }
        std::filesystem::remove_all(entry.path());
    }
}

bool confirm_scoop_uninstall(bool purge, std::istream& input, std::ostream& out) {
    if (purge) {
        out << "WARN  This will uninstall Scoop, all apps installed with Scoop and all persisted data!\n";
    } else {
        out << "WARN  This will uninstall Scoop and all apps installed with Scoop!\n";
    }
    out << "Are you sure? (yN) ";

    std::string answer;
    if (!std::getline(input, answer)) {
        return false;
    }
    answer = normalize_prompt_answer(std::move(answer));
    return !answer.empty() && (answer[0] == 'y' || answer[0] == 'Y');
}

int uninstall_scoop_self(const Environment& environment, bool global, bool purge, std::istream& input, std::ostream& out, std::ostream& err) {
    if (!confirm_scoop_uninstall(purge, input, out)) {
        out << "Scoop uninstall cancelled.\n";
        return 0;
    }

    for (const auto scope : {false, true}) {
        if (scope && !global) {
            continue;
        }
        std::vector<InstalledApp> apps;
        for (const auto& app : list_installed_apps(environment)) {
            if (app.global == scope) {
                apps.push_back(app);
            }
        }

        for (const auto& app : apps) {
            out << "Uninstalling '" << app.name << "'.\n";
            const auto result = uninstall_app(environment, app.name, app.global, purge);
            if (!result.removed) {
                err << "sco uninstall: couldn't uninstall '" << app.name << "'\n";
                return 1;
            }
            for (const auto& message : result.messages) {
                out << message << '\n';
            }
            for (const auto& warning : result.warnings) {
                out << "WARN  " << warning << '\n';
            }
        }
    }

    remove_environment_path(environment, "PATH", environment.shims_dir(false), false);
    if (global) {
        remove_environment_path(environment, "PATH", environment.shims_dir(true), true);
    }

    if (purge) {
        std::filesystem::remove_all(environment.root_dir);
    } else {
        keep_only_persist(environment.root_dir);
    }

    if (global) {
        if (purge) {
            std::filesystem::remove_all(environment.global_dir);
        } else {
            keep_only_persist(environment.global_dir);
        }
    }

    out << "Scoop has been uninstalled.\n";
    return 0;
}

bool is_help_argument(const std::string& argument) {
    const auto normalized = lower_ascii(argument);
    return normalized == "-h" || normalized == "--help" || normalized == "/?";
}

std::vector<std::string> split_cli_lines(const std::string& value) {
    std::vector<std::string> lines;
    std::stringstream stream(value);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines.push_back(line);
    }
    if (lines.empty()) {
        lines.push_back({});
    }
    return lines;
}

void write_cli_property_list(
    std::ostream& out,
    const std::vector<std::pair<std::string, std::string>>& properties) {
    if (properties.empty()) {
        return;
    }

    std::size_t width = 0;
    for (const auto& property : properties) {
        if (property.first.size() > width) {
            width = property.first.size();
        }
    }

    out << '\n';
    for (const auto& property : properties) {
        const auto lines = split_cli_lines(property.second);
        out << property.first;
        if (property.first.size() < width) {
            out << std::string(width - property.first.size(), ' ');
        }
        out << " : " << lines.front() << '\n';

        for (std::size_t i = 1; i < lines.size(); ++i) {
            out << std::string(width + 3, ' ') << lines[i] << '\n';
        }
    }
    out << '\n';
}

bool is_public_scoop_command(const std::string& command) {
    static const std::unordered_set<std::string> commands{
        "alias",
        "bucket",
        "cache",
        "cat",
        "checkhashes",
        "checkurls",
        "checkup",
        "checkver",
        "cleanup",
        "config",
        "create",
        "depends",
        "download",
        "export",
        "formatjson",
        "help",
        "hold",
        "home",
        "import",
        "info",
        "init",
        "install",
        "list",
        "missing-checkver",
        "prefix",
        "reset",
        "search",
        "shim",
        "status",
        "unhold",
        "uninstall",
        "update",
        "virustotal",
        "which",
    };
    return commands.contains(lower_ascii(command));
}

} // namespace

int Cli::run(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) const {
    if (args.empty() || is_help_argument(args[0])) {
        print_help(out);
        return 0;
    }

    const auto command = lower_ascii(args[0]);

    if (args.size() > 1 && is_public_scoop_command(command) && is_help_argument(args[1])) {
        return run_help({"help", command}, out, err);
    }

    if (command == "help") {
        return run_help(args, out, err);
    }

    if (command == "-v" || command == "--version") {
        print_version(out);
        return 0;
    }

    if (command == "manifest") {
        return inspect_manifest(args, out, err);
    }

    if (command == "alias") {
        return run_alias(args, out, err);
    }

    if (command == "config") {
        return run_config(args, out, err);
    }

    if (command == "cat") {
        return run_cat(args, out, err);
    }

    if (command == "checkurls") {
        return run_checkurls(args, out, err);
    }

    if (command == "checkhashes") {
        return run_checkhashes(args, out, err);
    }

    if (command == "checkup") {
        return run_checkup(args, out, err);
    }

    if (command == "checkver") {
        return run_checkver(args, out, err);
    }

    if (command == "describe") {
        return run_describe(args, out, err);
    }

    if (command == "missing-checkver") {
        return run_missing_checkver(args, out, err);
    }

    if (command == "create") {
        return run_create(args, out, err);
    }

    if (command == "depends") {
        return run_depends(args, out, err);
    }

    if (command == "download") {
        return run_download(args, out, err);
    }

    if (command == "export") {
        return run_export(args, out, err);
    }

    if (command == "formatjson") {
        return run_formatjson(args, out, err);
    }

    if (command == "init") {
        return run_init(args, out, err);
    }

    if (command == "bucket") {
        return run_bucket(args, out, err);
    }

    if (command == "install") {
        return run_install(args, out, err);
    }

    if (command == "info") {
        return run_info(args, out, err);
    }

    if (command == "hold") {
        return run_hold(args, out, err);
    }

    if (command == "home") {
        return run_home(args, out, err);
    }

    if (command == "import") {
        return run_import(args, out, err);
    }

    if (command == "unhold") {
        return run_unhold(args, out, err);
    }

    if (command == "uninstall") {
        return run_uninstall(args, out, err);
    }

    if (command == "update") {
        return run_update(args, out, err);
    }

    if (command == "virustotal") {
        return run_virustotal(args, out, err);
    }

    if (command == "cleanup") {
        return run_cleanup(args, out, err);
    }

    if (command == "cache") {
        return run_cache(args, out, err);
    }

    if (command == "prefix") {
        return run_prefix(args, out, err);
    }

    if (command == "reset") {
        return run_reset(args, out, err);
    }

    if (command == "shim") {
        return run_shim(args, out, err);
    }

    if (command == "which") {
        return run_which(args, out, err);
    }

    if (command == "list") {
        return run_list(args, out, err);
    }

    if (command == "status") {
        return run_status(args, out, err);
    }

    if (command == "search") {
        return run_search(args, out, err);
    }

    try {
        const auto environment = load_environment();
        if (std::filesystem::is_regular_file(alias_script_path(environment, command))) {
            if (args.size() > 1 && is_help_argument(args[1])) {
                return run_help({"help", command}, out, err);
            }
            std::vector<std::string> shim_args(args.begin() + 1, args.end());
            return execute_alias_script(environment, command, shim_args);
        }

        const auto aliases = alias_config_object(ConfigStore(environment.config_file));
        const auto alias_key = alias_config_key(aliases, command);
        if (alias_key && aliases.at(*alias_key).is_string()) {
            if (args.size() > 1 && is_help_argument(args[1])) {
                return run_help({"help", command}, out, err);
            }
            std::vector<std::string> alias_args(args.begin() + 1, args.end());
            return execute_alias_script(environment, *alias_key, alias_args);
        }
    } catch (const std::exception&) {
    }

    err << "WARN  scoop: '" << args[0] << "' isn't a scoop command. See 'sco help'.\n";
    return 1;
}

void Cli::print_help(std::ostream& out) {
    out << "Usage: sco <command> [<args>]\n\n"
        << "Available commands are listed below.\n\n"
        << "Type 'sco help <command>' to get more help for a specific command.\n";

    std::vector<std::vector<std::string>> rows{
        {"alias", "Manage scoop aliases"},
        {"bucket", "Manage Scoop buckets"},
        {"cache", "Show or clear the download cache"},
        {"cat", "Show content of specified manifest."},
        {"checkup", "Check for potential problems"},
        {"cleanup", "Cleanup apps by removing old versions"},
        {"config", "Get or set configuration values"},
        {"create", "Create a custom app manifest"},
        {"depends", "List dependencies for an app, in the order they'll be installed"},
        {"download", "Download apps in the cache folder and verify hashes"},
        {"export", "Exports installed apps, buckets (and optionally configs) in JSON format"},
        {"help", "Show help for a command"},
        {"hold", "Hold an app to disable updates"},
        {"home", "Opens the app homepage"},
        {"import", "Imports apps, buckets and configs from a Scoopfile in JSON format"},
        {"info", "Display information about an app"},
        {"install", "Install apps"},
        {"list", "List installed apps"},
        {"prefix", "Returns the path to the specified app"},
        {"reset", "Reset an app to resolve conflicts"},
        {"search", "Search available apps"},
        {"shim", "Manipulate Scoop shims"},
        {"status", "Show status and check for new app versions"},
        {"unhold", "Unhold an app to enable updates"},
        {"uninstall", "Uninstall an app"},
        {"update", "Update apps, or Scoop itself"},
        {"virustotal", "Look for app's hash or url on virustotal.com"},
        {"which", "Locate a shim/executable (similar to 'which' on Linux)"},
    };

    try {
        const auto environment = load_environment();
        const auto shims = environment.shims_dir(false);
        if (std::filesystem::is_directory(shims)) {
            std::vector<std::pair<std::string, std::string>> alias_rows;
            for (const auto& entry : std::filesystem::directory_iterator(shims)) {
                if (!entry.is_regular_file()) {
                    continue;
                }
                const auto filename = entry.path().filename().string();
                constexpr std::string_view prefix = "scoop-";
                constexpr std::string_view suffix = ".ps1";
                if (filename.rfind(prefix, 0) != 0 || filename.size() <= prefix.size() + suffix.size()
                    || filename.substr(filename.size() - suffix.size()) != suffix) {
                    continue;
                }
                auto command = filename.substr(prefix.size(), filename.size() - prefix.size() - suffix.size());
                alias_rows.emplace_back(command, read_alias_summary(shim_command_path(environment, command)));
            }
            std::sort(alias_rows.begin(), alias_rows.end(), [](const auto& left, const auto& right) {
                return left.first < right.first;
            });
            for (const auto& [command, summary] : alias_rows) {
                rows.push_back({command, summary});
            }
        }
    } catch (const std::exception&) {
    }

    write_table(
        out,
        std::vector<std::string>{"Command", "Summary"},
        rows,
        TableOptions{.leading_blank_line = false, .trailing_blank_line = false, .indent = 2, .column_spacing = 2});
}

int Cli::run_help(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2) {
        print_help(out);
        return 0;
    }

    const auto& requested_command = args[1];
    const auto command = lower_ascii(requested_command);
    if (command == "alias") {
        return run_alias({"alias", "--help"}, out, err);
    }
    if (command == "bucket") {
        return run_bucket({"bucket", "--help"}, out, err);
    }
    if (command == "cache") {
        return run_cache({"cache", "--help"}, out, err);
    }
    if (command == "cat") {
        return run_cat({"cat", "--help"}, out, err);
    }
    if (command == "checkhashes") {
        return run_checkhashes({"checkhashes", "--help"}, out, err);
    }
    if (command == "checkurls") {
        return run_checkurls({"checkurls", "--help"}, out, err);
    }
    if (command == "checkup") {
        return run_checkup({"checkup", "--help"}, out, err);
    }
    if (command == "checkver") {
        return run_checkver({"checkver", "--help"}, out, err);
    }
    if (command == "missing-checkver") {
        return run_missing_checkver({"missing-checkver", "--help"}, out, err);
    }
    if (command == "cleanup") {
        return run_cleanup({"cleanup", "--help"}, out, err);
    }
    if (command == "config") {
        return run_config({"config", "--help"}, out, err);
    }
    if (command == "create") {
        return run_create({"create", "--help"}, out, err);
    }
    if (command == "depends") {
        return run_depends({"depends", "--help"}, out, err);
    }
    if (command == "describe") {
        return run_describe({"describe", "--help"}, out, err);
    }
    if (command == "download") {
        return run_download({"download", "--help"}, out, err);
    }
    if (command == "export") {
        return run_export({"export", "--help"}, out, err);
    }
    if (command == "formatjson") {
        return run_formatjson({"formatjson", "--help"}, out, err);
    }
    if (command == "help") {
        out << "Usage: sco help <command>\n";
        return 0;
    }
    if (command == "hold") {
        return run_hold({"hold", "--help"}, out, err);
    }
    if (command == "home") {
        return run_home({"home", "--help"}, out, err);
    }
    if (command == "import") {
        return run_import({"import", "--help"}, out, err);
    }
    if (command == "info") {
        return run_info({"info", "--help"}, out, err);
    }
    if (command == "init") {
        return run_init({"init", "--help"}, out, err);
    }
    if (command == "install") {
        return run_install({"install", "--help"}, out, err);
    }
    if (command == "list") {
        return run_list({"list", "--help"}, out, err);
    }
    if (command == "prefix") {
        return run_prefix({"prefix", "--help"}, out, err);
    }
    if (command == "reset") {
        return run_reset({"reset", "--help"}, out, err);
    }
    if (command == "search") {
        return run_search({"search", "--help"}, out, err);
    }
    if (command == "shim") {
        return run_shim({"shim", "--help"}, out, err);
    }
    if (command == "status") {
        return run_status({"status", "--help"}, out, err);
    }
    if (command == "unhold") {
        return run_unhold({"unhold", "--help"}, out, err);
    }
    if (command == "uninstall") {
        return run_uninstall({"uninstall", "--help"}, out, err);
    }
    if (command == "update") {
        return run_update({"update", "--help"}, out, err);
    }
    if (command == "virustotal") {
        return run_virustotal({"virustotal", "--help"}, out, err);
    }
    if (command == "which") {
        return run_which({"which", "--help"}, out, err);
    }
    if (print_shim_command_help_if_known(command, out)) {
        return 0;
    }
    out << "WARN  scoop help: no such command '" << requested_command << "'\n";
    return 0;
}

void Cli::print_version(std::ostream& out) {
    out << "Current Scoop version:\n"
        << "sco 0.5.1\n\n";
}

int Cli::inspect_manifest(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2 || is_help_argument(args[1])) {
        out << "Usage: sco manifest <path-to-app.json>\n";
        return args.size() < 2 ? 1 : 0;
    }

    try {
        const auto manifest = load_manifest_file(std::filesystem::path(args[1]));
        out << "name: " << manifest.name << '\n'
            << "version: " << manifest.version << '\n'
            << "architecture: " << manifest.architecture << '\n'
            << "urls: " << manifest.urls.size() << '\n'
            << "hashes: " << manifest.hashes.size() << '\n'
            << "extract_dirs: " << manifest.extract_dirs.size() << '\n'
            << "depends: " << manifest.depends.size() << '\n'
            << "env_add_path: " << manifest.env_add_path.size() << '\n'
            << "env_set: " << manifest.env_set.size() << '\n'
            << "pre_install: " << manifest.pre_install.size() << '\n'
            << "post_install: " << manifest.post_install.size() << '\n'
            << "installer_script: " << manifest.installer.script.size() << '\n'
            << "installer_file: " << (manifest.installer.file.empty() ? 0 : 1) << '\n'
            << "pre_uninstall: " << manifest.pre_uninstall.size() << '\n'
            << "post_uninstall: " << manifest.post_uninstall.size() << '\n'
            << "uninstaller_script: " << manifest.uninstaller.script.size() << '\n'
            << "uninstaller_file: " << (manifest.uninstaller.file.empty() ? 0 : 1) << '\n'
            << "psmodule: " << (manifest.psmodule_name.empty() ? 0 : 1) << '\n'
            << "suggest: " << manifest.suggestions.size() << '\n'
            << "persists: " << manifest.persists.size() << '\n'
            << "shortcuts: " << manifest.shortcuts.size() << '\n'
            << "bins: " << manifest.bins.size() << '\n';
        return 0;
    } catch (const ManifestError& error) {
        err << "manifest error: " << error.what() << '\n';
        return 1;
    } catch (const std::exception& error) {
        err << "error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_create(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2 || is_help_argument(args[1])) {
        out << "Usage: sco create <url>\n\n"
            << "Create your own custom app manifest\n";
        return 0;
    }

    std::string url;
    std::string name;
    std::string version;
    std::string hash;
    std::string bin;
    std::string homepage;
    std::string license;
    std::filesystem::path output_path;

    const std::unordered_set<std::string> value_options{
        "-n", "--name", "-v", "--version", "-h", "--hash", "-b", "--bin", "-o", "--output", "--homepage", "--license"};

    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        if (value_options.contains(arg)) {
            if (i + 1 >= args.size()) {
                err << "sco create: option requires a value: " << arg << '\n';
                return 1;
            }
            const auto& value = args[++i];
            if (arg == "-n" || arg == "--name") {
                name = value;
            } else if (arg == "-v" || arg == "--version") {
                version = value;
            } else if (arg == "-h" || arg == "--hash") {
                hash = value;
            } else if (arg == "-b" || arg == "--bin") {
                bin = value;
            } else if (arg == "-o" || arg == "--output") {
                output_path = value;
            } else if (arg == "--homepage") {
                homepage = value;
            } else if (arg == "--license") {
                license = value;
            }
            continue;
        }

        if (!url.empty()) {
            continue;
        }
        url = arg;
    }

    if (url.empty()) {
        out << "Usage: sco create <url>\n\n"
            << "Create your own custom app manifest\n";
        return 0;
    }

    const auto parsed = parse_create_url(url);
    if (!parsed) {
        err << "Error: " << url << " is not a valid URL\n";
        return 1;
    }

    if (name.empty()) {
        name = infer_name_from_url(*parsed);
    } else {
        name = sanitize_manifest_name(name);
    }
    if (version.empty()) {
        version = infer_version_from_url(*parsed);
    }
    if (bin.empty()) {
        bin = parsed->filename.empty() ? name : parsed->filename;
    }
    if (output_path.empty()) {
        output_path = std::filesystem::current_path() / (name + ".json");
    }

    try {
        nlohmann::json manifest = nlohmann::json::object();
        manifest["homepage"] = homepage;
        manifest["license"] = license;
        manifest["version"] = version;
        manifest["url"] = url;
        manifest["hash"] = hash;
        manifest["extract_dir"] = "";
        manifest["bin"] = bin;
        manifest["depends"] = "";

        std::filesystem::create_directories(output_path.parent_path());
        std::ofstream stream(output_path, std::ios::binary);
        if (!stream) {
            err << "sco create: cannot write " << output_path.string() << '\n';
            return 1;
        }
        stream << manifest.dump(4) << '\n';
        out << "Created '" << std::filesystem::absolute(output_path).string() << "'.\n";
        return 0;
    } catch (const std::exception& error) {
        err << "create error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_alias(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco alias <subcommand> [options] [<args>]";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco alias <subcommand> [options] [<args>]\n\n"
            << "Available subcommands: add, rm, list.\n\n"
            << "Aliases are custom Scoop subcommands that can be created to make common tasks easier.\n\n"
            << "To add an alias:\n\n"
            << "    sco alias add <name> <command> [<description>]\n\n"
            << "e.g.,\n\n"
            << "    sco alias add rm 'sco uninstall $args[0]' 'Uninstall an app'\n"
            << "    sco alias add upgrade 'sco update *' 'Update all apps, just like \"brew\" or \"apt\"'\n\n"
            << "To remove an alias:\n\n"
            << "    sco alias rm <name>\n\n"
            << "To list all aliases:\n\n"
            << "    sco alias list [-v|--verbose]\n\n"
            << "Options:\n"
            << "  -v, --verbose  Show alias description and table headers (works only for \"list\")\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <subcommand> missing\n" << usage << '\n';
        return 1;
    }

    const auto subcommand_arg = args[1];
    const auto subcommand = lower_ascii(subcommand_arg);
    if (subcommand != "add" && subcommand != "rm" && subcommand != "list") {
        err << "ERROR '" << subcommand_arg << "' is not one of available subcommands: add, rm, list\n"
            << usage << '\n';
        return 1;
    }

    std::vector<std::string> option_args{args[0]};
    option_args.insert(option_args.end(), args.begin() + 2, args.end());
    const auto parsed = parse_scoop_options(option_args, {
        {'v', "verbose", false},
    });
    if (!parsed.error.empty()) {
        err << "sco alias: " << parsed.error << '\n';
        return 1;
    }
    const auto& positional = parsed.positional;

    try {
        const auto environment = load_environment();
        ConfigStore config(environment.config_file);
        auto aliases = alias_config_object(config);

        if (subcommand == "add") {
            if (positional.size() < 2) {
                err << "ERROR <name> and <command> must be specified for subcommand 'add'\n";
                return 1;
            }

            const auto& name = positional[0];
            if (!valid_alias_name(name)) {
                err << "sco alias: invalid alias name '" << name << "'\n";
                return 1;
            }
            if (alias_config_key(aliases, name)) {
                err << "Alias '" << name << "' already exists.\n";
                return 1;
            }

            const auto script = alias_script_path(environment, name);
            if (std::filesystem::exists(script)) {
                err << "File '" << script.filename().string() << "' already exists in shims directory.\n";
                return 1;
            }

            std::filesystem::create_directories(script.parent_path());
            std::ofstream stream(script, std::ios::binary);
            if (!stream) {
                err << "sco alias: cannot write " << script.string() << '\n';
                return 1;
            }
            const auto description = positional.size() >= 3 ? positional[2] : std::string{};
            stream << "# Summary: " << description << "\n" << positional[1] << "\n";

            aliases[name] = "scoop-" + name;
            config.set("alias", aliases);
            config.save();
            return 0;
        }

        if (subcommand == "rm") {
            if (positional.empty()) {
                err << "ERROR <name> must be specified for subcommand 'rm'\n";
                return 1;
            }

            const auto& name = positional[0];
            const auto alias_key = alias_config_key(aliases, name);
            if (!alias_key) {
                err << "Alias '" << name << "' doesn't exist.\n";
                return 1;
            }

            out << "INFO  Removing alias '" << name << "'...\n";
            std::error_code error;
            std::filesystem::remove(alias_script_path(environment, *alias_key), error);
            aliases.erase(*alias_key);
            config.set("alias", aliases);
            config.save();
            return 0;
        }

        if (subcommand == "list") {
            const auto verbose = has_option(parsed, "verbose");

            if (aliases.empty()) {
                out << "INFO  No alias found.\n";
                return 0;
            }

            std::vector<std::string> names;
            for (const auto& item : aliases.items()) {
                names.push_back(item.key());
            }
            std::sort(names.begin(), names.end());

            std::vector<std::vector<std::string>> rows;
            rows.reserve(names.size());
            for (const auto& name : names) {
                const auto script = alias_script_path(environment, name);
                const auto command = read_alias_command(std::filesystem::is_regular_file(script) ? shim_command_path(environment, name) : script);
                if (verbose) {
                    const auto summary = command == "<BROKEN>" ? std::string{} : read_alias_summary(shim_command_path(environment, name));
                    rows.push_back({name, command, summary});
                } else {
                    rows.push_back({name, command});
                }
            }
            write_table(out, verbose ? std::vector<std::string>{"Name", "Command", "Summary"} : std::vector<std::string>{"Name", "Command"}, rows);
            return 0;
        }
    } catch (const std::exception& error) {
        err << "alias error: " << error.what() << '\n';
        return 1;
    }
    err << "sco alias: internal dispatch error\n";
    return 1;
}

int Cli::run_config(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view config_help = R"(Usage: sco config [rm] name [value]

The Scoop configuration file is saved at ~/.config/scoop/config.json.

To get all configuration settings:

    sco config

To get a configuration setting:

    sco config <name>

To set a configuration setting:

    sco config <name> <value>

To remove a configuration setting:

    sco config rm <name>

Settings
--------

use_external_7zip: $true|$false
      External 7zip (from path) will be used for archives extraction.

use_lessmsi: $true|$false
      Prefer lessmsi utility over native msiexec.

use_sqlite_cache: $true|$false
      Use SQLite database for caching. This is useful for speeding up 'scoop search' and 'scoop shim' commands.

no_junction: $true|$false
      The 'current' version alias will not be used. Shims and shortcuts will point to specific version instead.

scoop_repo: http://github.com/ScoopInstaller/Scoop
      Git repository containining scoop source code.
      This configuration is useful for custom forks.

scoop_branch: master|develop
      Allow to use different branch than master.
      Could be used for testing specific functionalities before released into all users.
      If you want to receive updates earlier to test new functionalities use develop (see: 'https://github.com/ScoopInstaller/Scoop/issues/2939')

proxy: [username:password@]host:port
      By default, Scoop will use the proxy settings from Internet Options, but with anonymous authentication.

      * To use the credentials for the current logged-in user, use 'currentuser' in place of username:password
      * To use the system proxy settings configured in Internet Options, use 'default' in place of host:port
      * An empty or unset value for proxy is equivalent to 'default' (with no username or password)
      * To bypass the system proxy and connect directly, use 'none' (with no username or password)

autostash_on_conflict: $true|$false
      When a conflict is detected during updating, Scoop will auto-stash the uncommitted changes.
      (Default is $false, which will abort the update)

default_architecture: 64bit|32bit|arm64
      Allow to configure preferred architecture for application installation.
      If not specified, architecture is determined by system.

debug: $true|$false
      Additional and detailed output will be shown.

force_update: $true|$false
      Force apps updating to bucket's version.

show_update_log: $true|$false
      Do not show changed commits on 'scoop update'

show_manifest: $true|$false
      Displays the manifest of every app that's about to
      be installed, then asks user if they wish to proceed.

shim: kiennq|scoopcs|71
      Choose scoop shim build.

root_path: $Env:UserProfile\scoop
      Path to Scoop root directory.

global_path: $Env:ProgramData\scoop
      Path to Scoop root directory for global apps.

cache_path:
      For downloads, defaults to 'cache' folder under Scoop root directory.

gh_token:
      GitHub API token used to make authenticated requests.
      This is essential for checkver and similar functions to run without
      incurring rate limits and download from private repositories.

virustotal_api_key:
      API key used for uploading/scanning files using virustotal.
      See: 'https://support.virustotal.com/hc/en-us/articles/115002088769-Please-give-me-an-API-key'

cat_style:
      When set to a non-empty string, Scoop will use 'bat' to display the manifest for
      the `scoop cat` command and while doing manifest review. This requires 'bat' to be
      installed (run `scoop install bat` to install it), otherwise errors will be thrown.
      The accepted values are the same as ones passed to the --style flag of 'bat'.

ignore_running_processes: $true|$false
      When set to $false (default), Scoop would stop its procedure immediately if it detects
      any target app process is running. Procedure here refers to reset/uninstall/update.
      When set to $true, Scoop only displays a warning message and continues procedure.

private_hosts:
      Array of private hosts that need additional authentication.
      For example, if you want to access a private GitHub repository,
      you need to add the host to this list with 'match' and 'headers' strings.

hold_update_until:
      Disable/Hold Scoop self-updates, until the specified date.
      `scoop hold scoop` will set the value to one day later.
      Should be in the format 'YYYY-MM-DD', 'YYYY/MM/DD' or any other forms that accepted by '[System.DateTime]::Parse()'.
      Ref: https://docs.microsoft.com/dotnet/api/system.datetime.parse?view=netframework-4.5#StringToParse

update_nightly: $true|$false
      Nightly version is formatted as 'nightly-yyyyMMdd' and will be updated after one day if this is set to $true.
      Otherwise, nightly version will not be updated unless `--force` is used.

use_isolated_path: $true|$false|[string]
      When set to $true, Scoop will use `SCOOP_PATH` environment variable to store apps' `PATH`s.
      When set to arbitrary non-empty string, Scoop will use that string as the environment variable name instead.
      This is useful when you want to isolate Scoop from the system `PATH`.

ARIA2 configuration
-------------------

aria2-enabled: $true|$false
      Aria2c will be used for downloading of artifacts.

aria2-warning-enabled: $true|$false
      Disable Aria2c warning which is shown while downloading.

aria2-retry-wait: 2
      Number of seconds to wait between retries.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-retry-wait'

aria2-split: 5
      Number of connections used for downlaod.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-s'

aria2-max-connection-per-server: 5
      The maximum number of connections to one server for each download.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-x'

aria2-min-split-size: 5M
      Downloaded files will be splitted by this configured size and downloaded using multiple connections.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-k'

aria2-options:
      Array of additional aria2 options.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#options'
)";
    try {
        const auto environment = load_environment();
        ConfigStore config(environment.config_file);

        if (args.size() == 1) {
            const auto formatted = format_config_values(config.values());
            if (!formatted.empty()) {
                out << formatted << '\n';
            }
            return 0;
        }

        if (is_help_argument(args[1])) {
            out << config_help;
            return 0;
        }

        if (lower_ascii(args[1]) == "rm") {
            if (args.size() < 3) {
                out << "'' has been removed\n";
                return 0;
            }
            complete_config_change(environment, config, args[2], nullptr, out);
            config.remove(args[2]);
            config.save();
            out << "'" << args[2] << "' has been removed\n";
            return 0;
        }

        if (args.size() >= 3) {
            const auto parsed_value = parse_config_value(args[2]);
            complete_config_change(environment, config, args[1], &parsed_value, out);
            config.set(args[1], parsed_value);
            config.save();
            out << "'" << args[1] << "' has been set to '" << args[2] << "'\n";
            return 0;
        }

        const auto value = config.get(args[1]);
        if (!value) {
            out << "'" << args[1] << "' is not set\n";
            return 0;
        }

        out << format_config_value(*value) << '\n';
        return 0;
    } catch (const std::exception& error) {
        err << "config error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_cat(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco cat <app>";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco cat <app>\n\n"
            << "Show content of specified manifest.\n"
            << "If configured, `bat` will be used to pretty-print the JSON.\n"
            << "See `cat_style` in `sco help config` for further information.\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }
    try {
        const auto environment = load_environment();
        std::string resolve_error;
        const auto manifest = resolve_app_manifest_target_for_read(
            environment,
            args[1],
            &resolve_error,
            "cat",
            InstalledScopePreference::GlobalFirst);
        if (!manifest) {
            if (!resolve_error.empty()) {
                err << resolve_error;
                return 1;
            }
            const auto parsed = parse_app_version_reference(args[1]);
            const auto slash = parsed.app.find_first_of("/\\");
            if (slash != std::string::npos && slash > 0 && slash + 1 < parsed.app.size()) {
                err << "Couldn't find manifest for '" << parsed.app.substr(slash + 1) << "' from '" << parsed.app.substr(0, slash) << "' bucket.\n";
                return 1;
            }
            err << "Couldn't find manifest for '" << args[1] << "'.\n";
            return 1;
        }

        const auto pretty_json = read_pretty_manifest_json(manifest->path, "cat", err);
        if (!pretty_json) {
            return 1;
        }
        return write_cat_output(environment, *pretty_json, out, err);
    } catch (const std::exception& error) {
        err << "cat error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_checkurls(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco checkurls [app] -Dir <directory> [options]\n\n"
            << "Options:\n"
            << "  -Dir, --dir <directory>  Directory containing manifests\n"
            << "  -Timeout, --timeout <seconds> Request timeout in seconds\n"
            << "  -SkipValid, --skip-valid Hide manifests whose URLs are all valid\n";
        return 0;
    }

    HelperAppDirBinding binding;
    auto skip_valid = false;
    auto timeout_seconds = 5;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto app_dir_parse = parse_helper_app_dir_option(args, i, "checkurls", binding, err);
        if (app_dir_parse == HelperOptionParse::Error) {
            return 1;
        }
        if (app_dir_parse == HelperOptionParse::Parsed) {
            continue;
        }
        if (is_helper_option(arg, {"timeout"})) {
            std::string value;
            if (!take_helper_option_value(args, i, "checkurls", arg, value, err)) {
                return 1;
            }
            try {
                std::size_t parsed = 0;
                timeout_seconds = std::stoi(value, &parsed);
                if (parsed != value.size() || timeout_seconds < 0) {
                    err << "sco checkurls: " << arg << " must be a non-negative integer.\n";
                    return 1;
                }
            } catch (const std::exception&) {
                err << "sco checkurls: " << arg << " must be a non-negative integer.\n";
                return 1;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"skipvalid", "skip-valid"}, "checkurls", skip_valid, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (!arg.empty() && arg[0] == '-') {
            err << "sco checkurls: Option " << arg << " not recognized.\n";
            return 1;
        }
        binding.positionals.push_back(arg);
    }
    bind_helper_app_dir_positionals(binding);
    const auto app_pattern = binding.app_pattern;
    auto dir = binding.dir;

    try {
        const auto environment = load_environment();
        if (!require_helper_dir("checkurls", dir, err)) {
            return 1;
        }
        if (!std::filesystem::is_directory(dir)) {
            err << "sco checkurls: " << dir.string() << " is not a directory.\n";
            return 1;
        }

        out << "[U]RLs\n | [O]kay\n |  | [F]ailed\n |  |  |\n";
        for (const auto& manifest_path : checkurls_manifest_paths(dir, app_pattern)) {
            const auto name = manifest_path.stem().string();
            std::vector<CheckUrlResult> results;
            for (const auto& manifest : checkurls_manifest_views(manifest_path)) {
                for (const auto& url : manifest.urls) {
                    results.push_back(check_manifest_url(environment, url, manifest.cookies, manifest_path.parent_path(), timeout_seconds));
                }
            }

            const auto ok_count = static_cast<int>(std::count_if(results.begin(), results.end(), [](const auto& result) {
                return result.ok;
            }));
            const auto failed_count = static_cast<int>(results.size()) - ok_count;
            if (skip_valid && failed_count == 0) {
                continue;
            }

            out << '[' << results.size() << "][" << ok_count << "][" << failed_count << "] " << name << '\n';
            for (const auto& result : results) {
                if (!result.ok) {
                    out << "       > " << result.error << " (" << result.url << ")\n";
                }
            }
        }
        return 0;
    } catch (const std::exception& error) {
        err << "checkurls error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_checkhashes(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco checkhashes [app] -Dir <directory> [options]\n\n"
            << "Options:\n"
            << "  -Dir, --dir <directory>  Directory containing manifests\n"
            << "  -Update, --update        Update mismatched hashes in manifests\n"
            << "  -ForceUpdate, --force-update Update hashes even when they already match\n"
            << "  -SkipCorrect, --skip-correct Hide manifests without mismatches\n"
            << "  -k, -UseCache, --use-cache Reuse existing cached artifacts\n";
        return 0;
    }

    HelperAppDirBinding binding;
    auto update = false;
    auto force_update = false;
    auto skip_correct = false;
    auto use_cache = false;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto app_dir_parse = parse_helper_app_dir_option(args, i, "checkhashes", binding, err);
        if (app_dir_parse == HelperOptionParse::Error) {
            return 1;
        }
        if (app_dir_parse == HelperOptionParse::Parsed) {
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"update"}, "checkhashes", update, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"forceupdate", "force-update"}, "checkhashes", force_update, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            if (force_update) {
                update = true;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"skipcorrect", "skip-correct"}, "checkhashes", skip_correct, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"usecache", "use-cache", "k"}, "checkhashes", use_cache, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (!arg.empty() && arg[0] == '-') {
            err << "sco checkhashes: Option " << arg << " not recognized.\n";
            return 1;
        }
        binding.positionals.push_back(arg);
    }
    bind_helper_app_dir_positionals(binding);
    const auto app_pattern = binding.app_pattern;
    auto dir = binding.dir;

    try {
        const auto environment = load_environment();
        if (!require_helper_dir("checkhashes", dir, err)) {
            return 1;
        }
        if (!std::filesystem::is_directory(dir)) {
            err << "sco checkhashes: " << dir.string() << " is not a directory.\n";
            return 1;
        }
        if (!use_cache && std::filesystem::is_directory(environment.cache_dir)) {
            for (const auto& entry : std::filesystem::directory_iterator(environment.cache_dir)) {
                if (entry.path().filename().string().find("HASH_CHECK") != std::string::npos) {
                    std::error_code ignored;
                    std::filesystem::remove(entry.path(), ignored);
                }
            }
        }

        for (const auto& manifest_path : checkver_manifest_paths(dir, app_pattern)) {
            const auto app = manifest_path.stem().string();
            nlohmann::ordered_json manifest_json;
            try {
                manifest_json = read_ordered_json_file_or_throw(manifest_path);
            } catch (const std::exception& error) {
                out << app << ": " << error.what() << '\n';
                continue;
            }

            const auto* version_value = ordered_json_property(manifest_json, "version");
            const auto version = version_value != nullptr && version_value->is_string()
                ? version_value->get<std::string>()
                : std::string{};
            if (version == "nightly") {
                continue;
            }

            if (const auto validation_error = checkhash_manifest_validation_error(manifest_json)) {
                out << app << ": " << *validation_error << '\n';
                continue;
            }

            const auto items = checkhash_items_from_manifest(manifest_json);
            if (items.empty()) {
                out << app << ": Manifest does not contain URL property.\n";
                continue;
            }

            std::vector<CheckHashResult> results;
            for (const auto& item : items) {
                CheckHashResult result;
                result.item = item;
                try {
                    result.cached = fetch_artifact_to_cache(
                        environment,
                        app,
                        use_cache ? version : "HASH_CHECK",
                        item.url,
                        manifest_path.parent_path(),
                        use_cache,
                        {});

                    const auto parsed_hash = parse_download_hash(item.hash);
                    result.algorithm = parsed_hash.algorithm;
                    result.expected = parsed_hash.expected;
                    if (!supported_download_hash_algorithm(parsed_hash.algorithm)) {
                        result.error = "Hash type '" + parsed_hash.algorithm + "' isn't supported.";
                    } else {
                        result.actual = hash_file(result.cached, parsed_hash.algorithm);
                        result.mismatch = parsed_hash.expected.empty() || result.actual != parsed_hash.expected;
                    }
                } catch (const std::exception& error) {
                    result.error = error.what();
                }
                results.push_back(std::move(result));
            }

            const auto has_error = std::any_of(results.begin(), results.end(), [](const auto& result) {
                return !result.error.empty();
            });
            const auto has_mismatch = std::any_of(results.begin(), results.end(), [](const auto& result) {
                return result.mismatch;
            });
            if (!has_error && !has_mismatch) {
                if (!skip_correct) {
                    out << app << ": OK\n";
                }
                if (update) {
                    for (const auto& result : results) {
                        if (!result.actual.empty()) {
                            assign_manifest_hash(manifest_json, result.item, result.algorithm == "sha256" ? result.actual : result.algorithm + ":" + result.actual);
                        }
                    }
                    write_ordered_json_file(manifest_path, manifest_json);
                    out << "Writing updated " << app << " manifest\n";
                }
                continue;
            }

            out << app << ": " << (has_error ? "Error" : "Mismatch found") << '\n';
            for (const auto& result : results) {
                if (result.error.empty() && !result.mismatch && !force_update) {
                    continue;
                }
                out << "\tURL:\t\t" << result.item.url << '\n';
                if (!result.error.empty()) {
                    out << "\tError:\t\t" << result.error << '\n';
                    continue;
                }
                if (const auto first_bytes = first_file_bytes_hex(result.cached); !first_bytes.empty()) {
                    out << "\tFirst bytes:\t" << first_bytes << '\n';
                }
                out << "\tExpected:\t" << result.item.hash << '\n'
                    << "\tActual:\t\t" << (result.algorithm == "sha256" ? result.actual : result.algorithm + ":" + result.actual) << '\n';
            }

            if (!update || has_error) {
                continue;
            }

            for (const auto& result : results) {
                if (!result.error.empty() || result.actual.empty()) {
                    continue;
                }
                assign_manifest_hash(manifest_json, result.item, result.algorithm == "sha256" ? result.actual : result.algorithm + ":" + result.actual);
            }
            write_ordered_json_file(manifest_path, manifest_json);
            out << "Writing updated " << app << " manifest\n";
        }
        return 0;
    } catch (const std::exception& error) {
        err << "checkhashes error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_checkup(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco checkup\n\n"
            << "Performs a series of diagnostic tests to try to identify things that may\n"
            << "cause problems with Scoop.\n";
        return 0;
    }
    try {
        const auto environment = load_environment();
        int issues = 0;
        int defender_issues = 0;

        if (should_check_windows_defender()) {
            defender_issues += check_windows_defender_path(environment.root_dir, out) ? 0 : 1;
            defender_issues += check_windows_defender_path(environment.global_dir, out) ? 0 : 1;
        }

        const auto buckets = list_local_buckets(environment);
        const auto has_main = std::any_of(buckets.begin(), buckets.end(), [](const auto& bucket) {
            return lower_ascii(bucket.name) == "main";
        });
        if (!has_main) {
            out << "WARN  Main bucket is not added.\n"
                << "  run 'sco bucket add main'\n";
            ++issues;
        }

        if (!long_paths_enabled()) {
            out << "WARN  LongPaths support is not enabled.\n"
                << "  You can enable it by running:\n"
                << "    sudo Set-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' -Name 'LongPathsEnabled' -Value 1\n"
                << "  (Requires 'sudo' command. Run 'sco install sudo' if you don't have it.)\n";
            ++issues;
        }

        if (!developer_mode_enabled()) {
            out << "WARN  Windows Developer Mode is not enabled. Operations relevant to symlinks may fail without proper rights.\n"
                << "  You may read more about the symlinks support here:\n"
                << "  https://blogs.windows.com/windowsdeveloper/2016/12/02/symlinks-windows-10/\n";
            ++issues;
        }

        const auto use_external_7zip = ConfigStore(environment.config_file).get("use_external_7zip");
        if ((!use_external_7zip || !use_external_7zip->is_boolean() || !use_external_7zip->get<bool>()) && !installation_helper_installed(environment, "7zip")) {
            out << "WARN  '7-Zip' is not installed! It's required for unpacking most programs. Please Run 'sco install 7zip'.\n";
            ++issues;
        }
        if (!installation_helper_installed(environment, "innounp")) {
            out << "WARN  'Inno Setup Unpacker' is not installed! It's required for unpacking InnoSetup files. Please run 'sco install innounp'.\n";
            ++issues;
        }
        if (!installation_helper_installed(environment, "dark")) {
            out << "WARN  'dark' is not installed! It's required for unpacking installers created with the WiX Toolset. Please run 'sco install dark' or 'sco install wixtoolset'.\n";
            ++issues;
        }

        if (!is_ntfs_volume(environment.root_dir)) {
            out << "ERROR Scoop requires an NTFS volume for " << environment.root_dir.generic_string() << ".\n";
            ++issues;
        }
        if (!is_ntfs_volume(environment.global_dir)) {
            out << "ERROR Scoop requires an NTFS volume for " << environment.global_dir.generic_string() << ".\n";
            ++issues;
        }

        if (issues == 0) {
            if (defender_issues == 0) {
                out << "No problems identified!\n";
            } else {
                out << "INFO  Found " << defender_issues << " performance " << (defender_issues == 1 ? "problem" : "problems") << ".\n"
                    << "WARN  Security is more important than performance, in most cases.\n";
            }
        } else {
            out << "WARN  Found " << issues << " potential " << (issues == 1 ? "problem" : "problems") << ".\n";
        }
        return 0;
    } catch (const std::exception& error) {
        err << "checkup error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_checkver(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco checkver [app] -Dir <directory> [options]\n\n"
            << "Options:\n"
            << "  -Dir, --dir <directory>  Directory containing manifests\n"
            << "  -Update, --update        Update manifests with autoupdate\n"
            << "  -ForceUpdate, --force-update Update even when the version did not change\n"
            << "  -SkipUpdated, --skip-updated Hide manifests whose version is current\n"
            << "  -Version, --version <version> Use an explicit target version\n"
            << "  -ThrowError, --throw-error Throw autoupdate errors instead of continuing\n";
        return 0;
    }

    HelperAppDirBinding binding;
    auto update = false;
    auto force_update = false;
    auto skip_updated = false;
    auto throw_error = false;
    std::string explicit_version;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto app_dir_parse = parse_helper_app_dir_option(args, i, "checkver", binding, err);
        if (app_dir_parse == HelperOptionParse::Error) {
            return 1;
        }
        if (app_dir_parse == HelperOptionParse::Parsed) {
            continue;
        }
        if (is_helper_option(arg, {"version"})) {
            if (!take_helper_option_value(args, i, "checkver", arg, explicit_version, err)) {
                return 1;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"update"}, "checkver", update, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"forceupdate", "force-update"}, "checkver", force_update, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            if (force_update) {
                update = true;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"skipupdated", "skip-updated"}, "checkver", skip_updated, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"throwerror", "throw-error"}, "checkver", throw_error, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (!arg.empty() && arg[0] == '-') {
            err << "sco checkver: Option " << arg << " not recognized.\n";
            return 1;
        }
        binding.positionals.push_back(arg);
    }
    bind_helper_app_dir_positionals(binding);
    const auto app_pattern = binding.app_pattern;
    auto dir = binding.dir;

    if (app_pattern == "*" && !explicit_version.empty()) {
        err << "sco checkver: Don't use '-Version' with '-App *'.\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        if (dir.empty()) {
            if (std::filesystem::is_regular_file(std::filesystem::path(app_pattern))) {
                dir = std::filesystem::path(app_pattern).parent_path();
                if (dir.empty()) {
                    dir = std::filesystem::current_path();
                }
            } else {
                err << "sco checkver: '-Dir' parameter required if '-App' is not a filepath.\n";
                return 1;
            }
        }
        if (!std::filesystem::is_directory(dir)) {
            err << "sco checkver: " << dir.string() << " is not a directory.\n";
            return 1;
        }

        for (const auto& manifest_path : checkver_manifest_paths(dir, app_pattern)) {
            const auto app = manifest_path.stem().string();
            if (!manifest_has_checkver(manifest_path)) {
                continue;
            }

            const auto current_version = manifest_json_version(manifest_path).value_or(std::string{});
            std::string latest_version;
            try {
                latest_version = explicit_version.empty()
                    ? resolve_checkver_version(environment, manifest_path).value_or(std::string{})
                    : explicit_version;
            } catch (const std::exception& error) {
                out << app << ": " << error.what() << '\n';
                continue;
            }

            if (latest_version.empty()) {
                out << app << ": couldn't find new version\n";
                continue;
            }

            const auto changed = latest_version != current_version;
            if (!changed && !force_update && skip_updated) {
                continue;
            }

            out << app << ": " << latest_version;
            if (!changed && !force_update) {
                out << '\n';
                continue;
            }

            if (changed || force_update) {
                out << " (scoop version is " << current_version << ')';
            }
            if (manifest_has_autoupdate(manifest_path) && compare_versions(current_version, latest_version) != 0) {
                out << " autoupdate available";
            }
            out << '\n';

            if (!update || !manifest_has_autoupdate(manifest_path)) {
                continue;
            }

            try {
                if (force_update) {
                    out << "Forcing autoupdate!\n";
                }
                const auto generated = generate_autoupdate_manifest(environment, manifest_path, app, latest_version);
                std::filesystem::copy_file(generated, manifest_path, std::filesystem::copy_options::overwrite_existing);
                out << "Writing updated " << app << " manifest\n";
            } catch (const std::exception& error) {
                err << "sco checkver: " << error.what() << '\n';
                if (throw_error) {
                    return 1;
                }
            }
        }
        return 0;
    } catch (const std::exception& error) {
        err << "checkver error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_describe(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco describe [app] -Dir <directory>\n\n"
            << "Options:\n"
            << "  -Dir, --dir <directory>  Directory containing manifests\n";
        return 0;
    }

    HelperAppDirBinding binding;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto app_dir_parse = parse_helper_app_dir_option(args, i, "describe", binding, err);
        if (app_dir_parse == HelperOptionParse::Error) {
            return 1;
        }
        if (app_dir_parse == HelperOptionParse::Parsed) {
            continue;
        }
        if (!arg.empty() && arg[0] == '-') {
            err << "sco describe: Option " << arg << " not recognized.\n";
            return 1;
        }
        binding.positionals.push_back(arg);
    }
    bind_helper_app_dir_positionals(binding);
    const auto app_pattern = binding.app_pattern;
    auto dir = binding.dir;

    try {
        const auto environment = load_environment();
        if (!require_helper_dir("describe", dir, err)) {
            return 1;
        }
        if (!std::filesystem::is_directory(dir)) {
            err << "sco describe: " << dir.string() << " is not a directory.\n";
            return 1;
        }

        const HttpClient client;
        for (const auto& manifest_path : checkurls_manifest_paths(dir, app_pattern)) {
            out << manifest_path.stem().string() << ": ";

            std::ifstream stream(manifest_path, std::ios::binary);
            if (!stream) {
                out << "\nUnable to read manifest.\n";
                continue;
            }

            nlohmann::json manifest;
            try {
                stream >> manifest;
            } catch (const nlohmann::json::exception&) {
                manifest = nlohmann::json::object();
            }
            if (!manifest.is_object()) {
                manifest = nlohmann::json::object();
            }

            const auto homepage = json_string_field(manifest, "homepage");
            if (homepage.empty()) {
                out << "\nNo homepage set.\n";
                continue;
            }

            const auto response = client.get(homepage, {{"User-Agent", "sco"}});
            if (response.status < 200 || response.status >= 300) {
                out << "\n" << (response.error.empty() ? "HTTP " + std::to_string(response.status) : response.error) << "\n";
                continue;
            }

            const auto description = describe_find_description(homepage, response.body);
            if (!description) {
                out << "\nDescription not found (" << homepage << ")\n";
                continue;
            }

            out << "(found by " << description->method << ")\n"
                << "  \"" << description->description << "\"\n";
        }
        return 0;
    } catch (const std::exception& error) {
        err << "describe error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_formatjson(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco formatjson [app] -Dir <directory>\n\n"
            << "Options:\n"
            << "  -Dir, --dir <directory>  Directory containing manifests\n";
        return 0;
    }

    HelperAppDirBinding binding;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto app_dir_parse = parse_helper_app_dir_option(args, i, "formatjson", binding, err);
        if (app_dir_parse == HelperOptionParse::Error) {
            return 1;
        }
        if (app_dir_parse == HelperOptionParse::Parsed) {
            continue;
        }
        if (!arg.empty() && arg[0] == '-') {
            err << "sco formatjson: Option " << arg << " not recognized.\n";
            return 1;
        }
        binding.positionals.push_back(arg);
    }
    bind_helper_app_dir_positionals(binding);
    const auto app_pattern = binding.app_pattern;
    auto dir = binding.dir;

    try {
        const auto environment = load_environment();
        if (!require_helper_dir("formatjson", dir, err)) {
            return 1;
        }
        if (!std::filesystem::is_directory(dir)) {
            err << "sco formatjson: " << dir.string() << " is not a directory.\n";
            return 1;
        }

        for (const auto& manifest_path : checkver_manifest_paths(dir, app_pattern)) {
            std::string error;
            const auto manifest = read_ordered_json_object(manifest_path, error);
            if (!manifest) {
                err << "sco formatjson: invalid manifest JSON in '" << manifest_path.string() << "': " << error << '\n';
                return 1;
            }
            write_ordered_json_file(manifest_path, *manifest);
        }
        return 0;
    } catch (const std::exception& error) {
        err << "formatjson error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_missing_checkver(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco missing-checkver [app] -Dir <directory> [options]\n\n"
            << "Options:\n"
            << "  -Dir, --dir <directory>  Directory containing manifests\n"
            << "  -SkipSupported, --skip-supported Hide manifests with both checkver and autoupdate\n";
        return 0;
    }

    HelperAppDirBinding binding;
    auto skip_supported = false;
    for (std::size_t i = 1; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto app_dir_parse = parse_helper_app_dir_option(args, i, "missing-checkver", binding, err);
        if (app_dir_parse == HelperOptionParse::Error) {
            return 1;
        }
        if (app_dir_parse == HelperOptionParse::Parsed) {
            continue;
        }
        if (const auto parsed_switch = parse_helper_switch_option(arg, {"skipsupported", "skip-supported"}, "missing-checkver", skip_supported, err);
            parsed_switch != HelperSwitchParse::NotMatched) {
            if (parsed_switch == HelperSwitchParse::Error) {
                return 1;
            }
            continue;
        }
        if (!arg.empty() && arg[0] == '-') {
            err << "sco missing-checkver: Option " << arg << " not recognized.\n";
            return 1;
        }
        binding.positionals.push_back(arg);
    }
    bind_helper_app_dir_positionals(binding);
    const auto app_pattern = binding.app_pattern;
    auto dir = binding.dir;

    try {
        const auto environment = load_environment();
        if (!require_helper_dir("missing-checkver", dir, err)) {
            return 1;
        }
        if (!std::filesystem::is_directory(dir)) {
            err << "sco missing-checkver: " << dir.string() << " is not a directory.\n";
            return 1;
        }

        out << "[C]heckver\n | [A]utoupdate\n |  |\n";
        for (const auto& manifest_path : checkurls_manifest_paths(dir, app_pattern)) {
            std::ifstream stream(manifest_path, std::ios::binary);
            if (!stream) {
                continue;
            }

            nlohmann::json manifest;
            try {
                stream >> manifest;
            } catch (const nlohmann::json::exception&) {
                manifest = nlohmann::json::object();
            }
            if (!manifest.is_object()) {
                manifest = nlohmann::json::object();
            }

            const auto has_checkver = json_property_truthy(manifest, "checkver");
            const auto has_autoupdate = json_property_truthy(manifest, "autoupdate");
            if (skip_supported && has_checkver && has_autoupdate) {
                continue;
            }

            out << '[' << (has_checkver ? 'C' : ' ') << "][" << (has_autoupdate ? 'A' : ' ') << "] " << manifest_path.stem().string() << '\n';
        }
        return 0;
    } catch (const std::exception& error) {
        err << "missing-checkver error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_depends(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco depends <app>";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco depends <app>\n\n"
            << "List dependencies for an app, in the order they'll be installed\n\n"
            << "Options:\n"
            << "  -a, --arch <32bit|64bit|arm64>  Use the specified architecture\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    InstallOptions options;
    const auto parsed = parse_scoop_options(args, {
        {'a', "arch", true},
    });
    if (!parsed.error.empty()) {
        err << "sco depends: " << parsed.error << '\n';
        return 1;
    }
    const auto explicit_architecture = option_value(parsed, "arch");
    const auto& apps = parsed.positional;

    if (apps.empty()) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    try {
        const auto environment = load_environment();
        apply_default_architecture(options, environment, explicit_architecture);
        if (!is_supported_architecture(options.architecture)) {
            write_invalid_architecture_error(options.architecture, err);
            return 1;
        }

        const auto parsed_ref = parse_app_version_reference(apps.front());
        const auto bucket_names = find_manifest_bucket_names(environment, parsed_ref.app);
        if (bucket_names.size() > 1) {
            const auto resolved = find_manifest_in_buckets(environment, parsed_ref.app);
            if (resolved) {
                const auto selected_bucket = bucket_name_for_manifest(environment, *resolved);
                err << "WARN  Multiple buckets contain manifest '" << parsed_ref.app << "', the current selection is '" << selected_bucket << "/" << parsed_ref.app << "'.\n";
            }
        }

        std::set<std::string> visiting;
        std::set<std::string> visited;
        std::vector<std::string> dependency_stack;
        std::vector<ReadManifestTarget> dependency_order;
        if (!collect_dependency_order(
                environment,
                apps.front(),
                options,
                InstalledScopePreference::GlobalFirst,
                err,
                visiting,
                visited,
                dependency_stack,
                dependency_order)) {
            return 1;
        }

        std::vector<std::vector<std::string>> rows;
        rows.reserve(dependency_order.size());
        for (const auto& target : dependency_order) {
            rows.push_back({target.source, target.name});
        }
        write_table(
            out,
            std::vector<std::string>{"Source", "Name"},
            rows,
            TableOptions{.leading_blank_line = false, .trailing_blank_line = false});
        return 0;
    } catch (const std::exception& error) {
        err << "depends error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_download(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco download <app> [options]";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco download <app> [options]\n\n"
            << "e.g. The usual way to download an app, without installing it (uses your local 'buckets'):\n"
            << "     sco download git\n\n"
            << "To download a different version of the app\n"
            << "(note that this will auto-generate the manifest using current version):\n"
            << "     sco download gh@2.7.0\n\n"
            << "To download an app from a manifest at a URL:\n"
            << "     sco download https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/runat.json\n\n"
            << "To download an app from a manifest on your computer\n"
            << "     sco download path\\to\\app.json\n\n"
            << "Options:\n"
            << "  -f, --force                     Force download (overwrite cache)\n"
            << "  -s, --skip-hash-check           Skip hash verification (use with caution!)\n"
            << "  -u, --no-update-scoop           Don't update Scoop before downloading if it's outdated\n"
            << "  -a, --arch <32bit|64bit|arm64>  Use the specified architecture, if the app supports it\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    bool use_cache = true;
    bool check_hash = true;
    const auto parsed = parse_scoop_options(args, {
        {'f', "force", false},
        {'s', "skip-hash-check", false},
        {'u', "no-update-scoop", false},
        {'a', "arch", true},
    });
    if (!parsed.error.empty()) {
        err << "sco download: " << parsed.error << '\n';
        return 1;
    }
    if (has_option(parsed, "force")) {
        use_cache = false;
    }
    if (has_option(parsed, "skip-hash-check")) {
        check_hash = false;
    }
    auto architecture = option_value(parsed, "arch");
    const auto& apps = parsed.positional;

    if (apps.empty()) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    try {
        const auto environment = load_environment();
        InstallOptions defaults;
        apply_default_architecture(defaults, environment, architecture);
        architecture = defaults.architecture;
        if (!is_supported_architecture(architecture)) {
            write_invalid_architecture_error(architecture, err);
            return 1;
        }
        if (const auto status = update_scoop_if_outdated(environment, !has_option(parsed, "no-update-scoop"), out, err); status != 0) {
            return status;
        }
        if (!use_cache) {
            out << "WARN  Cache is being ignored.\n";
        }

        for (const auto& app : apps) {
            auto autoupdate_error = false;
            const auto manifest_path = resolve_install_manifest(environment, app, err, "download", &autoupdate_error);
            if (autoupdate_error) {
                return 1;
            }
            if (manifest_path.empty()) {
                continue;
            }

            Manifest manifest;
            try {
                manifest = load_manifest_file(manifest_path, std::nullopt, architecture);
            } catch (const ManifestError& error) {
                out << "ERROR " << error.what() << '\n';
                continue;
            }
            if (!manifest.supports_current_architecture) {
                err << "'" << manifest.name << "' doesn't support current architecture!\n";
                continue;
            }
            if (manifest.urls.empty()) {
                out << "No artifacts to download for '" << manifest.name << "'.\n";
                continue;
            }

            const auto effective_version = manifest.version == "nightly" ? nightly_version() : manifest.version;
            const auto effective_check_hash = manifest.version == "nightly" ? false : check_hash;
            out << "INFO  Downloading '" << manifest.name << "'";
            const auto parsed_reference = parse_app_version_reference(app);
            if (!parsed_reference.version.empty()) {
                out << " (" << parsed_reference.version << ")";
            }
            out << " [" << manifest.architecture << "]";
            if (const auto bucket = bucket_name_for_manifest(environment, manifest_path); !bucket.empty()) {
                out << " from " << bucket << " bucket";
            }
            out << '\n';

            auto app_failed = false;
            for (std::size_t i = 0; i < manifest.urls.size(); ++i) {
                const auto loaded_from_cache = use_cache && std::filesystem::exists(cache_path(environment, manifest.name, effective_version, manifest.urls[i]));
                std::filesystem::path cached;
                try {
                    cached = fetch_artifact_to_cache(
                        environment,
                        manifest.name,
                        effective_version,
                        manifest.urls[i],
                        manifest_path.parent_path(),
                        use_cache,
                        manifest.cookies);
                } catch (const std::exception& error) {
                    out << error.what() << '\n'
                        << "ERROR URL " << manifest.urls[i] << " is not valid\n";
                    app_failed = true;
                    continue;
                }
                if (loaded_from_cache) {
                    out << "Loading " << url_remote_filename(manifest.urls[i]) << " from cache\n";
                }

                const auto manifest_hash = i < manifest.hashes.size() ? manifest.hashes[i] : std::string{};
                if (!effective_check_hash) {
                    out << "INFO  Skipping hash verification.\n";
                } else if (manifest_hash.empty()) {
                    write_download_missing_hash_warning(cached, out);
                } else {
                    const auto parsed_hash = parse_download_hash(manifest_hash);
                    auto hash_ok = false;
                    if (supported_download_hash_algorithm(parsed_hash.algorithm) && !parsed_hash.expected.empty()) {
                        hash_ok = hash_file(cached, parsed_hash.algorithm) == parsed_hash.expected;
                    }
                    if (!hash_ok) {
                        write_download_hash_failure(
                            environment,
                            manifest_path,
                            manifest,
                            effective_version,
                            manifest.urls[i],
                            cached,
                            manifest_hash,
                            out);
                        continue;
                    }
                }
            }
            if (!app_failed) {
                out << "'" << manifest.name << "' (" << effective_version << ") was downloaded successfully!\n";
            }
        }
        return 0;
    } catch (const std::exception& error) {
        err << "download error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_export(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco export > scoopfile.json\n\n"
            << "Exports installed apps, buckets (and optionally configs) in JSON format\n\n"
            << "Options:\n"
            << "  -c, --config       Export the Scoop configuration file too\n";
        return 0;
    }
    const auto include_config = args.size() > 1 && (lower_ascii(args[1]) == "-c" || lower_ascii(args[1]) == "--config");

    try {
        const auto environment = load_environment();
        nlohmann::json exported = nlohmann::json::object();

        if (include_config) {
            exported["config"] = exportable_config(ConfigStore(environment.config_file).values());
        }

        exported["buckets"] = nlohmann::json::array();
        for (const auto& bucket : list_local_buckets(environment)) {
            exported["buckets"].push_back(nlohmann::json{
                {"Name", bucket.name},
                {"Source", bucket_source(bucket)},
                {"Updated", bucket.updated},
                {"Manifests", bucket.manifests},
            });
        }

        exported["apps"] = nlohmann::json::array();
        for (const auto& app : list_installed_apps(environment)) {
            exported["apps"].push_back(nlohmann::json{
                {"Name", app.name},
                {"Version", app.version},
                {"Source", export_app_source(environment, app)},
                {"Updated", app.updated},
                {"Info", app.info},
            });
        }

        out << exported.dump(4) << '\n';
        return 0;
    } catch (const std::exception& error) {
        err << "export error: " << error.what() << '\n';
        return 1;
    }
}

namespace {

bool local_bucket_exists(const Environment& environment, const std::string& name) {
    const auto normalized = lower_ascii(name);
    for (const auto& bucket : list_local_buckets(environment)) {
        if (lower_ascii(bucket.name) == normalized) {
            return true;
        }
    }
    return false;
}

std::optional<std::string> known_bucket_repository(const Environment& environment, const std::string& name) {
    const auto normalized = lower_ascii(name);
    for (const auto& bucket : list_known_buckets_for_environment(environment)) {
        if (lower_ascii(bucket.name) == normalized) {
            return bucket.repository;
        }
    }
    return builtin_known_bucket_repository(name);
}

bool shim_points_to_target(const std::filesystem::path& shim, const std::filesystem::path& target) {
    std::ifstream stream(shim, std::ios::binary);
    if (!stream) {
        return false;
    }
    std::string content((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    return lower_ascii(content).find(lower_ascii(target.string())) != std::string::npos;
}

bool files_have_same_content(const std::filesystem::path& lhs, const std::filesystem::path& rhs) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(lhs, error) || !std::filesystem::is_regular_file(rhs, error)) {
        return false;
    }
    const auto lhs_size = std::filesystem::file_size(lhs, error);
    if (error) {
        return false;
    }
    const auto rhs_size = std::filesystem::file_size(rhs, error);
    if (error || lhs_size != rhs_size) {
        return false;
    }

    std::ifstream lhs_stream(lhs, std::ios::binary);
    std::ifstream rhs_stream(rhs, std::ios::binary);
    if (!lhs_stream || !rhs_stream) {
        return false;
    }
    return std::equal(
        std::istreambuf_iterator<char>(lhs_stream),
        std::istreambuf_iterator<char>(),
        std::istreambuf_iterator<char>(rhs_stream),
        std::istreambuf_iterator<char>());
}

std::filesystem::path sco_runtime_executable_path(const Environment& environment) {
    return environment.apps_dir(false) / "sco" / "current" / "sco.exe";
}

std::filesystem::path sco_runtime_version_dir(const Environment& environment) {
    return environment.apps_dir(false) / "sco" / SCO_VERSION;
}

bool write_ordered_json_file_if_changed(const std::filesystem::path& path, const nlohmann::ordered_json& value) {
    const auto content = value.dump(4) + "\n";
    {
        std::ifstream existing(path, std::ios::binary);
        if (existing) {
            const std::string current((std::istreambuf_iterator<char>(existing)), std::istreambuf_iterator<char>());
            if (current == content) {
                return false;
            }
        }
    }

    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write " + path.string());
    }
    stream << content;
    return true;
}

bool ensure_sco_runtime_metadata(const Environment& environment) {
    const auto version_dir = sco_runtime_version_dir(environment);
    const auto current_dir = environment.apps_dir(false) / "sco" / "current";
    const auto version_manifest_path = version_dir / "manifest.json";

    const nlohmann::ordered_json manifest{
        {"version", SCO_VERSION},
        {"description", "Scoop-compatible sco runtime"},
        {"bin", "sco.exe"},
    };
    const nlohmann::ordered_json install{
        {"architecture", default_architecture(environment)},
        {"url", version_manifest_path.string()},
        {"manifest", version_manifest_path.string()},
        {"installed_by", "sco"},
        {"downloaded", false},
        {"artifact_count", 0},
        {"use_cache", false},
        {"check_hash", false},
        {"independent", true},
    };

    bool changed = false;
    changed = write_ordered_json_file_if_changed(version_dir / "manifest.json", manifest) || changed;
    changed = write_ordered_json_file_if_changed(version_dir / "install.json", install) || changed;
    changed = write_ordered_json_file_if_changed(current_dir / "manifest.json", manifest) || changed;
    changed = write_ordered_json_file_if_changed(current_dir / "install.json", install) || changed;
    return changed;
}

void ensure_environment_variable(
    const std::string& name,
    const std::filesystem::path& value,
    bool global,
    std::ostream& out) {
    if (!environment_variable_value(name, global).empty()) {
        out << name << " is already configured.\n";
        return;
    }
    set_environment_variable_value(name, value.string(), global);
    out << "Set " << name << " to " << value.string() << ".\n";
}

} // namespace

int Cli::run_init(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco init\n\n"
            << "Initializes the Scoop-compatible environment for sco.\n";
        return 0;
    }
    if (args.size() > 1) {
        err << "sco init: unexpected argument '" << args[1] << "'\n"
            << "Usage: sco init\n";
        return 1;
    }

    try {
        const auto environment = load_environment();

        std::filesystem::create_directories(environment.apps_dir(false));
        std::filesystem::create_directories(environment.shims_dir(false));
        std::filesystem::create_directories(environment.buckets_dir());
        std::filesystem::create_directories(environment.cache_dir);
        std::filesystem::create_directories(environment.persist_dir(false));
        out << "Ensured Scoop directories under " << environment.root_dir.string() << ".\n";

        ensure_environment_variable("SCOOP", environment.root_dir, false, out);
        ensure_environment_variable("SCOOP_GLOBAL", environment.global_dir, false, out);
        ensure_environment_variable("SCOOP_CACHE", environment.cache_dir, false, out);

        if (add_environment_path(environment, "PATH", environment.shims_dir(false), false)) {
            out << "Added " << environment.shims_dir(false).string() << " to your PATH.\n";
        } else {
            out << "Scoop shims directory is already in your PATH.\n";
        }

        const auto executable = std::filesystem::weakly_canonical(current_executable_path());
        const auto runtime_executable = sco_runtime_executable_path(environment);
        const auto version_executable = sco_runtime_version_dir(environment) / "sco.exe";
        const auto runtime_executable_current = files_have_same_content(executable, runtime_executable);
        const auto version_executable_current = files_have_same_content(executable, version_executable);
        if (runtime_executable_current && version_executable_current) {
            out << "sco runtime executables are already installed.\n";
        } else {
            std::filesystem::create_directories(runtime_executable.parent_path());
            std::filesystem::create_directories(version_executable.parent_path());
            if (!runtime_executable_current) {
                std::filesystem::copy_file(executable, runtime_executable, std::filesystem::copy_options::overwrite_existing);
            }
            if (!version_executable_current) {
                std::filesystem::copy_file(executable, version_executable, std::filesystem::copy_options::overwrite_existing);
            }
            out << "Installed sco runtime executables to " << runtime_executable.parent_path().string() << ".\n";
        }

        if (ensure_sco_runtime_metadata(environment)) {
            out << "Configured sco runtime metadata.\n";
        } else {
            out << "sco runtime metadata is already configured.\n";
        }

        const auto shim = environment.shims_dir(false) / "sco.cmd";
        if (std::filesystem::is_regular_file(shim) && shim_points_to_target(shim, runtime_executable)) {
            out << "sco shim is already configured.\n";
        } else {
            write_cmd_shim(environment.shims_dir(false), "sco", runtime_executable, {});
            out << "Created sco shim.\n";
        }

        if (local_bucket_exists(environment, "main")) {
            out << "Main bucket is already added.\n";
        } else {
            try {
                const auto repository = known_bucket_repository(environment, "main");
                if (!repository) {
                    err << "WARN  Cannot find the known 'main' bucket repository.\n";
                } else {
                    const auto source_path = std::filesystem::path(*repository);
                    bool added = false;
                    if (std::filesystem::is_directory(source_path) && !std::filesystem::exists(source_path / ".git")) {
                        const auto result = add_local_bucket(environment, "main", source_path);
                        added = result.changed;
                    } else {
                        try {
                            const auto result = add_git_bucket(environment, "main", *repository);
                            added = result.changed;
                        } catch (const std::exception&) {
                            const auto zip_url = *repository + "/archive/refs/heads/master.zip";
                            const auto zip_path = environment.cache_dir / "main-bucket.zip";
                            const auto extract_dir = environment.cache_dir / "main-bucket-extract";
                            std::filesystem::create_directories(environment.cache_dir);
                            if (std::filesystem::exists(extract_dir)) {
                                std::filesystem::remove_all(extract_dir);
                            }
                            out << "Downloading main bucket...\n";
                            const auto download_cmd =
                                "powershell -NoProfile -Command \""
                                "Invoke-WebRequest -Uri '" + zip_url + "' -OutFile '" + zip_path.string() + "'"
                                "; Expand-Archive -LiteralPath '" + zip_path.string() + "' -DestinationPath '" + extract_dir.string() + "' -Force"
                                "\"";
                            if (std::system(download_cmd.c_str()) != 0) {
                                throw std::runtime_error("failed to download or extract main bucket");
                            }
                            const auto result = add_local_bucket(environment, "main", extract_dir / "Main-master");
                            added = result.changed;
                        }
                    }
                    out << (added ? "Added main bucket.\n" : "Main bucket is already added.\n");
                }
            } catch (const std::exception& bucket_error) {
                err << "WARN  Could not add main bucket: " << bucket_error.what() << "\n";
                err << "You can add it later with: sco bucket add main\n";
            }
        }

        const auto buckets_json_path = environment.root_dir / "buckets.json";
        if (!std::filesystem::is_regular_file(buckets_json_path)) {
            nlohmann::ordered_json buckets;
            for (const auto& bucket : builtin_known_buckets()) {
                buckets[bucket.name] = bucket.repository;
            }
            std::ofstream stream(buckets_json_path, std::ios::binary);
            stream << buckets.dump(4) << std::endl;
            out << "Created known buckets registry.\n";
        }

        ConfigStore config(environment.config_file);
        if (!config.get("last_update")) {
            config.set("last_update", iso_utc_time_after_days(0));
            config.save();
            out << "Initialized Scoop config.\n";
        } else {
            out << "Scoop config is already initialized.\n";
        }

        out << "sco init completed.\n";
        return 0;
    } catch (const std::exception& error) {
        err << "init error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_install(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco install <app> [options]";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco install <app> [options]\n\n"
            << "e.g. The usual way to install an app (uses your local 'buckets'):\n"
            << "     sco install git\n\n"
            << "To install a different version of the app\n"
            << "(note that this will auto-generate the manifest using current version):\n"
            << "     sco install gh@2.7.0\n\n"
            << "To install an app from a manifest at a URL:\n"
            << "     sco install https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/runat.json\n\n"
            << "To install a different version of the app from a URL:\n"
            << "      sco install https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/neovim.json@0.9.0\n\n"
            << "To install an app from a manifest on your computer\n"
            << "     sco install \\path\\to\\app.json\n\n"
            << "To install a different version of an app from a manifest on your computer\n"
            << "     sco install \\path\\to\\app.json@version\n\n"
            << "Options:\n"
            << "  -g, --global                    Install the app globally\n"
            << "  -i, --independent               Don't install dependencies automatically\n"
            << "  -k, --no-cache                  Don't use the download cache\n"
            << "  -s, --skip-hash-check           Skip hash validation (use with caution!)\n"
            << "  -u, --no-update-scoop           Don't update Scoop before installing if it's outdated\n"
            << "  -a, --arch <32bit|64bit|arm64>  Use the specified architecture, if the app supports it\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    InstallOptions options;
    const auto parsed = parse_scoop_options(args, {
        {'g', "global", false},
        {'i', "independent", false},
        {'k', "no-cache", false},
        {'s', "skip-hash-check", false},
        {'u', "no-update-scoop", false},
        {'a', "arch", true},
    });
    if (!parsed.error.empty()) {
        err << "sco install: " << parsed.error << '\n';
        return 1;
    }
    options.global = has_option(parsed, "global");
    options.independent = has_option(parsed, "independent");
    options.use_cache = !has_option(parsed, "no-cache");
    options.check_hash = !has_option(parsed, "skip-hash-check");
    options.update_scoop = !has_option(parsed, "no-update-scoop");
    const auto explicit_architecture = option_value(parsed, "arch");
    const auto& apps = parsed.positional;

    if (apps.empty()) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    try {
        const auto environment = load_environment();
        apply_default_architecture(options, environment, explicit_architecture);
        if (!is_supported_architecture(options.architecture)) {
            write_invalid_architecture_error(options.architecture, err);
            return 1;
        }
        if (options.global && !current_user_is_admin()) {
            err << "ERROR: you need admin rights to install global apps\n";
            return 1;
        }

        if (const auto status = update_scoop_if_outdated(environment, options.update_scoop, out, err); status != 0) {
            return status;
        }
        if (!options.use_cache) {
            out << "WARN  Cache is being ignored.\n";
        }

        std::set<std::string> failed_install_checks;
        for (const auto& app : apps) {
            repair_failed_installations_for_app(environment, install_reference_app_name(app), failed_install_checks, out);
        }

        if (handle_single_installed_install_request(environment, apps, options.global, out)) {
            return 0;
        }

        std::set<std::string> visiting;
        std::set<std::string> visited;
        std::vector<std::string> dependency_stack;
        std::vector<InstallPlanItem> install_order;
        std::map<std::string, std::map<std::string, std::vector<std::string>>> suggestions;
        std::set<std::string> explicit_app_names;
        for (const auto& app : apps) {
            explicit_app_names.insert(lower_ascii(install_reference_app_name(app)));
            if (!collect_install_order(environment, app, options, err, visiting, visited, dependency_stack, install_order)) {
                return 1;
            }
        }
        for (const auto& item : install_order) {
            const auto manifest = load_manifest_file(item.manifest_path, std::nullopt, options.architecture);
            repair_failed_installations_for_app(environment, manifest.name, failed_install_checks, out);
        }

        for (const auto& item : install_order) {
            const auto& path = item.manifest_path;
            const auto manifest = load_manifest_file(path, std::nullopt, options.architecture);
            if (!manifest.supports_current_architecture) {
                throw std::runtime_error("'" + manifest.name + "' doesn't support current architecture!");
            }
            if (write_installed_skip_if_explicit(environment, explicit_app_names, manifest, options.global, out)) {
                continue;
            }
            const auto decision = show_install_manifest_if_configured(environment, path, manifest, std::cin, out, err);
            if (decision == InstallManifestDecision::Error) {
                return 1;
            }
            if (decision == InstallManifestDecision::Skip) {
                continue;
            }

            write_nightly_install_warning(manifest, out);
            write_install_start(environment, path, manifest, out);
            InstallResult result;
            auto item_options = options;
            item_options.source_url = item.source_url;
            try {
                result = install_manifest_file(environment, path, item_options);
            } catch (const HashCheckError& error) {
                write_install_hash_failure(environment, error, out);
                return 1;
            } catch (const ArtifactFetchError& error) {
                write_install_artifact_fetch_failure(error, out);
                return 1;
            }
            write_install_messages(result, out);
            write_install_warnings(result, out);
            write_install_result(result, out);
            write_install_notes(environment, manifest, result, options.global, out);
            remember_install_suggestions(suggestions, manifest);
        }
        write_install_suggestions(environment, suggestions, out);
        return 0;
    } catch (const std::exception& error) {
        err << "install error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_uninstall(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco uninstall <app> [options]\n\n"
            << "e.g. sco uninstall git\n\n"
            << "Options:\n"
            << "  -g, --global   Uninstall a globally installed app\n"
            << "  -p, --purge    Remove all persistent data\n";
        return 0;
    }

    const auto parsed = parse_scoop_options(args, {
        {'g', "global", false},
        {'p', "purge", false},
    });
    if (!parsed.error.empty()) {
        err << "sco uninstall: " << parsed.error << '\n';
        return 1;
    }
    const auto global = has_option(parsed, "global");
    const auto purge = has_option(parsed, "purge");
    const auto& apps = parsed.positional;

    if (apps.empty()) {
        out << "ERROR <app> missing\n"
            << "Usage: sco uninstall <app> [options]\n";
        return 1;
    }
    if (global && !current_user_is_admin()) {
        err << "ERROR You need admin rights to uninstall global apps.\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        if (std::find(apps.begin(), apps.end(), "scoop") != apps.end()) {
            return uninstall_scoop_self(environment, global, purge, std::cin, out, err);
        }
        for (const auto& app : unique_installed_app_arguments(apps)) {
            const auto target = select_installed_app_target(environment, app, global, out);
            if (!target) {
                continue;
            }

            const auto version = select_current_version(environment, target->app, target->global);
            if (!version.empty()) {
                out << "Uninstalling '" << target->app << "' (" << version << ").\n";
            }
            const auto result = uninstall_app(environment, target->app, target->global, purge, [&]() {
                return should_skip_for_running_processes(environment, target->app, target->global, out);
            });
            if (result.skipped) {
                continue;
            }
            if (!result.removed) {
                out << "ERROR '" << result.app << "' isn't installed.\n";
                continue;
            }
            for (const auto& message : result.messages) {
                out << message << '\n';
            }
            for (const auto& warning : result.warnings) {
                out << "WARN  " << warning << '\n';
            }
            if (purge) {
                out << "Removing persisted data.\n";
            }
            out << "'" << result.app << "' was uninstalled.\n";
        }
        return 0;
    } catch (const std::exception& error) {
        err << "uninstall error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_hold(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2 || is_help_argument(args[1])) {
        out << "Usage: sco hold <apps>\n\n"
            << "To hold a user-scoped app:\n"
            << "     sco hold <app>\n\n"
            << "To hold a global app:\n"
            << "     sco hold -g <app>\n\n"
            << "Options:\n"
            << "  -g, --global  Hold globally installed apps\n";
        return args.size() < 2 ? 1 : 0;
    }

    const auto parsed = parse_scoop_options(args, {
        {'g', "global", false},
    });
    if (!parsed.error.empty()) {
        err << "sco hold: " << parsed.error << '\n';
        return 1;
    }
    const auto global = has_option(parsed, "global");
    const auto& apps = parsed.positional;

    if (apps.empty()) {
        out << "Usage: sco hold <apps>\n\n"
            << "To hold a user-scoped app:\n"
            << "     sco hold <app>\n\n"
            << "To hold a global app:\n"
            << "     sco hold -g <app>\n\n"
            << "Options:\n"
            << "  -g, --global  Hold globally installed apps\n";
        return 1;
    }
    if (global && !current_user_is_admin()) {
        err << "ERROR You need admin rights to hold a global app.\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        auto failed = false;
        for (const auto& reference : apps) {
            const auto app = installed_app_argument_name(reference);
            if (app == "scoop") {
                const auto hold_until = iso_utc_time_after_days(1);
                ConfigStore config(environment.config_file);
                config.set("hold_update_until", hold_until);
                config.save();
                out << "scoop is now held and might not be updated until " << hold_until << ".\n";
                continue;
            }

            const auto result = set_app_hold(environment, app, true, global);
            if (!result.installed) {
                err << "ERROR '" << app << "' is not installed" << (global ? " globally" : "") << ".\n";
                failed = true;
                continue;
            }
            if (!result.changed) {
                out << "INFO  '" << app << "' is already held.\n";
            } else {
                out << app << " is now held and can not be updated anymore.\n";
            }
        }
        return failed ? 1 : 0;
    } catch (const std::exception& error) {
        err << "hold error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_home(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2) {
        out << "Usage: sco home <app>\n";
        return 1;
    }
    if (is_help_argument(args[1])) {
        out << "Usage: sco home <app>\n\n"
            << "Opens the app homepage\n";
        return 0;
    }

    const auto app = args[1];
    bool show = false;
    for (std::size_t i = 2; i < args.size(); ++i) {
        if (args[i] == "--show") {
            show = true;
        }
    }

    if (app.empty()) {
        out << "Usage: sco home <app>\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        std::string resolve_error;
        const auto target = resolve_app_manifest_target_for_read(
            environment,
            app,
            &resolve_error,
            "home",
            InstalledScopePreference::GlobalFirst);
        if (!target) {
            if (!resolve_error.empty()) {
                err << resolve_error;
                return 1;
            }
            err << "Could not find manifest for '" << app << "'.\n";
            return 1;
        }

        const auto forced_name = target->name.empty() ? std::optional<std::string>{} : std::optional<std::string>{target->name};
        const auto manifest = load_manifest_file(target->path, forced_name);
        if (manifest.homepage.empty()) {
            err << "Could not find homepage in manifest for '" << app << "'.\n";
            return 1;
        }

        if (show) {
            out << manifest.homepage << '\n';
        } else {
            open_url(manifest.homepage);
        }
        return 0;
    } catch (const std::exception& error) {
        err << "home error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_import(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2 || is_help_argument(args[1])) {
        out << "Usage: sco import <path/url to scoopfile.json>\n\n"
            << "To replicate a Scoop installation from a file stored on Desktop, run\n"
            << "     sco import Desktop\\scoopfile.json\n";
        return args.size() < 2 ? 1 : 0;
    }
    try {
        const auto imported = read_json_from_path_or_url(args[1]);
        if (!imported) {
            err << "Input file not a valid JSON.\n";
            return 1;
        }

        const auto environment = load_environment();
        if (imported->contains("config") && imported->at("config").is_object()) {
            ConfigStore config(environment.config_file);
            for (const auto& item : imported->at("config").items()) {
                complete_config_change(environment, config, item.key(), &item.value(), out);
                config.set(item.key(), item.value());
                out << "'" << item.key() << "' has been set to '" << format_config_value(item.value()) << "'\n";
            }
            config.save();
        }

        std::set<std::string> imported_buckets;
        bool bucket_cache_needs_refresh = false;
        if (imported->contains("buckets") && imported->at("buckets").is_array()) {
            for (const auto& item : imported->at("buckets")) {
                const auto name = json_string_field(item, "Name");
                const auto source = json_string_field(item, "Source");
                if (name.empty() || source.empty()) {
                    continue;
                }

                BucketChangeResult result;
                const auto source_path = std::filesystem::path(source);
                if (std::filesystem::is_directory(source_path) && !std::filesystem::exists(source_path / ".git")) {
                    result = add_local_bucket(environment, name, source_path);
                } else {
                    result = add_git_bucket(environment, name, source);
                }
                imported_buckets.insert(name);
                bucket_cache_needs_refresh = bucket_cache_needs_refresh || result.changed;
                out << (result.changed ? "Added bucket '" : "Bucket '") << name << (result.changed ? "'.\n" : "' already exists.\n");
            }
        }
        if (bucket_cache_needs_refresh && config_bool(environment, "use_sqlite_cache")) {
            out << "INFO  Updating cache...\n";
            (void)list_bucket_manifest_index(environment);
        }

        if (imported->contains("apps") && imported->at("apps").is_array()) {
            for (const auto& item : imported->at("apps")) {
                const auto name = json_string_field(item, "Name");
                const auto version = json_string_field(item, "Version");
                const auto source = json_string_field(item, "Source");
                const auto info = json_string_field(item, "Info");
                if (name.empty()) {
                    continue;
                }

                auto reference = name;
                if (!source.empty() && imported_buckets.contains(source)) {
                    reference = source + "/" + name;
                } else if (source == "<auto-generated>" && !version.empty()) {
                    reference = name + "@" + version;
                } else if (!source.empty() && source != "<auto-generated>") {
                    reference = source;
                }

                InstallOptions options;
                options.global = info_contains(info, "Global install");
                std::string explicit_architecture;
                if (info_contains(info, "64bit")) {
                    explicit_architecture = "64bit";
                } else if (info_contains(info, "32bit")) {
                    explicit_architecture = "32bit";
                } else if (info_contains(info, "arm64")) {
                    explicit_architecture = "arm64";
                }
                apply_default_architecture(options, environment, explicit_architecture);
                if (options.global && !current_user_is_admin()) {
                    err << "ERROR: you need admin rights to install global apps\n";
                    return 1;
                }
                std::set<std::string> failed_install_checks;
                repair_failed_installations_for_app(environment, install_reference_app_name(reference), failed_install_checks, out);

                const auto already_installed = handle_single_installed_install_request(environment, {reference}, options.global, out);
                if (!already_installed) {
                    std::set<std::string> visiting;
                    std::set<std::string> visited;
                    std::vector<std::string> dependency_stack;
                    std::vector<InstallPlanItem> install_order;
                    if (!collect_install_order(environment, reference, options, err, visiting, visited, dependency_stack, install_order)) {
                        return 1;
                    }

                    std::map<std::string, std::map<std::string, std::vector<std::string>>> suggestions;
                    std::set<std::string> explicit_app_names{lower_ascii(install_reference_app_name(reference))};
                    for (const auto& install_item : install_order) {
                        const auto manifest = load_manifest_file(install_item.manifest_path, std::nullopt, options.architecture);
                        if (!manifest.supports_current_architecture) {
                            throw std::runtime_error("'" + manifest.name + "' doesn't support current architecture!");
                        }
                        if (write_installed_skip_if_explicit(environment, explicit_app_names, manifest, options.global, out)) {
                            continue;
                        }

                        write_nightly_install_warning(manifest, out);
                        write_install_start(environment, install_item.manifest_path, manifest, out);
                        InstallResult result;
                        auto item_options = options;
                        item_options.source_url = install_item.source_url;
                        try {
                            result = install_manifest_file(environment, install_item.manifest_path, item_options);
                        } catch (const HashCheckError& error) {
                            write_install_hash_failure(environment, error, out);
                            return 1;
                        } catch (const ArtifactFetchError& error) {
                            write_install_artifact_fetch_failure(error, out);
                            return 1;
                        }
                        write_install_messages(result, out);
                        write_install_warnings(result, out);
                        write_install_result(result, out);
                        write_install_notes(environment, manifest, result, options.global, out);
                        remember_install_suggestions(suggestions, manifest);
                    }
                    write_install_suggestions(environment, suggestions, out);
                }

                if (info_contains(info, "Held package")) {
                    const auto hold = set_app_hold(environment, name, true, options.global);
                    if (!hold.installed) {
                        err << "ERROR '" << name << "' is not installed" << (options.global ? " globally" : "") << ".\n";
                    } else if (!hold.changed) {
                        out << "INFO  '" << name << "' is already held.\n";
                    } else {
                        out << name << " is now held and can not be updated anymore.\n";
                    }
                }
            }
        }
        return 0;
    } catch (const std::exception& error) {
        err << "import error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_unhold(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2 || is_help_argument(args[1])) {
        out << "Usage: sco unhold <app>\n\n"
            << "To unhold a user-scoped app:\n"
            << "     sco unhold <app>\n\n"
            << "To unhold a global app:\n"
            << "     sco unhold -g <app>\n\n"
            << "Options:\n"
            << "  -g, --global  Unhold globally installed apps\n";
        return args.size() < 2 ? 1 : 0;
    }

    const auto parsed = parse_scoop_options(args, {
        {'g', "global", false},
    });
    if (!parsed.error.empty()) {
        err << "sco unhold: " << parsed.error << '\n';
        return 1;
    }
    const auto global = has_option(parsed, "global");
    const auto& apps = parsed.positional;

    if (apps.empty()) {
        out << "Usage: sco unhold <app>\n\n"
            << "To unhold a user-scoped app:\n"
            << "     sco unhold <app>\n\n"
            << "To unhold a global app:\n"
            << "     sco unhold -g <app>\n\n"
            << "Options:\n"
            << "  -g, --global  Unhold globally installed apps\n";
        return 1;
    }
    if (global && !current_user_is_admin()) {
        err << "ERROR You need admin rights to unhold a global app.\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        auto failed = false;
        for (const auto& reference : apps) {
            const auto app = installed_app_argument_name(reference);
            if (app == "scoop") {
                ConfigStore config(environment.config_file);
                config.remove("hold_update_until");
                config.save();
                out << "scoop is no longer held and can be updated again.\n";
                continue;
            }

            const auto result = set_app_hold(environment, app, false, global);
            if (!result.installed) {
                err << "ERROR '" << app << "' is not installed" << (global ? " globally" : "") << ".\n";
                failed = true;
                continue;
            }
            if (!result.changed) {
                out << "INFO  '" << app << "' is not held.\n";
            } else {
                out << app << " is no longer held and can be updated again.\n";
            }
        }
        return failed ? 1 : 0;
    } catch (const std::exception& error) {
        err << "unhold error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_update(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco update <app> [options]\n\n"
            << "'sco update' updates Scoop to the latest version.\n"
            << "'sco update <app>' installs a new version of that app, if there is one.\n\n"
            << "You can use '*' in place of <app> to update all apps.\n\n"
            << "Options:\n"
            << "  -f, --force            Force update even when there isn't a newer version\n"
            << "  -g, --global           Update a globally installed app\n"
            << "  -i, --independent      Don't install dependencies automatically\n"
            << "  -k, --no-cache         Don't use the download cache\n"
            << "  -s, --skip-hash-check  Skip hash validation (use with caution!)\n"
            << "  -q, --quiet            Hide extraneous messages\n"
            << "  -a, --all              Update all apps (alternative to '*')\n";
        return 0;
    }

    InstallOptions options;
    const auto parsed = parse_scoop_options(args, {
        {'g', "global", false},
        {'f', "force", false},
        {'i', "independent", false},
        {'k', "no-cache", false},
        {'s', "skip-hash-check", false},
        {'q', "quiet", false},
        {'a', "all", false},
    });
    if (!parsed.error.empty()) {
        err << "sco update: " << parsed.error << '\n';
        return 1;
    }
    options.global = has_option(parsed, "global");
    options.force = has_option(parsed, "force");
    options.independent = has_option(parsed, "independent");
    options.use_cache = !has_option(parsed, "no-cache");
    options.check_hash = !has_option(parsed, "skip-hash-check");
    const auto quiet = has_option(parsed, "quiet");
    auto all = has_option(parsed, "all");
    auto apps = parsed.positional;

    try {
        const auto environment = load_environment();
        ensure_update_channel_config_defaults(environment);
        options.architecture.clear();

        if (apps.empty() && !all) {
            if (options.global) {
                err << "ERROR scoop update: --global is invalid when <app> is not specified.\n";
                return 1;
            }
            if (!options.use_cache) {
                err << "ERROR scoop update: --no-cache is invalid when <app> is not specified.\n";
                return 1;
            }

            return update_scoop_and_buckets(environment, out, err);
        }
        if (options.global && !current_user_is_admin()) {
            err << "ERROR: You need admin rights to update global apps.\n";
            return 1;
        }

        const auto explicitly_updates_scoop = std::find(apps.begin(), apps.end(), "scoop") != apps.end();
        if (explicitly_updates_scoop) {
            const auto status = update_scoop_and_buckets(environment, out, err);
            if (status != 0) {
                return status;
            }
            apps.erase(std::remove(apps.begin(), apps.end(), "scoop"), apps.end());
            if (apps.empty() && !all) {
                return 0;
            }
        } else if (scoop_update_should_refresh(environment)) {
            const auto status = update_scoop_and_buckets(environment, out, err);
            if (status != 0) {
                return status;
            }
        }

        if (std::find(apps.begin(), apps.end(), "*") != apps.end()) {
            all = true;
        }

        std::vector<UpdateTarget> targets;
        if (all) {
            const auto include_local = true;
            const auto include_global = options.global;
            auto installed_apps = list_installed_apps(environment);
            const auto considered_any = std::any_of(installed_apps.begin(), installed_apps.end(), [&](const auto& installed) {
                return !((installed.global && !include_global) || (!installed.global && !include_local));
            });
            if (options.force) {
                for (const auto& installed : installed_apps) {
                    if ((installed.global && !include_global) || (!installed.global && !include_local)) {
                        continue;
                    }
                    if (is_app_held(environment, installed.name, installed.global)) {
                        if (!quiet) {
                            out << "'" << installed.name << "' is held to version " << installed.version << ".\n";
                        }
                        continue;
                    }
                    targets.push_back(UpdateTarget{installed.name, installed.global});
                }
            } else {
                for (const auto& status : list_app_statuses(environment)) {
                    if (!status.outdated || (status.global && !include_global) || (!status.global && !include_local)) {
                        continue;
                    }
                    if (status.held) {
                        if (!quiet) {
                            out << "'" << status.name << "' is held to version " << status.installed_version << ".\n";
                        }
                        continue;
                    }
                    targets.push_back(UpdateTarget{status.name, status.global});
                    if (!quiet) {
                        out << status.name << ": " << status.installed_version << " -> " << status.latest_version;
                        if (status.global) {
                            out << " (global)";
                        }
                        out << '\n';
                    }
                }
            }

            if (targets.empty()) {
                if (considered_any) {
                    out << "Latest versions for all apps are installed! For more information try 'sco status'\n";
                }
                return 0;
            }

            if (options.force) {
                out << (targets.size() == 1 ? "Force updating one app:\n" : "Force updating " + std::to_string(targets.size()) + " apps:\n");
            } else {
                out << (targets.size() == 1 ? "Updating one outdated app:\n" : "Updating " + std::to_string(targets.size()) + " outdated apps:\n");
            }
        } else {
            for (const auto& app : unique_installed_app_arguments(apps)) {
                const auto target = select_installed_app_target(environment, app, options.global, out);
                if (target) {
                    targets.push_back(UpdateTarget{target->app, target->global});
                }
            }
        }

        auto failed = false;
        for (const auto& target : targets) {
            if (target.app == "*") {
                continue;
            }
            auto target_options = options;
            target_options.global = target.global;
            const auto status = update_one_app(environment, target.app, target_options, out, err, all ? quiet : false, !all);
            if (status != 0) {
                failed = true;
            }
        }
        return failed ? 1 : 0;
    } catch (const std::exception& error) {
        err << "update error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_virustotal(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco virustotal [* | app1 app2 ...] [options]";
    auto print_help = [&]() {
        out << usage << "\n\n"
            << "Look for app's hash or url on virustotal.com\n\n"
            << "Use a single '*' or the '-a/--all' switch to check all installed apps.\n\n"
            << "To use this command, you have to sign up to VirusTotal's community,\n"
            << "and get an API key. Then, tell scoop about your API key with:\n\n"
            << "  sco config virustotal_api_key <your API key: 64 lower case hex digits>\n\n"
            << "Exit codes:\n"
            << "  0 -> success\n"
            << "  1 -> problem parsing arguments\n"
            << "  2 -> at least one package was marked unsafe by VirusTotal\n"
            << "  4 -> at least one exception was raised while looking for info\n"
            << "  8 -> at least one package couldn't be queried because the manifest couldn't be found\n"
            << " 16 -> VirusTotal API key is not configured\n"
            << "Note: the exit codes (2, 4 & 8) may be combined, e.g. 6 -> exit codes\n"
            << "      2 & 4 combined\n\n"
            << "Options:\n"
            << "  -a, --all                 Check for all installed apps\n"
            << "  -s, --scan                For packages where VirusTotal has no information, send download URL\n"
            << "                            for analysis (and future retrieval). This requires you to configure\n"
            << "                            your virustotal_api_key.\n"
            << "  -n, --no-depends          By default, all dependencies are checked too. This flag avoids it.\n"
            << "  -u, --no-update-scoop     Don't update Scoop before checking if it's outdated\n"
            << "  -p, --passthru            Return reports as objects\n"
            << "      --dry-run             Print planned lookups without using the API\n";
    };

    if (args.size() < 2) {
        out << usage << '\n';
        return 1;
    }
    if (is_help_argument(args[1])) {
        print_help();
        return 0;
    }

    const auto parsed = parse_scoop_options(args, {
        {'a', "all", false},
        {'s', "scan", false},
        {'n', "no-depends", false},
        {'u', "no-update-scoop", false},
        {'p', "passthru", false},
        {'\0', "dry-run", false},
    });
    if (!parsed.error.empty()) {
        err << "sco virustotal: " << parsed.error << '\n';
        return 1;
    }

    auto all = has_option(parsed, "all");
    const auto scan = has_option(parsed, "scan");
    const auto no_depends = has_option(parsed, "no-depends");
    const auto passthru = has_option(parsed, "passthru");
    const auto dry_run = has_option(parsed, "dry-run");
    auto apps = parsed.positional;

    if (std::find(apps.begin(), apps.end(), "*") != apps.end()) {
        all = true;
        apps.erase(std::remove(apps.begin(), apps.end(), "*"), apps.end());
    }

    if (apps.empty() && !all) {
        out << usage << '\n';
        return 1;
    }

    try {
        const auto environment = load_environment();
        if (const auto status = update_scoop_if_outdated(environment, !has_option(parsed, "no-update-scoop"), out, err); status != 0) {
            return status;
        }

        if (all) {
            apps.clear();
            for (const auto& app : list_installed_apps(environment)) {
                apps.push_back(app.name);
            }
        }

        if (!no_depends) {
            InstallOptions options;
            apply_default_architecture(options, environment);
            std::set<std::string> visiting;
            std::set<std::string> visited;
            std::vector<std::string> dependency_stack;
            std::vector<InstallPlanItem> order;
            auto failed_dependency_resolution = false;
            for (const auto& app : apps) {
                if (!collect_install_order(environment, app, options, err, visiting, visited, dependency_stack, order)) {
                    failed_dependency_resolution = true;
                }
            }
            if (failed_dependency_resolution) {
                return 1;
            }

            const auto plain_app_references = std::all_of(apps.begin(), apps.end(), [](const auto& app) {
                const auto parsed = parse_app_version_reference(app);
                return !looks_like_http_url(parsed.app) && lower_ascii(std::filesystem::path(parsed.app).extension().string()) != ".json";
            });
            std::vector<std::string> expanded_apps = plain_app_references ? std::vector<std::string>{} : apps;
            for (const auto& item : order) {
                const auto name = app_name_from_manifest_path(item.manifest_path);
                auto reference = name;
                if (const auto bucket = bucket_name_for_manifest(environment, item.manifest_path); !bucket.empty()) {
                    reference = bucket + "/" + name;
                }
                if (std::find(expanded_apps.begin(), expanded_apps.end(), reference) == expanded_apps.end()) {
                    expanded_apps.push_back(std::move(reference));
                }
            }
            apps = std::move(expanded_apps);
        }

        const auto api_key = ConfigStore(environment.config_file).get("virustotal_api_key");
        if (!dry_run && (!api_key || !api_key->is_string() || api_key->get<std::string>().empty())) {
            err << "VirusTotal API key is not configured\n"
                << "  You could get one from https://www.virustotal.com/gui/my-apikey and set with\n"
                << "  sco config virustotal_api_key <API key>\n";
            return virustotal_exit_code(false, false, false, true);
        }

        nlohmann::json reports = nlohmann::json::array();
        bool unsafe = false;
        bool exception = false;
        bool no_info = false;
        bool stop_virustotal_requests = false;
        const HttpClient client;
        const auto api_base_url = virustotal_api_base_url();

        for (const auto& app : apps) {
            if (stop_virustotal_requests) {
                break;
            }
            const auto manifest_path = resolve_app_manifest_for_read(environment, app, InstalledScopePreference::GlobalFirst);
            if (!manifest_path) {
                no_info = true;
                err << app << ": manifest not found\n";
                continue;
            }

            const auto manifest = load_manifest_file(*manifest_path, app);
            for (std::size_t i = 0; i < manifest.urls.size(); ++i) {
                if (stop_virustotal_requests) {
                    break;
                }
                const auto& url = manifest.urls[i];
                if (manifest.urls.size() > 1) {
                    out << manifest.name << ": url " << (i + 1) << '\n';
                }
                const auto hash_candidate = i < manifest.hashes.size() ? parse_virustotal_hash(manifest.hashes[i]) : VirusTotalHashCandidate{};
                const auto& hash = hash_candidate.value;
                const auto url_id = virustotal_url_id(url);
                nlohmann::json report{
                    {"App.Name", manifest.name},
                    {"App.Url", url},
                    {"App.Hash", hash},
                    {"App.HashType", hash_candidate.algorithm},
                    {"FileReport.Url", hash.empty() ? std::string{} : virustotal_file_report_url(hash)},
                };

                if (dry_run) {
                    reports.push_back(report);
                    out << manifest.name << ": " << (hash.empty() ? std::string{"hash not found"} : "would query " + hash) << '\n';
                    continue;
                }

                const auto request_headers = std::vector<std::pair<std::string, std::string>>{
                    {"Accept", "application/json"},
                    {"x-apikey", api_key->get<std::string>()},
                };
                enum class VirusTotalLookupStatus {
                    found,
                    not_found,
                    failed,
                };
                struct VirusTotalFileLookup {
                    VirusTotalLookupStatus status = VirusTotalLookupStatus::failed;
                    nlohmann::json report;
                };
                struct VirusTotalUrlLookup {
                    VirusTotalLookupStatus status = VirusTotalLookupStatus::failed;
                    nlohmann::json report;
                    std::string related_hash;
                    bool has_related_hash = false;
                };
                auto response_failure = [](const HttpResponse& response) {
                    return response.error.empty() ? std::to_string(response.status) : response.error;
                };
                auto query_file_report = [&](const std::string& lookup_hash, nlohmann::json file_report) -> VirusTotalFileLookup {
                    const auto response = client.get(api_base_url + "/files/" + lookup_hash, request_headers);
                    if (response.status == 404) {
                        return {.status = VirusTotalLookupStatus::not_found, .report = std::move(file_report)};
                    }
                    if (response.status < 200 || response.status >= 300) {
                        exception = true;
                        if (response.status == 204 || response.status == 429) {
                            stop_virustotal_requests = true;
                        }
                        err << manifest.name << ": VirusTotal request failed: " << response_failure(response) << '\n';
                        return {.status = VirusTotalLookupStatus::failed, .report = std::move(file_report)};
                    }

                    try {
                        const auto result = nlohmann::json::parse(response.body);
                        const auto& attributes = result.at("data").at("attributes");
                        const auto stats = attributes.at("last_analysis_stats");
                        const auto malicious = stats.value("malicious", 0);
                        const auto suspicious = stats.value("suspicious", 0);
                        const auto undetected = stats.value("undetected", 0);
                        const auto timeout = stats.value("timeout", 0);
                        const auto total = malicious + suspicious + undetected;
                        const auto report_hash = attributes.value("sha256", lookup_hash);
                        const auto report_url = virustotal_file_report_url(report_hash.empty() ? lookup_hash : report_hash);
                        file_report["FileReport.Url"] = report_url;
                        file_report["FileReport.Hash"] = report_hash;
                        file_report["FileReport.Malicious"] = malicious;
                        file_report["FileReport.Suspicious"] = suspicious;
                        file_report["FileReport.Timeout"] = timeout;
                        file_report["FileReport.Undetected"] = undetected;
                        if (malicious + suspicious > 0) {
                            unsafe = true;
                        }
                        if (total == 0) {
                            out << manifest.name << ": Analysis in progress.\n";
                        } else {
                            out << manifest.name << ": " << (malicious + suspicious) << "/" << total << ", see " << report_url << '\n';
                        }
                        return {.status = VirusTotalLookupStatus::found, .report = std::move(file_report)};
                    } catch (const std::exception& error) {
                        exception = true;
                        err << manifest.name << ": VirusTotal response parse failed: " << error.what() << '\n';
                        return {.status = VirusTotalLookupStatus::failed, .report = std::move(file_report)};
                    }
                };
                auto query_url_report = [&](nlohmann::json url_report) -> VirusTotalUrlLookup {
                    const auto url_response = client.get(api_base_url + "/urls/" + url_id, request_headers);
                    if (url_response.status >= 200 && url_response.status < 300) {
                        try {
                            const auto url_result = nlohmann::json::parse(url_response.body);
                            const auto& data = url_result.at("data");
                            const auto report_id = data.value("id", url_id);
                            url_report["FileReport.Url"] = std::string{};
                            url_report["UrlReport.Url"] = virustotal_url_report_url(report_id);
                            VirusTotalUrlLookup lookup{
                                .status = VirusTotalLookupStatus::found,
                                .report = std::move(url_report),
                            };
                            out << manifest.name << ": url report found, see " << lookup.report["UrlReport.Url"].get<std::string>() << '\n';
                            if (data.contains("attributes")) {
                                const auto& attributes = data.at("attributes");
                                lookup.related_hash = attributes.value("last_http_response_content_sha256", "");
                                lookup.has_related_hash = !lookup.related_hash.empty();
                                lookup.report["UrlReport.Hash"] = lookup.related_hash;
                                if (lookup.has_related_hash) {
                                    out << manifest.name << ": Related file report found.\n";
                                } else if (!attributes.contains("last_analysis_date") || attributes.at("last_analysis_date").is_null()) {
                                    out << manifest.name << ": Analysis in progress.\n";
                                } else {
                                    out << manifest.name << ": Related file report not found.\n";
                                    out << "WARN  " << manifest.name << ": Manual file upload is required (instead of url submission).\n";
                                }
                            } else {
                                lookup.report["UrlReport.Hash"] = std::string{};
                                out << manifest.name << ": Analysis in progress.\n";
                            }
                            return lookup;
                        } catch (const std::exception& error) {
                            exception = true;
                            err << manifest.name << ": VirusTotal URL response parse failed: " << error.what() << '\n';
                            return {.status = VirusTotalLookupStatus::failed, .report = std::move(url_report)};
                        }
                    }
                    if (url_response.status != 404) {
                        exception = true;
                        if (url_response.status == 204 || url_response.status == 429) {
                            stop_virustotal_requests = true;
                        }
                        err << manifest.name << ": VirusTotal URL request failed: " << response_failure(url_response) << '\n';
                        return {.status = VirusTotalLookupStatus::failed, .report = std::move(url_report)};
                    }

                    return {.status = VirusTotalLookupStatus::not_found, .report = std::move(url_report)};
                };
                auto submit_url_report = [&](nlohmann::json submitted_report) {
                    if (!scan) {
                        out << "WARN  " << manifest.name << ": not found: you can manually submit " << url << '\n';
                        reports.push_back(std::move(submitted_report));
                        return;
                    }

                    const auto scan_response = client.post(
                        api_base_url + "/urls",
                        request_headers,
                        "url=" + form_url_encode(url),
                        "application/x-www-form-urlencoded");
                    if (scan_response.status < 200 || scan_response.status >= 300) {
                        exception = true;
                        err << manifest.name << ": VirusTotal URL submission failed: " << response_failure(scan_response) << '\n';
                        reports.push_back(std::move(submitted_report));
                        return;
                    }

                    try {
                        const auto scan_result = nlohmann::json::parse(scan_response.body);
                        const auto analysis_id = scan_result.at("data").value("id", std::string{});
                        auto submitted_id = analysis_id;
                        if (const auto dash = submitted_id.find('-'); dash != std::string::npos && dash + 1 < submitted_id.size()) {
                            submitted_id = submitted_id.substr(dash + 1);
                        }
                        if (submitted_id.empty()) {
                            submitted_id = url_id;
                        }
                        submitted_report["UrlReport.Url"] = virustotal_url_report_url(submitted_id);
                        out << manifest.name << ": analysis in progress, see " << submitted_report["UrlReport.Url"].get<std::string>() << '\n';
                    } catch (const std::exception& error) {
                        exception = true;
                        err << manifest.name << ": VirusTotal submission response parse failed: " << error.what() << '\n';
                    }
                    reports.push_back(std::move(submitted_report));
                };
                auto query_url_fallback = [&](bool file_report_not_found) {
                    auto url_report = report;
                    url_report["FileReport.Url"] = std::string{};
                    auto url_lookup = query_url_report(std::move(url_report));
                    if (url_lookup.status == VirusTotalLookupStatus::not_found) {
                        exception = true;
                        out << "WARN  " << manifest.name << ": Url report not found. Will submit " << url << '\n';
                        submit_url_report(std::move(url_lookup.report));
                        return;
                    }
                    if (url_lookup.status == VirusTotalLookupStatus::failed) {
                        reports.push_back(std::move(url_lookup.report));
                        return;
                    }

                    auto resolved_report = std::move(url_lookup.report);
                    resolved_report["App.Hash"] = hash;
                    resolved_report["App.HashType"] = hash_candidate.algorithm;
                    if (!url_lookup.has_related_hash) {
                        reports.push_back(std::move(resolved_report));
                        return;
                    }

                    if (file_report_not_found && hash_candidate.present) {
                        if (hash_candidate.algorithm == "sha256") {
                            if (lower_ascii(url_lookup.related_hash) == hash) {
                                out << "WARN  " << manifest.name << ": Manual file upload is required (instead of url submission) for " << url << '\n';
                            } else {
                                out << "ERROR " << manifest.name << ": Hash not matched for " << url << '\n';
                            }
                        } else {
                            out << "ERROR " << manifest.name << ": Hash not matched or manual file upload is required (instead of url submission) for " << url << '\n';
                        }
                        reports.push_back(std::move(resolved_report));
                        return;
                    }

                    auto related_file_lookup = query_file_report(url_lookup.related_hash, resolved_report);
                    if (related_file_lookup.status == VirusTotalLookupStatus::found) {
                        auto related_file_report = std::move(related_file_lookup.report);
                        related_file_report["App.Hash"] = hash;
                        related_file_report["App.HashType"] = hash_candidate.algorithm;
                        if (resolved_report.contains("UrlReport.Url")) {
                            related_file_report["UrlReport.Url"] = resolved_report["UrlReport.Url"];
                        }
                        reports.push_back(std::move(related_file_report));
                        out << "WARN  " << manifest.name << ": Unable to check hash match for " << url << '\n';
                        return;
                    }
                    if (related_file_lookup.status == VirusTotalLookupStatus::not_found) {
                        exception = true;
                        out << "WARN  " << manifest.name << ": File report not found for unknown reason. Manual file upload is required (instead of url submission).\n";
                    }
                    reports.push_back(std::move(related_file_lookup.report));
                };

                if (hash_candidate.unsupported_algorithm) {
                    out << "WARN  " << manifest.name << ": Unsupported hash " << hash_candidate.algorithm << ". Will search by url instead.\n";
                    query_url_fallback(false);
                    continue;
                }

                if (!hash_candidate.present) {
                    out << "WARN  " << manifest.name << ": Hash not found. Will search by url instead.\n";
                    query_url_fallback(false);
                    continue;
                }

                auto file_lookup = query_file_report(hash, report);
                if (file_lookup.status == VirusTotalLookupStatus::not_found) {
                    exception = true;
                    out << "WARN  " << manifest.name << ": File report not found. Will search by url instead.\n";
                    query_url_fallback(true);
                    continue;
                }
                reports.push_back(std::move(file_lookup.report));
            }
        }

        if (passthru) {
            out << reports.dump(4) << '\n';
        }
        return virustotal_exit_code(unsafe, exception, no_info, false);
    } catch (const std::exception& error) {
        err << "virustotal error: " << error.what() << '\n';
        return virustotal_exit_code(false, true, false, false);
    }
}

int Cli::run_cleanup(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco cleanup <app> [options]";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco cleanup <app> [options]\n\n"
            << "'sco cleanup' cleans Scoop apps by removing old versions.\n"
            << "'sco cleanup <app>' cleans up the old versions of that app if said versions exist.\n\n"
            << "You can use '*' in place of <app> or `-a`/`--all` switch to cleanup all apps.\n\n"
            << "Options:\n"
            << "  -a, --all          Cleanup all apps (alternative to '*')\n"
            << "  -g, --global       Cleanup a globally installed app\n"
            << "  -k, --cache        Remove outdated download cache\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR: <app> missing\n" << usage << '\n';
        return 1;
    }

    const auto parsed = parse_scoop_options(args, {
        {'a', "all", false},
        {'g', "global", false},
        {'k', "cache", false},
    });
    if (!parsed.error.empty()) {
        err << "sco cleanup: " << parsed.error << '\n';
        return 1;
    }
    const auto global = has_option(parsed, "global");
    auto all = has_option(parsed, "all");
    const auto cache = has_option(parsed, "cache");
    auto apps = parsed.positional;
    if (std::find(apps.begin(), apps.end(), "*") != apps.end()) {
        all = true;
    }

    if (apps.empty() && !all) {
        out << "ERROR: <app> missing\n" << usage << '\n';
        return 1;
    }
    if (global && !current_user_is_admin()) {
        err << "ERROR: you need admin rights to cleanup global apps\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        std::vector<InstalledApp> targets;
        if (all) {
            for (const auto& installed : list_installed_apps(environment)) {
                if (!installed.global || global) {
                    targets.push_back(installed);
                }
            }
        } else {
            for (const auto& app : unique_installed_app_arguments(apps)) {
                if (installed_app_argument_name(app) == "scoop") {
                    continue;
                }
                const auto target = select_installed_app_target(environment, app, global, out);
                if (target) {
                    targets.push_back(InstalledApp{.name = target->app, .global = target->global});
                }
            }
        }

        for (const auto& target : targets) {
            const auto result = cleanup_app(environment, target.name, target.global);
            if (!result.app_dir_exists) {
                out << "ERROR '" << result.app << "' isn't installed.\n";
                continue;
            }

            if (result.removed_versions.empty()) {
                if (!all) {
                    out << result.app << " is already clean\n";
                }
            } else {
                out << "Removing " << result.app << ":";
                for (const auto& path : result.removed_versions) {
                    out << " " << path.filename().string();
                }
                out << '\n';
            }

            if (cache) {
                remove_cache_entries_for_app_except_version(environment, result.app, result.current_version);
            }
        }
        if (cache) {
            remove_temporary_download_entries(environment);
        }
        if (all) {
            out << "Everything is shiny now!\n";
        }
        return 0;
    } catch (const std::exception& error) {
        err << "cleanup error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_cache(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco cache show|rm [app(s)]\n\n"
            << "Scoop caches downloads so you don't need to download the same files\n"
            << "when you uninstall and re-install the same version of an app.\n\n"
            << "You can use\n"
            << "    sco cache show\n"
            << "to see what's in the cache, and\n"
            << "    sco cache rm <app>\n"
            << "to remove downloads for a specific app.\n\n"
            << "To clear everything in your cache, use:\n"
            << "    sco cache rm *\n"
            << "You can also use the `-a/--all` switch in place of `*` here\n\n"
            << "Options for rm:\n"
            << "  -a, --all  Remove all cache entries\n";
        return 0;
    }

    auto command = std::string{"show"};
    std::size_t first_filter = 1;
    if (args.size() > 1) {
        const auto requested_command = lower_ascii(args[1]);
        if (requested_command == "show" || requested_command == "rm") {
            command = requested_command;
            first_filter = 2;
        }
    }

    bool all = false;
    std::vector<std::string> app_filters;
    for (std::size_t i = first_filter; i < args.size(); ++i) {
        const auto& arg = args[i];
        const auto normalized_arg = lower_ascii(arg);
        if ((command == "rm" && (normalized_arg == "-a" || normalized_arg == "--all")) || arg == "*") {
            all = true;
        } else {
            app_filters.push_back(arg);
        }
    }

    try {
        const auto environment = load_environment();
        if (command == "rm") {
            if (!all && app_filters.empty()) {
                out << "ERROR: <app(s)> missing\n"
                    << "Usage: sco cache show|rm [app(s)]\n";
                return 1;
            }

            std::vector<CacheEntry> removed;
            if (all) {
                removed = remove_cache_entries(environment);
            } else {
                removed = remove_cache_entries(environment, app_filters);
            }

            for (const auto& entry : removed) {
                out << "Removing " << entry.name << "...\n";
            }
            out << "Deleted: " << file_count_label(removed.size()) << ", " << human_size(cache_entries_size(removed)) << '\n';
            return 0;
        }

        const auto entries = all ? list_cache_entries(environment) : list_cache_entries(environment, app_filters);
        if (!entries.empty()) {
            out << '\n';
        }
        out << "Total: " << file_count_label(entries.size()) << ", " << human_size(cache_entries_size(entries)) << '\n';
        write_cache_entries_table(out, entries);
        return 0;
    } catch (const std::exception& error) {
        err << "cache error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_info(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2) {
        out << "Usage: sco info <app> [options]\n";
        return 1;
    }
    if (is_help_argument(args[1])) {
        out << "Usage: sco info <app> [options]\n\n"
            << "Options:\n"
            << "  -v, --verbose   Show full paths and URLs\n";
        return 0;
    }

    const auto parsed = parse_scoop_options(args, {
        {'v', "verbose", false},
    });
    if (!parsed.error.empty()) {
        err << "sco info: " << parsed.error << '\n';
        return 1;
    }

    const auto verbose = has_option(parsed, "verbose");
    std::string app;
    if (!parsed.positional.empty()) {
        app = parsed.positional.front();
    }

    if (app.empty()) {
        out << "Usage: sco info <app> [options]\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        std::string resolve_error;
        const auto target = resolve_app_manifest_target_for_read(
            environment,
            app,
            &resolve_error,
            "info",
            InstalledScopePreference::GlobalFirst);
        if (!target) {
            if (!resolve_error.empty()) {
                err << resolve_error;
                return 1;
            }
            err << "Could not find manifest for '" << app << "' in local buckets.\n";
            return 1;
        }

        const auto parsed_ref = parse_app_version_reference(app);
        const auto bucket_names = find_manifest_bucket_names(environment, parsed_ref.app);
        if (bucket_names.size() > 1) {
            err << "WARN  Multiple buckets contain manifest '" << parsed_ref.app << "', the current selection is '" << target->source << "/" << parsed_ref.app << "'.\n";
        }

        const auto forced_name = target->name.empty() ? std::optional<std::string>{} : std::optional<std::string>{target->name};
        auto manifest = load_manifest_file(target->path, forced_name);
        const auto current_global = select_current_version(environment, manifest.name, true);
        const auto current_local = select_current_version(environment, manifest.name, false);
        const auto candidate_installed_version = !current_global.empty() ? current_global : current_local;
        const auto candidate_installed_global = !current_global.empty();
        const auto same_installed_source = !candidate_installed_version.empty()
            && info_target_matches_installed_source(environment, *target, manifest.name, candidate_installed_global);
        const auto installed_version = same_installed_source ? candidate_installed_version : std::string{};
        const auto installed_global = same_installed_source && candidate_installed_global;
        if (same_installed_source) {
            if (const auto architecture = installed_app_architecture(environment, manifest.name, installed_global)) {
                manifest = load_manifest_file(target->path, forced_name, *architecture);
            }
        }
        const auto deprecated_path = !installed_version.empty() ? deprecated_manifest_path(environment, manifest.name, target->source) : std::optional<std::filesystem::path>{};

        std::vector<std::pair<std::string, std::string>> properties;
        const auto add_property = [&](std::string name, std::string value) {
            if (!value.empty()) {
                properties.emplace_back(std::move(name), std::move(value));
            }
        };

        add_property("Name", manifest.name + (deprecated_path ? " (DEPRECATED)" : ""));
        if (!manifest.description.empty()) {
            add_property("Description", manifest.description);
        }

        auto display_manifest_version = manifest.version;
        if (display_manifest_version == "nightly") {
            display_manifest_version = nightly_version();
        }
        const auto update_nightly = config_bool(environment, "update_nightly");
        const auto version_comparison = installed_version.empty() ? 0 : compare_versions(installed_version, display_manifest_version, update_nightly);
        const auto update_available = config_bool(environment, "force_update") ? version_comparison != 0 : version_comparison > 0;
        if (!installed_version.empty() && update_available) {
            add_property("Version", installed_version + " (Update to " + display_manifest_version + " available)");
        } else {
            add_property("Version", manifest.version);
        }

        if (!target->source.empty()) {
            add_property("Source", target->source);
        }
        if (!manifest.homepage.empty()) {
            add_property("Website", trim_trailing_slashes(manifest.homepage));
        }
        if (const auto license = info_license_value(manifest, verbose); !license.empty()) {
            add_property("License", license);
        }
        if (!manifest.depends.empty()) {
            add_property("Dependencies", join_strings(manifest.depends, " | "));
        }
        const auto update_info = manifest_update_info(target->path);
        if (!update_info.updated_at.empty()) {
            add_property("Updated at", update_info.updated_at);
        }
        if (!update_info.updated_by.empty()) {
            add_property("Updated by", update_info.updated_by);
        }
        if (verbose) {
            add_property("Manifest", (deprecated_path ? deprecated_path->generic_string() : target->path.generic_string()));
        }
        if (!installed_version.empty()) {
            const auto installed_lines = info_installed_lines(environment, manifest.name, installed_global, verbose);
            if (!installed_lines.empty()) {
                add_property("Installed", join_strings(installed_lines, "\n"));
            }
            if (verbose) {
                const auto size_lines = installed_size_lines(environment, manifest.name, installed_version, installed_global);
                if (!size_lines.empty()) {
                    add_property("Installed size", join_strings(size_lines, "\n"));
                }
            }
        } else if (verbose) {
            const auto download_size = download_size_line(environment, manifest, target->path.parent_path());
            if (!download_size.empty()) {
                add_property("Download size", download_size);
            }
        }
        const auto binaries = info_binary_names(manifest);
        if (!binaries.empty()) {
            add_property("Binaries", join_strings(binaries, " | "));
        }
        const auto shortcuts = info_shortcut_names(manifest);
        if (!shortcuts.empty()) {
            add_property("Shortcuts", join_strings(shortcuts, " | "));
        }
        const auto info_dir = [&] {
            if (verbose) {
                if (!installed_version.empty()) {
                    return current_dir(environment, manifest.name, installed_global);
                }
                if (const auto prefix = find_app_prefix(environment, manifest.name)) {
                    return *prefix;
                }
            }
            return std::filesystem::path{"<root>"};
        }();
        const auto env_lines = info_environment_lines(manifest, info_dir);
        if (!env_lines.empty()) {
            add_property("Environment", join_strings(env_lines, "\n"));
        }
        const auto path_lines = info_path_added_lines(manifest, info_dir);
        if (!path_lines.empty()) {
            add_property("Path Added", join_strings(path_lines, "\n"));
        }
        if (!manifest.psmodule_name.empty()) {
            add_property("PowerShell module", manifest.psmodule_name);
        }
        if (!manifest.suggestions.empty()) {
            if (const auto suggestions = info_suggestions_value(manifest); !suggestions.empty()) {
                add_property("Suggestions", suggestions);
            }
        }
        if (!manifest.notes.empty()) {
            const auto notes = info_note_lines(manifest, environment, installed_version, installed_global, verbose);
            if (!notes.empty()) {
                add_property("Notes", join_strings(notes, "\n"));
            }
        }

        write_cli_property_list(out, properties);
        return 0;
    } catch (const std::exception& error) {
        err << "info error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_bucket(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco bucket add|list|known|rm [<args>]\n\n"
            << "Add, list or remove buckets.\n\n"
            << "Buckets are repositories of apps available to install. Scoop comes with\n"
            << "a default bucket, but you can also add buckets that you or others have\n"
            << "published.\n\n"
            << "To add a bucket:\n"
            << "    sco bucket add <name> [<repo>]\n\n"
            << "e.g.:\n"
            << "    sco bucket add extras https://github.com/ScoopInstaller/Extras.git\n\n"
            << "Since the 'extras' bucket is known to Scoop, this can be shortened to:\n"
            << "    sco bucket add extras\n\n"
            << "To list all known buckets, use:\n"
            << "    sco bucket known\n";
        return 0;
    }

    if (args.size() < 2) {
        err << "scoop bucket: cmd '' not supported\n"
            << "Usage: sco bucket add|list|known|rm [<args>]\n";
        return 1;
    }

    const auto subcommand = lower_ascii(args[1]);
    if (subcommand != "list" && subcommand != "known" && subcommand != "add" && subcommand != "rm" && subcommand != "update") {
        err << "scoop bucket: cmd '" << args[1] << "' not supported\n"
            << "Usage: sco bucket add|list|known|rm [<args>]\n";
        return 1;
    }

    try {
        const auto environment = load_environment();
        constexpr std::string_view usage_add = "usage: scoop bucket add <name> [<repo>]";
        constexpr std::string_view usage_rm = "usage: scoop bucket rm <name>";
        if (subcommand == "add") {
            if (args.size() < 3) {
                out << "<name> missing\n" << usage_add << '\n';
                return 1;
            }

            auto source = std::string{};
            if (args.size() < 4) {
                const auto known = list_known_buckets_for_environment(environment);
                const auto found = std::find_if(known.begin(), known.end(), [&](const auto& bucket) {
                    return lower_ascii(bucket.name) == lower_ascii(args[2]);
                });
                if (found != known.end()) {
                    source = found->repository;
                } else {
                    const auto fallback = builtin_known_bucket_repository(args[2]);
                    if (fallback) {
                        source = *fallback;
                    } else {
                        out << "Unknown bucket '" << args[2] << "'. Try specifying <repo>.\n"
                            << usage_add << '\n';
                        return 1;
                    }
                }
            } else {
                source = args[3];
            }

            BucketChangeResult result;
            const auto source_path = std::filesystem::path(source);
            if (std::filesystem::is_directory(source_path) && !std::filesystem::exists(source_path / ".git")) {
                result = add_local_bucket(environment, args[2], source_path);
            } else {
                result = add_git_bucket(environment, args[2], source);
            }
            if (!result.changed) {
                if (result.reason == BucketChangeReason::RepositoryAlreadyExists) {
                    out << "WARN  Bucket " << result.name << " already exists for " << source << "\n";
                } else {
                    out << "WARN  The '" << result.name
                        << "' bucket already exists. To add this bucket again, first remove it by running 'scoop bucket rm "
                        << result.name << "'.\n";
                }
                return 2;
            }

            out << "The " << result.name << " bucket was added successfully.\n";
            if (config_bool(environment, "use_sqlite_cache")) {
                out << "INFO  Updating cache...\n";
                (void)list_bucket_manifest_index(environment);
            }
            return 0;
        }

        if (subcommand == "rm") {
            if (args.size() < 3) {
                out << "<name> missing\n" << usage_rm << '\n';
                return 1;
            }

            const auto result = remove_bucket(environment, args[2]);
            if (!result.changed) {
                out << "ERROR '" << result.name << "' bucket not found.\n";
                return 0;
            }

            out << "The " << result.name << " bucket was removed successfully.\n";
            if (config_bool(environment, "use_sqlite_cache")) {
                out << "INFO  Updating cache...\n";
                (void)list_bucket_manifest_index(environment);
            }
            return 0;
        }

        if (subcommand == "known") {
            const auto buckets = list_known_buckets_for_environment(environment);
            for (const auto& bucket : buckets) {
                out << bucket.name << '\n';
            }
            return 0;
        }

        if (subcommand == "update") {
            const auto name = args.size() > 2 ? args[2] : std::string{};
            const auto results = update_buckets(environment, name);
            if (results.empty()) {
                out << "No buckets are installed.\n";
                return 0;
            }

            auto failed = false;
            auto updated_bucket_cache = false;
            for (const auto& result : results) {
                if (result.updated) {
                    out << "Updated '" << result.name << "' bucket.\n";
                    updated_bucket_cache = updated_bucket_cache || result.changed;
                } else if (result.message == "not a git bucket") {
                    out << "'" << result.name << "' is not a git repository. Skipped.\n";
                } else {
                    failed = true;
                    err << "Could not update '" << result.name << "' bucket: " << result.message << "\n";
                }
            }

            if (failed) {
                return 1;
            }
            if (updated_bucket_cache && config_bool(environment, "use_sqlite_cache")) {
                out << "INFO  Updating cache...\n";
                (void)list_bucket_manifest_index(environment);
            }
            return 0;
        }

        const auto buckets = list_local_buckets(environment);
        if (buckets.empty()) {
            out << "WARN  No bucket found. Please run 'sco bucket add main' to add the default 'main' bucket.\n";
            return 2;
        }

        std::vector<std::vector<std::string>> rows;
        rows.reserve(buckets.size());
        for (const auto& bucket : buckets) {
            rows.push_back({bucket.name, bucket.source, bucket.updated, std::to_string(bucket.manifests)});
        }
        write_table(out, std::vector<std::string>{"Name", "Source", "Updated", "Manifests"}, rows);
        return 0;
    } catch (const std::exception& error) {
        err << "bucket error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_prefix(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() < 2) {
        out << "Usage: sco prefix <app>\n";
        return 1;
    }
    if (is_help_argument(args[1])) {
        out << "Usage: sco prefix <app>\n\n"
            << "Returns the path to the specified app\n";
        return 0;
    }

    try {
        const auto prefix = find_app_prefix(load_environment(), args[1]);
        if (!prefix) {
            err << "Could not find app path for '" << args[1] << "'.\n";
            return 1;
        }

        out << prefix->generic_string() << '\n';
        return 0;
    } catch (const std::exception& error) {
        err << "prefix error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_reset(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco reset <app>";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco reset <app>\n\n"
            << "Used to resolve conflicts in favor of a particular app. For example,\n"
            << "if you've installed 'python' and 'python27', you can use 'sco reset' to switch between\n"
            << "using one or the other.\n\n"
            << "You can use '*' in place of <app> or `-a`/`--all` switch to reset all apps.\n\n"
            << "Options:\n"
            << "  -a, --all     Reset all installed apps\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <app> missing\n" << usage << '\n';
        return 1;
    }

    const auto parsed = parse_scoop_options(args, {
        {'a', "all", false},
    });
    if (!parsed.error.empty()) {
        err << "sco reset: " << parsed.error << '\n';
        return 1;
    }
    auto all = has_option(parsed, "all");
    const auto& positional = parsed.positional;

    if (std::find(positional.begin(), positional.end(), "*") != positional.end()) {
        all = true;
    }

    try {
        const auto environment = load_environment();
        if (all) {
            const auto apps = list_installed_apps(environment);
            if (apps.empty()) {
                return 0;
            }
            for (const auto& app : apps) {
                if (app.global && !current_user_is_admin()) {
                    out << "WARN  '" << app.name << "' (" << app.version << ") is a global app. You need admin rights to reset it. Skipping.\n";
                    continue;
                }
                if (should_skip_for_running_processes(environment, app.name, app.global, out)) {
                    continue;
                }
                const auto result = reset_app(environment, app.name, {}, app.global);
                if (result.reset) {
                    out << "Resetting " << result.app << " (" << result.version << ").\n";
                    for (const auto& message : result.messages) {
                        out << message << '\n';
                    }
                    for (const auto& warning : result.warnings) {
                        out << "WARN  " << warning << '\n';
                    }
                }
            }
            return 0;
        }

        if (positional.empty()) {
            out << "ERROR <app> missing\n" << usage << '\n';
            return 1;
        }

        const auto reset_one = [&](const std::string& reference, const std::string& explicit_version) {
            const auto parsed_reference = parse_app_version_reference(reference);
            const auto app = installed_app_argument_name(parsed_reference.app);
            const auto version = explicit_version.empty() ? parsed_reference.version : explicit_version;
            const auto reset_global = !select_current_version(environment, app, true).empty();

            if (app == "scoop") {
                return 0;
            }

            const auto app_installed = !select_current_version(environment, app, false).empty()
                || !select_current_version(environment, app, true).empty();
            if (!app_installed) {
                out << "ERROR '" << app << "' isn't installed.\n";
                return 1;
            }
            if (reset_global && !current_user_is_admin()) {
                const auto display_version = version.empty() ? select_current_version(environment, app, true) : version;
                out << "WARN  '" << app << "' (" << display_version << ") is a global app. You need admin rights to reset it. Skipping.\n";
                return 0;
            }

            if (should_skip_for_running_processes(environment, app, reset_global, out)) {
                return 0;
            }
            const auto result = reset_app(environment, app, version, reset_global);
            if (!result.reset) {
                out << "ERROR '" << app << (version.empty() ? "" : " (" + version + ")") << "' isn't installed.\n";
                return 1;
            }
            out << "Resetting " << result.app << " (" << result.version << ").\n";
            for (const auto& message : result.messages) {
                out << message << '\n';
            }
            for (const auto& warning : result.warnings) {
                out << "WARN  " << warning << '\n';
            }
            return 0;
        };

        const auto installed_app_exists = [&](const std::string& reference) {
            const auto parsed_reference = parse_app_version_reference(reference);
            const auto app = installed_app_argument_name(parsed_reference.app);
            return !select_current_version(environment, app, false).empty()
                || !select_current_version(environment, app, true).empty();
        };

        const auto reset_version_exists = [&](const std::string& reference, const std::string& version) {
            const auto parsed_reference = parse_app_version_reference(reference);
            const auto app = installed_app_argument_name(parsed_reference.app);
            const auto reset_global = !select_current_version(environment, app, true).empty();
            const auto versions = installed_versions(environment, app, reset_global);
            return std::find(versions.begin(), versions.end(), version) != versions.end();
        };

        const auto looks_like_version = [](const std::string& value) {
            if (value == "nightly" || value == "current") {
                return true;
            }
            if (value.empty()) {
                return false;
            }
            auto candidate = value;
            if ((candidate.front() == 'v' || candidate.front() == 'V') && candidate.size() > 1) {
                candidate.erase(candidate.begin());
            }
            if (candidate.empty() || std::isdigit(static_cast<unsigned char>(candidate.front())) == 0) {
                return false;
            }
            return std::all_of(candidate.begin(), candidate.end(), [](unsigned char ch) {
                return std::isdigit(ch) != 0;
            }) || candidate.find_first_of(".-+_") != std::string::npos;
        };

        const auto first_reference = parse_app_version_reference(positional[0]);
        if (positional.size() == 2 && first_reference.version.empty()
            && (reset_version_exists(positional[0], positional[1]) || (!installed_app_exists(positional[1]) && looks_like_version(positional[1])))) {
            (void)reset_one(positional[0], positional[1]);
            return 0;
        }

        auto failed = false;
        for (const auto& reference : positional) {
            if (reset_one(reference, {}) != 0) {
                failed = true;
            }
        }
        (void)failed;
        return 0;
    } catch (const std::exception& error) {
        err << "reset error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_shim(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco shim <subcommand> [<shim_name>...] [options] [other_args]";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco shim <subcommand> [<shim_name>...] [options] [other_args]\n\n"
            << "Available subcommands: add, rm, list, info, alter.\n\n"
            << "To add a custom shim, use the 'add' subcommand:\n\n"
            << "    sco shim add <shim_name> <command_path> [<args>...]\n\n"
            << "To remove shims, use the 'rm' subcommand: (CAUTION: this could remove shims added by an app manifest)\n\n"
            << "    sco shim rm <shim_name> [<shim_name>...]\n\n"
            << "To list all shims or matching shims, use the 'list' subcommand:\n\n"
            << "    sco shim list [<regex_pattern>...]\n\n"
            << "To show a shim's information, use the 'info' subcommand:\n\n"
            << "    sco shim info <shim_name>\n\n"
            << "To alternate a shim's target source, use the 'alter' subcommand:\n\n"
            << "    sco shim alter <shim_name>\n\n"
            << "Options:\n"
            << "  -g, --global       Manipulate global shim(s)\n\n"
            << "HINT: The FIRST double-hyphen '--', if any, will be treated as the POSIX-style command option terminator\n"
            << "and will NOT be included in arguments, so if you want to pass arguments like '-g' or '--global' to\n"
            << "the shim, put them after a '--'. Note that in PowerShell, you must use a QUOTED '--', e.g.,\n\n"
            << "    sco shim add myapp 'D:\\path\\myapp.exe' '--' myapp_args --global\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <subcommand> missing\n" << usage << '\n';
        return 1;
    }

    const auto subcommand_arg = args[1];
    const auto subcommand = lower_ascii(subcommand_arg);
    if (subcommand != "add" && subcommand != "rm" && subcommand != "list" && subcommand != "info" && subcommand != "alter") {
        err << "ERROR '" << subcommand_arg << "' is not one of available subcommands: add, rm, list, info, alter\n"
            << usage << '\n';
        return 1;
    }

    std::vector<std::string> option_args{args[0]};
    option_args.insert(option_args.end(), args.begin() + 2, args.end());
    const auto parsed = parse_scoop_options(option_args, {
        {'g', "global", false},
    });
    if (!parsed.error.empty()) {
        err << "sco shim: " << parsed.error << '\n';
        return 1;
    }
    const auto global = has_option(parsed, "global");
    const auto& positional = parsed.positional;

    try {
        const auto environment = load_environment();
        if (subcommand == "add") {
            if (positional.empty()) {
                err << "ERROR <shim_name> must be specified for subcommand 'add'\n";
                return 1;
            }
            if (positional.size() < 2 || positional[1].empty()) {
                err << "ERROR <command_path> must be specified for subcommand 'add'\n"
                    << usage << '\n';
                return 1;
            }

            auto command_path = std::filesystem::path(positional[1]);
            if (!std::filesystem::is_regular_file(command_path)) {
                if (positional[1].find_first_of("/\\") == std::string::npos) {
                    if (const auto resolved = find_which_target(environment, positional[1], global)) {
                        command_path = *resolved;
                    } else if (!global) {
                        if (const auto global_resolved = find_which_target(environment, positional[1], true)) {
                            command_path = *global_resolved;
                        }
                    }
                    if (!std::filesystem::is_regular_file(command_path)) {
                        if (const auto path_resolved = find_path_executable(positional[1])) {
                            command_path = *path_resolved;
                        }
                    }
                }
            }
            if (!std::filesystem::is_regular_file(command_path)) {
                err << "ERROR: Command path does not exist: " << positional[1] << '\n';
                return 3;
            }

            const auto name = cmd_shim_stem(positional[0]);
            if (!valid_shim_name(name)) {
                err << "sco shim: invalid shim name '" << positional[0] << "'\n";
                return 1;
            }
            command_path = std::filesystem::weakly_canonical(command_path);

            std::vector<std::string> command_args;
            if (positional.size() > 2) {
                command_args.assign(positional.begin() + 2, positional.end());
            }

            write_cmd_shim(environment.shims_dir(global), name, command_path, command_args);
            out << "Adding " << (global ? "global" : "local") << " shim " << name << "...\n";
            return 0;
        }

        if (subcommand == "rm") {
            if (positional.empty()) {
                err << "ERROR <shim_name> must be specified for subcommand 'rm'\n"
                    << usage << '\n';
                return 1;
            }

            auto failed = false;
            for (const auto& name : positional) {
                if (!active_shim_path(environment, name, global)) {
                    failed = true;
                    err << "ERROR: " << (global ? "Global" : "Local") << " shim not found: " << cmd_shim_stem(name) << '\n';
                    continue;
                }

                remove_active_shim_files(environment, name, global);
                out << "Removed " << (global ? "global" : "local") << " shim " << cmd_shim_stem(name) << ".\n";
            }
            return failed ? 3 : 0;
        }

        if (subcommand == "list") {
            std::vector<std::regex> patterns;
            for (const auto& pattern : positional) {
                if (pattern == "*") {
                    continue;
                }
                try {
                    patterns.emplace_back(pattern, std::regex_constants::icase);
                } catch (const std::regex_error&) {
                    err << "ERROR: Invalid pattern: " << pattern << '\n';
                    return 1;
                }
            }

            auto shims = list_shims(environment, global);
            if (!global) {
                auto global_shims = list_shims(environment, true);
                shims.insert(shims.end(), global_shims.begin(), global_shims.end());
                std::sort(shims.begin(), shims.end());
            }

            std::vector<std::vector<std::string>> rows;
            for (const auto& shim : shims) {
                const auto name = shim.stem().string();
                if (any_pattern_matches(name, patterns)) {
                    const auto is_global = path_is_in_tree(shim, comparable_path(environment.shims_dir(true)));
                    const auto alternatives = shim_alternatives(shim);
                    rows.push_back({
                        name,
                        source_from_shim_or_external(shim),
                        alternatives.size() > 1 ? join_strings(alternatives, " ") : std::string{},
                        is_global ? "true" : "false",
                        shim_is_hidden_from_path(shim) ? "true" : "false",
                    });
                }
            }
            if (!rows.empty()) {
                write_table(out, std::vector<std::string>{"Name", "Source", "Alternatives", "IsGlobal", "IsHidden"}, rows);
            }
            return 0;
        }

        if (positional.empty()) {
            err << "ERROR <shim_name> must be specified for subcommand '" << subcommand << "'\n"
                << usage << '\n';
            return 1;
        }

        const auto shim_name = cmd_shim_stem(positional[0]);
        const auto shim = active_shim_path(environment, shim_name, global);
        if (!shim) {
            err << "ERROR: " << (global ? "Global" : "Local") << " shim not found: " << shim_name << '\n';
            if (active_shim_path(environment, shim_name, !global)) {
                err << "But a " << (global ? "local" : "global") << " shim exists, run 'scoop shim " << subcommand << ' ' << shim_name;
                if (!global) {
                    err << " --global";
                }
                err << "' to " << (subcommand == "info" ? "show its info" : "alternate its source") << '\n';
                return 2;
            }
            return 3;
        }

        if (subcommand == "alter") {
            const auto alternatives = shim_alternatives(*shim);
            if (alternatives.size() < 2) {
                err << "ERROR: No alternatives of " << shim->stem().string() << " found.\n";
                return 2;
            }

            if (positional.size() < 2) {
                out << "Alternatives for " << shim->stem().string() << ":\n";
                const auto active = source_from_shim_or_external(*shim);
                for (const auto& source : alternatives) {
                    out << (source == active ? "* " : "  ") << source << '\n';
                }
                return 0;
            }

            const auto changed = switch_shim_source(*shim, positional[1]);
            out << shim->stem().string() << " is " << (changed ? "now" : "already") << " from " << positional[1] << ".\n";
            return 0;
        }

        out << "Name: " << shim->stem().string() << '\n'
            << "Path: " << shim_display_path(*shim).generic_string() << '\n';
        out << "Type: " << shim_info_type(*shim) << '\n';
        if (const auto target = read_target_from_shim(*shim)) {
            out << "Target: " << target->generic_string() << '\n';
        }
        if (lower_ascii(shim->extension().string()) == ".cmd") {
            const auto command_line = read_cmd_shim_command_line(*shim);
            if (!command_line.empty()) {
                out << "Command: " << command_line << '\n';
            }
        }
        out << "Source: " << source_from_shim_or_external(*shim) << '\n';
        const auto alternatives = shim_alternatives(*shim);
        if (alternatives.size() > 1) {
            out << "Alternatives: " << join_strings(alternatives, " ") << '\n';
        }
        out << "IsGlobal: " << (global ? "true" : "false") << '\n';
        out << "IsHidden: " << (shim_is_hidden_from_path(*shim) ? "true" : "false") << '\n';
        out << "Global: " << (global ? "true" : "false") << '\n';
        return 0;
    } catch (const std::exception& error) {
        err << "shim error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_which(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    constexpr std::string_view usage = "Usage: sco which <command>";
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco which <command>\n\n"
            << "Locate the path to a shim/executable that was installed with Scoop "
            << "(similar to 'which' on Linux)\n";
        return 0;
    }
    if (args.size() < 2) {
        out << "ERROR <command> missing\n" << usage << '\n';
        return 1;
    }

    const auto command = args[1];

    if (command.empty()) {
        out << "ERROR <command> missing\n" << usage << '\n';
        return 1;
    }

    try {
        const auto environment = load_environment();
        if (is_path_like_command(command)) {
            const auto target = find_explicit_which_target(environment, command);
            if (!target) {
                out << "WARN  '" << command << "' not found, not a scoop shim, or a broken shim.\n";
                return 0;
            }

            out << target->generic_string() << '\n';
            return 0;
        }

        bool path_command_found = false;
        auto target = find_path_which_target(environment, command, path_command_found);
        if (path_command_found && !target) {
            out << "WARN  '" << command << "' not found, not a scoop shim, or a broken shim.\n";
            return 0;
        }
        if (!target) {
            out << "WARN  '" << command << "' not found, not a scoop shim, or a broken shim.\n";
            return 0;
        }

        out << target->generic_string() << '\n';
        return 0;
    } catch (const std::exception& error) {
        err << "which error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_list(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco list [query]\n\n"
            << "Lists all installed apps, or the apps matching the supplied query.\n";
        return 0;
    }

    try {
        const auto query = args.size() > 1 ? args[1] : std::string{};
        const auto environment = load_environment();
        const auto apps = list_installed_apps(environment, query);
        if (apps.empty() && (query.empty() || !has_installed_apps(environment))) {
            out << "There aren't any apps installed.\n";
            return 1;
        }

        out << "Installed apps";
        if (!query.empty()) {
            out << " matching '" << query << "'";
        }
        out << ":\n";

        if (!apps.empty()) {
            std::vector<std::vector<std::string>> rows;
            rows.reserve(apps.size());
            for (const auto& app : apps) {
                rows.push_back({app.name, app.version, app.source, app.updated, app.info});
            }
            write_table(out, std::vector<std::string>{"Name", "Version", "Source", "Updated", "Info"}, rows);
        }
        return 0;
    } catch (const std::exception& error) {
        const std::string message = error.what();
        if (message.rfind("Invalid regular expression:", 0) == 0) {
            err << message << '\n';
        } else {
            err << "list error: " << message << '\n';
        }
        return 1;
    }
}

int Cli::run_status(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco status\n\n"
            << "Options:\n"
            << "  -l, --local         Checks the status for only the locally installed apps,\n"
            << "                      and disables remote fetching/checking for Scoop and buckets\n";
        return 0;
    }

    const auto local_only = args.size() > 1 && (lower_ascii(args[1]) == "-l" || lower_ascii(args[1]) == "--local");

    try {
        const auto environment = load_environment();
        const auto scoop_check = local_only ? StatusRemoteCheck{} : status_scoop_update_check(environment);
        const auto bucket_check = local_only ? StatusRemoteCheck{} : status_bucket_update_check(environment);
        const auto scoop_needs_update = scoop_check.needs_update;
        const auto bucket_needs_update = bucket_check.needs_update;
        const auto network_failure = scoop_check.network_failure || bucket_check.network_failure;
        if (scoop_needs_update) {
            out << "WARN  Scoop out of date. Run 'scoop update' to get the latest changes.\n";
        } else if (bucket_needs_update) {
            out << "WARN  Scoop bucket(s) out of date. Run 'scoop update' to get the latest changes.\n";
        } else if (!local_only && !network_failure) {
            out << "Scoop is up to date.\n";
        }

        const auto statuses = list_app_statuses(environment, local_only);
        if (statuses.empty()) {
            if (!scoop_needs_update && !bucket_needs_update && !network_failure) {
                out << "Everything is ok!\n";
            }
            return 0;
        }

        std::vector<std::vector<std::string>> rows;
        rows.reserve(statuses.size());
        for (const auto& status : statuses) {
            std::vector<std::string> info;
            if (status.failed) {
                info.push_back(status.info.empty() || status.info == "Install failed" ? "Install failed" : status.info);
            }
            if (status.held) {
                info.push_back("Held package");
            }
            if (status.deprecated) {
                info.push_back("Deprecated");
            }
            if (status.removed) {
                info.push_back("Manifest removed");
            }
            if (!status.info.empty() && status.info != "Install failed" && status.info != "Manifest removed"
                && std::find(info.begin(), info.end(), status.info) == info.end()) {
                info.push_back(status.info);
            }
            rows.push_back({
                status.name,
                status.installed_version,
                status.outdated ? status.latest_version : std::string{},
                join_strings(status.missing_dependencies, " | "),
                join_strings(info, ", "),
            });
        }
        write_table(out, std::vector<std::string>{"Name", "Installed Version", "Latest Version", "Missing Dependencies", "Info"}, rows);
        return 0;
    } catch (const std::exception& error) {
        err << "status error: " << error.what() << '\n';
        return 1;
    }
}

int Cli::run_search(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
    if (args.size() > 1 && is_help_argument(args[1])) {
        out << "Usage: sco search <query>\n\n"
            << "Searches for apps that are available to install.\n\n"
            << "If used with [query], shows app names that match the query.\n"
            << "  - With 'use_sqlite_cache' enabled, [query] is partially matched against app names, binaries, and shortcuts.\n"
            << "  - Without 'use_sqlite_cache', [query] can be a regular expression to match against app names and binaries.\n"
            << "Without [query], shows all the available apps.\n";
        return 0;
    }
    try {
        const auto environment = load_environment();
        const auto query = args.size() > 1 ? args[1] : std::string{};
        const auto sqlite_cache_mode = config_bool(environment, "use_sqlite_cache");
        const auto results = search_bucket_manifests(environment, query, sqlite_cache_mode);
        if (!results.empty()) {
            out << "Results from local buckets...\n";
            std::vector<std::vector<std::string>> rows;
            rows.reserve(results.size());
            for (const auto& result : results) {
                rows.push_back({result.name, result.version, result.bucket, join_strings(result.bins, " | ")});
            }
            write_table(out, std::vector<std::string>{"Name", "Version", "Source", "Binaries"}, rows);
            return 0;
        }

        const auto remote_results = search_known_bucket_manifests(environment, query);
        if (remote_results.empty()) {
            out << "WARN  No matches found.\n";
            return 1;
        }

        out << "Results from other known buckets...\n"
            << "(add them using 'sco bucket add <bucket name>')\n";
        std::vector<std::vector<std::string>> rows;
        rows.reserve(remote_results.size());
        for (const auto& result : remote_results) {
            rows.push_back({result.name, result.bucket});
        }
        write_table(out, std::vector<std::string>{"Name", "Source"}, rows);
        return 0;
    } catch (const std::exception& error) {
        const std::string message = error.what();
        if (message.rfind("Invalid regular expression:", 0) == 0) {
            err << message << '\n';
        } else {
            err << "search error: " << message << '\n';
        }
        return 1;
    }
}

} // namespace sco
