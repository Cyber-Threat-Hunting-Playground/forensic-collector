# Cursor Extension Inventory

**Author**: Jean-Marc ALBERT aka WikiJM
**Date**: 2026-03-12  
**Platform**: Windows, macOS

---

## Objective

This script provides an automated inventory of installed extensions for:

- **Cursor IDE** (Windows: `AppData\Roaming\Cursor\User\extensions`, macOS: `~/Library/Application Support/Cursor/User/extensions`)

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

- Supports Cursor IDE extension location
- Tags each record with `ExtensionProduct` for easy filtering

### 3. Metadata Extraction

For each extension, the script collects:

- Extension ID (`publisher.name` when available)
- Display name and internal name fallback
- Publisher
- Version
- Description
- Categories
- VS Code engine compatibility (`engines.vscode` — Cursor uses VS Code–compatible extensions)
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
  - `Cursor_Extensions_Inventory.json`
  - `Cursor_Extensions_Inventory.log`
- **Local execution**: `$Env:TEMP` (Windows) / `$TMPDIR` (macOS)
  - `Cursor_Extensions_Inventory_<timestamp>.json`
  - `Cursor_Extensions_Inventory_<timestamp>.log`

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
- `ExtensionPlatform` (always "Cursor")
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
    "EndpointCollectionDate": "2026-03-12 11:30:00"
  },
  {
    "RecordType": "ExtensionInfo",
    "ExtensionPlatform": "Cursor",
    "ExtensionProduct": "Cursor",
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
    "ExtensionInstallPath": "C:\\Users\\jdoe\\AppData\\Roaming\\Cursor\\User\\extensions\\ms-python.python-2026.2.0",
    "ExtensionManifestPath": "C:\\Users\\jdoe\\AppData\\Roaming\\Cursor\\User\\extensions\\ms-python.python-2026.2.0\\package.json",
    "ExtensionInstallDate": "2026-03-11 16:15:42",
    "ExtensionLastModified": "2026-03-11 16:15:42"
  }
]
```

---

## Usage

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_cursor_extensions.ps1"
```

Or from the script directory:

```powershell
.\collect_cursor_extensions.ps1
```

### macOS (Bash)

```bash
chmod +x collect_cursor_extensions.sh
./collect_cursor_extensions.sh
```

---

## Notes and Limitations

- If `package.json` is missing or unreadable, the script still emits a record using folder-name inference where possible.
- Some user profiles may be skipped if permissions are insufficient.
- Administrator/root execution is strongly recommended for full host coverage.
- Cursor uses the same extension format as VS Code (Open VSX registry), so extensions have `engines.vscode` in their manifest.
