# Extract Download URLs from Zone.Identifier ADS

**Author**: Jean-Marc ALBERT
**Date**: 2026-02-19  
**Platform**: Windows

---

## Objective

This script inventories downloaded files by extracting download metadata from the `Zone.Identifier` Alternate Data Stream (ADS), with a focus on:

- `HostUrl` (download source URL)
- `ReferrerUrl` (source page URL)
- `ZoneId` (security zone marker)

It scans all local user profiles and targets Downloads locations in multilingual and redirected environments.

---

## Script

- `collect_download_urls_from_zone_identifier.ps1`

---

## Requirements

- **Platform**: Windows
- **PowerShell**: 5.0 or later
- **Dependencies**: None (built-in PowerShell/.NET only)
- **Permissions**: Administrator privileges recommended to access all user profiles and folders

---

## Discovery Logic

The script scans all user profiles under `C:\Users` (excluding default/public profiles), then resolves potential Downloads paths using:

- Common localized folder names (e.g., `Downloads`, `Téléchargements`, `Descargas`, `Загрузки`, `下载`, `ダウンロード`, etc.)
- `OneDrive\<DownloadsFolderName>` variants
- Per-user registry known folder path from:
  - `HKU\<SID>\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`
  - Downloads GUID: `{374DE290-123F-4565-9164-39C4925E467B}`

Each candidate folder is scanned recursively for files. For each file, the script attempts to read:

- `Zone.Identifier` stream

If `HostUrl` and/or `ReferrerUrl` exist, a record is exported.

---

## Output Files

The script produces:

- JSON inventory
- Log file

Output destination depends on execution context:

- **RemoteOps** (`$Env:S1_OUTPUT_DIR_PATH`):
  - `Downloaded_Files_ZoneIdentifier_Inventory.json`
  - `Downloaded_Files_ZoneIdentifier_Inventory.log`
- **Local execution** (`$Env:TEMP`):
  - `Downloaded_Files_ZoneIdentifier_Inventory.json`
  - `Downloaded_Files_ZoneIdentifier_Inventory.log`
- **Local execution with `-AddDate`** (`$Env:TEMP`):
  - `Downloaded_Files_ZoneIdentifier_Inventory_<timestamp>.json`
  - `Downloaded_Files_ZoneIdentifier_Inventory_<timestamp>.log`

JSON is written as UTF-8 without BOM.

---

## Output Structure

The JSON output is an array:

1. First object: endpoint metadata (`RecordType = "EndpointInfo"`)
2. Following objects: downloaded file records (`RecordType = "DownloadedFileInfo"`)

### Endpoint Metadata Fields

- `RecordType`
- `EndpointHostname`
- `EndpointOS`
- `EndpointOSVersion`
- `EndpointOSBuild`
- `EndpointCollectionDate`

### Downloaded File Fields

- `RecordType`
- `DownloadedFileUser`
- `DownloadedFilePath`
- `DownloadedFileName`
- `DownloadedFileExtension`
- `DownloadedFileSize`
- `DownloadedFileCreated`
- `DownloadedFileModified`
- `DownloadedFileDownloadFolder`
- `DownloadedFileZoneId`
- `DownloadedFileHostUrl`
- `DownloadedFileHostDomain`
- `DownloadedFileReferrerUrl`
- `DownloadedFileReferrerDomain`

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
    "EndpointCollectionDate": "2026-02-19 14:20:00"
  },
  {
    "RecordType": "DownloadedFileInfo",
    "DownloadedFileUser": "jdoe",
    "DownloadedFilePath": "C:\\Users\\jdoe\\Downloads\\installer.exe",
    "DownloadedFileName": "installer.exe",
    "DownloadedFileExtension": ".exe",
    "DownloadedFileSize": 24863944,
    "DownloadedFileCreated": "2026-02-12 09:11:42",
    "DownloadedFileModified": "2026-02-12 09:11:43",
    "DownloadedFileDownloadFolder": "C:\\Users\\jdoe\\Downloads",
    "DownloadedFileZoneId": "3",
    "DownloadedFileHostUrl": "https://download.example.com/installer.exe",
    "DownloadedFileHostDomain": "download.example.com",
    "DownloadedFileReferrerUrl": "https://example.com/download",
    "DownloadedFileReferrerDomain": "example.com"
  }
]
```

---

## Usage

From PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_download_urls_from_zone_identifier.ps1"
```

Or from the script directory:

```powershell
.\collect_download_urls_from_zone_identifier.ps1
```

To include a timestamp in the output file names:

```powershell
.\collect_download_urls_from_zone_identifier.ps1 -AddDate
```

---

## Notes and Limitations

- Not all files have a `Zone.Identifier` stream (e.g., locally created files, copied files, stripped ADS).
- Some archive extraction workflows remove or do not propagate ADS metadata.
- Encrypted filesystems, non-NTFS targets, or tool-based file transfers may not preserve ADS.
- Running without admin rights may reduce coverage across user profiles.

