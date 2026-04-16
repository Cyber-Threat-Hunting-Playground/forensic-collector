# VSCodium Extension Inventory

**Author**: Jean-Marc ALBERT aka WikiJM
**Date**: 2026-04-16  
**Platform**: Windows, macOS

---

## Objective

This script provides an automated inventory of installed extensions for:

- **VSCodium** (Windows: `.vscode-oss\extensions`, macOS: `~/.vscode-oss/extensions`)

It scans local user profiles, extracts extension metadata from each extension `package.json`, and exports results as JSON for investigation, auditing, and baseline tracking.

---

## Requirements

- **Platform**: Windows or macOS
- **PowerShell** (Windows): 5.0 or later
- **Bash** (macOS): Built-in
- **Dependencies**: None (native tools only)
- **Permissions**: Administrator/root privileges recommended to access all user profiles

---

## Key Features

### 1. Multi-User Discovery

- Scans profiles under `C:\Users` (Windows) or `/Users` (macOS)
- Enumerates installed extensions for each user independently

### 2. Product Coverage

- Supports VSCodium extension location (`.vscode-oss\extensions`)
- Tags each record with `ExtensionProduct` for easy filtering

### 3. Metadata Extraction

For each extension, the script collects:

- Extension ID (`publisher.name` when available)
- Display name and internal name fallback
- Publisher
- Version
- Description
- Categories
- VS Code engine compatibility (`engines.vscode` — VSCodium uses VS Code–compatible extensions)
- Install path and manifest path
- Install and last modified timestamps

### 4. Endpoint Context

The first JSON object always contains endpoint metadata:

- Hostname
- OS family/version/build
- Collection timestamp

---

## Output Files

The script writes two files:

- JSON inventory
- Log file

Output destination depends on execution context:

- **RemoteOps**: `$Env:S1_OUTPUT_DIR_PATH` (Windows) / `$S1_OUTPUT_DIR_PATH` (macOS)
  - `VSCodium_Extensions_Inventory.json`
  - `VSCodium_Extensions_Inventory.log`
- **Local execution**: `$Env:TEMP` (Windows) / `$TMPDIR` (macOS)
  - `VSCodium_Extensions_Inventory_<timestamp>.json`
  - `VSCodium_Extensions_Inventory_<timestamp>.log`

JSON is written in UTF-8 without BOM.

---

## Output Structure

The JSON output is an array:

1. First element: endpoint metadata (`RecordType = "EndpointInfo"`)
2. Following elements: extension records (`RecordType = "ExtensionInfo"`)

### Endpoint Metadata Fields

- `RecordType`
- `EndpointHostname`
- `EndpointOS`
- `EndpointOSVersion`
- `EndpointOSBuild`
- `EndpointCollectionDate`

### Extension Record Fields

- `RecordType`
- `ExtensionPlatform` (always "VSCodium")
- `ExtensionProduct`
- `ExtensionUser`
- `ExtensionID`
- `ExtensionName`
- `ExtensionPublisher`
- `ExtensionVersion`
- `ExtensionDescription`
- `ExtensionCategories`
- `ExtensionEngineVSCode`
- `ExtensionInstallPath`
- `ExtensionManifestPath`
- `ExtensionInstallDate`
- `ExtensionLastModified`

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
    "EndpointCollectionDate": "2026-04-16 11:30:00"
  },
  {
    "RecordType": "ExtensionInfo",
    "ExtensionPlatform": "VSCodium",
    "ExtensionProduct": "VSCodium",
    "ExtensionUser": "jdoe",
    "ExtensionID": "ms-python.python",
    "ExtensionName": "Python",
    "ExtensionPublisher": "ms-python",
    "ExtensionVersion": "2026.2.0",
    "ExtensionDescription": "Python language support.",
    "ExtensionCategories": [
      "Programming Languages"
    ],
    "ExtensionEngineVSCode": "1.90.0",
    "ExtensionInstallPath": "C:\\Users\\jdoe\\.vscode-oss\\extensions\\ms-python.python-2026.2.0",
    "ExtensionManifestPath": "C:\\Users\\jdoe\\.vscode-oss\\extensions\\ms-python.python-2026.2.0\\package.json",
    "ExtensionInstallDate": "2026-04-15 16:15:42",
    "ExtensionLastModified": "2026-04-15 16:15:42"
  }
]
```

---

## Usage

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_vscodium_extensions.ps1"
```

Or from the script directory:

```powershell
.\collect_vscodium_extensions.ps1
```

### macOS (Bash)

```bash
chmod +x collect_vscodium_extensions.sh
./collect_vscodium_extensions.sh
```

---

## Notes and Limitations

- If `package.json` is missing or unreadable, the script still emits a record using folder-name inference where possible.
- Some user profiles may be skipped if permissions are insufficient.
- Administrator/root execution is strongly recommended for full host coverage.
- VSCodium is an open-source build of VS Code and uses the same extension format, so extensions have `engines.vscode` in their manifest.
