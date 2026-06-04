# sco — Native C++ Rewrite of Scoop

A high-performance native C++ reimplementation of [Scoop](https://github.com/ScoopInstaller/Scoop), the Windows command-line package manager. Built as a compiled binary (`sco.exe`) for faster startup, reduced overhead, and no PowerShell runtime dependency — while maintaining full compatibility with the existing Scoop ecosystem (manifests, buckets, shims, config).

## Install

Download the latest release and initialize (pick your shell):

**PowerShell**

```powershell
Invoke-WebRequest -Uri ((Invoke-RestMethod https://api.github.com/repos/o3ku/sco/releases/latest).assets[0].browser_download_url) -OutFile sco.exe; .\sco.exe init
```

**CMD**

```cmd
curl -sLO https://github.com/o3ku/sco/releases/latest/download/sco.exe && sco.exe init
```

> After `sco init` completes, restart your terminal and `sco` is ready to use.

## Features

- **Full Scoop compatibility** — Reads standard Scoop JSON manifests, supports `url`, `hash`, `bin`, `extract_dir`, `depends`, `pre_install`/`post_install` scripts, `env_add_path`, `env_set`, `shortcuts`, `persist`, architecture-specific sections, and autoupdate
- **30+ commands** — `install`, `uninstall`, `update`, `search`, `list`, `info`, `bucket`, `cache`, `shim`, `config`, and more
- **Native shim launcher** — When renamed (e.g., to `git.exe`), `sco.exe` detects sibling `.shim` files and launches the target executable
- **Multiple archive formats** — ZIP, MSI, Inno Setup, WiX, 7zip
- **Bucket management** — Add, remove, update, and search across git/local buckets and the known bucket registry
- **Dependency resolution** — Automatic transitive dependency installation
- **Download engine** — HTTP client with redirect following, gzip decompression, and SHA-256 hash verification
- **Version management** — Semantic version comparison with nightly and autoupdate support
- **Architecture support** — 64bit, 32bit, arm64
- **Global installs** — Per-user and system-wide (global) installation
- **VirusTotal integration** — Hash and URL lookups via the VirusTotal API

## Commands

| Command | Description |
|---|---|
| `install` | Install apps |
| `uninstall` | Uninstall an app |
| `update` | Update apps or Scoop itself |
| `search` | Search available apps |
| `list` | List installed apps |
| `info` | Display information about an app |
| `bucket` | Manage Scoop buckets |
| `cache` | Show or clear the download cache |
| `cat` | Show content of a manifest |
| `cleanup` | Remove old app versions |
| `config` | Get or set configuration values |
| `depends` | List dependencies for an app |
| `download` | Download apps to cache and verify hashes |
| `export` | Export installed apps/buckets as JSON |
| `hold` / `unhold` | Hold/unhold an app to disable/enable updates |
| `import` | Import apps from a Scoopfile |
| `prefix` | Return the path to a specified app |
| `reset` | Reset an app to resolve conflicts |
| `shim` | Manipulate Scoop shims |
| `status` | Show status and check for new versions |
| `virustotal` | Check hashes/URLs on VirusTotal |
| `which` | Locate a shim/executable |

Run `sco help` for the full list of commands.

## Build

### Prerequisites

- **CMake** 3.25+
- **MSVC** (Visual Studio 2019+ with C++20 support)
- **vcpkg** — [installation guide](https://vcpkg.io/en/getting-started)

### Configure & Build

```bash
# Configure (uses the msvc-release preset from CMakePresets.json)
cmake --preset msvc-release

# Build
cmake --build build/msvc-release
```

The preset configures vcpkg toolchain integration and static linking (`x64-windows-static-md` triplet).

### Dependencies (via vcpkg)

| Library | Purpose |
|---|---|
| cpp-httplib | HTTP client (with OpenSSL) |
| nlohmann-json | JSON parsing |
| pugixml | XML/XPath parsing |
| zlib | Gzip decompression |
| OpenSSL | SHA-256 hashing, HTTPS |

## Test

```bash
ctest --test-dir build/msvc-release
```

The test suite includes:
- **C++ unit tests** — Version comparison and core logic
- **50+ PowerShell integration tests** — Each runs in an isolated environment
- **Paired tests** — Run `sco` (C++) alongside the original `scoop` (PowerShell) to verify behavioral equivalence

Test fixtures are located in `testdata/`, including sample manifests and a mock Scoop installation.

## Configuration

| Variable / Config | Default | Purpose |
|---|---|---|
| `SCOOP` env / `root_path` config | `%USERPROFILE%\scoop` | Root install directory |
| `SCOOP_GLOBAL` env / `global_path` config | `C:\ProgramData\scoop` | Global install directory |
| `SCOOP_CACHE` env / `cache_path` config | `<root>\cache` | Download cache directory |
| `XDG_CONFIG_HOME` env | `%USERPROFILE%\.config` | Config home directory |
| Config file | `%XDG_CONFIG_HOME%\scoop\config.json` | Persistent configuration |

## Project Structure

```
sco/
├── CMakeLists.txt          # Build definition
├── CMakePresets.json       # MSVC + vcpkg preset
├── vcpkg.json              # Dependency manifest
├── include/sco/            # Public headers
│   ├── cli.hpp             # CLI dispatcher
│   ├── environment.hpp     # Path configuration
│   ├── manifest.hpp        # Manifest parsing
│   ├── installer.hpp       # Install/uninstall engine
│   ├── buckets.hpp         # Bucket management
│   ├── artifact.hpp        # Download & hashing
│   ├── http_client.hpp     # HTTP client
│   ├── versions.hpp        # Version comparison
│   └── ...                 # config, apps, shim, envvars, etc.
├── src/                    # Implementation
│   ├── main.cpp            # Entry point (CLI + shim launcher)
│   ├── cli.cpp             # All CLI commands
│   ├── installer.cpp       # Core install/uninstall logic
│   ├── buckets.cpp         # Bucket operations
│   ├── shim_main.cpp       # sco-shim.exe entry point
│   └── ...
├── test/                   # Test scripts & unit tests
├── testdata/               # Test fixtures
└── ref/                    # Reference Scoop repo (for paired testing)
```

## Executables

| Target | Description |
|---|---|
| `sco.exe` | Main Scoop CLI replacement — also acts as a native shim launcher when renamed |

## License

This project is inspired by and compatible with [Scoop](https://github.com/ScoopInstaller/Scoop) (Unlicense/MIT).
