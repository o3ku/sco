cmake_minimum_required(VERSION 3.25)

project(sco VERSION 0.5.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(httplib CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(pugixml CONFIG REQUIRED)
find_package(ZLIB REQUIRED)

add_executable(sco
    src/apps.cpp
    src/artifact.cpp
    src/buckets.cpp
    src/cache.cpp
    src/checkver.cpp
    src/cli.cpp
    src/compression.cpp
    src/config.cpp
    src/environment.cpp
    src/envvars.cpp
    src/http_client.cpp
    src/installer.cpp
    src/main.cpp
    src/manifest.cpp
    src/table.cpp
    src/versions.cpp
    src/xml.cpp
)

target_include_directories(sco
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(sco
    PRIVATE
        bcrypt
        httplib::httplib
        nlohmann_json::nlohmann_json
        OpenSSL::SSL
        OpenSSL::Crypto
        pugixml::pugixml
        ZLIB::ZLIB
)

target_compile_definitions(sco PRIVATE _CRT_SECURE_NO_WARNINGS SCO_VERSION="${PROJECT_VERSION}")

add_executable(sco_versions_tests
    src/versions.cpp
    test/versions-test.cpp
)

target_include_directories(sco_versions_tests
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

if(MSVC)
    target_compile_options(sco PRIVATE /W4 /permissive-)
else()
    target_compile_options(sco PRIVATE -Wall -Wextra -Wpedantic)
endif()

enable_testing()

add_test(NAME sco_version COMMAND sco --version)
set_tests_properties(sco_version PROPERTIES PASS_REGULAR_EXPRESSION "sco 0\\.5\\.1")

add_test(NAME sco_versions_compare COMMAND sco_versions_tests)

add_test(NAME sco_help COMMAND sco help)
set_tests_properties(sco_help PROPERTIES PASS_REGULAR_EXPRESSION "Usage: sco <command>")

add_test(
    NAME sco_help_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/help-command.ps1"
        "$<TARGET_FILE:sco>"
)

add_test(
    NAME sco_init_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/init-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-init-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-init-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/ref/test/fixtures/manifest/wget.json")
    add_test(
        NAME sco_manifest_wget
        COMMAND sco manifest "${CMAKE_CURRENT_SOURCE_DIR}/ref/test/fixtures/manifest/wget.json"
    )
    set_tests_properties(sco_manifest_wget PROPERTIES PASS_REGULAR_EXPRESSION "urls: 2")
endif()

set(SCO_TEST_ENV
    "SCOOP=${CMAKE_CURRENT_SOURCE_DIR}/testdata/scoop-home"
    "XDG_CONFIG_HOME=${CMAKE_CURRENT_BINARY_DIR}/test-config"
)

add_test(NAME sco_prefix_demo COMMAND sco prefix demo)
set_tests_properties(sco_prefix_demo PROPERTIES
    ENVIRONMENT "${SCO_TEST_ENV}"
    PASS_REGULAR_EXPRESSION "testdata.*/scoop-home.*/apps.*/demo.*/current"
)

add_test(
    NAME sco_prefix_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/prefix-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-prefix-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-prefix-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-prefix-config"
)

add_test(NAME sco_list_demo COMMAND sco list)
set_tests_properties(sco_list_demo PROPERTIES
    ENVIRONMENT "${SCO_TEST_ENV}"
    PASS_REGULAR_EXPRESSION "demo"
)

add_test(
    NAME sco_list_query_regex
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/list-query.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/scoop-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-config"
)

add_test(
    NAME sco_scoop_paired_install_list_uninstall
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/pair-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-pair-command-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-pair-command-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_scoop_paired_help_commands
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-help-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-help-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-help-config"
)

add_test(
    NAME sco_scoop_paired_basic_output
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-basic-output.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-basic-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-basic-config"
)

add_test(
    NAME sco_scoop_paired_state_commands
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-state-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-state-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-state-config"
)

add_test(
    NAME sco_scoop_paired_installed_commands
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-installed-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-installed-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-installed-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_scoop_paired_manifest_commands
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-manifest-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-manifest-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-manifest-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_scoop_paired_import_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-import-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-import-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-import-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_scoop_paired_update_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-update-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-update-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-update-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_scoop_paired_helper_commands
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/paired-helper-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/ref/bin/scoop.ps1"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-helper-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-paired-helper-config"
)

add_test(NAME sco_config_unset COMMAND sco config missing_key)
set_tests_properties(sco_config_unset PROPERTIES
    ENVIRONMENT "${SCO_TEST_ENV}"
    PASS_REGULAR_EXPRESSION "'missing_key' is not set"
)

add_test(
    NAME sco_config_get_set_rm
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/config-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-config-command-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-config-command-config"
)

add_test(
    NAME sco_alias_add_list_run_rm
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/alias-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-alias-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-alias-config"
)

add_test(NAME sco_search_demo COMMAND sco search grep)
set_tests_properties(sco_search_demo PROPERTIES
    ENVIRONMENT "${SCO_TEST_ENV}"
    PASS_REGULAR_EXPRESSION "grep"
)

add_test(
    NAME sco_shim_add_list_info_rm
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/shim-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-shim-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-shim-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_shim_alter_duplicate_provider
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/shim-alter.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-shim-alter-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-shim-alter-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_create_manifest_from_url
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/create-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-create-command"
)

add_test(
    NAME sco_virustotal_missing_key_and_dry_run
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/virustotal-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-virustotal-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-virustotal-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-virustotal-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_virustotal_scan_submits_missing_url
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/virustotal-scan.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-virustotal-scan-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-virustotal-scan-config"
)

add_test(
    NAME sco_search_bucket_index_cache
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/search-index-cache.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-search-index-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-search-index-config"
)

add_test(
    NAME sco_search_remote_known_bucket
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/search-remote-known.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-search-remote-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-search-remote-config"
)

add_test(NAME sco_cat_demo_manifest COMMAND sco cat grep)
set_tests_properties(sco_cat_demo_manifest PROPERTIES
    ENVIRONMENT "${SCO_TEST_ENV}"
    PASS_REGULAR_EXPRESSION "Pattern search utility"
)

add_test(
    NAME sco_cat_filetool_manifest_sources
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/cat-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cat-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cat-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cat-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_checkup_empty_root_reports_main_bucket
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/checkup-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkup-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkup-config"
)

add_test(
    NAME sco_checkurls_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/checkurls-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkurls-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkurls-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_checkhashes_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/checkhashes-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkhashes-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkhashes-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_checkver_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/checkver-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkver-command-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-checkver-command-config"
)

add_test(
    NAME sco_missing_checkver_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/missing-checkver-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-missing-checkver-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-missing-checkver-config"
)

add_test(
    NAME sco_describe_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/describe-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-describe-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-describe-config"
)

add_test(
    NAME sco_formatjson_command
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/formatjson-command.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-formatjson-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-formatjson-config"
)

add_test(
    NAME sco_bucket_known
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/bucket-known.ps1"
        "$<TARGET_FILE:sco>"
)

add_test(
    NAME sco_install_file_artifact_layout
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/manifests/filetool.json"
        "${CMAKE_CURRENT_BINARY_DIR}/test-filetool-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-filetool-config"
)

add_test(
    NAME sco_install_zip_artifact_layout
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-ziptool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/manifests/ziptool.json"
        "${CMAKE_CURRENT_BINARY_DIR}/test-ziptool-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-ziptool-config"
)

add_test(
    NAME sco_install_zip_extract_dir
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-extract-dir.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-extract-dir-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-extract-dir-config"
)

add_test(
    NAME sco_install_external_7zip_archive
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-7zip-external.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-7zip-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-7zip-config"
)

add_test(
    NAME sco_install_7zip_script_helper
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-7zip-script.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-7zip-script-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-7zip-script-config"
)

add_test(
    NAME sco_install_msi_msiexec_archive
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-msi-msiexec.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-msi-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-msi-config"
)

add_test(
    NAME sco_install_msi_script_helper
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-msi-script.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-msi-script-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-msi-script-config"
)

add_test(
    NAME sco_install_msi_lessmsi_archive
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-msi-lessmsi.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-msi-lessmsi-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-msi-lessmsi-config"
)

add_test(
    NAME sco_install_inno_innounp_archive
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-inno-innounp.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-inno-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-inno-config"
)

add_test(
    NAME sco_install_inno_script_helper
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-inno-script.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-inno-script-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-inno-script-config"
)

add_test(
    NAME sco_install_dark_script_helper
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-dark-script.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-dark-script-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-dark-script-config"
)

add_test(
    NAME sco_install_from_bucket_name
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-from-bucket.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-install-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-install-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_install_download_autoupdate_version
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-autoupdate-version.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-autoupdate-version-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-autoupdate-version-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_install_depends_from_bucket
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-depends.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-depends-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-depends-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-depends-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_depends_filetool_order
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/depends-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-depends-command-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-depends-command-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-depends-command-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_install_independent_skips_depends
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-independent.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-independent-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-independent-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_install_pre_post_hooks
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-hooks.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-hooks-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-hooks-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_install_uninstall_scripts
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-uninstall-scripts.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-scripts-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-scripts-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_install_uninstall_file_args
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/install-file-args.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-file-args-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-file-args-config"
)

add_test(
    NAME sco_info_installed_bucket_app
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/info-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-info-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-info-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-info-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_manifest_metadata_psmodule_suggest
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/manifest-metadata.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-manifest-metadata-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-manifest-metadata-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_home_filetool_show
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/home-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-home-command-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-home-command-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-home-command-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_download_filetool_to_cache
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/download-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/manifests/filetool.json"
        "${CMAKE_CURRENT_BINARY_DIR}/test-download-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-download-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-download-config"
)

add_test(
    NAME sco_download_range_multithreaded
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/multithread-download.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-range-download-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-range-download-config"
)

add_test(
    NAME sco_export_filetool_scoopfile
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/export-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-export-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-export-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-export-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_import_filetool_scoopfile
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/import-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-import-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-import-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-import-config"
        "${CMAKE_CURRENT_BINARY_DIR}/test-import-bucket-source"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_uninstall_filetool_layout
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/uninstall-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/manifests/filetool.json"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-config"
)

add_test(
    NAME sco_uninstall_scoop_self
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/uninstall-scoop.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-scoop-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-scoop-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-uninstall-scoop-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_update_filetool_from_bucket
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/update-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_update_scoop_updates_buckets
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/update-scoop-buckets.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-scoop-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-scoop-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_update_force_reinstalls_same_version
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/update-force.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-force-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-force-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_update_all_outdated_apps
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/update-all.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-all-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-all-config"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-all-global"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_update_checkver_autoupdate
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/update-checkver-autoupdate.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-checkver-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-update-checkver-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_hold_unhold_skips_update_all
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/hold-update.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-hold-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-hold-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_reset_filetool_version
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/reset-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-reset-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-reset-config"
        "${CMAKE_CURRENT_BINARY_DIR}/test-reset-global-home"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_which_filetool_shim_target
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/which-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/manifests/filetool.json"
        "${CMAKE_CURRENT_BINARY_DIR}/test-which-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-which-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-which-config"
)

add_test(
    NAME sco_persist_data_survives_update_uninstall
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/persist-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-persist-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-persist-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_env_add_path_and_env_set
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/env-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-env-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-env-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_shortcuts_create_and_remove
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/shortcuts-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-shortcuts-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-shortcuts-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_cleanup_filetool_old_versions
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/cleanup-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cleanup-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cleanup-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_cache_filetool_show_rm
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/cache-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/manifests/filetool.json"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cache-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-cache-config"
)

add_test(
    NAME sco_status_filetool_outdated
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/status-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-status-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-status-global-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-status-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_nightly_version_install_update
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/nightly-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-nightly-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-nightly-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_no_junction_uses_version_dirs
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/no-junction-filetool.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-no-junction-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-no-junction-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_default_architecture_config
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/default-architecture.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-default-arch-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-default-arch-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool-v2.exe"
)

add_test(
    NAME sco_bucket_add_rm_local
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/bucket-add-rm.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-add-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-add-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_bucket_add_git_local_repo
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/bucket-add-git.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-git-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-git-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

add_test(
    NAME sco_bucket_update_git_local_repo
    COMMAND powershell -NoProfile -ExecutionPolicy Bypass
        -File "${CMAKE_CURRENT_SOURCE_DIR}/test/bucket-update-git.ps1"
        "$<TARGET_FILE:sco>"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-update-home"
        "${CMAKE_CURRENT_BINARY_DIR}/test-bucket-update-config"
        "${CMAKE_CURRENT_SOURCE_DIR}/testdata/artifacts/filetool.exe"
)

set_tests_properties(
    sco_cat_filetool_manifest_sources
    sco_checkurls_command
    sco_depends_filetool_order
    sco_describe_command
    sco_download_filetool_to_cache
    sco_download_range_multithreaded
    sco_home_filetool_show
    sco_info_installed_bucket_app
    sco_import_filetool_scoopfile
    sco_install_download_autoupdate_version
    sco_install_file_artifact_layout
    sco_search_remote_known_bucket
    sco_update_checkver_autoupdate
    sco_virustotal_missing_key_and_dry_run
    sco_virustotal_scan_submits_missing_url
    PROPERTIES RESOURCE_LOCK fixed_http_listener
)
