# Visual Studio Code Extension Inventory

**Author**: Replicated by AI  
**Date**: 2026-02-18  
**Platform**: Windows

---

## Objective

This script provides an automated inventory of installed extensions for:

- Visual Studio Code (`.vscode\extensions`)
- Visual Studio Code - Insiders (`.vscode-insiders\extensions`)

It scans local user profiles, extracts extension metadata from each extension `package.json`, and exports results as JSON for investigation, auditing, and baseline tracking.

---

## Requirements

- **Platform**: Windows
- **PowerShell**: 5.0 or later
- **Dependencies**: None (native PowerShell and .NET only)
- **Permissions**: Administrator privileges recommended to access all user profiles

---

## Key Features

### 1. Multi-User Discovery

- Scans profiles under `C:\Users` (excluding default/public profiles)
- Enumerates installed extensions for each user independently

### 2. Product Coverage

- Supports both standard VS Code and VS Code - Insiders extension locations
- Tags each record with `ExtensionProduct` for easy filtering

### 3. Metadata Extraction

For each extension, the script collects:

- Extension ID (`publisher.name` when available)
- Display name and internal name fallback
- Publisher
- Version
- Description
- Categories
- VS Code engine compatibility (`engines.vscode`)
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

- **RemoteOps**: `$Env:S1_OUTPUT_DIR_PATH`
  - `VSCode_Extensions_Inventory.json`
  - `VSCode_Extensions_Inventory.log`
- **Local execution**: `$Env:TEMP`
  - `VSCode_Extensions_Inventory_<timestamp>.json`
  - `VSCode_Extensions_Inventory_<timestamp>.log`

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
- `ExtensionPlatform`
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
    "EndpointCollectionDate": "2026-02-18 11:30:00"
  },
  {
    "RecordType": "ExtensionInfo",
    "ExtensionPlatform": "Visual Studio Code",
    "ExtensionProduct": "VS Code",
    "ExtensionUser": "jdoe",
    "ExtensionID": "ms-python.python",
    "ExtensionName": "Python",
    "ExtensionPublisher": "ms-python",
    "ExtensionVersion": "2026.2.0",
    "ExtensionDescription": "Python language support.",
    "ExtensionCategories": [
      "Programming Languages"
    ],
    "ExtensionEngineVSCode": "^1.90.0",
    "ExtensionInstallPath": "C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2026.2.0",
    "ExtensionManifestPath": "C:\\Users\\jdoe\\.vscode\\extensions\\ms-python.python-2026.2.0\\package.json",
    "ExtensionInstallDate": "2026-02-17 16:15:42",
    "ExtensionLastModified": "2026-02-17 16:15:42"
  }
]
```

---

## Usage

From PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_vscode_extensions.ps1"
```

Or from the script directory:

```powershell
.\collect_vscode_extensions.ps1
```

---

## Notes and Limitations

- If `package.json` is missing or unreadable, the script still emits a record using folder-name inference where possible.
- Some user profiles may be skipped if permissions are insufficient.
- Administrator execution is strongly recommended for full host coverage.

