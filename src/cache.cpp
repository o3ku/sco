#include "sco/cache.hpp"

#include <algorithm>
#include <cctype>
#include <regex>
#include <system_error>
#include <unordered_set>

namespace sco {

namespace {

std::string cache_app_name(const std::string& filename) {
    const auto marker = filename.find('#');
    if (marker == std::string::npos) {
        return {};
    }
    return filename.substr(0, marker);
}

std::string cache_version(const std::string& filename) {
    const auto first = filename.find('#');
    if (first == std::string::npos) {
        return {};
    }

    const auto second = filename.find('#', first + 1);
    if (second == std::string::npos) {
        return {};
    }

    return filename.substr(first + 1, second - first - 1);
}

bool app_matches(const std::string& app, const std::vector<std::string>& filters) {
    if (filters.empty()) {
        return true;
    }
    auto pattern = std::string{"^("};
    for (std::size_t i = 0; i < filters.size(); ++i) {
        if (i != 0) {
            pattern += '|';
        }
        pattern += filters[i];
    }
    pattern += ")$";
    return std::regex_match(app, std::regex(pattern, std::regex_constants::icase));
}

bool app_equals(const std::string& lhs, const std::string& rhs) {
    return lhs.size() == rhs.size()
        && std::equal(lhs.begin(), lhs.end(), rhs.begin(), [](unsigned char left, unsigned char right) {
               return std::tolower(left) == std::tolower(right);
           });
}

std::uintmax_t path_size(const std::filesystem::path& path) {
    std::error_code error;
    if (std::filesystem::is_regular_file(path, error)) {
        const auto size = std::filesystem::file_size(path, error);
        return error ? 0 : size;
    }

    error.clear();
    if (!std::filesystem::is_directory(path, error)) {
        return 0;
    }

    std::uintmax_t total = 0;
    std::filesystem::recursive_directory_iterator current(path, std::filesystem::directory_options::skip_permission_denied, error);
    const std::filesystem::recursive_directory_iterator end;
    while (!error && current != end) {
        if (current->is_regular_file(error)) {
            const auto size = current->file_size(error);
            if (!error) {
                total += size;
            }
        }
        error.clear();
        current.increment(error);
    }
    return total;
}

} // namespace

std::vector<CacheEntry> list_cache_entries(const Environment& environment, const std::vector<std::string>& app_filters) {
    std::vector<CacheEntry> entries;
    if (!std::filesystem::is_directory(environment.cache_dir)) {
        return entries;
    }

    for (const auto& entry : std::filesystem::directory_iterator(environment.cache_dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }

        const auto name = entry.path().filename().string();
        const auto app = cache_app_name(name);
        if (app.empty()) {
            continue;
        }
        if (!app_matches(app, app_filters)) {
            continue;
        }

        entries.push_back(CacheEntry{
            .name = name,
            .app = app,
            .path = entry.path(),
            .size = entry.file_size(),
        });
    }

    std::sort(entries.begin(), entries.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.name < rhs.name;
    });
    return entries;
}

std::vector<CacheEntry> list_cache_entries(const Environment& environment, const std::string& app_filter) {
    if (app_filter.empty()) {
        return list_cache_entries(environment, std::vector<std::string>{});
    }
    return list_cache_entries(environment, std::vector<std::string>{app_filter});
}

std::vector<CacheEntry> remove_cache_entries(const Environment& environment, const std::vector<std::string>& app_filters) {
    if (app_filters.empty()) {
        std::vector<CacheEntry> removed;
        if (!std::filesystem::is_directory(environment.cache_dir)) {
            return removed;
        }

        for (const auto& entry : std::filesystem::directory_iterator(environment.cache_dir)) {
            const auto name = entry.path().filename().string();
            removed.push_back(CacheEntry{
                .name = name,
                .app = cache_app_name(name),
                .path = entry.path(),
                .size = path_size(entry.path()),
            });
            std::filesystem::remove_all(entry.path());
        }
        std::sort(removed.begin(), removed.end(), [](const auto& lhs, const auto& rhs) {
            return lhs.name < rhs.name;
        });
        return removed;
    }

    auto entries = list_cache_entries(environment, app_filters);
    std::unordered_set<std::string> removed_apps;
    for (const auto& entry : entries) {
        std::filesystem::remove(entry.path);
        if (!entry.app.empty()) {
            removed_apps.insert(entry.app);
        }
    }

    for (const auto& app : removed_apps) {
        std::filesystem::remove(environment.cache_dir / (app + ".txt"));
    }
    return entries;
}

std::vector<CacheEntry> remove_cache_entries(const Environment& environment, const std::string& app_filter) {
    if (app_filter.empty()) {
        return remove_cache_entries(environment, std::vector<std::string>{});
    }
    return remove_cache_entries(environment, std::vector<std::string>{app_filter});
}

std::vector<CacheEntry> remove_cache_entries_for_app_except_version(
    const Environment& environment,
    const std::string& app,
    const std::string& keep_version) {
    std::vector<CacheEntry> entries;
    if (!std::filesystem::is_directory(environment.cache_dir)) {
        return entries;
    }

    for (const auto& entry : std::filesystem::directory_iterator(environment.cache_dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }

        const auto name = entry.path().filename().string();
        const auto entry_app = cache_app_name(name);
        if (!app_equals(entry_app, app) || cache_version(name) == keep_version) {
            continue;
        }

        entries.push_back(CacheEntry{
            .name = name,
            .app = entry_app,
            .path = entry.path(),
            .size = entry.file_size(),
        });
    }

    std::sort(entries.begin(), entries.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.name < rhs.name;
    });
    for (const auto& entry : entries) {
        std::filesystem::remove(entry.path);
    }
    return entries;
}

std::vector<std::filesystem::path> remove_temporary_download_entries(const Environment& environment) {
    std::vector<std::filesystem::path> removed;
    if (!std::filesystem::is_directory(environment.cache_dir)) {
        return removed;
    }

    for (const auto& entry : std::filesystem::directory_iterator(environment.cache_dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const auto name = entry.path().filename().string();
        if (!name.ends_with(".download")) {
            continue;
        }
        removed.push_back(entry.path());
        std::filesystem::remove(entry.path());
    }
    std::sort(removed.begin(), removed.end());
    return removed;
}

} // namespace sco
