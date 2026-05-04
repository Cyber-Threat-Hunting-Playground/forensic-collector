# IDE Log Event Collection

**Author**: Jean-Marc ALBERT aka WikiJM
**Date**: 2026-05-04  
**Platform**: Windows, macOS, Linux

---

## Objective

These scripts parse log files from Visual Studio Code, VS Code Insiders, VSCodium, and Cursor IDE to extract forensic-relevant events for DFIR investigations.

VS Code and its forks maintain timestamped session logs under their application data directories. The `sharedprocess.log` file in particular records extension lifecycle events (install, update, removal, signature verification), which are high-value DFIR artifacts given the increasing number of malicious extension campaigns targeting the VSCode ecosystem.

The scripts scan all local user profiles, parse `sharedprocess.log`, `renderer.log`, `main.log`, `network.log`, and `network-shared.log` from every session folder, and export structured JSON for investigation, threat hunting, and SIEM ingestion.

---

## Requirements

- **Platform**: Windows, macOS, or Linux
- **PowerShell** (Windows): 5.0 or later
- **Bash** (macOS/Linux): Built-in
- **Dependencies**: None (native tools only)
- **Permissions**: Administrator/root privileges recommended to access all user profiles

---

## Key Features

### 1. Multi-User Discovery

- Scans profiles under `C:\Users` (Windows), `/Users` (macOS), or `/home` + `/root` (Linux)
- Processes IDE logs for each user independently

### 2. Product Coverage

Covers all major VS Code variants:

| Product | Windows Path | macOS Path | Linux Path |
|---------|-------------|------------|------------|
| Visual Studio Code | `%APPDATA%\Code\logs\` | `~/Library/Application Support/Code/logs/` | `~/.config/Code/logs/` |
| VS Code Insiders | `%APPDATA%\Code - Insiders\logs\` | `~/Library/Application Support/Code - Insiders/logs/` | `~/.config/Code - Insiders/logs/` |
| VSCodium | `%APPDATA%\VSCodium\logs\` | `~/Library/Application Support/VSCodium/logs/` | `~/.config/VSCodium/logs/` |
| Cursor | `%APPDATA%\Cursor\logs\` | `~/Library/Application Support/Cursor/logs/` | `~/.config/Cursor/logs/` |

### 3. Events Extracted

#### From `sharedprocess.log` (Primary DFIR Value)

| RecordType | Event | DFIR Value |
|-----------|-------|------------|
| `ExtensionInstall` | Extension install/update with JSON metadata | Tracks installs and updates with operation code, product version, builtin flag |
| `ExtensionUninstall` | Extension removal with JSON metadata | Tracks explicit removals |
| `ExtensionInstallSuccess` | Installation confirmed | Confirms completion |
| `ExtensionSignatureVerification` | Signature check result | Detects unsigned or failed-verification extensions |
| `ExtensionExtracted` | Extension extracted to disk | Shows where extension was deployed |
| `ExtensionDeleted` | Old extension version cleaned up | Cleanup of previously removed versions |
| `ExtensionStaleDeleted` | Stale builtin extension removed | Auto-update builtin cleanup |
| `ExtensionMarkedRemoved` | Extension flagged for removal | Pending removal markers |
| `ExtensionInstallError` | Installation failure | Failed installs (potentially suspicious) |

#### From `renderer.log`

| RecordType | Event | DFIR Value |
|-----------|-------|------------|
| `AutoUpdateExtensions` | Auto-update triggered for extensions | Which extensions triggered auto-update |
| `SettingsSyncStatus` | Settings sync account status change | Settings sync activity |
| `ExtensionHostStarted` | Extension host process started | Extension host process lifecycle |

#### From `main.log`

| RecordType | Event | DFIR Value |
|-----------|-------|------------|
| `IDEUpdateState` | IDE self-update state change | IDE update lifecycle (checking/downloading/idle) |
| `ExtensionHostExited` | Extension host process exited | Extension host exit with code and signal |

#### From `network.log` and `network-shared.log`

| RecordType | Event | DFIR Value |
|-----------|-------|------------|
| `NetworkRequest` | HTTP request outcome (errors, timeouts, failures) | Network connectivity issues, blocked URLs, C2 indicators, marketplace access patterns |

`network-shared.log` is located directly in the session folder (shared process HTTP requests). `network.log` is found under each `window*/` subfolder (per-window HTTP requests). These logs capture outbound HTTP requests made by the IDE including marketplace queries, telemetry endpoints, extension gallery lookups, and CDN accesses. Forensically valuable for identifying network anomalies, blocked connections, and suspicious outbound URLs.

### 4. Endpoint Context

The first JSON object always contains endpoint metadata:

- Hostname
- OS family/version/build
- Collection timestamp

---

## Output Files

The script writes two files:

- JSON event inventory
- Log file

Output destination depends on execution context:

- **RemoteOps**: `$Env:S1_OUTPUT_DIR_PATH` (Windows) / `$S1_OUTPUT_DIR_PATH` (macOS/Linux)
  - `IDE_Logs_Inventory.json`
  - `IDE_Logs_Inventory.log`
- **Local execution**: `$Env:TEMP` (Windows) / `$TMPDIR` (macOS) / `/tmp` (Linux)
  - `IDE_Logs_Inventory_<timestamp>.json`
  - `IDE_Logs_Inventory_<timestamp>.log`

JSON is written in UTF-8 without BOM (Windows).

---

## Output Structure

The JSON output is an array:

1. First element: endpoint metadata (`RecordType = "EndpointInfo"`)
2. Following elements: log event records (various `RecordType` values)

### Endpoint Metadata Fields

- `RecordType`
- `EndpointHostname`
- `EndpointOS`
- `EndpointOSVersion`
- `EndpointOSBuild`
- `EndpointCollectionDate`

### Common Log Event Fields

All event records share these fields:

- `RecordType` -- event type identifier
- `LogPlatform` -- IDE product name (e.g. "Visual Studio Code", "Cursor")
- `LogUser` -- user profile name
- `LogSession` -- timestamped session folder (e.g. "20260422T093839")
- `LogSource` -- source log file name (e.g. "sharedprocess.log")
- `LogSourcePath` -- full path to the source log file
- `LogTimestamp` -- event timestamp from the log line
- `LogLevel` -- log level (e.g. "info", "error")
- `LogRawLine` -- the original unmodified log line

### Type-Specific Fields

| Field | Present in RecordType(s) | Description |
|-------|-------------------------|-------------|
| `LogExtensionID` | ExtensionInstall, ExtensionUninstall, ExtensionInstallSuccess, ExtensionSignatureVerification, ExtensionExtracted, ExtensionDeleted, ExtensionStaleDeleted, ExtensionInstallError | Extension identifier (e.g. "github.copilot-chat") |
| `LogOperation` | ExtensionInstall | Numeric operation code from JSON payload |
| `LogProductVersion` | ExtensionInstall, ExtensionUninstall | IDE product version from JSON payload |
| `LogIsBuiltin` | ExtensionInstall | Whether the extension is a builtin |
| `LogIsApplicationScoped` | ExtensionInstall | Whether the extension is application-scoped |
| `LogVerificationResult` | ExtensionSignatureVerification | Signature check outcome |
| `LogExtractPath` | ExtensionExtracted | Path where extension was extracted |
| `LogDeletedPath` | ExtensionDeleted, ExtensionStaleDeleted | Path of deleted extension folder |
| `LogExtensionFolder` | ExtensionMarkedRemoved | Folder name marked for removal |
| `LogErrorMessage` | ExtensionInstallError | Error message from failed install |
| `LogExtensionList` | AutoUpdateExtensions | Comma-separated list of auto-updated extensions |
| `LogDetail` | SettingsSyncStatus | Status change details |
| `LogPID` | ExtensionHostStarted, ExtensionHostExited | Process ID |
| `LogExitCode` | ExtensionHostExited | Process exit code |
| `LogSignal` | ExtensionHostExited | Process exit signal |
| `LogUpdateState` | IDEUpdateState | IDE update state (idle, checking, downloading, etc.) |
| `LogRequestSeq` | NetworkRequest | Request sequence number from the log |
| `LogRequestURL` | NetworkRequest | Target URL of the HTTP request |
| `LogRequestMethod` | NetworkRequest | HTTP method (GET, POST, etc.) |
| `LogRequestErrorType` | NetworkRequest | Error category (e.g. "error") |
| `LogRequestMessage` | NetworkRequest | Error detail (e.g. "net::ERR_NETWORK_IO_SUSPENDED", "Failed to fetch") |

---

## Example JSON

```json
[
  {
    "RecordType": "EndpointInfo",
    "EndpointHostname": "DESKTOP-ABC123",
    "EndpointOS": "Windows",
    "EndpointOSVersion": "11",
    "EndpointOSBuild": "26100",
    "EndpointCollectionDate": "2026-05-04 10:00:00"
  },
  {
    "RecordType": "ExtensionInstall",
    "LogPlatform": "Visual Studio Code",
    "LogUser": "jdoe",
    "LogSession": "20260422T093839",
    "LogSource": "sharedprocess.log",
    "LogSourcePath": "C:\\Users\\jdoe\\AppData\\Roaming\\Code\\logs\\20260422T093839\\sharedprocess.log",
    "LogTimestamp": "2026-04-22 09:38:45.340",
    "LogLevel": "info",
    "LogExtensionID": "github.copilot-chat",
    "LogOperation": 3,
    "LogProductVersion": "1.116.0",
    "LogIsBuiltin": true,
    "LogIsApplicationScoped": true,
    "LogRawLine": "2026-04-22 09:38:45.340 [info] Installing extension: github.copilot-chat {\"productVersion\":{\"version\":\"1.116.0\"},\"operation\":3,\"isBuiltin\":true,\"isApplicationScoped\":true}"
  },
  {
    "RecordType": "ExtensionSignatureVerification",
    "LogPlatform": "Visual Studio Code",
    "LogUser": "jdoe",
    "LogSession": "20260417T171954",
    "LogSource": "sharedprocess.log",
    "LogSourcePath": "C:\\Users\\jdoe\\AppData\\Roaming\\Code\\logs\\20260417T171954\\sharedprocess.log",
    "LogTimestamp": "2026-04-17 17:20:05.523",
    "LogLevel": "info",
    "LogExtensionID": "ms-python.vscode-python-envs",
    "LogVerificationResult": "Success. Internal Code: 0. Executed: true. Duration: 1990ms.",
    "LogRawLine": "..."
  },
  {
    "RecordType": "AutoUpdateExtensions",
    "LogPlatform": "Cursor",
    "LogUser": "jdoe",
    "LogSession": "20260422T090536",
    "LogSource": "renderer.log",
    "LogSourcePath": "C:\\Users\\jdoe\\AppData\\Roaming\\Cursor\\logs\\20260422T090536\\window1\\renderer.log",
    "LogTimestamp": "2026-04-22 09:06:19.885",
    "LogLevel": "info",
    "LogExtensionList": "github.vscode-github-actions, shd101wyy.markdown-preview-enhanced",
    "LogRawLine": "..."
  },
  {
    "RecordType": "IDEUpdateState",
    "LogPlatform": "Visual Studio Code",
    "LogUser": "jdoe",
    "LogSession": "20260417T171954",
    "LogSource": "main.log",
    "LogSourcePath": "C:\\Users\\jdoe\\AppData\\Roaming\\Code\\logs\\20260417T171954\\main.log",
    "LogTimestamp": "2026-04-17 17:20:28.404",
    "LogLevel": "info",
    "LogUpdateState": "checking",
    "LogRawLine": "..."
  },
  {
    "RecordType": "NetworkRequest",
    "LogPlatform": "Visual Studio Code",
    "LogUser": "jdoe",
    "LogSession": "20260417T171954",
    "LogSource": "network-shared.log",
    "LogSourcePath": "C:\\Users\\jdoe\\AppData\\Roaming\\Code\\logs\\20260417T171954\\network-shared.log",
    "LogTimestamp": "2026-04-17 17:28:26.068",
    "LogLevel": "error",
    "LogRequestSeq": "26",
    "LogRequestURL": "https://mobile.events.data.microsoft.com/OneCollector/1.0",
    "LogRequestMethod": "POST",
    "LogRequestErrorType": "error",
    "LogRequestMessage": "net::ERR_NETWORK_IO_SUSPENDED",
    "LogRawLine": "..."
  }
]
```

---

## Usage

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_ide_logs.ps1"
```

Or from the script directory:

```powershell
.\collect_ide_logs.ps1
```

### macOS (Bash)

```bash
chmod +x collect_ide_logs_macos.sh
./collect_ide_logs_macos.sh
```

### Linux (Bash)

```bash
chmod +x collect_ide_logs_linux.sh
./collect_ide_logs_linux.sh
```

---

## Notes and Limitations

- Logs from the currently running IDE session may be locked; the Windows script falls back to `Get-Content` for locked files, while Bash scripts will skip locked files with an error in the log.
- VSCode creates timestamped session folders under `logs/` -- all available sessions are scanned.
- The `IDEUpdateState` event deduplicates consecutive identical states (e.g. repeated "updating" lines) to reduce noise.
- Some user profiles may be skipped if permissions are insufficient.
- Administrator/root execution is strongly recommended for full host coverage.
- Exact log coverage varies by IDE version, installed extensions, and log level configuration.
- These logs should be treated as high-value supporting evidence rather than a complete audit trail.
