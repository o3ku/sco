#include "sco/http_client.hpp"

#include <httplib.h>

#include <algorithm>
#include <cctype>
#include <map>
#include <optional>
#include <regex>
#include <ctime>
#include <vector>

namespace sco {

namespace {

constexpr int max_redirects = 5;

struct ParsedUrl {
    std::string scheme;
    std::string host;
    std::string path;
};

enum class HttpMethod {
    get,
    head,
};

std::string lowercase(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::optional<ParsedUrl> parse_url(const std::string& url) {
    static const std::regex pattern(R"(^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/]+)(/.*)?$)");
    std::smatch match;
    if (!std::regex_match(url, match, pattern)) {
        return std::nullopt;
    }

    ParsedUrl parsed;
    parsed.scheme = lowercase(match[1].str());
    parsed.host = match[2].str();
    parsed.path = match[3].matched ? match[3].str() : "/";
    return parsed;
}

httplib::Headers request_headers_from(const std::vector<std::pair<std::string, std::string>>& headers) {
    httplib::Headers request_headers;
    for (const auto& header : headers) {
        request_headers.emplace(header.first, header.second);
    }
    return request_headers;
}

std::map<std::string, std::string> response_headers_from(const httplib::Headers& headers) {
    std::map<std::string, std::string> response_headers;
    for (const auto& header : headers) {
        response_headers[lowercase(header.first)] = header.second;
    }
    return response_headers;
}

void apply_timeout(httplib::Client& client, std::optional<int> timeout_seconds) {
    if (!timeout_seconds) {
        return;
    }
    const auto seconds = static_cast<time_t>(std::max(0, *timeout_seconds));
    client.set_connection_timeout(seconds, 0);
    client.set_read_timeout(seconds, 0);
    client.set_write_timeout(seconds, 0);
}

bool is_redirect_status(int status) {
    return status >= 300 && status < 400;
}

std::optional<std::string> header_value(const std::map<std::string, std::string>& headers, const std::string& name) {
    const auto found = headers.find(lowercase(name));
    if (found == headers.end()) {
        return std::nullopt;
    }
    return found->second;
}

bool is_absolute_http_url(const std::string& value) {
    const auto parsed = parse_url(value);
    return parsed && (parsed->scheme == "http" || parsed->scheme == "https");
}

std::string resolve_redirect_url(const ParsedUrl& current, const std::string& location) {
    if (is_absolute_http_url(location)) {
        return location;
    }

    const auto origin = current.scheme + "://" + current.host;
    if (!location.empty() && location.front() == '/') {
        return origin + location;
    }

    auto base_path = current.path;
    const auto slash = base_path.find_last_of('/');
    base_path = slash == std::string::npos ? "/" : base_path.substr(0, slash + 1);
    return origin + base_path + location;
}

HttpResponse request_once(
    HttpMethod method,
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    std::optional<int> timeout_seconds) {
    const auto parsed = parse_url(url);
    if (!parsed) {
        return {.status = 0, .body = {}, .error = "invalid URL"};
    }

    if (parsed->scheme != "http" && parsed->scheme != "https") {
        return {.status = 0, .body = {}, .error = "unsupported URL scheme"};
    }

#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
    httplib::Client client(parsed->scheme + "://" + parsed->host);
#else
    if (parsed->scheme == "https") {
        return {.status = 0, .body = {}, .error = "HTTPS support is not enabled in cpp-httplib"};
    }
    httplib::Client client(parsed->host);
#endif

    apply_timeout(client, timeout_seconds);
    const auto request_headers = request_headers_from(headers);

    httplib::Result response;
    if (method == HttpMethod::head) {
        response = request_headers.empty() ? client.Head(parsed->path) : client.Head(parsed->path, request_headers);
    } else {
        response = request_headers.empty() ? client.Get(parsed->path) : client.Get(parsed->path, request_headers);
    }

    if (response) {
        return {.status = response->status, .body = response->body, .error = {}, .headers = response_headers_from(response->headers)};
    }

    return {.status = 0, .body = {}, .error = "request failed"};
}

HttpResponse request_with_redirects(
    HttpMethod method,
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    std::optional<int> timeout_seconds) {
    auto current_url = url;
    for (int redirect = 0; redirect <= max_redirects; ++redirect) {
        auto response = request_once(method, current_url, headers, timeout_seconds);
        if (!is_redirect_status(response.status)) {
            return response;
        }

        const auto parsed = parse_url(current_url);
        const auto location = header_value(response.headers, "location");
        if (!parsed || !location || location->empty()) {
            return response;
        }
        current_url = resolve_redirect_url(*parsed, *location);
    }

    return {.status = 0, .body = {}, .error = "too many redirects"};
}

} // namespace

HttpResponse HttpClient::get(const std::string& url) const {
    return get(url, {});
}

HttpResponse HttpClient::get(const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers) const {
    return get(url, headers, 30);
}

HttpResponse HttpClient::get(
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    std::optional<int> timeout_seconds) const {
    return request_with_redirects(HttpMethod::get, url, headers, timeout_seconds);
}

HttpResponse HttpClient::head(const std::string& url) const {
    return head(url, {});
}

HttpResponse HttpClient::head(const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers) const {
    return request_with_redirects(HttpMethod::head, url, headers, 30);
}

HttpResponse HttpClient::head_no_redirect(
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers) const {
    return request_once(HttpMethod::head, url, headers, 30);
}

HttpResponse HttpClient::post(
    const std::string& url,
    const std::vector<std::pair<std::string, std::string>>& headers,
    const std::string& body,
    const std::string& content_type) const {
    const auto parsed = parse_url(url);
    if (!parsed) {
        return {.status = 0, .body = {}, .error = "invalid URL"};
    }

    if (parsed->scheme != "http" && parsed->scheme != "https") {
        return {.status = 0, .body = {}, .error = "unsupported URL scheme"};
    }

#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
    httplib::Client client(parsed->scheme + "://" + parsed->host);
#else
    if (parsed->scheme == "https") {
        return {.status = 0, .body = {}, .error = "HTTPS support is not enabled in cpp-httplib"};
    }
    httplib::Client client(parsed->host);
#endif

    client.set_follow_location(true);
    client.set_connection_timeout(30, 0);
    client.set_read_timeout(30, 0);
    client.set_write_timeout(30, 0);
    const auto request_headers = request_headers_from(headers);

    if (const auto response = client.Post(parsed->path, request_headers, body, content_type)) {
        return {.status = response->status, .body = response->body, .error = {}, .headers = response_headers_from(response->headers)};
    }

    return {.status = 0, .body = {}, .error = "request failed"};
}

} // namespace sco
