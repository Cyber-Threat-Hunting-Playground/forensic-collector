# forensic-collector

A growing collection of small, focused collectors that gather forensic artifacts and endpoint telemetry that may not be captured by deployed security tooling.

## What's in this repository (today)

This repo currently contains IDE-focused collectors and package manager collectors that inventory installed extensions/packages across local user profiles and export results as JSON for investigation, auditing, and baseline tracking.

### IDE collectors

#### Visual Studio Code (Windows)
- **Path:** `IDE/Visual Studio Code/`
- **Collectors:**
  - PowerShell script to inventory extensions for:
    - VS Code (`.vscode\extensions`)
    - VS Code - Insiders (`.vscode-insiders\extensions`)
- **Output:** JSON + log file (supports RemoteOps output directory when available)

See: `IDE/Visual Studio Code/README.md` for detailed fields, example JSON, and usage.

#### Cursor (Windows + macOS)
- **Path:** `IDE/Cursor/`
- **Collectors:**
  - Windows: PowerShell extension inventory
  - macOS: Bash extension inventory
- **Output:** JSON + log file (supports RemoteOps output directory when available)

See: `IDE/Cursor/README.md` for detailed fields, example JSON, and usage.

#### Google Antigravity (Windows + macOS)
- **Path:** `IDE/Google Antigravity/`
- **Collectors:**
  - Windows: PowerShell extension inventory
  - macOS: Bash extension inventory
- **Output:** JSON + log file (supports RemoteOps output directory when available)

See: `IDE/Google Antigravity/README.md` for detailed fields, example JSON, and usage.

#### Windsurf (Windows + macOS)
- **Path:** `IDE/Windsurf/`
- **Collectors:**
  - Windows: PowerShell extension inventory
  - macOS: Bash extension inventory
- **Output:** JSON + log file (supports RemoteOps output directory when available)

See: `IDE/Windsurf/README.md` for detailed fields, example JSON, and usage.

#### VSCodium (Windows + macOS)
- **Path:** `IDE/VSCodium/`
- **Collectors:**
  - Windows: PowerShell extension inventory
  - macOS: Bash extension inventory
- **Output:** JSON + log file (supports RemoteOps output directory when available)

See: `IDE/VSCodium/README.md` for detailed fields, example JSON, and usage.

### Package Manager collectors

#### NPM Packages (Windows + macOS)
- **Path:** `Packages/NPM/`
- **Collectors:**
  - Windows: PowerShell package inventory
  - macOS: Bash package inventory
- **Output:** JSON + log file (supports RemoteOps output directory when available)

See: `Packages/NPM/README.md` for detailed fields, example JSON, and usage.

## Output conventions (recommended)

Collectors in this repo aim to follow a consistent pattern:

- **Machine/endpoint metadata first** (hostname, OS, collection time)
- **Artifacts as structured JSON records** (easy to ingest into SIEM/data lake)
- **A log file** for execution notes and troubleshooting
- **Multi-user coverage** where applicable (collect artifacts across local profiles)

## How to use

Each collector folder contains its own README with prerequisites and commands.
Start by browsing the sub-folder documentation:

- `IDE/Visual Studio Code/README.md`
- `IDE/Cursor/README.md`
- `IDE/Google Antigravity/README.md`
- `IDE/Windsurf/README.md`
- `IDE/VSCodium/README.md`
- `Packages/NPM/README.md`

## Roadmap / adding new collectors

This repository is intended to grow over time. Contributions should:

1. Create a new folder under a clear category (examples: `IDE/`, `Browsers/`, `Persistence/`, `Networking/`, `Cloud/`, `EDR/`, `OS/Windows/`, `OS/macOS/`, `Packages/`).
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
