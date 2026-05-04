# forensic-collector

A growing collection of small, focused collectors that gather forensic artifacts and endpoint telemetry that may not be captured by deployed security tooling.

## What's in this repository (today)

This repo contains focused collectors that inventory endpoint artifacts across local user profiles and export results as JSON (plus a log file) for investigation and threat hunting.

| Category | Collector | Path | Windows | macOS | Linux | Documentation |
|----------|-----------|------|:-------:|:-----:|:-----:|---------------|
| **IDE** | Visual Studio Code | `IDE/Visual Studio Code/` | ✅ | | | [README](IDE/Visual%20Studio%20Code/README.md) |
| **IDE** | Cursor | `IDE/Cursor/` | ✅ | ✅ | | [README](IDE/Cursor/README.md) |
| **IDE** | Google Antigravity | `IDE/Google Antigravity/` | ✅ | ✅ | | [README](IDE/Google%20Antigravity/README.md) |
| **IDE** | Windsurf | `IDE/Windsurf/` | ✅ | ✅ | | [README](IDE/Windsurf/README.md) |
| **IDE** | VSCodium | `IDE/VSCodium/` | ✅ | ✅ | | [README](IDE/VSCodium/README.md) |
| **IDE** | IDE Logs (VS Code, Cursor, VSCodium) | `IDE/Logs/` | ✅ | ✅ | ✅ | [README](IDE/Logs/README.md) |
| **Packages** | NPM Packages | `Packages/NPM/` | ✅ | ✅ | ✅ | [README](Packages/NPM/README.md) |
| **Forensics** | Clipboard Content + Metadata | `Clipboard/` | ✅ | | | [README](Clipboard/README.md) |
| **Forensics** | Download URLs from `Zone.Identifier` ADS | `Download URLs from Zone.Identifier ADS/` | ✅ | | | [README](Download%20URLs%20from%20Zone.Identifier%20ADS/README.md) |

All collectors output **JSON + log file** format with support for RemoteOps output directory when available.

## Dashboards

Some collectors include ready-to-import dashboards to accelerate analysis.

| Platform | Collector | Dashboard file |
|----------|----------|----------------|
| SentinelOne | Download URLs from `Zone.Identifier` ADS | `Download URLs from Zone.Identifier ADS/SentinelOne--dashboard--collect_download_urls_from_zone_identifier.json` |
| SentinelOne | NPM Packages | `Packages/NPM/SentinelOne--dashboard--collect_npm_packages.json` |

## Output conventions (recommended)

Collectors in this repo aim to follow a consistent pattern:

- **Machine/endpoint metadata first** (hostname, OS, collection time)
- **Artifacts as structured JSON records** (easy to ingest into SIEM/data lake)
- **A log file** for execution notes and troubleshooting
- **Multi-user coverage** where applicable (collect artifacts across local profiles)

## How to use

Each collector folder contains its own README with prerequisites and commands.
Start by browsing the sub-folder documentation using the links in the tables above.

## Roadmap / adding new collectors

This repository is intended to grow over time. Contributions should:

1. Create a new folder under a clear category (examples: `IDE/`, `Browsers/`, `Persistence/`, `Networking/`, `Cloud/`, `EDR/`, `OS/Windows/`, `OS/macOS/`, `Packages/`, `Forensics/`).
2. Include:
   - The collector script(s)
   - A per-collector `README.md` describing:
     - Objective
     - Supported platforms
     - Requirements/permissions
     - Output files + schema
     - Example output
     - Usage
3. Prefer **native tooling** (PowerShell / Bash / built-in utilities) unless there is a strong reason to add dependencies.
4. Keep outputs **stable and documented** (schema changes should be noted).

## Disclaimer

These collectors are provided for defensive security, DFIR, and threat hunting use. Validate in a test environment and ensure you have appropriate authorization before running on endpoints.
