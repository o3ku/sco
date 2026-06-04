#include "sco/config.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <regex>
#include <sstream>
#include <unordered_set>

namespace sco {

namespace {

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
    return {first, last};
}

std::vector<std::pair<std::string, std::string>> parse_string_data_headers(const std::string& text) {
    std::vector<std::pair<std::string, std::string>> headers;
    std::stringstream stream(text);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        line = trim_ascii(std::move(line));
        if (line.empty() || line.front() == '#') {
            continue;
        }
        const auto equals = line.find('=');
        if (equals == std::string::npos) {
            continue;
        }
        auto name = trim_ascii(line.substr(0, equals));
        auto value = trim_ascii(line.substr(equals + 1));
        if (!name.empty()) {
            headers.emplace_back(std::move(name), std::move(value));
        }
    }
    return headers;
}

std::optional<std::string> optional_object_string_ci(const nlohmann::json& object, const std::string& key) {
    if (!object.is_object()) {
        return std::nullopt;
    }
    const auto normalized_key = normalize_config_name(key);
    for (const auto& item : object.items()) {
        if (normalize_config_name(item.key()) == normalized_key && item.value().is_string()) {
            return item.value().get<std::string>();
        }
    }
    return std::nullopt;
}

void set_header(std::vector<std::pair<std::string, std::string>>& headers, std::string name, std::string value) {
    const auto normalized = normalize_config_name(name);
    for (auto& header : headers) {
        if (normalize_config_name(header.first) == normalized) {
            header.second = std::move(value);
            return;
        }
    }
    headers.emplace_back(std::move(name), std::move(value));
}

std::string spaces(std::size_t count) {
    return std::string(count, ' ');
}

std::string format_config_scalar(const nlohmann::json& value) {
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
    return value.dump();
}

std::string format_config_inline(const nlohmann::json& value);

std::string format_config_object_inline(const nlohmann::json& value) {
    std::string result = "@{";
    bool first = true;
    for (const auto& item : value.items()) {
        if (!first) {
            result += "; ";
        }
        first = false;
        result += item.key();
        result += '=';
        result += format_config_inline(item.value());
    }
    result += '}';
    return result;
}

std::string format_config_array_inline(const nlohmann::json& value) {
    std::string result = "{";
    bool first = true;
    for (const auto& item : value) {
        if (!first) {
            result += ", ";
        }
        first = false;
        result += format_config_inline(item);
    }
    result += '}';
    return result;
}

std::string format_config_inline(const nlohmann::json& value) {
    if (value.is_object()) {
        return format_config_object_inline(value);
    }
    if (value.is_array()) {
        return format_config_array_inline(value);
    }
    return format_config_scalar(value);
}

struct ConfigCell {
    std::string text;
    bool right_aligned = false;
};

ConfigCell format_config_table_cell(const nlohmann::json& value) {
    ConfigCell cell;
    cell.text = format_config_inline(value);
    cell.right_aligned = value.is_boolean() || value.is_number();
    return cell;
}

std::string append_table_field(std::string line, const std::string& text, std::size_t width, bool right_aligned) {
    if (right_aligned && text.size() < width) {
        line += spaces(width - text.size());
        line += text;
    } else {
        line += text;
        if (text.size() < width) {
            line += spaces(width - text.size());
        }
    }
    return line;
}

std::string format_config_object_rows(const std::vector<const nlohmann::json*>& rows) {
    std::vector<std::string> columns;
    std::unordered_set<std::string> seen;
    for (const auto* row : rows) {
        if (row == nullptr || !row->is_object()) {
            continue;
        }
        for (const auto& item : row->items()) {
            if (seen.insert(item.key()).second) {
                columns.push_back(item.key());
            }
        }
    }
    if (columns.empty()) {
        return {};
    }

    std::vector<std::vector<ConfigCell>> cells;
    cells.reserve(rows.size());
    std::vector<std::size_t> widths;
    widths.reserve(columns.size());
    for (const auto& column : columns) {
        widths.push_back(column.size());
    }

    for (const auto* row : rows) {
        std::vector<ConfigCell> row_cells;
        row_cells.reserve(columns.size());
        for (std::size_t i = 0; i < columns.size(); ++i) {
            ConfigCell cell;
            if (row != nullptr && row->is_object() && row->contains(columns[i])) {
                cell = format_config_table_cell(row->at(columns[i]));
            }
            widths[i] = std::max(widths[i], cell.text.size());
            row_cells.push_back(std::move(cell));
        }
        cells.push_back(std::move(row_cells));
    }

    std::stringstream output;
    output << '\n';

    for (std::size_t i = 0; i < columns.size(); ++i) {
        if (i != 0) {
            output << ' ';
        }
        output << append_table_field({}, columns[i], widths[i], false);
    }
    output << '\n';

    for (std::size_t i = 0; i < columns.size(); ++i) {
        if (i != 0) {
            output << ' ';
        }
        output << append_table_field({}, std::string(columns[i].size(), '-'), widths[i], false);
    }
    output << '\n';

    for (const auto& row : cells) {
        for (std::size_t i = 0; i < row.size(); ++i) {
            if (i != 0) {
                output << ' ';
            }
            output << append_table_field({}, row[i].text, widths[i], row[i].right_aligned);
        }
        output << '\n';
    }

    return output.str();
}

std::string format_config_property_list(const nlohmann::json& values) {
    std::size_t width = 0;
    for (const auto& item : values.items()) {
        width = std::max(width, item.key().size());
    }

    std::stringstream output;
    output << '\n';
    for (const auto& item : values.items()) {
        output << item.key() << spaces(width - item.key().size()) << " : "
               << format_config_table_cell(item.value()).text << '\n';
    }
    return output.str();
}

} // namespace

ConfigStore::ConfigStore(std::filesystem::path path) : path_(std::move(path)), values_(nlohmann::json::object()) {
    std::ifstream stream(path_);
    if (!stream) {
        return;
    }

    try {
        stream >> values_;
    } catch (const nlohmann::json::exception&) {
        values_ = nlohmann::json::object();
    }

    if (!values_.is_object()) {
        values_ = nlohmann::json::object();
    }
}

const std::filesystem::path& ConfigStore::path() const {
    return path_;
}

const nlohmann::json& ConfigStore::values() const {
    return values_;
}

std::optional<nlohmann::json> ConfigStore::get(const std::string& name) const {
    const auto normalized = normalize_config_name(name);
    if (!values_.contains(normalized) || values_.at(normalized).is_null()) {
        for (const auto& item : values_.items()) {
            if (normalize_config_name(item.key()) == normalized && !item.value().is_null()) {
                return nlohmann::json(item.value());
            }
        }
        return std::nullopt;
    }
    return nlohmann::json(values_.at(normalized));
}

void ConfigStore::set(const std::string& name, nlohmann::json value) {
    const auto normalized = normalize_config_name(name);
    for (auto it = values_.begin(); it != values_.end(); ++it) {
        if (normalize_config_name(it.key()) == normalized) {
            it.value() = std::move(value);
            return;
        }
    }
    values_[normalized] = std::move(value);
}

void ConfigStore::remove(const std::string& name) {
    const auto normalized = normalize_config_name(name);
    for (auto it = values_.begin(); it != values_.end();) {
        if (normalize_config_name(it.key()) == normalized) {
            it = values_.erase(it);
        } else {
            ++it;
        }
    }
}

void ConfigStore::save() const {
    std::filesystem::create_directories(path_.parent_path());
    std::ofstream stream(path_, std::ios::binary);
    stream << values_.dump(4) << '\n';
}

std::string normalize_config_name(std::string name) {
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return name;
}

nlohmann::json parse_config_value(const std::string& value) {
    const auto normalized = normalize_config_name(value);
    if (normalized == "true") {
        return true;
    }
    if (normalized == "false") {
        return false;
    }
    return value;
}

std::string format_config_values(const nlohmann::json& values) {
    if (!values.is_object() || values.empty()) {
        return {};
    }
    if (values.size() > 4) {
        return format_config_property_list(values);
    }
    return format_config_object_rows({&values});
}

std::string format_config_value(const nlohmann::json& value) {
    if (value.is_object()) {
        return format_config_object_rows({&value});
    }
    if (value.is_array()) {
        std::vector<const nlohmann::json*> object_rows;
        object_rows.reserve(value.size());
        bool all_objects = !value.empty();
        for (const auto& item : value) {
            all_objects = all_objects && item.is_object();
            if (item.is_object()) {
                object_rows.push_back(&item);
            }
        }
        if (all_objects) {
            return format_config_object_rows(object_rows);
        }

        std::stringstream output;
        for (std::size_t i = 0; i < value.size(); ++i) {
            if (i != 0) {
                output << '\n';
            }
            output << format_config_inline(value.at(i));
        }
        return output.str();
    }
    return format_config_scalar(value);
}

void apply_private_host_headers(
    const ConfigStore& config,
    const std::string& url,
    std::vector<std::pair<std::string, std::string>>& headers) {
    const auto private_hosts = config.get("PRIVATE_HOSTS");
    if (!private_hosts || !private_hosts->is_array()) {
        return;
    }

    for (const auto& host : *private_hosts) {
        if (!host.is_object()) {
            continue;
        }
        const auto match = optional_object_string_ci(host, "match").value_or(std::string{});
        const auto header_text = optional_object_string_ci(host, "headers").value_or(std::string{});
        if (match.empty() || header_text.empty()) {
            continue;
        }

        try {
            if (!std::regex_search(url, std::regex(match, std::regex_constants::icase))) {
                continue;
            }
        } catch (const std::regex_error&) {
            continue;
        }

        for (auto [name, value] : parse_string_data_headers(header_text)) {
            set_header(headers, std::move(name), std::move(value));
        }
    }
}

} // namespace sco
