#pragma once

#include <iosfwd>
#include <string>
#include <vector>

namespace sco {

class Cli {
public:
    int run(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) const;

private:
    static void print_help(std::ostream& out);
    static void print_version(std::ostream& out);
    static int run_help(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int inspect_manifest(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_alias(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_config(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_cat(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_checkurls(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_checkhashes(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_checkup(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_checkver(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_describe(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_missing_checkver(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_create(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_depends(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_download(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_export(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_formatjson(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_init(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_install(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_uninstall(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_update(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_virustotal(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_cleanup(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_cache(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_hold(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_home(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_import(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_unhold(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_info(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_prefix(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_reset(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_shim(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_which(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_list(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_status(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_search(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
    static int run_bucket(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);
};

} // namespace sco
