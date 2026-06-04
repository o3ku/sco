#include "sco/buckets.hpp"

#include "sco/config.hpp"
#include "sco/http_client.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <unordered_map>
#include <unordered_set>

namespace sco {

namespace {

enum class QueryMatchMode {
    Regex,
    SqliteLike,
};

std::string lower_copy(std::string value);

std::string path_to_utf8(const std::filesystem::path& path) {
    const auto value = path.generic_u8string();
    return std::string(value.begin(), value.end());
}

std::filesystem::path path_from_utf8(const std::string& value) {
    return std::filesystem::path(std::u8string(value.begin(), value.end()));
}

std::string path_stem_utf8(const std::filesystem::path& path) {
    const auto value = path.stem().u8string();
    return std::string(value.begin(), value.end());
}

std::string path_extension_utf8(const std::filesystem::path& path) {
    const auto value = path.extension().u8string();
    return std::string(value.begin(), value.end());
}

std::string regex_escaped_char(const char value) {
    constexpr std::string_view special = R"(\.^$|()[]{}*+?)";
    if (special.find(value) != std::string_view::npos) {
        return std::string{"\\"} + value;
    }
    return std::string(1, value);
}

std::string sqlite_like_query_to_regex(const std::string& query) {
    std::string pattern = ".*";
    for (const auto value : query) {
        if (value == '%') {
            pattern += ".*";
        } else if (value == '_') {
            pattern += '.';
        } else {
            pattern += regex_escaped_char(value);
        }
    }
    pattern += ".*";
    return pattern;
}

class QueryMatcher {
public:
    explicit QueryMatcher(std::string query, QueryMatchMode mode = QueryMatchMode::Regex) : query_(std::move(query)), mode_(mode) {
        if (query_.empty()) {
            return;
        }

        try {
            if (mode == QueryMatchMode::SqliteLike) {
                regex_.emplace(sqlite_like_query_to_regex(query_), std::regex_constants::icase);
            } else {
                regex_.emplace(query_, std::regex_constants::icase);
            }
        } catch (const std::regex_error& error) {
            throw std::runtime_error(std::string("Invalid regular expression: ") + error.what());
        }
    }

    bool matches(const std::string& text) const {
        if (query_.empty()) {
            return true;
        }
        if (mode_ == QueryMatchMode::SqliteLike) {
            return std::regex_match(text, *regex_);
        }
        return std::regex_search(text, *regex_);
    }

private:
    std::string query_;
    QueryMatchMode mode_;
    std::optional<std::regex> regex_;
};

std::string optional_string(const nlohmann::json& object, const char* key) {
    if (object.contains(key) && object.at(key).is_string()) {
        return object.at(key).get<std::string>();
    }
    return {};
}

std::string strip_extension(std::string name) {
    const auto dot = name.find_last_of('.');
    if (dot != std::string::npos) {
        name.erase(dot);
    }
    return name;
}

bool sqlite_search_strips_extension(const std::string& extension) {
    const auto lowered = lower_copy(extension);
    return lowered == ".exe" || lowered == ".bat" || lowered == ".cmd" || lowered == ".ps1"
        || lowered == ".jar" || lowered == ".py";
}

std::string sqlite_search_binary_name(std::string value) {
    const auto extension = path_extension_utf8(path_from_utf8(value));
    if (!sqlite_search_strips_extension(extension)) {
        return value;
    }
    return path_stem_utf8(path_from_utf8(value));
}

void push_unique(std::vector<std::string>& values, std::string value) {
    if (value.empty()) {
        return;
    }
    if (std::find(values.begin(), values.end(), value) == values.end()) {
        values.push_back(std::move(value));
    }
}

std::string bin_name_from_target(const std::string& target) {
    const auto value = path_from_utf8(target).filename().u8string();
    return std::string(value.begin(), value.end());
}

std::string extension_segment_from_target(const std::string& target) {
    const auto filename = bin_name_from_target(target);
    const auto dot = filename.find_last_of('.');
    return dot == std::string::npos ? filename : filename.substr(dot + 1);
}

std::vector<std::string> collect_search_bins(const nlohmann::json& manifest) {
    std::vector<std::string> bins;
    if (!manifest.is_object() || !manifest.contains("bin") || manifest.at("bin").is_null()) {
        return bins;
    }

    const auto append = [&](const nlohmann::json& item) {
        if (item.is_string()) {
            push_unique(bins, sqlite_search_binary_name(item.get<std::string>()));
        } else if (item.is_array() && !item.empty() && item.front().is_string()) {
            const auto target = item.front().get<std::string>();
            if (item.size() > 1 && item.at(1).is_string()) {
                push_unique(bins, sqlite_search_binary_name(item.at(1).get<std::string>() + "." + extension_segment_from_target(target)));
            } else {
                push_unique(bins, sqlite_search_binary_name(target));
            }
        }
    };

    const auto& value = manifest.at("bin");
    if (value.is_array()) {
        for (const auto& item : value) {
            append(item);
        }
    } else {
        append(value);
    }
    return bins;
}

std::vector<std::string> collect_search_shortcuts(const nlohmann::json& manifest) {
    std::vector<std::string> shortcuts;
    if (!manifest.is_object() || !manifest.contains("shortcuts") || !manifest.at("shortcuts").is_array()) {
        return shortcuts;
    }

    for (const auto& item : manifest.at("shortcuts")) {
        if (item.is_array() && item.size() > 1 && item.at(1).is_string()) {
            push_unique(shortcuts, item.at(1).get<std::string>());
        }
    }
    return shortcuts;
}

std::vector<std::string> collect_matching_search_bins(const std::filesystem::path& path, const QueryMatcher& matcher) {
    std::ifstream stream(path);
    if (!stream) {
        return {};
    }

    nlohmann::json manifest;
    try {
        stream >> manifest;
    } catch (const nlohmann::json::exception&) {
        return {};
    }

    if (!manifest.is_object() || !manifest.contains("bin") || manifest.at("bin").is_null()) {
        return {};
    }

    std::vector<std::string> bins;
    const auto append = [&](const nlohmann::json& item) {
        if (item.is_string()) {
            const auto filename = bin_name_from_target(item.get<std::string>());
            if (matcher.matches(strip_extension(filename))) {
                push_unique(bins, filename);
            }
        } else if (item.is_array() && !item.empty() && item.front().is_string()) {
            const auto filename = bin_name_from_target(item.front().get<std::string>());
            if (matcher.matches(strip_extension(filename))) {
                push_unique(bins, filename);
            } else if (item.size() > 1 && item.at(1).is_string() && matcher.matches(item.at(1).get<std::string>())) {
                push_unique(bins, item.at(1).get<std::string>());
            }
        }
    };

    const auto& value = manifest.at("bin");
    if (value.is_array()) {
        for (const auto& item : value) {
            append(item);
        }
    } else {
        append(value);
    }
    return bins;
}

std::vector<std::string> collect_matching_values(const std::vector<std::string>& values, const QueryMatcher& matcher) {
    std::vector<std::string> matches;
    for (const auto& value : values) {
        if (matcher.matches(value)) {
            push_unique(matches, value);
        }
    }
    return matches;
}

SearchResult read_manifest_summary(const std::filesystem::path& path, const std::string& bucket) {
    SearchResult result;
    result.bucket = bucket;
    result.name = path_stem_utf8(path);
    result.path = path;

    std::ifstream stream(path);
    if (!stream) {
        return result;
    }

    nlohmann::json manifest;
    try {
        stream >> manifest;
    } catch (const nlohmann::json::exception&) {
        return result;
    }

    if (manifest.is_object()) {
        result.version = optional_string(manifest, "version");
        result.description = optional_string(manifest, "description");
        result.bins = collect_search_bins(manifest);
        result.shortcuts = collect_search_shortcuts(manifest);
    }
    return result;
}

std::int64_t file_time_ticks(const std::filesystem::file_time_type value) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(value.time_since_epoch()).count();
}

std::int64_t last_write_ticks(const std::filesystem::path& path) {
    std::error_code error;
    const auto value = std::filesystem::last_write_time(path, error);
    return error ? 0 : file_time_ticks(value);
}

std::uintmax_t file_size_or_zero(const std::filesystem::path& path) {
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    return error ? 0 : size;
}

struct BucketSignature {
    std::string name;
    std::filesystem::path path;
    std::uint64_t count = 0;
    std::int64_t max_write_time = 0;
    std::uint64_t size_sum = 0;
    std::uint64_t time_sum = 0;
};

std::filesystem::path bucket_manifest_search_dir(const std::filesystem::path& bucket_root) {
    const auto manifests = bucket_root / "bucket";
    if (std::filesystem::is_directory(manifests)) {
        return manifests;
    }
    return bucket_root;
}

std::vector<BucketSignature> bucket_signatures(const Environment& environment) {
    std::vector<BucketSignature> signatures;
    for (const auto& bucket : list_local_buckets(environment)) {
        BucketSignature signature;
        signature.name = bucket.name;
        signature.path = bucket.path;

        const auto manifests = bucket_manifest_search_dir(bucket.path);
        if (!std::filesystem::is_directory(manifests)) {
            signatures.push_back(std::move(signature));
            continue;
        }
        for (const auto& manifest_entry : std::filesystem::recursive_directory_iterator(manifests)) {
            if (!manifest_entry.is_regular_file() || lower_copy(path_extension_utf8(manifest_entry.path())) != ".json") {
                continue;
            }

            const auto ticks = last_write_ticks(manifest_entry.path());
            signature.count += 1;
            signature.max_write_time = std::max(signature.max_write_time, ticks);
            signature.time_sum += static_cast<std::uint64_t>(ticks);
            signature.size_sum += static_cast<std::uint64_t>(file_size_or_zero(manifest_entry.path()));
        }
        signatures.push_back(std::move(signature));
    }
    return signatures;
}

std::filesystem::path manifest_index_path(const Environment& environment) {
    return environment.cache_dir / "buckets.index.json";
}

nlohmann::json signatures_to_json(const std::vector<BucketSignature>& signatures) {
    nlohmann::json buckets = nlohmann::json::array();
    for (const auto& signature : signatures) {
        buckets.push_back({
            {"name", signature.name},
            {"path", path_to_utf8(std::filesystem::weakly_canonical(signature.path))},
            {"count", signature.count},
            {"max_write_time", signature.max_write_time},
            {"size_sum", signature.size_sum},
            {"time_sum", signature.time_sum},
        });
    }
    return buckets;
}

bool cache_signatures_match(const nlohmann::json& cache, const std::vector<BucketSignature>& signatures) {
    if (!cache.is_object() || !cache.contains("buckets") || !cache.at("buckets").is_array()) {
        return false;
    }
    if (!cache.contains("version") || !cache.at("version").is_number_integer() || cache.at("version").get<int>() != 4) {
        return false;
    }

    const auto expected = signatures_to_json(signatures);
    return cache.at("buckets") == expected;
}

std::vector<SearchResult> entries_from_cache(const nlohmann::json& cache) {
    std::vector<SearchResult> entries;
    if (!cache.is_object() || !cache.contains("entries") || !cache.at("entries").is_array()) {
        return entries;
    }

    for (const auto& item : cache.at("entries")) {
        if (!item.is_object()) {
            continue;
        }
        SearchResult entry;
        entry.bucket = optional_string(item, "bucket");
        entry.name = optional_string(item, "name");
        entry.version = optional_string(item, "version");
        entry.description = optional_string(item, "description");
        entry.path = path_from_utf8(optional_string(item, "path"));
        if (item.contains("bins") && item.at("bins").is_array()) {
            for (const auto& bin : item.at("bins")) {
                if (bin.is_string()) {
                    entry.bins.push_back(bin.get<std::string>());
                }
            }
        }
        if (item.contains("shortcuts") && item.at("shortcuts").is_array()) {
            for (const auto& shortcut : item.at("shortcuts")) {
                if (shortcut.is_string()) {
                    entry.shortcuts.push_back(shortcut.get<std::string>());
                }
            }
        }
        if (!entry.bucket.empty() && !entry.name.empty() && !entry.path.empty()) {
            entries.push_back(std::move(entry));
        }
    }
    return entries;
}

nlohmann::json entries_to_json(const std::vector<SearchResult>& entries) {
    nlohmann::json items = nlohmann::json::array();
    for (const auto& entry : entries) {
        items.push_back({
            {"bucket", entry.bucket},
            {"name", entry.name},
            {"version", entry.version},
            {"description", entry.description},
            {"bins", entry.bins},
            {"shortcuts", entry.shortcuts},
            {"path", path_to_utf8(entry.path)},
        });
    }
    return items;
}

std::vector<SearchResult> build_manifest_index(const std::vector<BucketSignature>& signatures) {
    std::vector<SearchResult> entries;
    for (const auto& bucket : signatures) {
        const auto manifests = bucket_manifest_search_dir(bucket.path);
        if (!std::filesystem::is_directory(manifests)) {
            continue;
        }

        for (const auto& manifest_entry : std::filesystem::recursive_directory_iterator(manifests)) {
            if (!manifest_entry.is_regular_file() || lower_copy(path_extension_utf8(manifest_entry.path())) != ".json") {
                continue;
            }
            entries.push_back(read_manifest_summary(manifest_entry.path(), bucket.name));
        }
    }

    std::sort(entries.begin(), entries.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.name != rhs.name) {
            return lhs.name < rhs.name;
        }
        return lhs.bucket < rhs.bucket;
    });
    return entries;
}

void write_manifest_index_cache(const Environment& environment, const std::vector<BucketSignature>& signatures, const std::vector<SearchResult>& entries) {
    std::error_code error;
    std::filesystem::create_directories(environment.cache_dir, error);
    if (error) {
        return;
    }

    std::ofstream stream(manifest_index_path(environment), std::ios::binary);
    if (!stream) {
        return;
    }

    nlohmann::json cache;
    cache["version"] = 4;
    cache["buckets"] = signatures_to_json(signatures);
    cache["entries"] = entries_to_json(entries);
    stream << cache.dump(2) << '\n';
}

std::optional<nlohmann::json> read_manifest_index_cache(const Environment& environment) {
    std::ifstream stream(manifest_index_path(environment));
    if (!stream) {
        return std::nullopt;
    }

    nlohmann::json cache;
    try {
        stream >> cache;
    } catch (const nlohmann::json::exception&) {
        return std::nullopt;
    }
    return cache;
}

std::optional<std::filesystem::path> find_known_buckets_file(std::filesystem::path start) {
    start = std::filesystem::weakly_canonical(start);
    if (std::filesystem::is_regular_file(start)) {
        start = start.parent_path();
    }

    for (auto current = start; !current.empty(); current = current.parent_path()) {
        for (const auto& candidate : {current / "buckets.json", current / "ref" / "buckets.json"}) {
            if (std::filesystem::is_regular_file(candidate)) {
                return candidate;
            }
        }

        if (current == current.root_path()) {
            break;
        }
    }

    return std::nullopt;
}

void validate_bucket_name(const std::string& name) {
    if (name.empty() || name.find_first_of("/\\") != std::string::npos) {
        throw std::runtime_error("invalid bucket name: " + name);
    }
}

std::string quote_command_arg(const std::filesystem::path& path) {
    auto value = path.string();
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

std::string quote_command_arg(const std::string& value) {
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

std::string trim_repository_value(std::string value) {
    while (!value.empty() && (value.back() == '\n' || value.back() == '\r' || value.back() == ' ' || value.back() == '\t')) {
        value.pop_back();
    }
    std::size_t first = 0;
    while (first < value.size() && (value[first] == ' ' || value[first] == '\t')) {
        ++first;
    }
    if (first > 0) {
        value.erase(0, first);
    }
    return value;
}

std::string lower_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

void strip_trailing_repository_separators(std::string& value) {
    while (value.size() > 1 && (value.back() == '/' || value.back() == '\\')) {
        if (value.size() == 3 && std::isalpha(static_cast<unsigned char>(value[0])) && value[1] == ':') {
            break;
        }
        value.pop_back();
    }
}

std::optional<std::filesystem::path> file_uri_path(const std::string& repository) {
    const auto lower = lower_copy(repository);
    if (!lower.starts_with("file://")) {
        return std::nullopt;
    }

    std::string path;
    if (lower.starts_with("file:///")) {
        path = repository.substr(8);
    } else {
        path = "//" + repository.substr(7);
    }

    if (path.size() > 2 && path[0] == '/' && std::isalpha(static_cast<unsigned char>(path[1])) && path[2] == ':') {
        path.erase(0, 1);
    }
    return std::filesystem::path(path);
}

std::string canonical_repository_path_key(const std::filesystem::path& path) {
    std::error_code error;
    auto canonical = std::filesystem::weakly_canonical(path, error);
    if (error) {
        canonical = std::filesystem::absolute(path, error);
    }

    auto value = error ? path.generic_string() : canonical.generic_string();
    strip_trailing_repository_separators(value);
#ifdef _WIN32
    value = lower_copy(std::move(value));
#endif
    return "path:" + value;
}

std::optional<std::string> repository_path_identity(const std::string& repository) {
    if (const auto path = file_uri_path(repository)) {
        return canonical_repository_path_key(*path);
    }

    const auto path = std::filesystem::path(repository);
    std::error_code error;
    if (std::filesystem::exists(path, error) || path.is_absolute()) {
        return canonical_repository_path_key(path);
    }
    return std::nullopt;
}

std::string strip_git_suffix(std::string repository) {
    if (repository.ends_with('/')) {
        repository.pop_back();
    }
    if (repository.ends_with(".git")) {
        repository.erase(repository.size() - 4);
    }
    return repository;
}

std::optional<std::string> repository_url_identity(const std::string& repository) {
    static const std::regex pattern(
        R"((?:@|/{1,3})(?:www\.|.*@)?([^/:]+)(?::\d+)?[:/](.+)/([^/]+?)/?$)",
        std::regex_constants::icase);

    std::smatch match;
    if (!std::regex_search(repository, match, pattern)) {
        return std::nullopt;
    }

    auto provider = lower_copy(match[1].str());
    auto owner = lower_copy(match[2].str());
    auto repo = lower_copy(strip_git_suffix(match[3].str()));
    strip_trailing_repository_separators(owner);
    strip_trailing_repository_separators(repo);
    if (provider.empty() || owner.empty() || repo.empty()) {
        return std::nullopt;
    }
    return "url:" + provider + "/" + owner + "/" + repo;
}

std::optional<std::string> repository_identity(const std::string& repository) {
    auto value = trim_repository_value(repository);
    if (value.empty()) {
        return std::nullopt;
    }

    if (const auto path = repository_path_identity(value)) {
        return path;
    }
    if (const auto url = repository_url_identity(value)) {
        return url;
    }

    strip_trailing_repository_separators(value);
    value = lower_copy(strip_git_suffix(std::move(value)));
    return value.empty() ? std::nullopt : std::optional<std::string>{"raw:" + value};
}

std::optional<LocalBucket> find_existing_git_bucket_for_repository(const Environment& environment, const std::string& repository) {
    const auto target = repository_identity(repository);
    if (!target) {
        return std::nullopt;
    }

    for (const auto& bucket : list_local_buckets(environment)) {
        if (!std::filesystem::is_directory(bucket.path / ".git")) {
            continue;
        }

        const auto existing = repository_identity(bucket.source);
        if (existing && *existing == *target) {
            return bucket;
        }
    }
    return std::nullopt;
}

std::optional<std::pair<std::string, std::string>> github_owner_repo(const std::string& repository) {
    const auto normalized = strip_git_suffix(repository);
    static const std::regex pattern(R"(^https?://github\.com/([^/]+)/([^/#?]+)$)", std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_match(normalized, match, pattern)) {
        return std::nullopt;
    }
    return std::make_pair(match[1].str(), match[2].str());
}

std::string github_tree_api_url(const std::string& repository) {
    if (repository.find("/git/trees/") != std::string::npos) {
        return repository;
    }

    const auto parsed = github_owner_repo(repository);
    if (!parsed) {
        return {};
    }
    return "https://api.github.com/repos/" + parsed->first + "/" + parsed->second + "/git/trees/HEAD?recursive=1";
}

std::vector<std::pair<std::string, std::string>> github_request_headers(const Environment& environment) {
    std::vector<std::pair<std::string, std::string>> headers{{"User-Agent", "sco"}};
    if (const char* token = std::getenv("SCOOP_GH_TOKEN"); token != nullptr && token[0] != '\0') {
        headers.emplace_back("Authorization", std::string("token ") + token);
        return headers;
    }

    const ConfigStore config(environment.config_file);
    const auto configured = config.get("gh_token");
    if (configured && configured->is_string() && !configured->get<std::string>().empty()) {
        headers.emplace_back("Authorization", "token " + configured->get<std::string>());
    }
    return headers;
}

std::vector<SearchResult> search_remote_known_bucket(
    const Environment& environment,
    const KnownBucket& bucket,
    const QueryMatcher& matcher) {
    std::vector<SearchResult> results;
    const auto api_url = github_tree_api_url(bucket.repository);
    if (api_url.empty()) {
        return results;
    }

    const HttpClient client;
    const auto response = client.get(api_url, github_request_headers(environment));
    if (response.status < 200 || response.status >= 300) {
        return results;
    }

    nlohmann::json root;
    try {
        root = nlohmann::json::parse(response.body);
    } catch (const nlohmann::json::exception&) {
        return results;
    }
    if (!root.is_object() || !root.contains("tree") || !root.at("tree").is_array()) {
        return results;
    }

    std::unordered_set<std::string> seen;
    for (const auto& item : root.at("tree")) {
        if (!item.is_object()) {
            continue;
        }
        const auto path = optional_string(item, "path");
        const auto comparable_path = lower_copy(path);
        if (!comparable_path.starts_with("bucket/") || !comparable_path.ends_with(".json")) {
            continue;
        }

        auto name = path_stem_utf8(path_from_utf8(path));
        if (!matcher.matches(name) || !seen.insert(name).second) {
            continue;
        }
        results.push_back(SearchResult{.bucket = bucket.name, .name = std::move(name)});
    }

    std::sort(results.begin(), results.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.name < rhs.name;
    });
    return results;
}

std::string current_git_branch(const std::filesystem::path& repository) {
    const auto command = "git -C " + quote_command_arg(repository) + " branch --show-current";
    std::array<char, 256> buffer{};
    std::string output;

    FILE* pipe = _popen(command.c_str(), "r");
    if (pipe == nullptr) {
        return {};
    }

    while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
        output += buffer.data();
    }
    _pclose(pipe);

    while (!output.empty() && (output.back() == '\n' || output.back() == '\r' || output.back() == ' ' || output.back() == '\t')) {
        output.pop_back();
    }
    return output;
}

std::string run_git_capture(const std::filesystem::path& repository, const std::string& arguments) {
    const auto command = "git -C " + quote_command_arg(repository) + " " + arguments + " 2>NUL";
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

bool git_remote_exists(const std::string& repository) {
    const auto command = "git ls-remote " + quote_command_arg(repository) + " >NUL 2>NUL";
    return std::system(command.c_str()) == 0;
}

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

std::string local_bucket_source(const std::filesystem::path& bucket_root) {
    if (std::filesystem::is_directory(bucket_root / ".git")) {
        const auto remote = run_git_capture(bucket_root, "config --get remote.origin.url");
        if (!remote.empty()) {
            return remote;
        }
    }
    return std::filesystem::absolute(bucket_root).generic_string();
}

std::string local_bucket_updated(const std::filesystem::path& bucket_root) {
    if (std::filesystem::is_directory(bucket_root / ".git")) {
        const auto commit_time = run_git_capture(bucket_root, "log -1 --format=%aI");
        if (!commit_time.empty()) {
            return commit_time;
        }
    }

    std::error_code error;
    const auto bucket_dir = bucket_root / "bucket";
    if (!std::filesystem::exists(bucket_dir, error)) {
        return {};
    }
    const auto updated = std::filesystem::last_write_time(bucket_dir, error);
    return error ? std::string{} : local_timestamp(updated);
}

std::size_t count_bucket_manifests(const std::filesystem::path& manifests) {
    std::size_t count = 0;
    if (!std::filesystem::is_directory(manifests)) {
        return count;
    }
    for (const auto& entry : std::filesystem::recursive_directory_iterator(manifests)) {
        (void)entry;
        ++count;
    }
    return count;
}

} // namespace

bool git_available() {
    return std::system("git --version >NUL 2>NUL") == 0;
}

std::vector<KnownBucket> list_known_buckets(const std::filesystem::path& start) {
    std::vector<KnownBucket> buckets;
    const auto path = find_known_buckets_file(start);
    if (!path) {
        return buckets;
    }

    std::ifstream stream(*path);
    if (!stream) {
        return buckets;
    }

    nlohmann::ordered_json value;
    try {
        stream >> value;
    } catch (const nlohmann::json::exception&) {
        return buckets;
    }

    if (!value.is_object()) {
        return buckets;
    }

    for (const auto& item : value.items()) {
        if (!item.value().is_string()) {
            continue;
        }
        buckets.push_back(KnownBucket{.name = item.key(), .repository = item.value().get<std::string>()});
    }
    return buckets;
}

std::vector<LocalBucket> list_local_buckets(const Environment& environment) {
    std::vector<LocalBucket> buckets;
    const auto buckets_root = environment.buckets_dir();
    if (!std::filesystem::is_directory(buckets_root)) {
        return buckets;
    }

    for (const auto& bucket_entry : std::filesystem::directory_iterator(buckets_root)) {
        if (!bucket_entry.is_directory()) {
            continue;
        }

        const auto manifests = bucket_entry.path() / "bucket";
        buckets.push_back(LocalBucket{
            .name = path_to_utf8(bucket_entry.path().filename()),
            .path = bucket_entry.path(),
            .source = local_bucket_source(bucket_entry.path()),
            .updated = local_bucket_updated(bucket_entry.path()),
            .manifests = count_bucket_manifests(manifests),
        });
    }

    std::sort(buckets.begin(), buckets.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.name < rhs.name;
    });

    const auto known = list_known_buckets(environment.root_dir);
    if (!known.empty()) {
        std::vector<LocalBucket> ordered;
        ordered.reserve(buckets.size());
        for (const auto& known_bucket : known) {
            const auto found = std::find_if(buckets.begin(), buckets.end(), [&](const auto& bucket) {
                return bucket.name == known_bucket.name;
            });
            if (found != buckets.end()) {
                ordered.push_back(*found);
            }
        }

        for (const auto& bucket : buckets) {
            const auto already_added = std::find_if(ordered.begin(), ordered.end(), [&](const auto& existing) {
                return existing.name == bucket.name;
            });
            if (already_added == ordered.end()) {
                ordered.push_back(bucket);
            }
        }
        return ordered;
    }

    return buckets;
}

BucketChangeResult add_local_bucket(const Environment& environment, const std::string& name, const std::filesystem::path& source) {
    validate_bucket_name(name);

    const auto source_root = std::filesystem::weakly_canonical(source);
    const auto source_bucket = source_root / "bucket";
    if (!std::filesystem::is_directory(source_bucket)) {
        throw std::runtime_error("bucket source must contain a bucket directory: " + source_root.string());
    }

    const auto destination = environment.buckets_dir() / name;
    if (std::filesystem::exists(destination)) {
        return BucketChangeResult{.name = name, .path = destination, .changed = false, .reason = BucketChangeReason::NameAlreadyExists};
    }

    std::filesystem::create_directories(environment.buckets_dir());
    try {
        std::filesystem::create_directory_symlink(source_root, destination);
    } catch (const std::filesystem::filesystem_error&) {
        std::filesystem::copy(source_root, destination, std::filesystem::copy_options::recursive);
    }

    return BucketChangeResult{.name = name, .path = destination, .changed = true};
}

BucketChangeResult add_git_bucket(const Environment& environment, const std::string& name, const std::string& repository) {
    validate_bucket_name(name);
    if (repository.empty()) {
        throw std::runtime_error("bucket repository is empty");
    }

    const auto destination = environment.buckets_dir() / name;
    if (std::filesystem::exists(destination)) {
        return BucketChangeResult{.name = name, .path = destination, .changed = false, .reason = BucketChangeReason::NameAlreadyExists};
    }

    if (const auto existing = find_existing_git_bucket_for_repository(environment, repository)) {
        return BucketChangeResult{
            .name = existing->name,
            .path = existing->path,
            .changed = false,
            .reason = BucketChangeReason::RepositoryAlreadyExists,
        };
    }

    if (!git_remote_exists(repository)) {
        throw std::runtime_error("'" + repository + "' doesn't look like a valid git repository");
    }

    std::filesystem::create_directories(environment.buckets_dir());
    const auto command = "git clone --depth 1 " + quote_command_arg(repository) + " " + quote_command_arg(destination);
    const int exit_code = std::system(command.c_str());
    if (exit_code != 0) {
        if (std::filesystem::exists(destination)) {
            std::filesystem::remove_all(destination);
        }
        throw std::runtime_error("git clone failed for bucket " + name);
    }

    if (!std::filesystem::is_directory(destination / "bucket")) {
        std::filesystem::remove_all(destination);
        throw std::runtime_error("cloned bucket does not contain a bucket directory: " + destination.string());
    }

    return BucketChangeResult{.name = name, .path = destination, .changed = true};
}

BucketChangeResult add_bucket_from_zip(const Environment& environment, const std::string& name, const std::string& repository) {
    validate_bucket_name(name);
    const auto destination = environment.buckets_dir() / name;
    if (std::filesystem::exists(destination)) {
        return BucketChangeResult{.name = name, .path = destination, .changed = false, .reason = BucketChangeReason::NameAlreadyExists};
    }

    const auto zip_url = repository + "/archive/refs/heads/master.zip";
    const auto zip_path = environment.cache_dir / (name + "-bucket.zip");
    const auto extract_dir = environment.cache_dir / (name + "-bucket-extract");
    std::filesystem::create_directories(environment.cache_dir);
    if (std::filesystem::exists(extract_dir)) {
        std::filesystem::remove_all(extract_dir);
    }

    const auto repo_name = std::filesystem::path(repository).filename().string();
    const auto extract_bucket = extract_dir / (repo_name + "-master");

    const auto download_cmd =
        "powershell -NoProfile -Command \""
        "Invoke-WebRequest -Uri '" + zip_url + "' -OutFile '" + zip_path.string() + "'"
        "; Expand-Archive -LiteralPath '" + zip_path.string() + "' -DestinationPath '" + extract_dir.string() + "' -Force"
        "\"";
    if (std::system(download_cmd.c_str()) != 0) {
        throw std::runtime_error("failed to download or extract bucket '" + name + "' from " + zip_url);
    }

    if (!std::filesystem::is_directory(extract_bucket / "bucket")) {
        if (std::filesystem::exists(extract_dir)) {
            std::filesystem::remove_all(extract_dir);
        }
        throw std::runtime_error("downloaded bucket '" + name + "' does not contain a bucket directory");
    }

    std::filesystem::create_directories(environment.buckets_dir());
    std::filesystem::rename(extract_bucket, destination);

    if (std::filesystem::exists(extract_dir)) {
        std::filesystem::remove_all(extract_dir);
    }

    return BucketChangeResult{.name = name, .path = destination, .changed = true};
}

BucketChangeResult remove_bucket(const Environment& environment, const std::string& name) {
    validate_bucket_name(name);

    const auto path = environment.buckets_dir() / name;
    if (!std::filesystem::exists(path)) {
        return BucketChangeResult{.name = name, .path = path, .changed = false};
    }

    std::filesystem::remove_all(path);
    return BucketChangeResult{.name = name, .path = path, .changed = true};
}

std::vector<BucketUpdateResult> update_buckets(const Environment& environment, const std::string& name) {
    std::vector<BucketUpdateResult> results;
    for (const auto& bucket : list_local_buckets(environment)) {
        if (!name.empty() && bucket.name != name) {
            continue;
        }

        const auto git_dir = bucket.path / ".git";
        if (!std::filesystem::exists(git_dir)) {
            results.push_back(BucketUpdateResult{
                .name = bucket.name,
                .path = bucket.path,
                .updated = false,
                .message = "not a git bucket",
            });
            continue;
        }

        const auto previous_head = run_git_capture(bucket.path, "rev-parse HEAD");
        const auto branch = current_git_branch(bucket.path);
        const auto command = branch.empty()
            ? "git -C " + quote_command_arg(bucket.path) + " pull --ff-only"
            : "git -C " + quote_command_arg(bucket.path) + " pull --ff-only origin " + quote_command_arg(branch);
        const int exit_code = std::system(command.c_str());
        const auto current_head = exit_code == 0 ? run_git_capture(bucket.path, "rev-parse HEAD") : std::string{};
        results.push_back(BucketUpdateResult{
            .name = bucket.name,
            .path = bucket.path,
            .updated = exit_code == 0,
            .changed = exit_code == 0 && !previous_head.empty() && previous_head != current_head,
            .message = exit_code == 0 ? std::string{} : std::string{"git pull failed"},
        });
    }

    if (!name.empty() && results.empty()) {
        results.push_back(BucketUpdateResult{
            .name = name,
            .path = environment.buckets_dir() / name,
            .updated = false,
            .message = "bucket not found",
        });
    }

    return results;
}

std::optional<std::filesystem::path> find_manifest_in_buckets(const Environment& environment, const std::string& app) {
    auto bucket_name = std::string{};
    auto app_name = app;
    if (const auto slash = app.find_first_of("/\\"); slash != std::string::npos) {
        bucket_name = app.substr(0, slash);
        app_name = app.substr(slash + 1);
    }

    if (app_name.empty() || app_name.find_first_of("/\\") != std::string::npos) {
        return std::nullopt;
    }

    const auto requested_bucket = lower_copy(bucket_name);
    const auto requested_app = lower_copy(app_name);

    const auto buckets_root = environment.buckets_dir();
    if (!std::filesystem::is_directory(buckets_root)) {
        return std::nullopt;
    }

    std::vector<std::filesystem::path> direct_buckets;
    std::vector<std::filesystem::path> all_buckets;
    for (const auto& bucket_entry : std::filesystem::directory_iterator(buckets_root)) {
        if (!bucket_entry.is_directory()) {
            continue;
        }
        all_buckets.push_back(bucket_entry.path());
        if (bucket_name.empty() || lower_copy(path_to_utf8(bucket_entry.path().filename())) == requested_bucket) {
            direct_buckets.push_back(bucket_entry.path());
        }
    }
    std::sort(direct_buckets.begin(), direct_buckets.end());
    std::sort(all_buckets.begin(), all_buckets.end());

    for (const auto& bucket_path : direct_buckets) {
        for (const auto& candidate : {
                 bucket_path / "bucket" / (app_name + ".json"),
                 bucket_path / (app_name + ".json"),
             }) {
            std::error_code error;
            if (std::filesystem::is_regular_file(candidate, error)) {
                return std::filesystem::weakly_canonical(candidate);
            }
        }
    }

    static std::unordered_map<std::string, std::unordered_map<std::string, std::filesystem::path>> process_cache;
    const auto cache_key = buckets_root.generic_string();
    auto [cache_it, inserted] = process_cache.try_emplace(cache_key);
    if (inserted) {
        for (const auto& bucket_path : all_buckets) {
            const auto current_bucket = lower_copy(path_to_utf8(bucket_path.filename()));
            const auto manifests = bucket_manifest_search_dir(bucket_path);
            if (!std::filesystem::is_directory(manifests)) {
                continue;
            }

            std::error_code iterator_error;
            auto it = std::filesystem::recursive_directory_iterator(
                manifests,
                std::filesystem::directory_options::skip_permission_denied,
                iterator_error);
            const auto end = std::filesystem::recursive_directory_iterator();
            while (!iterator_error && it != end) {
                std::error_code entry_error;
                if (it->is_regular_file(entry_error) && lower_copy(path_extension_utf8(it->path())) == ".json") {
                    const auto name = lower_copy(path_stem_utf8(it->path()));
                    cache_it->second.try_emplace(name, it->path());
                    cache_it->second.try_emplace(current_bucket + "/" + name, it->path());
                }
                it.increment(iterator_error);
            }
        }
    }

    const auto lookup = bucket_name.empty() ? requested_app : requested_bucket + "/" + requested_app;
    if (const auto match = cache_it->second.find(lookup); match != cache_it->second.end()) {
        return std::filesystem::weakly_canonical(match->second);
    }
    return std::nullopt;
}

std::vector<std::string> find_manifest_bucket_names(const Environment& environment, const std::string& app) {
    auto bucket_name = std::string{};
    auto app_name = app;
    if (const auto slash = app.find_first_of("/\\"); slash != std::string::npos) {
        bucket_name = app.substr(0, slash);
        app_name = app.substr(slash + 1);
    }

    if (app_name.empty()) {
        return {};
    }

    const auto requested_bucket = lower_copy(bucket_name);
    const auto requested_app = lower_copy(app_name);
    const auto buckets_root = environment.buckets_dir();
    if (!std::filesystem::is_directory(buckets_root)) {
        return {};
    }

    std::vector<std::string> result;
    for (const auto& bucket_entry : std::filesystem::directory_iterator(buckets_root)) {
        if (!bucket_entry.is_directory()) {
            continue;
        }
        const auto current_bucket = lower_copy(path_to_utf8(bucket_entry.path().filename()));
        if (!requested_bucket.empty() && current_bucket != requested_bucket) {
            continue;
        }
        for (const auto& candidate : {
                 bucket_entry.path() / "bucket" / (app_name + ".json"),
                 bucket_entry.path() / (app_name + ".json"),
             }) {
            std::error_code error;
            if (std::filesystem::is_regular_file(candidate, error)) {
                result.push_back(path_to_utf8(bucket_entry.path().filename()));
                break;
            }
        }
    }
    return result;
}

std::vector<SearchResult> list_bucket_manifest_index(const Environment& environment) {
    const auto signatures = bucket_signatures(environment);
    if (const auto cache = read_manifest_index_cache(environment); cache && cache_signatures_match(*cache, signatures)) {
        return entries_from_cache(*cache);
    }

    auto entries = build_manifest_index(signatures);
    write_manifest_index_cache(environment, signatures, entries);
    return entries;
}

std::vector<SearchResult> search_bucket_manifests(const Environment& environment, const std::string& query, bool sqlite_cache_mode) {
    std::vector<SearchResult> results;
    const QueryMatcher matcher(query, sqlite_cache_mode ? QueryMatchMode::SqliteLike : QueryMatchMode::Regex);
    for (const auto& entry : list_bucket_manifest_index(environment)) {
        const auto app_matches = matcher.matches(entry.name);
        const auto matched_bins = query.empty() || app_matches
            ? std::vector<std::string>{}
            : (sqlite_cache_mode ? collect_matching_values(entry.bins, matcher) : collect_matching_search_bins(entry.path, matcher));
        const auto matched_shortcuts = sqlite_cache_mode && !query.empty() && !app_matches ? collect_matching_values(entry.shortcuts, matcher) : std::vector<std::string>{};
        if (app_matches || !matched_bins.empty() || !matched_shortcuts.empty()) {
            auto result = entry;
            result.bins = sqlite_cache_mode ? entry.bins : matched_bins;
            result.shortcuts = {};
            results.push_back(std::move(result));
        }
    }

    std::sort(results.begin(), results.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.name != rhs.name) {
            return lhs.name < rhs.name;
        }
        return lhs.bucket < rhs.bucket;
    });
    return results;
}

std::vector<SearchResult> search_known_bucket_manifests(const Environment& environment, const std::string& query) {
    std::vector<SearchResult> results;
    const QueryMatcher matcher(query);
    const auto local_buckets = list_local_buckets(environment);
    std::unordered_set<std::string> local_names;
    for (const auto& bucket : local_buckets) {
        local_names.insert(lower_copy(bucket.name));
    }

    for (const auto& bucket : list_known_buckets(environment.root_dir)) {
        if (local_names.contains(lower_copy(bucket.name))) {
            continue;
        }
        auto bucket_results = search_remote_known_bucket(environment, bucket, matcher);
        results.insert(results.end(), std::make_move_iterator(bucket_results.begin()), std::make_move_iterator(bucket_results.end()));
    }

    std::sort(results.begin(), results.end(), [](const auto& lhs, const auto& rhs) {
        if (lhs.name != rhs.name) {
            return lhs.name < rhs.name;
        }
        return lhs.bucket < rhs.bucket;
    });
    return results;
}

} // namespace sco
