#include "sco/manifest.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <cctype>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace sco {

namespace {

std::string lower_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

bool powershell_truthy_json(const nlohmann::json& value) {
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
            return powershell_truthy_json(value.front());
        }
        return true;
    }
    return true;
}

bool powershell_truthy_json(const nlohmann::ordered_json& value) {
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
            return powershell_truthy_json(value.front());
        }
        return true;
    }
    return true;
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

std::string powershell_scalar_string(const nlohmann::json& value);
std::string powershell_note_string(const nlohmann::json& value);

std::vector<std::string> string_or_array(const nlohmann::json& object, const char* key) {
    std::vector<std::string> values;
    const auto* value = json_property(object, key);
    if (value == nullptr || value->is_null()) {
        return values;
    }
    if (!powershell_truthy_json(*value)) {
        return values;
    }

    if (value->is_string()) {
        values.push_back(value->get<std::string>());
        return values;
    }

    if (value->is_array()) {
        for (const auto& item : *value) {
            if (!item.is_string()) {
                throw ManifestError(std::string(key) + " entries must be strings");
            }
            values.push_back(item.get<std::string>());
        }
        return values;
    }

    throw ManifestError(std::string(key) + " must be a string or an array of strings");
}

std::vector<std::string> scalar_string_or_array(const nlohmann::json& value) {
    std::vector<std::string> values;
    if (value.is_array()) {
        for (const auto& item : value) {
            values.push_back(powershell_scalar_string(item));
        }
        return values;
    }
    values.push_back(powershell_scalar_string(value));
    return values;
}

std::string strip_extension(std::string name) {
    const auto pos = name.find_last_of('.');
    if (pos != std::string::npos) {
        name.erase(pos);
    }
    return name;
}

std::string args_value(const nlohmann::json& value, const char*) {
    if (value.is_string()) {
        return value.get<std::string>();
    }
    if (!value.is_array()) {
        return powershell_note_string(value);
    }

    std::string args;
    for (const auto& item : value) {
        if (!args.empty()) {
            args += ' ';
        }
        args += powershell_note_string(item);
    }
    return args;
}

std::vector<ManifestBin> collect_bins(const nlohmann::json& object) {
    std::vector<ManifestBin> bins;
    const auto* value = json_property(object, "bin");
    if (value == nullptr || value->is_null()) {
        return bins;
    }
    if (!powershell_truthy_json(*value)) {
        return bins;
    }

    if (value->is_string()) {
        const auto target = value->get<std::string>();
        bins.push_back(ManifestBin{.target = target, .name = strip_extension(std::filesystem::path(target).filename().string())});
        return bins;
    }

    if (!value->is_array()) {
        const auto target = powershell_note_string(*value);
        bins.push_back(ManifestBin{.target = target, .name = strip_extension(std::filesystem::path(target).filename().string())});
        return bins;
    }

    for (const auto& item : *value) {
        if (item.is_string()) {
            const auto target = item.get<std::string>();
            bins.push_back(ManifestBin{.target = target, .name = strip_extension(std::filesystem::path(target).filename().string())});
        } else if (!item.is_array()) {
            if (item.is_null()) {
                continue;
            }
            const auto target = powershell_note_string(item);
            bins.push_back(ManifestBin{.target = target, .name = strip_extension(std::filesystem::path(target).filename().string())});
        } else if (item.is_array() && !item.empty() && item.front().is_string()) {
            ManifestBin bin;
            bin.target = item.front().get<std::string>();
            bin.name = item.size() > 1 && item.at(1).is_string()
                ? item.at(1).get<std::string>()
                : strip_extension(std::filesystem::path(bin.target).filename().string());
            bin.args = item.size() > 2 && !item.at(2).is_null() ? args_value(item.at(2), "bin args") : std::string{};
            bins.push_back(std::move(bin));
        } else {
            throw ManifestError("bin entries must be strings or arrays whose first item is a string");
        }
    }

    return bins;
}

std::vector<ManifestPersist> collect_persists(const nlohmann::json& object) {
    std::vector<ManifestPersist> persists;
    const auto* value = json_property(object, "persist");
    if (value == nullptr || value->is_null()) {
        return persists;
    }

    const auto append_string = [&](const std::string& value) {
        persists.push_back(ManifestPersist{.source = value, .target = value});
    };

    const auto append_array = [&](const nlohmann::json& value) {
        if (value.empty() || !value.front().is_string()) {
            throw ManifestError("persist entries must be strings or arrays whose first item is a string");
        }
        ManifestPersist persist;
        persist.source = value.front().get<std::string>();
        persist.target = value.size() > 1 && value.at(1).is_string()
            ? value.at(1).get<std::string>()
            : persist.source;
        persists.push_back(std::move(persist));
    };

    const auto is_powershell_falsy_persist = [](const nlohmann::json& item) {
        if (item.is_null()) {
            return true;
        }
        if (item.is_string()) {
            return item.get<std::string>().empty();
        }
        if (item.is_boolean()) {
            return !item.get<bool>();
        }
        if (item.is_number_integer()) {
            return item.get<long long>() == 0;
        }
        if (item.is_number_unsigned()) {
            return item.get<unsigned long long>() == 0;
        }
        if (item.is_number_float()) {
            return item.get<double>() == 0.0;
        }
        if (item.is_array()) {
            return item.empty();
        }
        return false;
    };

    if (value->is_string()) {
        if (!value->get<std::string>().empty()) {
            append_string(value->get<std::string>());
        }
        return persists;
    }

    if (!value->is_array()) {
        if (is_powershell_falsy_persist(*value)) {
            return persists;
        }
        throw ManifestError("persist must be a string or an array");
    }

    if (value->size() == 1 && is_powershell_falsy_persist(value->front())) {
        return persists;
    }

    for (const auto& item : *value) {
        if (item.is_string()) {
            append_string(item.get<std::string>());
        } else if (item.is_array()) {
            append_array(item);
        } else {
            throw ManifestError("persist entries must be strings or arrays");
        }
    }

    return persists;
}

std::vector<ManifestShortcut> collect_shortcuts(const nlohmann::json& object) {
    std::vector<ManifestShortcut> shortcuts;
    const auto* value = json_property(object, "shortcuts");
    if (value == nullptr || value->is_null()) {
        return shortcuts;
    }
    if (!powershell_truthy_json(*value)) {
        return shortcuts;
    }

    if (!value->is_array()) {
        throw ManifestError("shortcuts must be an array");
    }

    for (const auto& item : *value) {
        if (!item.is_array() || item.size() < 2) {
            throw ManifestError("shortcut entries must be arrays with target and name values");
        }
        ManifestShortcut shortcut;
        shortcut.target = powershell_note_string(item.at(0));
        shortcut.name = powershell_note_string(item.at(1));
        shortcut.args = item.size() > 2 && !item.at(2).is_null() ? args_value(item.at(2), "shortcut args") : std::string{};
        shortcut.has_icon = item.size() > 3;
        shortcut.icon = shortcut.has_icon && !item.at(3).is_null() ? powershell_note_string(item.at(3)) : std::string{};
        shortcuts.push_back(std::move(shortcut));
    }
    return shortcuts;
}

std::map<std::string, std::string> collect_env_set(const nlohmann::json& object) {
    std::map<std::string, std::string> values;
    const auto* env_set = json_property(object, "env_set");
    if (env_set == nullptr || env_set->is_null()) {
        return values;
    }
    if (!powershell_truthy_json(*env_set)) {
        return values;
    }

    if (!env_set->is_object()) {
        throw ManifestError("env_set must be an object");
    }

    for (const auto& item : env_set->items()) {
        const auto& value = item.value();
        if (value.is_string()) {
            values[item.key()] = value.get<std::string>();
        } else if (value.is_boolean()) {
            values[item.key()] = value.get<bool>() ? "True" : "False";
        } else if (value.is_number()) {
            values[item.key()] = value.dump();
        } else if (value.is_null()) {
            values[item.key()] = {};
        } else {
            throw ManifestError("env_set values must be scalar values");
        }
    }
    return values;
}

std::vector<std::pair<std::string, std::string>> collect_ordered_cookie_values(const nlohmann::ordered_json& object) {
    std::vector<std::pair<std::string, std::string>> values;
    const auto* cookies = ordered_json_property(object, "cookie");
    if (cookies == nullptr || cookies->is_null()) {
        return values;
    }
    if (!powershell_truthy_json(*cookies)) {
        return values;
    }

    if (!cookies->is_object()) {
        throw ManifestError("cookie must be an object");
    }

    for (const auto& item : cookies->items()) {
        const auto& value = item.value();
        if (value.is_string()) {
            values.emplace_back(item.key(), value.get<std::string>());
        } else if (value.is_boolean()) {
            values.emplace_back(item.key(), value.get<bool>() ? "True" : "False");
        } else if (value.is_number()) {
            values.emplace_back(item.key(), value.dump());
        } else if (value.is_null()) {
            values.emplace_back(item.key(), std::string{});
        } else {
            throw ManifestError("cookie values must be scalar values");
        }
    }
    return values;
}

std::map<std::string, std::vector<std::string>> collect_suggestions(const nlohmann::json& object) {
    std::map<std::string, std::vector<std::string>> values;
    const auto* suggest = json_property(object, "suggest");
    if (suggest == nullptr || suggest->is_null()) {
        return values;
    }
    if (!powershell_truthy_json(*suggest)) {
        return values;
    }

    if (!suggest->is_object()) {
        return values;
    }

    for (const auto& item : suggest->items()) {
        values[item.key()] = scalar_string_or_array(item.value());
    }
    return values;
}

std::string psmodule_name(const nlohmann::json& object) {
    const auto* psmodule = json_property(object, "psmodule");
    if (psmodule == nullptr || psmodule->is_null()) {
        return {};
    }
    if (!powershell_truthy_json(*psmodule)) {
        return {};
    }

    const auto* name_value = psmodule->is_object() ? json_property(*psmodule, "name") : nullptr;
    if (name_value != nullptr && name_value->is_string()) {
        auto name = name_value->get<std::string>();
        if (!name.empty()) {
            return name;
        }
    }
    throw ManifestError("Invalid manifest: The 'name' property is missing from 'psmodule'.");
}

std::string optional_string(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value != nullptr && value->is_string()) {
        return value->get<std::string>();
    }
    return {};
}

std::string powershell_scalar_string(const nlohmann::json& value) {
    if (value.is_string()) {
        return value.get<std::string>();
    }
    if (value.is_boolean()) {
        return value.get<bool>() ? "True" : "False";
    }
    if (value.is_number_integer()) {
        return std::to_string(value.get<long long>());
    }
    if (value.is_number_unsigned()) {
        return std::to_string(value.get<unsigned long long>());
    }
    if (value.is_number_float()) {
        std::ostringstream stream;
        stream << value.get<double>();
        return stream.str();
    }
    return {};
}

std::string optional_powershell_scalar_string(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value != nullptr && powershell_truthy_json(*value)) {
        return powershell_scalar_string(*value);
    }
    return {};
}

std::string powershell_object_string(const nlohmann::json& value) {
    if (!value.is_object()) {
        return powershell_scalar_string(value);
    }
    std::string result = "@{";
    auto first = true;
    for (const auto& item : value.items()) {
        if (!first) {
            result += "; ";
        }
        first = false;
        result += item.key();
        result += '=';
        result += powershell_scalar_string(item.value());
    }
    result += '}';
    return result;
}

std::string powershell_note_string(const nlohmann::json& value) {
    if (value.is_object()) {
        return powershell_object_string(value);
    }
    return powershell_scalar_string(value);
}

std::vector<std::string> collect_notes(const nlohmann::json& object) {
    std::vector<std::string> values;
    const auto* notes = json_property(object, "notes");
    if (notes == nullptr || notes->is_null()) {
        return values;
    }
    if (!powershell_truthy_json(*notes)) {
        return values;
    }

    if (notes->is_array()) {
        for (const auto& item : *notes) {
            values.push_back(powershell_note_string(item));
        }
        return values;
    }

    values.push_back(powershell_note_string(*notes));
    return values;
}

std::vector<std::string> collect_powershell_string_or_array(const nlohmann::json& object, const char* key) {
    std::vector<std::string> values;
    const auto* value = json_property(object, key);
    if (value == nullptr || value->is_null()) {
        return values;
    }
    if (!powershell_truthy_json(*value)) {
        return values;
    }

    if (value->is_array()) {
        for (const auto& item : *value) {
            values.push_back(powershell_note_string(item));
        }
        return values;
    }

    values.push_back(powershell_note_string(*value));
    return values;
}

bool optional_bool(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    return value != nullptr && powershell_truthy_json(*value);
}

std::pair<std::string, std::string> license_value(const nlohmann::json& object) {
    const auto* license = json_property(object, "license");
    if (license == nullptr || license->is_null()) {
        return {};
    }
    if (!license->is_object()) {
        return powershell_truthy_json(*license) ? std::pair<std::string, std::string>{powershell_scalar_string(*license), {}} : std::pair<std::string, std::string>{};
    }
    if (license->is_object()) {
        auto identifier = std::string{};
        auto url = std::string{};
        if (const auto* identifier_value = json_property(*license, "identifier"); identifier_value != nullptr && powershell_truthy_json(*identifier_value)) {
            identifier = powershell_scalar_string(*identifier_value);
        }
        if (const auto* url_value = json_property(*license, "url"); url_value != nullptr && powershell_truthy_json(*url_value)) {
            url = powershell_scalar_string(*url_value);
        }
        if (!identifier.empty()) {
            return {identifier, url};
        }
        return {powershell_object_string(*license), {}};
    }
    return {};
}

ManifestCommand object_command(const nlohmann::json& object, const char* key) {
    ManifestCommand command;
    const auto* value = json_property(object, key);
    if (value == nullptr || value->is_null()) {
        return command;
    }
    if (!powershell_truthy_json(*value)) {
        return command;
    }

    if (!value->is_object()) {
        throw ManifestError(std::string(key) + " must be an object");
    }
    command.script = string_or_array(*value, "script");
    command.file = optional_string(*value, "file");
    command.args = string_or_array(*value, "args");
    const auto* keep = json_property(*value, "keep");
    if (keep != nullptr) {
        command.keep = powershell_truthy_json(*keep);
    }
    return command;
}

bool string_or_array_has_value(const nlohmann::json& object, const char* key) {
    const auto* value = json_property(object, key);
    if (value == nullptr || value->is_null()) {
        return false;
    }
    if (value->is_string()) {
        return !value->get<std::string>().empty();
    }
    if (!value->is_array()) {
        return false;
    }
    for (const auto& item : *value) {
        if (item.is_string() && !item.get<std::string>().empty()) {
            return true;
        }
    }
    return false;
}

bool architecture_override_has_value(const nlohmann::json& value) {
    return powershell_truthy_json(value);
}

std::optional<char> unsupported_version_character(const std::string& version) {
    for (const auto ch : version) {
        const auto value = static_cast<unsigned char>(ch);
        if (std::isalnum(value) != 0 || ch == '.' || ch == '-' || ch == '+' || ch == '_') {
            continue;
        }
        return ch;
    }
    return std::nullopt;
}

bool architecture_url_available(const nlohmann::json& root, const std::string& architecture) {
    if (const auto* architectures = json_property(root, "architecture"); architectures != nullptr && architectures->is_object()) {
        if (const auto* selected = json_property(*architectures, architecture); selected != nullptr && selected->is_object() &&
            string_or_array_has_value(*selected, "url")) {
            return true;
        }
    }
    return string_or_array_has_value(root, "url");
}

bool manifest_mentions_arm64(const nlohmann::json& value) {
    if (value.is_object()) {
        for (const auto& item : value.items()) {
            if (lower_ascii(item.key()) == "arm64" || manifest_mentions_arm64(item.value())) {
                return true;
            }
        }
        return false;
    }
    if (value.is_array()) {
        for (const auto& item : value) {
            if (manifest_mentions_arm64(item)) {
                return true;
            }
        }
        return false;
    }
    return value.is_string() && lower_ascii(value.get<std::string>()) == "arm64";
}

unsigned long windows_build_number() {
#ifdef _WIN32
    using RtlGetVersionFn = long(WINAPI*)(OSVERSIONINFOW*);
    const auto ntdll = GetModuleHandleW(L"ntdll.dll");
    if (ntdll != nullptr) {
        const auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));
        if (rtl_get_version != nullptr) {
            OSVERSIONINFOW version{};
            version.dwOSVersionInfoSize = sizeof(version);
            if (rtl_get_version(&version) == 0) {
                return version.dwBuildNumber;
            }
        }
    }
#endif
    return 22000;
}

std::string arm64_fallback_architecture() {
    return windows_build_number() >= 22000 ? "64bit" : "32bit";
}

std::string resolve_supported_architecture(const nlohmann::json& root, const std::string& requested) {
    if (requested != "arm64") {
        return requested;
    }
    if (manifest_mentions_arm64(root)) {
        return "arm64";
    }

    const auto fallback = arm64_fallback_architecture();
    if (architecture_url_available(root, fallback)) {
        return fallback;
    }
    return requested;
}

nlohmann::json select_architecture_view(const nlohmann::json& root, const std::string& architecture) {
    auto view = root;
    const auto* architectures = json_property(root, "architecture");
    if (architectures == nullptr || architectures->is_null()) {
        return view;
    }
    if (!powershell_truthy_json(*architectures)) {
        return view;
    }

    if (!architectures->is_object()) {
        return view;
    }

    const auto* selected = json_property(*architectures, architecture);
    if (selected == nullptr || selected->is_null()) {
        return view;
    }
    if (!powershell_truthy_json(*selected)) {
        return view;
    }

    if (!selected->is_object()) {
        return view;
    }

    for (const auto& item : selected->items()) {
        if (architecture_override_has_value(item.value())) {
            set_json_property(view, item.key(), item.value());
        }
    }
    return view;
}

} // namespace

ManifestError::ManifestError(const std::string& message) : std::runtime_error(message) {}

Manifest load_manifest_file(
    const std::filesystem::path& path,
    std::optional<std::string> forced_name,
    std::string architecture) {
    std::ifstream stream(path);
    if (!stream) {
        throw ManifestError("cannot open " + path.string());
    }

    const std::string manifest_text((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());

    nlohmann::json root;
    nlohmann::ordered_json ordered_root;
    try {
        root = nlohmann::json::parse(manifest_text);
        ordered_root = nlohmann::ordered_json::parse(manifest_text);
    } catch (const nlohmann::json::exception& error) {
        throw ManifestError(std::string("invalid JSON: ") + error.what());
    }

    if (!root.is_object()) {
        throw ManifestError("manifest root must be a JSON object");
    }

    const auto* version_value = json_property(root, "version");
    if (version_value == nullptr || !version_value->is_string()) {
        throw ManifestError("manifest must contain a string version");
    }

    const auto manifest_version = version_value->get<std::string>();
    if (manifest_version.empty()) {
        throw ManifestError("Manifest doesn't specify a version.");
    }
    if (const auto unsupported = unsupported_version_character(manifest_version)) {
        throw ManifestError(std::string("Manifest version has unsupported character '") + *unsupported + "'.");
    }

    architecture = resolve_supported_architecture(root, architecture);
    const auto view = select_architecture_view(root, architecture);

    Manifest manifest;
    manifest.name = forced_name.value_or(path.stem().string());
    manifest.version = manifest_version;
    manifest.architecture = std::move(architecture);
    manifest.supports_current_architecture = string_or_array_has_value(view, "url");
    manifest.description = optional_powershell_scalar_string(root, "description");
    manifest.homepage = optional_string(root, "homepage");
    const auto [license, license_url] = license_value(root);
    manifest.license = license;
    manifest.license_url = license_url;
    manifest.innosetup = optional_bool(root, "innosetup");
    manifest.cookies = collect_ordered_cookie_values(ordered_root);
    manifest.urls = string_or_array(view, "url");
    manifest.hashes = string_or_array(view, "hash");
    manifest.extract_dirs = string_or_array(view, "extract_dir");
    manifest.extract_tos = string_or_array(view, "extract_to");
    manifest.depends = collect_powershell_string_or_array(view, "depends");
    manifest.env_add_path = collect_powershell_string_or_array(view, "env_add_path");
    manifest.env_set = collect_env_set(view);
    manifest.pre_install = string_or_array(view, "pre_install");
    manifest.post_install = string_or_array(view, "post_install");
    manifest.installer = object_command(view, "installer");
    manifest.pre_uninstall = string_or_array(view, "pre_uninstall");
    manifest.post_uninstall = string_or_array(view, "post_uninstall");
    manifest.uninstaller = object_command(view, "uninstaller");
    manifest.notes = collect_notes(root);
    manifest.psmodule_name = psmodule_name(root);
    manifest.suggestions = collect_suggestions(root);
    manifest.shortcuts = collect_shortcuts(view);
    manifest.persists = collect_persists(view);
    manifest.bins = collect_bins(view);
    return manifest;
}

} // namespace sco
