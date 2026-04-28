# NPM Packages Inventory

**Author**: Jean-Marc ALBERT  
**Date**: 2026-04-27  
**Platform**: Windows, macOS, Linux

---

## Objective

These scripts provide an automated inventory of installed npm packages — both system-wide and per-user — across all local user profiles.

They scan well-known installation locations for Node.js, npm, and popular version managers (nvm, fnm, Volta, n), extract package metadata from each `package.json`, and export results as JSON for investigation, auditing, and baseline tracking.

---

## Requirements

- **Platform**: Windows, macOS, or Linux
- **PowerShell** (Windows): 5.0 or later
- **Bash** (macOS/Linux): Built-in
- **Dependencies**: None (native tools only)
- **Permissions**: Administrator/root privileges recommended to access all user profiles

---

## Scanned Locations

### Windows (`collect_npm_packages.ps1`)

| Scope | Location |
|-------|----------|
| System global | `C:\Program Files\nodejs\node_modules` |
| User npm prefix | `%APPDATA%\npm\node_modules` |
| nvm for Windows | `%APPDATA%\nvm\<version>\node_modules` |
| fnm | `%APPDATA%\fnm\node-versions\<version>\installation\lib\node_modules` |
| Volta | `%LOCALAPPDATA%\Volta\tools\image\packages` |

### macOS (`collect_npm_packages_macos.sh`)

| Scope | Location |
|-------|----------|
| System global | `/usr/local/lib/node_modules`, `/opt/homebrew/lib/node_modules` |
| User npm prefix | `~/.npm-global/lib/node_modules`, `~/npm-global/lib/node_modules` |
| nvm | `~/.nvm/versions/node/<version>/lib/node_modules` |
| fnm | `~/Library/Application Support/fnm/node-versions/<version>/installation/lib/node_modules` |
| Volta | `~/.volta/tools/image/packages` |

### Linux (`collect_npm_packages_linux.sh`)

| Scope | Location |
|-------|----------|
| System global | `/usr/local/lib/node_modules`, `/usr/lib/node_modules` |
| User npm prefix | `~/.npm-global/lib/node_modules`, `~/.local/lib/node_modules` |
| nvm | `~/.nvm/versions/node/<version>/lib/node_modules` |
| fnm | `~/.local/share/fnm/node-versions/<version>/installation/lib/node_modules` |
| Volta | `~/.volta/tools/image/packages` |
| n (tj/n) | `~/n/lib/node_modules` |

---

## Key Features

### 1. Multi-User Discovery

- Scans profiles under `C:\Users` (Windows), `/Users` (macOS), or `/home` + `/root` (Linux)
- Enumerates installed packages for each user independently

### 2. Version Manager Awareness

- Detects and scans nvm, fnm, Volta, and n installations
- Tags each record with the version manager source for easy filtering
- Infers the associated Node.js version from the installation path

### 3. Metadata Extraction

For each package, the script collects:

- Package name (including scoped packages like `@scope/name`)
- Version
- Description
- Author
- License
- Homepage URL
- Whether the package provides CLI binaries (`bin` field)
- Associated Node.js version (when detectable)
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

- **RemoteOps**: `$Env:S1_OUTPUT_DIR_PATH` (Windows) / `$S1_OUTPUT_DIR_PATH` (macOS/Linux)
  - `NPM_Packages_Inventory.json`
  - `NPM_Packages_Inventory.log`
- **Local execution**: `$Env:TEMP` (Windows) / `$TMPDIR` (macOS) / `/tmp` (Linux)
  - `NPM_Packages_Inventory.json`
  - `NPM_Packages_Inventory.log`
- **Local execution with `-AddDate` / `--add-date`**: same directory
  - `NPM_Packages_Inventory_<timestamp>.json`
  - `NPM_Packages_Inventory_<timestamp>.log`

JSON is written in UTF-8 without BOM.

---

## Output Structure

The JSON output is an array:

1. First element: endpoint metadata (`RecordType = "EndpointInfo"`)
2. Following elements: package records (`RecordType = "PackageInfo"`)

### Endpoint Metadata Fields

- `RecordType`
- `EndpointHostname`
- `EndpointOS`
- `EndpointOSVersion`
- `EndpointOSBuild`
- `EndpointCollectionDate`

### Package Record Fields

- `RecordType`
- `PackageScope` — `SystemGlobal` or `UserGlobal`
- `PackageSource` — origin such as `npm`, `nodejs`, `nvm/v20.11.0`, `fnm/v22.1.0`, `volta`, `n`
- `PackageUser`
- `PackageName`
- `PackageVersion`
- `PackageDescription`
- `PackageAuthor`
- `PackageLicense`
- `PackageHomepage`
- `PackageHasBin` — `true` if the package declares a `bin` entry
- `PackageNodeVersion` — Node.js version associated with the install path (when detectable)
- `PackageInstallPath`
- `PackageManifestPath`
- `PackageInstallDate`
- `PackageLastModified`

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
    "EndpointCollectionDate": "2026-04-27 14:30:00"
  },
  {
    "RecordType": "PackageInfo",
    "PackageScope": "UserGlobal",
    "PackageSource": "nvm/22.11.0",
    "PackageUser": "jdoe",
    "PackageName": "typescript",
    "PackageVersion": "5.7.3",
    "PackageDescription": "TypeScript is a language for application scale JavaScript development",
    "PackageAuthor": "Microsoft Corp.",
    "PackageLicense": "Apache-2.0",
    "PackageHomepage": "https://www.typescriptlang.org/",
    "PackageHasBin": true,
    "PackageNodeVersion": "22.11.0",
    "PackageInstallPath": "C:\\Users\\jdoe\\AppData\\Roaming\\nvm\\22.11.0\\node_modules\\typescript",
    "PackageManifestPath": "C:\\Users\\jdoe\\AppData\\Roaming\\nvm\\22.11.0\\node_modules\\typescript\\package.json",
    "PackageInstallDate": "2026-04-15 09:12:33",
    "PackageLastModified": "2026-04-15 09:12:33"
  },
  {
    "RecordType": "PackageInfo",
    "PackageScope": "UserGlobal",
    "PackageSource": "npm",
    "PackageUser": "jdoe",
    "PackageName": "@angular/cli",
    "PackageVersion": "19.2.0",
    "PackageDescription": "CLI tool for Angular",
    "PackageAuthor": "Angular Authors",
    "PackageLicense": "MIT",
    "PackageHomepage": "https://github.com/angular/angular-cli",
    "PackageHasBin": true,
    "PackageNodeVersion": null,
    "PackageInstallPath": "C:\\Users\\jdoe\\AppData\\Roaming\\npm\\node_modules\\@angular\\cli",
    "PackageManifestPath": "C:\\Users\\jdoe\\AppData\\Roaming\\npm\\node_modules\\@angular\\cli\\package.json",
    "PackageInstallDate": "2026-03-20 16:45:10",
    "PackageLastModified": "2026-03-20 16:45:10"
  }
]
```

---

## Usage

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File ".\collect_npm_packages.ps1"
```

Or from the script directory:

```powershell
.\collect_npm_packages.ps1
```

To include a timestamp in the output file names:

```powershell
.\collect_npm_packages.ps1 -AddDate
```

### macOS (Bash)

```bash
chmod +x collect_npm_packages_macos.sh
./collect_npm_packages_macos.sh
```

To include a timestamp in the output file names:

```bash
./collect_npm_packages_macos.sh --add-date
```

### Linux (Bash)

```bash
chmod +x collect_npm_packages_linux.sh
./collect_npm_packages_linux.sh
```

To include a timestamp in the output file names:

```bash
./collect_npm_packages_linux.sh --add-date
```

---

## Notes and Limitations

- If `package.json` is missing or unreadable, the script still emits a record using the folder name as the package name.
- The bundled `npm` package inside Node.js system installations is skipped (it is part of Node.js itself, not user-installed).
- Scoped packages (e.g. `@angular/cli`) are correctly detected and their full name is preserved.
- Some user profiles may be skipped if permissions are insufficient.
- Administrator/root execution is strongly recommended for full host coverage.
- The `PackageNodeVersion` field is inferred from the installation path (e.g. nvm version directory) or by querying the nearby `node` binary; it may be `null` for default npm prefix installs.
- On Linux, the `PackageInstallDate` falls back to last-modified time on filesystems that do not support birth time.
