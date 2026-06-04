#pragma once

#include <optional>
#include <string>

namespace sco {

std::optional<std::string> select_xml_xpath_text(
    const std::string& text,
    const std::string& xpath,
    const std::string& parse_error_context,
    const std::string& xpath_error_context);

}
