#include "sco/artifact.hpp"

#include "sco/config.hpp"
#include "sco/http_client.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <fstream>
#include <cstdint>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

namespace sco {

namespace {

constexpr int download_max_parts = 5;
constexpr int download_retry_attempts = 3;

std::string to_hex(const unsigned char* data, std::size_t size) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string output;
    output.reserve(size * 2);
    for (std::size_t i = 0; i < size; ++i) {
        output.push_back(digits[(data[i] >> 4) & 0x0f]);
        output.push_back(digits[data[i] & 0x0f]);
    }
    return output;
}

std::string lowercase(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string strip_fragment_and_query(std::string url) {
    if (const auto fragment = url.find('#'); fragment != std::string::npos) {
        url.erase(fragment);
    }
    if (const auto query = url.find('?'); query != std::string::npos) {
        url.erase(query);
    }
    return url;
}

bool starts_with(const std::string& value, const char* prefix) {
    return value.rfind(prefix, 0) == 0;
}

std::string strip_fragment(std::string url) {
    if (const auto fragment = url.find('#'); fragment != std::string::npos) {
        url.erase(fragment);
    }
    return url;
}

std::string strip_filename(const std::string& url) {
    const auto clean = strip_fragment(url);
    const auto slash = clean.find_last_of('/');
    return slash == std::string::npos ? std::string{} : clean.substr(0, slash);
}

bool should_send_referer(const std::string& url) {
    const auto lower = lowercase(url);
    return lower.find("sourceforge.net") == std::string::npos &&
        lower.find("portableapps.com") == std::string::npos;
}

std::string strip_query(std::string value) {
    if (const auto query = value.find('?'); query != std::string::npos) {
        value.erase(query);
    }
    return value;
}

std::string path_leaf(const std::string& value) {
    const auto slash = value.find_last_of("/\\");
    if (slash == std::string::npos) {
        return value;
    }
    return value.substr(slash + 1);
}

bool has_filename_extension(const std::string& value) {
    return value.find('.') != std::string::npos;
}

bool looks_like_version_basename(const std::string& value) {
    if (value.empty()) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return ch == 'v' || ch == '.' || std::isdigit(ch) != 0;
    });
}

bool is_remote_filename_token(const std::string& value) {
    if (value.empty()) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return std::isalnum(ch) != 0 || ch == '_' || ch == '.' || ch == '-';
    });
}

std::string trim_fragment_filename(std::string value) {
    while (!value.empty() && (value.front() == '/' || value.front() == '#')) {
        value.erase(value.begin());
    }
    while (!value.empty() && value.back() == '/') {
        value.pop_back();
    }
    return value;
}

std::string legacy_cache_url_key(const std::string& url) {
    std::string key;
    key.reserve(url.size());
    auto replaced = false;
    for (const unsigned char ch : url) {
        const auto keep = std::isalnum(ch) != 0 || ch == '_' || ch == '.' || ch == '-';
        if (keep) {
            key.push_back(static_cast<char>(ch));
            replaced = false;
        } else if (!replaced) {
            key.push_back('_');
            replaced = true;
        }
    }
    return key;
}

std::filesystem::path local_source_path(const std::string& url, const std::filesystem::path& manifest_dir) {
    std::string path = url;
    if (starts_with(path, "file:///")) {
        path = path.substr(8);
    } else if (starts_with(path, "file://")) {
        path = path.substr(7);
    }

    path = strip_fragment_and_query(path);
    std::replace(path.begin(), path.end(), '/', '\\');

    std::filesystem::path source(path);
    if (source.is_relative()) {
        source = manifest_dir / source;
    }
    return source;
}

void write_bytes(const std::filesystem::path& path, const std::string& bytes) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot write " + path.string());
    }
    stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

std::string artifact_cookie_header(const std::vector<std::pair<std::string, std::string>>& cookies) {
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

std::optional<std::uint64_t> parse_unsigned_header(const std::string& value) {
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoull(value, &consumed);
        while (consumed < value.size()) {
            if (std::isspace(static_cast<unsigned char>(value[consumed])) == 0) {
                return std::nullopt;
            }
            ++consumed;
        }
        return parsed;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

bool header_has_token(const std::map<std::string, std::string>& headers, const char* name, const char* token) {
    const auto found = headers.find(name);
    if (found == headers.end()) {
        return false;
    }
    return lowercase(found->second).find(token) != std::string::npos;
}

std::optional<std::uint64_t> content_length_from(const HttpResponse& response) {
    const auto found = response.headers.find("content-length");
    if (found == response.headers.end()) {
        return std::nullopt;
    }
    return parse_unsigned_header(found->second);
}

void remove_download_parts(const std::filesystem::path& destination) {
    for (auto index = 0; index < download_max_parts; ++index) {
        std::error_code ignored;
        std::filesystem::remove(destination.string() + ".part" + std::to_string(index), ignored);
    }
}

void cleanup_temporary_download(const std::filesystem::path& destination) {
    std::error_code ignored;
    std::filesystem::remove(destination, ignored);
    remove_download_parts(destination);
}

bool download_artifact_parallel(
    const std::string& request_url,
    const std::filesystem::path& destination,
    const std::vector<std::pair<std::string, std::string>>& headers) {
    constexpr std::uint64_t min_part_size = 5ull * 1024ull * 1024ull;

    const HttpClient client;
    const auto head = client.head(request_url, headers);
    if (head.status < 200 || head.status >= 300 || !header_has_token(head.headers, "accept-ranges", "bytes")) {
        return false;
    }

    const auto content_length = content_length_from(head);
    if (!content_length || *content_length < min_part_size * 2) {
        return false;
    }

    const auto calculated_parts = static_cast<int>(*content_length / min_part_size);
    const auto parts = std::clamp(calculated_parts, 2, download_max_parts);
    const auto chunk_size = (*content_length + static_cast<std::uint64_t>(parts) - 1) / static_cast<std::uint64_t>(parts);
    cleanup_temporary_download(destination);

    struct Part {
        std::uint64_t start = 0;
        std::uint64_t end = 0;
        std::filesystem::path path;
        std::string error;
    };

    std::vector<Part> ranges;
    ranges.reserve(parts);
    for (auto index = 0; index < parts; ++index) {
        const auto start = static_cast<std::uint64_t>(index) * chunk_size;
        if (start >= *content_length) {
            break;
        }
        const auto end = std::min(*content_length - 1, start + chunk_size - 1);
        ranges.push_back(Part{
            .start = start,
            .end = end,
            .path = destination.string() + ".part" + std::to_string(index),
            .error = {},
        });
    }

    std::vector<std::thread> workers;
    workers.reserve(ranges.size());
    for (auto index = std::size_t{0}; index < ranges.size(); ++index) {
        workers.emplace_back([&, index] {
            try {
                auto part_headers = headers;
                part_headers.emplace_back(
                    "Range",
                    "bytes=" + std::to_string(ranges[index].start) + "-" + std::to_string(ranges[index].end));

                const auto expected_size = ranges[index].end - ranges[index].start + 1;
                for (auto attempt = 1; attempt <= download_retry_attempts; ++attempt) {
                    const HttpClient part_client;
                    const auto response = part_client.get(request_url, part_headers);
                    if (response.status == 206 && response.body.size() == expected_size) {
                        write_bytes(ranges[index].path, response.body);
                        ranges[index].error.clear();
                        return;
                    }

                    ranges[index].error = response.status == 206
                        ? "range request returned " + std::to_string(response.body.size()) +
                            " bytes instead of " + std::to_string(expected_size)
                        : "range request returned " + (response.error.empty() ? "HTTP " + std::to_string(response.status) : response.error);

                    if (attempt < download_retry_attempts) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(200 * attempt));
                    }
                }
            } catch (const std::exception& error) {
                ranges[index].error = error.what();
            }
        });
    }

    for (auto& worker : workers) {
        worker.join();
    }

    for (const auto& range : ranges) {
        if (!range.error.empty()) {
            cleanup_temporary_download(destination);
            return false;
        }
    }

    std::filesystem::create_directories(destination.parent_path());
    std::ofstream output(destination, std::ios::binary);
    if (!output) {
        cleanup_temporary_download(destination);
        throw std::runtime_error("cannot write " + destination.string());
    }

    for (const auto& range : ranges) {
        std::ifstream input(range.path, std::ios::binary);
        if (!input) {
            cleanup_temporary_download(destination);
            return false;
        }
        output << input.rdbuf();
    }
    output.close();
    if (!output) {
        cleanup_temporary_download(destination);
        throw std::runtime_error("cannot write " + destination.string());
    }

    std::error_code size_error;
    if (std::filesystem::file_size(destination, size_error) != *content_length || size_error) {
        cleanup_temporary_download(destination);
        return false;
    }

    remove_download_parts(destination);
    return true;
}

HttpResponse download_artifact_single(
    const std::string& request_url,
    const std::vector<std::pair<std::string, std::string>>& headers) {
    HttpResponse last_response;
    for (auto attempt = 1; attempt <= download_retry_attempts; ++attempt) {
        const HttpClient client;
        last_response = client.get(request_url, headers);
        if (last_response.status >= 200 && last_response.status < 300) {
            return last_response;
        }
        if (attempt < download_retry_attempts) {
            std::this_thread::sleep_for(std::chrono::milliseconds(300 * attempt));
        }
    }
    return last_response;
}

void copy_or_download(
    const Environment& environment,
    const std::string& url,
    const std::filesystem::path& manifest_dir,
    const std::filesystem::path& destination,
    const std::vector<std::pair<std::string, std::string>>& cookies) {
    const auto lower_url = lowercase(url);
    if (starts_with(lower_url, "http://") || starts_with(lower_url, "https://")) {
        const auto request_url = strip_fragment(url);
        std::vector<std::pair<std::string, std::string>> headers{{"User-Agent", "sco"}};
        if (should_send_referer(request_url)) {
            headers.emplace_back("Referer", strip_filename(request_url));
        }
        if (const auto cookie = artifact_cookie_header(cookies); !cookie.empty()) {
            headers.emplace_back("Cookie", cookie);
        }
        headers.emplace_back("Accept-Encoding", "identity");
        apply_private_host_headers(ConfigStore(environment.config_file), request_url, headers);
        if (download_artifact_parallel(request_url, destination, headers)) {
            return;
        }

        const auto response = download_artifact_single(request_url, headers);
        if (response.status < 200 || response.status >= 300) {
            throw std::runtime_error("download failed for " + request_url + ": " + (response.error.empty() ? std::to_string(response.status) : response.error));
        }
        write_bytes(destination, response.body);
        return;
    }

    const auto source = local_source_path(url, manifest_dir);
    if (!std::filesystem::is_regular_file(source)) {
        throw std::runtime_error("local artifact does not exist: " + source.string());
    }

    std::filesystem::create_directories(destination.parent_path());
    std::filesystem::copy_file(source, destination, std::filesystem::copy_options::overwrite_existing);
}

LPCWSTR bcrypt_algorithm_name(const std::string& algorithm) {
    const auto lower = lowercase(algorithm);
    if (lower == "md5") {
        return BCRYPT_MD5_ALGORITHM;
    }
    if (lower == "sha1") {
        return BCRYPT_SHA1_ALGORITHM;
    }
    if (lower == "sha256") {
        return BCRYPT_SHA256_ALGORITHM;
    }
    if (lower == "sha512") {
        return BCRYPT_SHA512_ALGORITHM;
    }
    throw std::runtime_error("unsupported hash algorithm: " + algorithm);
}

std::string hash_bytes(const std::vector<unsigned char>& bytes, const std::string& algorithm_name) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD object_size = 0;
    DWORD data_size = 0;
    DWORD hash_size = 0;

    if (BCryptOpenAlgorithmProvider(&algorithm, bcrypt_algorithm_name(algorithm_name), nullptr, 0) != 0) {
        throw std::runtime_error("BCryptOpenAlgorithmProvider failed");
    }

    auto cleanup = [&] {
        if (hash != nullptr) {
            BCryptDestroyHash(hash);
        }
        if (algorithm != nullptr) {
            BCryptCloseAlgorithmProvider(algorithm, 0);
        }
    };

    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size), &data_size, 0) != 0 ||
        BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, reinterpret_cast<PUCHAR>(&hash_size), sizeof(hash_size), &data_size, 0) != 0) {
        cleanup();
        throw std::runtime_error("BCryptGetProperty failed");
    }

    std::vector<unsigned char> object(object_size);
    std::vector<unsigned char> digest(hash_size);
    if (BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr, 0, 0) != 0 ||
        BCryptHashData(hash, const_cast<PUCHAR>(bytes.data()), static_cast<ULONG>(bytes.size()), 0) != 0 ||
        BCryptFinishHash(hash, digest.data(), hash_size, 0) != 0) {
        cleanup();
        throw std::runtime_error("BCrypt " + algorithm_name + " failed");
    }

    cleanup();
    return to_hex(digest.data(), digest.size());
}

std::pair<std::string, std::string> parse_manifest_hash(std::string value) {
    value.erase(std::remove_if(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), value.end());
    value = lowercase(std::move(value));

    if (const auto colon = value.find(':'); colon != std::string::npos) {
        return {value.substr(0, colon), value.substr(colon + 1)};
    }
    return {"sha256", value};
}

} // namespace

std::string sha256_text(const std::string& text) {
    return hash_bytes(std::vector<unsigned char>(text.begin(), text.end()), "sha256");
}

std::string hash_file(const std::filesystem::path& path, const std::string& algorithm) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        throw std::runtime_error("cannot open " + path.string());
    }
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    return hash_bytes(bytes, algorithm);
}

bool file_hash_matches(const std::filesystem::path& path, const std::string& manifest_hash) {
    const auto [algorithm, expected] = parse_manifest_hash(manifest_hash);
    if (expected.empty()) {
        return false;
    }
    return hash_file(path, algorithm) == expected;
}

std::string sha256_file(const std::filesystem::path& path) {
    return hash_file(path, "sha256");
}

std::string url_filename(const std::string& url) {
    return strip_query(path_leaf(url));
}

std::string url_remote_filename(const std::string& url) {
    auto without_fragment = url;
    std::string fragment;
    if (const auto marker = without_fragment.find('#'); marker != std::string::npos) {
        fragment = without_fragment.substr(marker + 1);
        without_fragment.erase(marker);
    }

    auto basename = path_leaf(without_fragment);
    if (const auto token = basename.find_last_of("?="); token != std::string::npos) {
        const auto suffix = basename.substr(token + 1);
        if (is_remote_filename_token(suffix)) {
            basename = suffix;
        }
    }

    if (!has_filename_extension(basename) || looks_like_version_basename(basename)) {
        basename = path_leaf(strip_query(without_fragment));
    }
    if (!has_filename_extension(basename) && !fragment.empty()) {
        basename = trim_fragment_filename(std::move(fragment));
    }
    return basename;
}

std::filesystem::path cache_path(const Environment& environment, const std::string& app, const std::string& version, const std::string& url) {
    const auto legacy = environment.cache_dir / (app + "#" + version + "#" + legacy_cache_url_key(url));
    if (std::filesystem::exists(legacy)) {
        return legacy;
    }

    std::string extension = std::filesystem::path(url_filename(url)).extension().string();
    const auto hash = sha256_text(url).substr(0, 7);
    return environment.cache_dir / (app + "#" + version + "#" + hash + extension);
}

std::filesystem::path fetch_artifact_to_cache(
    const Environment& environment,
    const std::string& app,
    const std::string& version,
    const std::string& url,
    const std::filesystem::path& manifest_dir,
    bool use_cache,
    const std::vector<std::pair<std::string, std::string>>& cookies) {
    const auto cached = cache_path(environment, app, version, url);
    if (!std::filesystem::exists(cached) || !use_cache) {
        const auto temporary = cached.string() + ".download";
        cleanup_temporary_download(temporary);
        try {
            copy_or_download(environment, url, manifest_dir, temporary, cookies);
        } catch (...) {
            cleanup_temporary_download(temporary);
            throw;
        }
        if (std::filesystem::exists(cached)) {
            std::filesystem::remove(cached);
        }
        std::filesystem::rename(temporary, cached);
    }
    return cached;
}

FetchedArtifact fetch_artifact(
    const Environment& environment,
    const std::string& app,
    const std::string& version,
    const std::string& url,
    const std::filesystem::path& manifest_dir,
    const std::filesystem::path& destination_dir,
    bool use_cache,
    const std::vector<std::pair<std::string, std::string>>& cookies) {
    const auto cached = fetch_artifact_to_cache(environment, app, version, url, manifest_dir, use_cache, cookies);

    const auto filename = url_filename(url);
    const auto destination = destination_dir / filename;
    std::filesystem::create_directories(destination.parent_path());
    if (!use_cache) {
        if (std::filesystem::exists(destination)) {
            std::filesystem::remove(destination);
        }
        std::filesystem::rename(cached, destination);
        return FetchedArtifact{
            .cache_path = destination,
            .install_path = destination,
            .filename = filename,
        };
    }

    std::filesystem::copy_file(cached, destination, std::filesystem::copy_options::overwrite_existing);
    return FetchedArtifact{
        .cache_path = cached,
        .install_path = destination,
        .filename = filename,
    };
}

} // namespace sco
