#include "sco/versions.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

struct VersionCase {
    std::string reference;
    std::string difference;
    int expected = 0;
    bool update_nightly = false;
};

int check_case(const VersionCase& test_case) {
    const auto actual = test_case.update_nightly
        ? sco::compare_versions(test_case.reference, test_case.difference, true)
        : sco::compare_versions(test_case.reference, test_case.difference);
    if (actual == test_case.expected) {
        return 0;
    }

    std::cerr << "compare_versions('" << test_case.reference << "', '" << test_case.difference << "'";
    if (test_case.update_nightly) {
        std::cerr << ", update_nightly=true";
    }
    std::cerr << ") returned " << actual << ", expected " << test_case.expected << '\n';
    return 1;
}

} // namespace

int main() {
    const std::vector<VersionCase> cases{
        {"0.1.0", "0.1.1", 1},
        {"0.1.1", "0.2.0", 1},
        {"0.2.0", "1.0.0", 1},
        {"0.4.0", "0.5.0-alpha.1", 1},
        {"0.5.0-alpha.1", "0.5.0-alpha.2", 1},
        {"0.5.0-alpha.2", "0.5.0-alpha.10", 1},
        {"0.5.0-alpha.10", "0.5.0-beta", 1},
        {"0.5.0-beta", "0.5.0-alpha.10", -1},
        {"0.5.0-beta", "0.5.0-beta.0", 1},
        {"0.5.0-rc.1", "0.5.0-z", 1},
        {"0.5.0-rc.1", "0.5.0-howdy", -1},
        {"0.5.0-howdy", "0.5.0-rc.1", 1},
        {"0.0.0.0", "0.0.0.1", 1},
        {"0.0.0.1", "0.0.0.2", 1},
        {"0.0.0.2", "0.0.1.0", 1},
        {"0.0.1.0", "0.0.1.1", 1},
        {"0.0.1.1", "0.0.1.2", 1},
        {"0.0.1.2", "0.0.2.0", 1},
        {"0.0.2.0", "0.1.0.0", 1},
        {"0.1.0.0", "0.1.0.1", 1},
        {"0.1.0.1", "0.1.0.2", 1},
        {"0.1.0.2", "0.1.1.0", 1},
        {"0.1.1.0", "0.1.1.1", 1},
        {"0.1.1.1", "0.1.1.2", 1},
        {"0.1.1.2", "0.2.0.0", 1},
        {"0.2.0.0", "1.0.0.0", 1},
        {"1", "1.1", 1},
        {"1", "1.0", 1},
        {"1.1.0.0", "1.1", -1},
        {"1.4", "1.3.0", -1},
        {"1.4", "1.3.255.255", -1},
        {"1.4", "1.4.4", 1},
        {"1.1.1_8", "1.1.1", -1},
        {"1.1.1_8", "1.1.1_9", 1},
        {"1.1.1_10", "1.1.1_9", -1},
        {"1.1.1b", "1.1.1a", -1},
        {"1.1.1a", "1.1.1b", 1},
        {"1.1a2", "1.1a3", 1},
        {"1.1.1a10", "1.1.1b1", 1},
        {"1.8.9", "1.8.5-1", -1},
        {"7.0.4-9", "7.0.4-10", 1},
        {"7.0.4-9", "7.0.4-8", -1},
        {"2019-01-01", "2019-01-02", 1},
        {"2019-01-02", "2019-01-01", -1},
        {"2018-01-01", "2019-01-01", 1},
        {"2019-01-01", "2018-01-01", -1},
        {"1", "1+hotfix.0", 1},
        {"1.0.0", "1.0.0+hotfix.0", 1},
        {"1.0.0+hotfix.0", "1.0.0+hotfix.1", 1},
        {"1.0.0+hotfix.1", "1.0.1", 1},
        {"1.0.0+1.1", "1.0.0+1", -1},
        {"latest", "20150405", -1},
        {"0.5alpha", "0.5", 1},
        {"0.5", "0.5Beta", -1},
        {"0.4", "0.5Beta", 1},
        {"7.0.4-9", "", -1},
        {"12.0", "12.0", 0},
        {"7.0.4-9", "7.0.4-9", 0},
        {"nightly-20190801", "nightly", 0},
        {"nightly-20190801", "nightly-20200801", 0},
        {"nightly-19000101", "nightly", 1, true},
        {"nightly-19000101", "nightly-29991231", 1, true},
        {"nightly-29991231", "nightly", -1, true},
        {"nightly-29991231", "nightly-19000101", -1, true},
    };

    int failures = 0;
    for (const auto& test_case : cases) {
        failures += check_case(test_case);
    }

    return failures == 0 ? 0 : 1;
}
