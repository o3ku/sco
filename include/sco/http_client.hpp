#pragma once

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace sco {

struct HttpResponse {
    int status = 0;
    std::string body;
    std::string error;
    std::map<std::string, std::string> headers;
};

class HttpClient {
public:
    HttpResponse get(const std::string& url) const;
    HttpResponse get(const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers) const;
    HttpResponse get(
        const std::string& url,
        const std::vector<std::pair<std::string, std::string>>& headers,
        std::optional<int> timeout_seconds) const;
    HttpResponse head(const std::string& url) const;
    HttpResponse head(const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers) const;
    HttpResponse head_no_redirect(const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers) const;
    HttpResponse post(
        const std::string& url,
        const std::vector<std::pair<std::string, std::string>>& headers,
        const std::string& body,
        const std::string& content_type) const;
};

} // namespace sco
