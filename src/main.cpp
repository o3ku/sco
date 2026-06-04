#include "sco/cli.hpp"
#include "sco/installer.hpp"

#include <iostream>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

int wmain(int argc, wchar_t** argv) {
    const auto shim_result = sco::try_run_as_shim(argc, argv);
    if (shim_result >= 0) {
        return shim_result;
    }

    std::vector<std::string> args;
    args.reserve(static_cast<std::size_t>(argc > 0 ? argc - 1 : 0));

    for (int i = 1; i < argc; ++i) {
        std::wstring wide(argv[i]);
        if (wide.empty()) {
            args.emplace_back();
            continue;
        }
        auto size = WideCharToMultiByte(CP_UTF8, 0,
            wide.data(), static_cast<int>(wide.size()),
            nullptr, 0, nullptr, nullptr);
        if (size == 0) {
            args.emplace_back();
            continue;
        }
        std::string narrow(static_cast<std::size_t>(size), '\0');
        WideCharToMultiByte(CP_UTF8, 0,
            wide.data(), static_cast<int>(wide.size()),
            narrow.data(), size, nullptr, nullptr);
        args.push_back(std::move(narrow));
    }

    const sco::Cli cli;
    return cli.run(args, std::cout, std::cerr);
}
