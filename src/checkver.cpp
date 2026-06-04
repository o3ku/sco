#include "sco/checkver.hpp"

#include "sco/compression.hpp"
#include "sco/config.hpp"
#include "sco/environment.hpp"
#include "sco/http_client.hpp"
#include "sco/xml.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <vector>

#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace sco {

namespace {

std::string lowercase_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

const nlohmann::json* json_property(const nlohmann::json& object, const char* key) {
    if (!object.is_object()) {
        return nullptr;
    }

    if (const auto exact = object.find(key); exact != object.end()) {
        return &*exact;
    }

    const auto normalized = lowercase_ascii(key);
    for (auto it = object.begin(); it != object.end(); ++it) {
        if (lowercase_ascii(it.key()) == normalized) {
            return &*it;
        }
    }
    return nullptr;
}

std::optional<std::string> optional_string(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value != nullptr && value->is_string()) {
        return value->get<std::string>();
    }
    return std::nullopt;
}

bool optional_bool(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value == nullptr) {
        return false;
    }
    if (value->is_boolean()) {
        return value->get<bool>();
    }
    if (value->is_string()) {
        return lowercase_ascii(value->get<std::string>()) == "true";
    }
    return false;
}

bool powershell_truthy(const nlohmann::json& value) {
    if (value.is_null()) {
        return false;
    }
    if (value.is_boolean()) {
        return value.get<bool>();
    }
    if (value.is_number_integer()) {
        return value.get<long long>() != 0;
    }
    if (value.is_number_unsigned()) {
        return value.get<unsigned long long>() != 0;
    }
    if (value.is_number_float()) {
        return value.get<double>() != 0.0;
    }
    if (value.is_string()) {
        return !value.get<std::string>().empty();
    }
    if (value.is_array()) {
        return !value.empty();
    }
    return true;
}

std::vector<std::string> optional_string_array(const nlohmann::json& object, const char* key) {
    std::vector<std::string> values;
    const auto* value = json_property(object, key);
    if (value == nullptr || value->is_null()) {
        return values;
    }

    if (value->is_string()) {
        values.push_back(value->get<std::string>());
        return values;
    }
    if (value->is_array()) {
        for (const auto& item : *value) {
            if (item.is_string()) {
                values.push_back(item.get<std::string>());
            }
        }
    }
    return values;
}

std::string first_non_empty(std::initializer_list<std::optional<std::string>> values) {
    for (const auto& value : values) {
        if (value && !value->empty()) {
            return *value;
        }
    }
    return {};
}

std::string trim_trailing_slashes(std::string value) {
    while (!value.empty() && value.back() == '/') {
        value.pop_back();
    }
    return value;
}

bool is_github_homepage(const std::string& value) {
    return lowercase_ascii(value).rfind("https://github.com/", 0) == 0;
}

std::optional<std::string> github_latest_release_api_url(const std::string& value) {
    static const std::regex pattern(R"(^https://(?:www\.)?github\.com/([^/]+)/([^/#?]+)/releases/latest$)", std::regex_constants::icase);
    std::smatch match;
    if (!std::regex_match(value, match, pattern)) {
        return std::nullopt;
    }
    return "https://api.github.com/repos/" + match[1].str() + "/" + match[2].str() + "/releases/latest";
}

bool looks_like_http_url(const std::string& value) {
    const auto lower = lowercase_ascii(value);
    return lower.rfind("http://", 0) == 0 || lower.rfind("https://", 0) == 0;
}

void set_request_header(std::vector<std::pair<std::string, std::string>>& headers, std::string name, std::string value) {
    const auto normalized = lowercase_ascii(name);
    for (auto& header : headers) {
        if (lowercase_ascii(header.first) == normalized) {
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

std::string trim_slashes(std::string value) {
    while (!value.empty() && value.front() == '/') {
        value.erase(value.begin());
    }
    while (!value.empty() && value.back() == '/') {
        value.pop_back();
    }
    return value;
}

std::string strip_url_fragment(std::string url) {
    if (const auto fragment = url.find('#'); fragment != std::string::npos) {
        url.erase(fragment);
    }
    return url;
}

std::string strip_url_filename(const std::string& url) {
    const auto clean = strip_url_fragment(url);
    const auto slash = clean.find_last_of('/');
    return slash == std::string::npos ? std::string{} : clean.substr(0, slash);
}

std::string quote_process_argument(const std::filesystem::path& path) {
    std::string quoted = "\"";
    for (const auto ch : path.string()) {
        if (ch == '"') {
            quoted += "\\\"";
        } else {
            quoted.push_back(ch);
        }
    }
    quoted += '"';
    return quoted;
}

std::string unique_checkver_script_path() {
    auto temp_dir = std::filesystem::temp_directory_path();
#ifdef _WIN32
    char buffer[MAX_PATH]{};
    if (GetTempFileNameA(temp_dir.string().c_str(), "sco", 0, buffer) != 0) {
        auto path = std::filesystem::path(buffer);
        std::filesystem::remove(path);
        path.replace_extension(".ps1");
        return path.string();
    }
#endif
    return (temp_dir / ("sco-checkver-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".ps1")).string();
}

std::string run_checkver_script(const std::vector<std::string>& lines) {
    if (lines.empty()) {
        return {};
    }

    const auto script_path = std::filesystem::path(unique_checkver_script_path());
    {
        std::ofstream stream(script_path, std::ios::binary);
        if (!stream) {
            throw std::runtime_error("cannot write checkver script " + script_path.string());
        }
        stream << "$ErrorActionPreference = 'Stop'\r\n";
        for (const auto& line : lines) {
            stream << line << "\r\n";
        }
    }

    const auto command = "powershell -NoProfile -ExecutionPolicy Bypass -File " + quote_process_argument(script_path) + " 2>NUL";
    std::array<char, 512> buffer{};
    std::string output;
    FILE* pipe = _popen(command.c_str(), "r");
    if (pipe == nullptr) {
        std::filesystem::remove(script_path);
        throw std::runtime_error("cannot run checkver script");
    }
    while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
        output += buffer.data();
    }
    const auto status = _pclose(pipe);
    std::filesystem::remove(script_path);
    if (status != 0) {
        throw std::runtime_error("checkver script failed");
    }
    return output;
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
    return {};
}

std::string substitute_version_tokens(std::string value, const std::string& version) {
    for (const auto& key : {
             "$underscoreVersion", "$majorVersion", "$minorVersion", "$patchVersion", "$buildVersion",
             "$preReleaseVersion", "$cleanVersion", "$dashVersion", "$dotVersion", "$version"}) {
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

std::string read_text_source(
    const std::string& source,
    const std::filesystem::path& base_dir,
    const std::vector<std::pair<std::string, std::string>>& headers) {
    if (looks_like_http_url(source)) {
        const HttpClient client;
        const auto response = client.get(source, headers);
        if (response.status < 200 || response.status >= 300) {
            throw std::runtime_error("checkver request failed for " + source + ": " + (response.error.empty() ? std::to_string(response.status) : response.error));
        }
        return decompress_gzip_if_needed(response.body);
    }

    auto path = std::filesystem::path(source);
    if (path.is_relative()) {
        path = base_dir / path;
    }

    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("checkver source does not exist: " + path.string());
    }
    const std::string data{std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    return decompress_gzip_if_needed(data);
}

struct PreparedRegex {
    std::string pattern;
    std::optional<std::size_t> version_group;
    std::map<std::string, std::size_t> named_groups;
};

PreparedRegex prepare_dotnet_regex_groups(const std::string& pattern) {
    PreparedRegex prepared{.pattern = {}, .version_group = std::nullopt, .named_groups = {}};
    prepared.pattern.reserve(pattern.size());

    bool escaped = false;
    bool in_class = false;
    std::size_t capture_index = 0;
    for (std::size_t i = 0; i < pattern.size(); ++i) {
        const auto ch = pattern[i];
        if (escaped) {
            prepared.pattern.push_back(ch);
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            prepared.pattern.push_back(ch);
            escaped = true;
            continue;
        }
        if (ch == '[') {
            in_class = true;
            prepared.pattern.push_back(ch);
            continue;
        }
        if (ch == ']') {
            in_class = false;
            prepared.pattern.push_back(ch);
            continue;
        }

        if (!in_class && ch == '(') {
            if (i + 3 < pattern.size() && pattern[i + 1] == '?' && pattern[i + 2] == '<'
                && pattern[i + 3] != '=' && pattern[i + 3] != '!') {
                const auto name_end = pattern.find('>', i + 3);
                if (name_end != std::string::npos) {
                    capture_index += 1;
                    const auto name = lowercase_ascii(pattern.substr(i + 3, name_end - i - 3));
                    prepared.named_groups[name] = capture_index;
                    if (name == "version") {
                        prepared.version_group = capture_index;
                    }
                    prepared.pattern.push_back('(');
                    i = name_end;
                    continue;
                }
            } else if (i + 1 >= pattern.size() || pattern[i + 1] != '?') {
                capture_index += 1;
            }
        }
        prepared.pattern.push_back(ch);
    }
    return prepared;
}

std::string dotnet_named_replacement_to_ecmascript(std::string replacement, const std::map<std::string, std::size_t>& groups) {
    for (const auto& [name, index] : groups) {
        const auto token = "${" + name + "}";
        const auto numbered = "$" + std::to_string(index);
        std::size_t pos = 0;
        while ((pos = replacement.find(token, pos)) != std::string::npos) {
            replacement.replace(pos, token.size(), numbered);
            pos += numbered.size();
        }
    }
    return replacement;
}

std::optional<std::string> regex_version(const std::string& text, const std::string& pattern_text, bool reverse, const std::string& replace) {
    const auto prepared = prepare_dotnet_regex_groups(pattern_text.empty()
        ? std::string{R"((?:v|version[-_])?([0-9]+(?:[._-][0-9A-Za-z]+)+))"}
        : pattern_text);
    const auto pattern = std::regex(prepared.pattern, std::regex_constants::icase);

    std::vector<std::smatch> matches;
    for (auto it = std::sregex_iterator(text.begin(), text.end(), pattern); it != std::sregex_iterator(); ++it) {
        matches.push_back(*it);
    }
    if (matches.empty()) {
        return std::nullopt;
    }
    const auto& match = reverse ? matches.back() : matches.front();
    if (!replace.empty()) {
        return std::regex_replace(
            match[0].str(),
            pattern,
            dotnet_named_replacement_to_ecmascript(replace, prepared.named_groups),
            std::regex_constants::format_first_only);
    }
    if (match.size() > 1 && !match[1].str().empty()) {
        return match[1].str();
    }
    if (prepared.version_group && *prepared.version_group < match.size() && !match[*prepared.version_group].str().empty()) {
        return match[*prepared.version_group].str();
    }
    return match.size() > 1 ? match[1].str() : match[0].str();
}

std::optional<std::string> json_scalar_value(const nlohmann::json& value) {
    if (value.is_string()) {
        return value.get<std::string>();
    }
    if (value.is_number_integer()) {
        return std::to_string(value.get<long long>());
    }
    if (value.is_number_float()) {
        std::ostringstream out;
        out << value.get<double>();
        return out.str();
    }
    return std::nullopt;
}

void collect_json_field_values(const nlohmann::json& value, const std::string& field, std::vector<std::string>& values) {
    if (value.is_object()) {
        if (value.contains(field)) {
            if (const auto scalar = json_scalar_value(value.at(field))) {
                values.push_back(*scalar);
            }
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

std::optional<std::string> json_filter_value(const nlohmann::json& root, const std::string& path, bool reverse) {
    static const std::regex filter_pattern(R"(^\$\.([A-Za-z0-9_]+)\[\?\(@\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'\)\]\.([A-Za-z0-9_]+)$)");
    std::smatch match;
    if (!std::regex_match(path, match, filter_pattern)) {
        return std::nullopt;
    }

    const auto array_field = match[1].str();
    const auto filter_field = match[2].str();
    const auto filter_value = match[3].str();
    const auto result_field = match[4].str();
    if (!root.is_object() || !root.contains(array_field) || !root.at(array_field).is_array()) {
        return std::nullopt;
    }

    std::vector<std::string> values;
    for (const auto& item : root.at(array_field)) {
        if (!item.is_object() || !item.contains(filter_field) || !item.at(filter_field).is_string()) {
            continue;
        }
        if (item.at(filter_field).get<std::string>() == filter_value && item.contains(result_field)) {
            if (const auto value = json_scalar_value(item.at(result_field))) {
                values.push_back(*value);
            }
        }
    }
    if (values.empty()) {
        return std::nullopt;
    }
    return reverse ? values.back() : values.front();
}

void collect_recursive_json_filter_values(
    const nlohmann::json& value,
    const std::string& array_field,
    const std::string& filter_field,
    const std::string& filter_value,
    const std::string& result_field,
    std::vector<std::string>& values) {
    if (value.is_object()) {
        if (value.contains(array_field) && value.at(array_field).is_array()) {
            for (const auto& item : value.at(array_field)) {
                if (!item.is_object() || !item.contains(filter_field) || !item.at(filter_field).is_string()) {
                    continue;
                }
                if (item.at(filter_field).get<std::string>() == filter_value && item.contains(result_field)) {
                    if (const auto scalar = json_scalar_value(item.at(result_field))) {
                        values.push_back(*scalar);
                    }
                }
            }
        }
        for (const auto& item : value.items()) {
            collect_recursive_json_filter_values(item.value(), array_field, filter_field, filter_value, result_field, values);
        }
    } else if (value.is_array()) {
        for (const auto& item : value) {
            collect_recursive_json_filter_values(item, array_field, filter_field, filter_value, result_field, values);
        }
    }
}

std::optional<std::string> json_recursive_filter_value(const nlohmann::json& root, const std::string& path, bool reverse) {
    static const std::regex filter_pattern(R"(^\$\.\.([A-Za-z0-9_]+)\[\?\(@\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'\)\]\.([A-Za-z0-9_]+)$)");
    std::smatch match;
    if (!std::regex_match(path, match, filter_pattern)) {
        return std::nullopt;
    }

    std::vector<std::string> values;
    collect_recursive_json_filter_values(root, match[1].str(), match[2].str(), match[3].str(), match[4].str(), values);
    if (values.empty()) {
        return std::nullopt;
    }
    return reverse ? values.back() : values.front();
}

std::optional<std::string> json_path_value(const nlohmann::json& root, std::string path) {
    if (path.rfind("$.", 0) == 0) {
        path.erase(0, 2);
    } else if (path == "$" && root.is_string()) {
        return root.get<std::string>();
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

    return json_scalar_value(*current);
}

std::optional<std::string> json_path_legacy_value(const nlohmann::json& root, std::string path) {
    if (path.empty()) {
        return std::nullopt;
    }

    const auto is_json_path = path.front() == '$';
    const nlohmann::json* current = &root;
    std::stringstream stream(path);
    std::string segment;
    while (std::getline(stream, segment, '.')) {
        if (segment.empty()) {
            return std::nullopt;
        }
        if (is_json_path && segment == "$") {
            continue;
        }

        std::optional<std::size_t> index;
        if (const auto open = segment.find('['); open != std::string::npos && segment.ends_with(']')) {
            const auto text = segment.substr(open + 1, segment.size() - open - 2);
            segment.erase(open);
            if (!text.empty() && std::all_of(text.begin(), text.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; })) {
                index = static_cast<std::size_t>(std::stoull(text));
            } else {
                return std::nullopt;
            }
        }

        if (!segment.empty()) {
            current = json_property(*current, segment.c_str());
            if (current == nullptr) {
                return std::nullopt;
            }
        }
        if (index) {
            if (!current->is_array() || *index >= current->size()) {
                return std::nullopt;
            }
            current = &current->at(*index);
        }
    }

    return json_scalar_value(*current);
}

std::optional<std::string> json_version(const std::string& text, const std::string& path, bool reverse) {
    if (path.empty()) {
        return std::nullopt;
    }
    const auto root = nlohmann::json::parse(text);
    if (const auto filtered = json_filter_value(root, path, reverse)) {
        return *filtered;
    }
    if (const auto filtered = json_recursive_filter_value(root, path, reverse)) {
        return *filtered;
    }
    if (path.rfind("$..", 0) == 0 && path.find_first_of("[]()?") == std::string::npos) {
        std::vector<std::string> values;
        collect_json_field_values(root, path.substr(3), values);
        if (!values.empty()) {
            return reverse ? values.back() : values.front();
        }
        return std::nullopt;
    }
    if (const auto value = json_path_value(root, path)) {
        return value;
    }
    return json_path_legacy_value(root, path);
}

std::optional<std::string> xpath_version(const std::string& text, const std::string& path) {
    if (path.empty()) {
        return std::nullopt;
    }
    return select_xml_xpath_text(text, path, "checkver XML", "checkver xpath");
}

struct SourceForgeCheckverConfig {
    std::string url;
    std::string regex;
};

std::string sourceforge_version_regex(const std::string& regex) {
    return regex.empty() ? std::string{R"(([0-9]+(?:\.[0-9]+)*))"} : regex;
}

std::string sourceforge_checkver_regex(std::string path, const std::string& regex) {
    path = trim_slashes(std::move(path));
    auto pattern = std::string{R"(CDATA\[/)"};
    if (!path.empty()) {
        pattern += path + "/";
    }
    pattern += ".*?" + sourceforge_version_regex(regex) + R"(.*?\])";
    return pattern;
}

std::string sourceforge_rss_url(const std::string& project, std::string path) {
    auto url = "https://sourceforge.net/projects/" + project + "/rss";
    path = trim_slashes(std::move(path));
    if (!path.empty()) {
        url += "?path=/" + path;
    }
    return url;
}

SourceForgeCheckverConfig sourceforge_config(const std::string& project, const std::string& path, const std::string& regex) {
    return {sourceforge_rss_url(project, path), sourceforge_checkver_regex(path, regex)};
}

SourceForgeCheckverConfig sourceforge_config_from_homepage(const std::string& homepage, const std::string& app, const std::string& regex) {
    static const std::regex project_url(
        R"(//(?:sourceforge|sf)\.net/projects/([^/?#]+)(?:/files/([^/?#]+))?|//([^./?#]+)\.(?:sourceforge\.(?:net|io)|sf\.net))",
        std::regex_constants::icase);

    std::smatch match;
    if (std::regex_search(homepage, match, project_url)) {
        const auto project = match[1].matched ? match[1].str() : match[3].str();
        const auto path = match[2].matched ? match[2].str() : std::string{};
        return sourceforge_config(project, path, regex);
    }
    return sourceforge_config(app, {}, regex);
}

std::optional<SourceForgeCheckverConfig> sourceforge_config_from_value(const nlohmann::json& value, const std::string& app, const std::string& regex) {
    if (value.is_string()) {
        static const std::regex sourceforge_text(R"(^([A-Za-z0-9_-]*)(?:/(.*))?$)");
        std::smatch match;
        const auto text = value.get<std::string>();
        if (!std::regex_match(text, match, sourceforge_text)) {
            return std::nullopt;
        }
        const auto project = match[1].str().empty() ? app : match[1].str();
        const auto path = match[2].matched ? match[2].str() : std::string{};
        return sourceforge_config(project, path, regex);
    }

    if (value.is_object()) {
        const auto project = optional_string(value, "project").value_or(app);
        const auto path = optional_string(value, "path").value_or(std::string{});
        return sourceforge_config(project.empty() ? app : project, path, regex);
    }

    return std::nullopt;
}

} // namespace

std::optional<std::string> resolve_checkver_version(const Environment& environment, const std::filesystem::path& manifest_path) {
    std::ifstream stream(manifest_path);
    if (!stream) {
        throw std::runtime_error("cannot open " + manifest_path.string());
    }

    nlohmann::json manifest;
    stream >> manifest;
    const auto* checkver_value = json_property(manifest, "checkver");
    if (!manifest.is_object() || checkver_value == nullptr || checkver_value->is_null()) {
        return std::nullopt;
    }

    const auto& checkver = *checkver_value;
    std::string source;
    std::string regex;
    std::string jsonpath;
    std::string xpath;
    std::vector<std::string> script_lines;
    std::string replace;
    std::string useragent;
    auto reverse = false;
    auto uses_github_checkver = false;
    auto use_github_api_headers = false;
    static constexpr std::string_view github_default_regex = R"(/releases/tag/(?:v|V)?([\d.]+))";
    const auto app = manifest_path.stem().string();

    if (checkver.is_string()) {
        const auto value = checkver.get<std::string>();
        const auto normalized_value = lowercase_ascii(value);
        if (value.empty()) {
            return std::nullopt;
        }
        source = optional_string(manifest, "homepage").value_or(std::string{});
        if (normalized_value == "github") {
            if (!is_github_homepage(source)) {
                throw std::runtime_error(app + " checkver expects the homepage to be a github repository");
            }
            regex = std::string(github_default_regex);
            source = trim_trailing_slashes(std::move(source)) + "/releases/latest";
            uses_github_checkver = true;
            use_github_api_headers = true;
        } else if (normalized_value == "sourceforge") {
            const auto config = sourceforge_config_from_homepage(optional_string(manifest, "homepage").value_or(std::string{}), app, {});
            source = config.url;
            regex = config.regex;
        } else {
            regex = value;
        }
    } else if (checkver.is_object()) {
        const auto github = optional_string(checkver, "github");
        const auto explicit_source = optional_string(checkver, "url").value_or(std::string{});
        source = first_non_empty({explicit_source.empty() ? std::nullopt : std::optional<std::string>{explicit_source}, optional_string(manifest, "homepage")});
        regex = first_non_empty({optional_string(checkver, "regex"), optional_string(checkver, "re")});
        if (github && !github->empty()) {
            source = trim_trailing_slashes(*github) + "/releases/latest";
            if (regex.empty()) {
                regex = std::string(github_default_regex);
            }
            uses_github_checkver = true;
            use_github_api_headers = checkver.size() == 1;
        }
        if (const auto* sourceforge = json_property(checkver, "sourceforge"); sourceforge != nullptr && powershell_truthy(*sourceforge)) {
            if (const auto config = sourceforge_config_from_value(*sourceforge, app, regex)) {
                source = explicit_source.empty() ? config->url : explicit_source;
                regex = config->regex;
            }
        }
        jsonpath = first_non_empty({optional_string(checkver, "jsonpath"), optional_string(checkver, "jp")});
        xpath = optional_string(checkver, "xpath").value_or(std::string{});
        script_lines = optional_string_array(checkver, "script");
        replace = optional_string(checkver, "replace").value_or(std::string{});
        useragent = optional_string(checkver, "useragent").value_or(std::string{});
        reverse = optional_bool(checkver, "reverse");
    } else {
        return std::nullopt;
    }

    if (source.empty() && script_lines.empty()) {
        return std::nullopt;
    }
    if (!replace.empty() && regex.empty()) {
        throw std::runtime_error("'replace' requires 're' or 'regex'");
    }

    const auto manifest_version = optional_string(manifest, "version").value_or(std::string{});
    if (!source.empty()) {
        source = substitute_version_tokens(std::move(source), manifest_version);
    }
    if (uses_github_checkver && !jsonpath.empty()) {
        if (const auto api_url = github_latest_release_api_url(source)) {
            source = *api_url;
            use_github_api_headers = true;
        }
    }
    if (source.find("api.github.com/") != std::string::npos) {
        use_github_api_headers = true;
    }

    std::vector<std::pair<std::string, std::string>> headers;
    if (!useragent.empty()) {
        headers.emplace_back("User-Agent", substitute_version_tokens(std::move(useragent), manifest_version));
    } else {
        headers.emplace_back("User-Agent", "sco");
    }
    if (use_github_api_headers) {
        if (const auto token = configured_github_token(environment)) {
            set_request_header(headers, "Authorization", "token " + *token);
        }
    }
    if (!source.empty() && looks_like_http_url(source)) {
        headers.emplace_back("Referer", strip_url_filename(source));
        apply_private_host_headers(ConfigStore(environment.config_file), source, headers);
    }

    const auto text = script_lines.empty()
        ? read_text_source(source, manifest_path.parent_path(), headers)
        : run_checkver_script(script_lines);
    if (!jsonpath.empty()) {
        std::optional<std::string> version;
        try {
            version = json_version(text, jsonpath, reverse && regex.empty());
        } catch (const nlohmann::json::exception& error) {
            throw std::runtime_error("cannot parse checkver JSON from " + source + ": " + error.what());
        }
        if (!regex.empty() && version) {
            version = regex_version(*version, regex, reverse, replace);
        }
        return version;
    }
    if (!xpath.empty()) {
        auto version = xpath_version(text, xpath);
        if (!regex.empty() && version) {
            version = regex_version(*version, regex, reverse, replace);
        }
        return version;
    }
    return regex_version(text, regex, reverse, replace);
}

} // namespace sco
