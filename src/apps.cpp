#include "sco/apps.hpp"

#include "sco/artifact.hpp"
#include "sco/buckets.hpp"
#include "sco/checkver.hpp"
#include "sco/config.hpp"
#include "sco/http_client.hpp"
#include "sco/manifest.hpp"
#include "sco/versions.hpp"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <ctime>
#include <iomanip>
#include <nlohmann/json.hpp>

#include <fstream>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <unordered_map>

namespace sco {

namespace {

class QueryMatcher {
public:
    explicit QueryMatcher(std::string query) : query_(std::move(query)) {
        if (query_.empty()) {
            return;
        }

        try {
            regex_.emplace(query_, std::regex_constants::icase);
        } catch (const std::regex_error& error) {
            throw std::runtime_error(std::string("Invalid regular expression: ") + error.what());
        }
    }

    bool matches(const std::string& value) const {
        if (query_.empty()) {
            return true;
        }
        return std::regex_search(value, *regex_);
    }

private:
    std::string query_;
    std::optional<std::regex> regex_;
};

struct InstalledAppReference {
    std::string name;
    std::string version;
    std::string source;
    bool global = false;
};

nlohmann::json read_json_file(const std::filesystem::path& path) {
    std::ifstream stream(path);
    if (!stream) {
        return nlohmann::json::object();
    }

    nlohmann::json value;
    try {
        stream >> value;
    } catch (const nlohmann::json::exception&) {
        return nlohmann::json::object();
    }
    return value;
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

std::optional<std::string> json_string_property(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value != nullptr && value->is_string()) {
        return value->get<std::string>();
    }
    return std::nullopt;
}

bool json_bool_property(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    return value != nullptr && value->is_boolean() && value->get<bool>();
}

void erase_json_property(nlohmann::json& object, const char* key) {
    if (!object.is_object()) {
        return;
    }
    if (object.erase(key) != 0) {
        return;
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
            object.erase(it);
            return;
        }
    }
}

std::string normalize_architecture_name(std::string architecture) {
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
    return architecture;
}

std::string lower_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string current_version_impl(const Environment& environment, const std::string& app, bool global) {
    const auto root = app_dir(environment, app, global);
    const auto no_junction_value = ConfigStore(environment.config_file).get("no_junction");
    const auto no_junction = no_junction_value && no_junction_value->is_boolean() && no_junction_value->get<bool>();
    if (!no_junction) {
        const auto current_manifest = root / "current" / "manifest.json";
        const auto manifest = read_json_file(current_manifest);
        if (const auto version_value = json_string_property(manifest, "version")) {
            const auto version = *version_value;
            if (version == "nightly") {
                std::error_code error;
                const auto resolved = std::filesystem::weakly_canonical(root / "current", error);
                if (!error && resolved.filename().string().rfind("nightly-", 0) == 0) {
                    return resolved.filename().string();
                }
            }
            return version;
        }
    }

    const auto versions = installed_versions(environment, app, global);
    return versions.empty() ? std::string{} : versions.back();
}

bool install_failed_impl(const Environment& environment, const std::string& app, bool global) {
    const auto root = app_dir(environment, app, global);
    if (!std::filesystem::is_directory(root)) {
        return false;
    }

    const auto no_junction_value = ConfigStore(environment.config_file).get("no_junction");
    const auto no_junction = no_junction_value && no_junction_value->is_boolean() && no_junction_value->get<bool>();
    const auto has_current = no_junction || std::filesystem::exists(root / "current");
    return !(has_current && !current_version_impl(environment, app, global).empty());
}

std::vector<std::string> installed_versions_impl(const Environment& environment, const std::string& app, bool global) {
    std::vector<std::filesystem::path> versions;
    const auto root = app_dir(environment, app, global);
    if (!std::filesystem::is_directory(root)) {
        return {};
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_directory()) {
            continue;
        }
        const auto name = entry.path().filename().string();
        if (name == "current" || name.rfind("_", 0) == 0) {
            continue;
        }
        if (std::filesystem::exists(entry.path() / "install.json")) {
            versions.push_back(entry.path());
        }
    }

    std::sort(versions.begin(), versions.end(), [](const auto& lhs, const auto& rhs) {
        return std::filesystem::last_write_time(lhs / "install.json") < std::filesystem::last_write_time(rhs / "install.json");
    });

    std::vector<std::string> names;
    names.reserve(versions.size());
    for (const auto& version : versions) {
        names.push_back(version.filename().string());
    }
    return names;
}

std::string source_for(const Environment& environment, const std::string& app, const std::string& version, bool global) {
    if (version.empty()) {
        return {};
    }

    const auto install = read_json_file(app_dir(environment, app, global) / version / "install.json");
    if (const auto bucket = json_string_property(install, "bucket")) {
        return *bucket;
    }
    if (auto source_value = json_string_property(install, "url")) {
        auto source = *source_value;
        const auto generated = environment.cache_dir / "generated-manifests" / app / version / (app + ".json");
        std::error_code source_error;
        const auto source_path = std::filesystem::weakly_canonical(std::filesystem::path(source), source_error);
        std::error_code generated_error;
        const auto generated_path = std::filesystem::weakly_canonical(generated, generated_error);
        if (!source_error && !generated_error && source_path == generated_path) {
            return "<auto-generated>";
        }
        return source;
    }
    return {};
}

bool path_is_inside(const std::filesystem::path& path, const std::filesystem::path& root) {
    std::error_code path_error;
    const auto canonical_path = std::filesystem::weakly_canonical(path, path_error);
    std::error_code root_error;
    const auto canonical_root = std::filesystem::weakly_canonical(root, root_error);
    if (path_error || root_error) {
        return false;
    }

    const auto relative = std::filesystem::relative(canonical_path, canonical_root, path_error);
    return !path_error && !relative.empty() && *relative.begin() != std::filesystem::path("..");
}

bool looks_like_http_url(const std::string& value) {
    const auto lower = lower_copy(value);
    return lower.rfind("http://", 0) == 0 || lower.rfind("https://", 0) == 0;
}

std::optional<std::filesystem::path> materialize_remote_manifest(const Environment& environment, const std::string& url) {
    const HttpClient client;
    const auto response = client.get(url);
    if (response.status < 200 || response.status >= 300) {
        return std::nullopt;
    }

    try {
        const auto parsed = nlohmann::json::parse(response.body);
        if (!parsed.is_object()) {
            return std::nullopt;
        }
    } catch (const nlohmann::json::exception&) {
        return std::nullopt;
    }

    auto filename = url_filename(url);
    if (filename.empty() || lower_copy(std::filesystem::path(filename).extension().string()) != ".json") {
        filename = "manifest.json";
    }
    const auto output = environment.cache_dir / "remote-manifests" / sha256_text(url).substr(0, 12) / filename;
    std::filesystem::create_directories(output.parent_path());
    std::ofstream stream(output, std::ios::binary);
    if (!stream) {
        return std::nullopt;
    }
    stream << response.body;
    if (response.body.empty() || response.body.back() != '\n') {
        stream << '\n';
    }
    return output;
}

std::filesystem::path install_json_path(const Environment& environment, const std::string& app, bool global) {
    const auto current = current_dir(environment, app, global) / "install.json";
    if (std::filesystem::is_regular_file(current)) {
        return current;
    }

    const auto version = current_version_impl(environment, app, global);
    if (!version.empty()) {
        return app_dir(environment, app, global) / version / "install.json";
    }
    return current;
}

std::string local_timestamp(std::filesystem::file_time_type value) {
    const auto system_time = std::chrono::time_point_cast<std::chrono::system_clock::duration>(
        value - std::filesystem::file_time_type::clock::now() + std::chrono::system_clock::now());
    const auto time = std::chrono::system_clock::to_time_t(system_time);
    std::tm local{};
    localtime_s(&local, &time);

    int offset_min = 0;
    {
        std::tm utc{};
        gmtime_s(&utc, &time);
        const auto local_seconds = localtime_s(&local, &time) == 0 ? std::mktime(&local) : 0;
        gmtime_s(&utc, &time);
        const auto utc_seconds = std::mktime(&utc);
        offset_min = static_cast<int>((local_seconds - utc_seconds) / 60);
    }
    localtime_s(&local, &time);
    const auto offset_hours = offset_min / 60;
    const auto offset_mins = std::abs(offset_min) % 60;
    const auto sign = offset_min >= 0 ? '+' : '-';

    std::ostringstream stream;
    stream << std::put_time(&local, "%Y-%m-%dT%H:%M:%S")
           << sign << std::setfill('0') << std::setw(2) << std::abs(offset_hours)
           << ':' << std::setfill('0') << std::setw(2) << offset_mins;
    return stream.str();
}

std::string updated_for(const Environment& environment, const std::string& app, bool global) {
    std::error_code error;
    const auto install_path = install_json_path(environment, app, global);
    if (std::filesystem::is_regular_file(install_path, error)) {
        const auto updated = std::filesystem::last_write_time(install_path, error);
        if (!error) {
            return local_timestamp(updated);
        }
    }

    const auto root = app_dir(environment, app, global);
    const auto updated = std::filesystem::last_write_time(root, error);
    return error ? std::string{} : local_timestamp(updated);
}

std::string join_info_parts(const std::vector<std::string>& values) {
    std::ostringstream stream;
    for (const auto& value : values) {
        if (value.empty()) {
            continue;
        }
        if (stream.tellp() > 0) {
            stream << ", ";
        }
        stream << value;
    }
    return stream.str();
}

std::string info_for(const Environment& environment, const std::string& app, bool global) {
    std::vector<std::string> info;
    const auto install = read_json_file(install_json_path(environment, app, global));
    if (const auto bucket = json_string_property(install, "bucket");
        bucket && deprecated_manifest_path(environment, app, *bucket)) {
        info.push_back("Deprecated package");
    }
    if (global) {
        info.push_back("Global install");
    }
    if (install_failed_impl(environment, app, global)) {
        info.push_back("Install failed");
    }

    if (json_bool_property(install, "hold")) {
        info.push_back("Held package");
    }

    const auto configured = ConfigStore(environment.config_file).get("default_architecture");
    const auto default_architecture = configured && configured->is_string() && !configured->get<std::string>().empty()
        ? normalize_architecture_name(configured->get<std::string>())
        : std::string{"64bit"};
    if (const auto architecture_value = json_string_property(install, "architecture")) {
        const auto architecture = *architecture_value;
        if (!architecture.empty() && architecture != default_architecture) {
            info.push_back(architecture);
        }
    }
    return join_info_parts(info);
}

std::string app_name_for_dependency(const std::string& dependency) {
    auto name = dependency;
    if (const auto at = name.rfind('@'); at != std::string::npos && at + 1 < name.size()) {
        name.erase(at);
    }
    if (const auto slash = name.find_last_of("/\\"); slash != std::string::npos) {
        name = name.substr(slash + 1);
    }
    return name;
}

bool installed_in_any_scope(const Environment& environment, const std::string& app) {
    return !select_current_version(environment, app, false).empty()
        || !select_current_version(environment, app, true).empty();
}

std::vector<std::string> missing_dependencies_for(const Environment& environment, const Manifest& manifest) {
    std::vector<std::string> missing;
    for (const auto& dependency : manifest.depends) {
        const auto app = app_name_for_dependency(dependency);
        if (!app.empty() && !installed_in_any_scope(environment, app)) {
            missing.push_back(dependency);
        }
    }
    return missing;
}

void write_json_file(const std::filesystem::path& path, const nlohmann::json& value) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    if (stream) {
        stream << value.dump(4) << '\n';
    }
}

void collect_apps(const Environment& environment, bool global, const QueryMatcher& query, std::vector<InstalledApp>& apps) {
    const auto root = environment.apps_dir(global);
    if (!std::filesystem::is_directory(root)) {
        return;
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_directory()) {
            continue;
        }

        const auto name = entry.path().filename().string();
        if (name == "scoop" || !query.matches(name)) {
            continue;
        }

        const auto version = current_version_impl(environment, name, global);
        apps.push_back(InstalledApp{
            .name = name,
            .version = version,
            .source = source_for(environment, name, version, global),
            .updated = updated_for(environment, name, global),
            .info = info_for(environment, name, global),
            .global = global,
        });
    }
}

void collect_app_references(const Environment& environment, bool global, std::vector<InstalledAppReference>& apps) {
    const auto root = environment.apps_dir(global);
    if (!std::filesystem::is_directory(root)) {
        return;
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_directory()) {
            continue;
        }

        const auto name = entry.path().filename().string();
        if (name == "scoop") {
            continue;
        }

        const auto version = current_version_impl(environment, name, global);
        apps.push_back(InstalledAppReference{
            .name = name,
            .version = version,
            .source = source_for(environment, name, version, global),
            .global = global,
        });
    }
}

bool has_installed_apps_in_scope(const Environment& environment, bool global) {
    const auto root = environment.apps_dir(global);
    if (!std::filesystem::is_directory(root)) {
        return false;
    }

    for (const auto& entry : std::filesystem::directory_iterator(root)) {
        if (!entry.is_directory()) {
            continue;
        }
        if (entry.path().filename().string() != "scoop") {
            return true;
        }
    }
    return false;
}

} // namespace

std::filesystem::path app_dir(const Environment& environment, const std::string& app, bool global) {
    return environment.apps_dir(global) / app;
}

std::filesystem::path current_dir_for_version(const Environment& environment, const std::string& app, const std::string& version, bool global) {
    const auto no_junction_value = ConfigStore(environment.config_file).get("no_junction");
    if (no_junction_value && no_junction_value->is_boolean() && no_junction_value->get<bool>() && !version.empty()) {
        return app_dir(environment, app, global) / version;
    }
    return app_dir(environment, app, global) / "current";
}

std::filesystem::path current_dir(const Environment& environment, const std::string& app, bool global) {
    return current_dir_for_version(environment, app, current_version_impl(environment, app, global), global);
}

std::string select_current_version(const Environment& environment, const std::string& app, bool global) {
    return current_version_impl(environment, app, global);
}

bool app_install_failed(const Environment& environment, const std::string& app, bool global) {
    return install_failed_impl(environment, app, global);
}

std::vector<std::string> installed_versions(const Environment& environment, const std::string& app, bool global) {
    return installed_versions_impl(environment, app, global);
}

std::optional<std::filesystem::path> find_app_prefix(const Environment& environment, const std::string& app) {
    const auto local = current_dir(environment, app, false);
    if (std::filesystem::exists(local)) {
        return local;
    }

    const auto global = current_dir(environment, app, true);
    if (std::filesystem::exists(global)) {
        return global;
    }

    return std::nullopt;
}

bool has_installed_apps(const Environment& environment) {
    return has_installed_apps_in_scope(environment, false) || has_installed_apps_in_scope(environment, true);
}

std::vector<InstalledApp> list_installed_apps(const Environment& environment, const std::string& query) {
    std::vector<InstalledApp> apps;
    const QueryMatcher matcher(query);
    collect_apps(environment, false, matcher, apps);
    collect_apps(environment, true, matcher, apps);
    std::sort(apps.begin(), apps.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.global != rhs.global) {
            return !lhs.global;
        }
        return lhs.name < rhs.name;
    });
    return apps;
}

std::vector<AppStatus> list_app_statuses(const Environment& environment, bool local_only) {
    std::vector<AppStatus> statuses;
    const auto force_update_value = ConfigStore(environment.config_file).get("force_update");
    const auto force_update = force_update_value && force_update_value->is_boolean() && force_update_value->get<bool>();
    const auto update_nightly_value = ConfigStore(environment.config_file).get("update_nightly");
    const auto update_nightly = update_nightly_value && update_nightly_value->is_boolean() && update_nightly_value->get<bool>();
    std::optional<std::unordered_map<std::string, std::filesystem::path>> manifest_paths;

    std::vector<InstalledAppReference> apps;
    collect_app_references(environment, false, apps);
    if (!local_only) {
        collect_app_references(environment, true, apps);
    }

    for (const auto& app : apps) {

        AppStatus status{
            .name = app.name,
            .installed_version = app.version,
            .global = app.global,
            .held = is_app_held(environment, app.name, app.global),
            .deprecated = deprecated_manifest_path(environment, app.name, app.source).has_value(),
            .failed = install_failed_impl(environment, app.name, app.global),
        };

        if (status.failed) {
            status.info = "Install failed";
        }
        if (app.version.empty()) {
            statuses.push_back(std::move(status));
            continue;
        }

        const auto remote_source = installed_app_manifest_url(environment, app.name, app.global);
        auto manifest_path = installed_app_manifest_path(environment, app.name, app.global);
        if (!manifest_path && !remote_source) {
            if (!manifest_paths) {
                manifest_paths.emplace();
                for (const auto& entry : list_bucket_manifest_index(environment)) {
                    manifest_paths->try_emplace(entry.name, entry.path);
                }
            }
            if (const auto bucket_manifest = manifest_paths->find(app.name); bucket_manifest != manifest_paths->end()) {
                manifest_path = bucket_manifest->second;
            }
        }
        if (!manifest_path) {
            status.removed = true;
            status.info = "Manifest removed";
            statuses.push_back(std::move(status));
            continue;
        }

        try {
            const auto latest = load_manifest_file(*manifest_path, app.name);
            status.latest_version = latest.version;
            if (status.latest_version == "nightly") {
                status.latest_version = nightly_version();
            }
            status.missing_dependencies = missing_dependencies_for(environment, latest);
            const auto comparison = status.latest_version.empty() ? 0 : compare_versions(app.version, status.latest_version, update_nightly);
            status.outdated = force_update ? comparison != 0 : comparison > 0;
            if (status.failed || status.outdated || status.deprecated || !status.missing_dependencies.empty()) {
                statuses.push_back(std::move(status));
            }
        } catch (const std::exception&) {
            status.failed = true;
            status.info = "Manifest parse failed";
            statuses.push_back(std::move(status));
        }
    }

    std::sort(statuses.begin(), statuses.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.global != rhs.global) {
            return lhs.global;
        }
        if (lhs.name != rhs.name) {
            return lhs.name < rhs.name;
        }
        return false;
    });
    return statuses;
}

std::optional<std::filesystem::path> deprecated_manifest_path(const Environment& environment, const std::string& app, const std::string& bucket_name) {
    if (bucket_name.empty()) {
        return std::nullopt;
    }

    const auto requested_bucket = lower_copy(bucket_name);
    const auto requested_app = lower_copy(app);
    static std::unordered_map<std::string, std::unordered_map<std::string, std::filesystem::path>> deprecated_by_bucket;
    const auto buckets_root = environment.buckets_dir();
    if (!std::filesystem::is_directory(buckets_root)) {
        return std::nullopt;
    }

    for (const auto& bucket_entry : std::filesystem::directory_iterator(buckets_root)) {
        if (!bucket_entry.is_directory()) {
            continue;
        }
        const auto current_bucket_name = bucket_entry.path().filename().string();
        if (lower_copy(current_bucket_name) != requested_bucket) {
            continue;
        }
        const auto bucket_path = bucket_entry.path();

        std::error_code canonical_error;
        const auto canonical_bucket = std::filesystem::weakly_canonical(bucket_path, canonical_error);
        const auto cache_key = (canonical_error ? bucket_path : canonical_bucket).generic_string() + "|" + requested_bucket;
        auto [cache_it, inserted] = deprecated_by_bucket.try_emplace(cache_key);
        if (inserted) {
            const auto deprecated_dir = bucket_path / "deprecated";
            if (std::filesystem::is_directory(deprecated_dir)) {
                std::error_code iterator_error;
                auto it = std::filesystem::recursive_directory_iterator(
                    deprecated_dir,
                    std::filesystem::directory_options::skip_permission_denied,
                    iterator_error);
                const auto end = std::filesystem::recursive_directory_iterator();
                while (!iterator_error && it != end) {
                    std::error_code entry_error;
                    if (it->is_regular_file(entry_error) && lower_copy(it->path().extension().string()) == ".json") {
                        std::error_code path_error;
                        const auto canonical_path = std::filesystem::weakly_canonical(it->path(), path_error);
                        cache_it->second.try_emplace(
                            lower_copy(it->path().stem().string()),
                            path_error ? it->path() : canonical_path);
                    }
                    it.increment(iterator_error);
                }
            }
        }
        if (const auto match = cache_it->second.find(requested_app); match != cache_it->second.end()) {
            return match->second;
        }
        return std::nullopt;
    }

    return std::nullopt;
}

std::optional<std::string> installed_app_architecture(const Environment& environment, const std::string& app, bool global) {
    const auto install = read_json_file(install_json_path(environment, app, global));
    if (const auto architecture_value = json_string_property(install, "architecture")) {
        const auto architecture = *architecture_value;
        if (!architecture.empty()) {
            return architecture;
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> installed_app_manifest_path(const Environment& environment, const std::string& app, bool global) {
    const auto install = read_json_file(install_json_path(environment, app, global));
    if (const auto bucket_value = json_string_property(install, "bucket")) {
        const auto bucket = *bucket_value;
        if (!bucket.empty()) {
            return find_manifest_in_buckets(environment, bucket + "/" + app);
        }
    }

    if (const auto remote_url = installed_app_manifest_url(environment, app, global)) {
        return materialize_remote_manifest(environment, *remote_url);
    }

    const auto generated_root = environment.cache_dir / "generated-manifests";
    for (const auto* key : {"url", "manifest"}) {
        const auto source = json_string_property(install, key).value_or(std::string{});
        if (source.empty()) {
            continue;
        }
        std::error_code error;
        const auto path = std::filesystem::weakly_canonical(std::filesystem::path(source), error);
        if (!error && std::filesystem::is_regular_file(path)) {
            if (path_is_inside(path, generated_root)) {
                continue;
            }
            return path;
        }
    }
    return std::nullopt;
}

std::optional<std::string> installed_app_manifest_url(const Environment& environment, const std::string& app, bool global) {
    const auto install = read_json_file(install_json_path(environment, app, global));
    const auto url = json_string_property(install, "url").value_or(std::string{});
    return looks_like_http_url(url) ? std::optional<std::string>{url} : std::nullopt;
}

bool is_app_held(const Environment& environment, const std::string& app, bool global) {
    const auto install = read_json_file(install_json_path(environment, app, global));
    return json_bool_property(install, "hold");
}

HoldResult set_app_hold(const Environment& environment, const std::string& app, bool hold, bool global) {
    const auto version = current_version_impl(environment, app, global);
    HoldResult result{.app = app, .installed = !version.empty()};
    if (!result.installed) {
        return result;
    }

    const auto path = install_json_path(environment, app, global);
    auto install = read_json_file(path);
    const auto was_held = json_bool_property(install, "hold");
    result.held = hold;
    result.changed = was_held != hold;
    if (hold) {
        install["hold"] = true;
    } else {
        erase_json_property(install, "hold");
    }
    write_json_file(path, install);
    return result;
}

} // namespace sco
