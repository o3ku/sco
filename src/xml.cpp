#include "sco/xml.hpp"

#include <pugixml.hpp>

#include <stdexcept>

namespace sco {

namespace {

std::optional<std::string> xpath_node_text(const pugi::xpath_node& selected) {
    if (!selected) {
        return std::nullopt;
    }

    if (const auto attribute = selected.attribute()) {
        const std::string value = attribute.value();
        return value.empty() ? std::nullopt : std::optional<std::string>{value};
    }

    const auto node = selected.node();
    if (!node) {
        return std::nullopt;
    }

    const auto value = node.type() == pugi::node_pcdata || node.type() == pugi::node_cdata
        ? std::string(node.value())
        : std::string(node.text().as_string());
    return value.empty() ? std::nullopt : std::optional<std::string>{value};
}

bool is_xpath_name_char(char ch) {
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.';
}

std::string strip_default_namespace_prefixes(const std::string& xpath) {
    std::string stripped;
    stripped.reserve(xpath.size());

    char quote = '\0';
    for (std::size_t i = 0; i < xpath.size();) {
        const auto ch = xpath[i];
        if (quote != '\0') {
            stripped.push_back(ch);
            if (ch == quote) {
                quote = '\0';
            }
            ++i;
            continue;
        }

        if (ch == '\'' || ch == '"') {
            quote = ch;
            stripped.push_back(ch);
            ++i;
            continue;
        }

        if (xpath.compare(i, 3, "ns:") == 0 && (i == 0 || !is_xpath_name_char(xpath[i - 1]))) {
            i += 3;
            continue;
        }

        stripped.push_back(ch);
        ++i;
    }

    return stripped;
}

std::optional<std::string> select_xpath_text(const pugi::xml_document& document, const std::string& xpath) {
    return xpath_node_text(document.select_node(xpath.c_str()));
}

} // namespace

std::optional<std::string> select_xml_xpath_text(
    const std::string& text,
    const std::string& xpath,
    const std::string& parse_error_context,
    const std::string& xpath_error_context) {
    pugi::xml_document document;
    const auto result = document.load_buffer(text.data(), text.size());
    if (!result) {
        throw std::runtime_error("cannot parse " + parse_error_context + ": " + std::string(result.description()));
    }

    try {
        if (const auto value = select_xpath_text(document, xpath)) {
            return value;
        }

        if (xpath.find("ns:") != std::string::npos) {
            const auto stripped = strip_default_namespace_prefixes(xpath);
            if (stripped != xpath) {
                return select_xpath_text(document, stripped);
            }
        }

        return std::nullopt;
    } catch (const pugi::xpath_exception& error) {
        throw std::runtime_error("invalid " + xpath_error_context + " '" + xpath + "': " + error.what());
    }
}

} // namespace sco
