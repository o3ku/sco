#include "sco/versions.hpp"

#include <algorithm>
#include <cctype>
#include <charconv>
#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>
#include <system_error>
#include <string_view>
#include <variant>
#include <vector>

namespace sco {

namespace {

using VersionPart = std::variant<long long, std::string>;

std::string replace_all(std::string value, char from, char to) {
    std::replace(value.begin(), value.end(), from, to);
    return value;
}

std::vector<std::string> split_literal(std::string_view value, char delimiter) {
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto end = value.find(delimiter, start);
        const auto stop = end == std::string_view::npos ? value.size() : end;
        if (stop > start) {
            parts.emplace_back(value.substr(start, stop - start));
        }
        if (end == std::string_view::npos) {
            break;
        }
        start = end + 1;
    }
    return parts;
}

bool is_digits(std::string_view value) {
    return !value.empty() && std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return std::isdigit(ch) != 0;
    });
}

VersionPart to_version_part(const std::string& value) {
    if (is_digits(value)) {
        long long number = 0;
        const auto result = std::from_chars(value.data(), value.data() + value.size(), number);
        if (result.ec == std::errc{} && result.ptr == value.data() + value.size()) {
            return number;
        }
    }
    return value;
}

std::vector<VersionPart> split_version(const std::string& version, char delimiter) {
    std::string expanded;
    expanded.reserve(version.size() * 3);
    for (std::size_t i = 0; i < version.size();) {
        const auto ch = static_cast<unsigned char>(version[i]);
        if (std::isalpha(ch) != 0) {
            expanded.push_back(delimiter);
            while (i < version.size() && std::isalpha(static_cast<unsigned char>(version[i])) != 0) {
                expanded.push_back(version[i]);
                ++i;
            }
            expanded.push_back(delimiter);
        } else {
            expanded.push_back(version[i]);
            ++i;
        }
    }

    std::vector<VersionPart> parts;
    for (const auto& part : split_literal(expanded, delimiter)) {
        parts.push_back(to_version_part(part));
    }
    return parts;
}

std::string part_string(const VersionPart& part) {
    if (std::holds_alternative<long long>(part)) {
        return std::to_string(std::get<long long>(part));
    }
    return std::get<std::string>(part);
}

bool string_part_contains_prerelease(const VersionPart& part) {
    if (!std::holds_alternative<std::string>(part)) {
        return false;
    }
    auto value = std::get<std::string>(part);
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value.find("alpha") != std::string::npos || value.find("beta") != std::string::npos ||
        value.find("rc") != std::string::npos || value.find("pre") != std::string::npos;
}

bool part_contains(const VersionPart& part, char value) {
    return part_string(part).find(value) != std::string::npos;
}

int sign(long long value) {
    return (value > 0) - (value < 0);
}

long long nightly_date_value(const VersionPart& part) {
    if (std::holds_alternative<long long>(part)) {
        return std::get<long long>(part);
    }
    return 0;
}

long long today_yyyyMMdd() {
    const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::tm local{};
    localtime_s(&local, &now);
    return static_cast<long long>(local.tm_year + 1900) * 10000 + static_cast<long long>(local.tm_mon + 1) * 100 + local.tm_mday;
}

int compare_parts(VersionPart reference, VersionPart difference) {
    if (reference.index() != difference.index()) {
        const auto result = part_string(difference).compare(part_string(reference));
        return sign(result);
    }
    if (std::holds_alternative<long long>(reference)) {
        return sign(std::get<long long>(difference) - std::get<long long>(reference));
    }
    auto reference_text = std::get<std::string>(reference);
    auto difference_text = std::get<std::string>(difference);
    std::transform(reference_text.begin(), reference_text.end(), reference_text.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    std::transform(difference_text.begin(), difference_text.end(), difference_text.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    const auto result = difference_text.compare(reference_text);
    return sign(result);
}

int compare_versions_impl(std::string reference, std::string difference, char delimiter, bool update_nightly) {
    reference = replace_all(std::move(reference), '+', '-');
    difference = replace_all(std::move(difference), '+', '-');

    if (difference == reference) {
        return 0;
    }

    auto reference_parts = split_version(reference, delimiter);
    auto difference_parts = split_version(difference, delimiter);

    if (!reference_parts.empty() && !difference_parts.empty() &&
        part_string(reference_parts.front()) == "nightly" && part_string(difference_parts.front()) == "nightly") {
        if (!update_nightly) {
            return 0;
        }
        if (reference_parts.size() < 2) {
            reference_parts.push_back(today_yyyyMMdd());
        }
        if (difference_parts.size() < 2) {
            difference_parts.push_back(today_yyyyMMdd());
        }
        return sign(nightly_date_value(difference_parts[1]) - nightly_date_value(reference_parts[1]));
    }

    const auto count = std::max(reference_parts.size(), difference_parts.size());
    for (std::size_t i = 0; i < count; ++i) {
        if (i >= reference_parts.size()) {
            return string_part_contains_prerelease(difference_parts[i]) ? -1 : 1;
        }
        if (i >= difference_parts.size()) {
            return string_part_contains_prerelease(reference_parts[i]) ? 1 : -1;
        }

        if (part_contains(reference_parts[i], '.') || part_contains(difference_parts[i], '.')) {
            const auto result = compare_versions_impl(part_string(reference_parts[i]), part_string(difference_parts[i]), '.', update_nightly);
            if (result != 0) {
                return result;
            }
            continue;
        }

        if (part_contains(reference_parts[i], '_') || part_contains(difference_parts[i], '_')) {
            const auto result = compare_versions_impl(part_string(reference_parts[i]), part_string(difference_parts[i]), '_', update_nightly);
            if (result != 0) {
                return result;
            }
            continue;
        }

        const auto result = compare_parts(reference_parts[i], difference_parts[i]);
        if (result != 0) {
            return result;
        }
    }

    return 0;
}

} // namespace

int compare_versions(const std::string& reference, const std::string& difference) {
    return compare_versions_impl(reference, difference, '-', false);
}

int compare_versions(const std::string& reference, const std::string& difference, bool update_nightly) {
    return compare_versions_impl(reference, difference, '-', update_nightly);
}

bool is_version_newer(const std::string& current, const std::string& latest) {
    return compare_versions(current, latest) > 0;
}

std::string nightly_version() {
    const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::tm local{};
    localtime_s(&local, &now);
    std::ostringstream stream;
    stream << "nightly-" << std::put_time(&local, "%Y%m%d");
    return stream.str();
}

} // namespace sco
