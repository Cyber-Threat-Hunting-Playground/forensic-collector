#Requires -Version 5.0

<#
.SYNOPSIS
    Collect installed npm packages from Windows user profiles.

.DESCRIPTION
    This script scans local Windows user profiles to inventory npm packages installed
    system-wide and per-user.

    Scanned locations:
    - System-wide Node.js global node_modules (e.g. C:\Program Files\nodejs\node_modules)
    - Per-user npm prefix (e.g. %APPDATA%\npm\node_modules)
    - Per-user nvm for Windows installations (%APPDATA%\nvm\<version>\node_modules)
    - Per-user fnm installations (%LOCALAPPDATA%\fnm_multishells, %APPDATA%\fnm\node-versions)
    - Per-user Volta installations (%LOCALAPPDATA%\Volta)

    It exports results as JSON with endpoint metadata as the first record, then one
    record per package. Output is written to:
    - $Env:S1_OUTPUT_DIR_PATH when running in RemoteOps context
    - $Env:TEMP when running locally

    No external dependencies are required.

.PARAMETER AddDate
    When specified, appends a timestamp (yyyy-MM-dd_HHmmss) to the output file names
    in local mode. Without this switch, output files use a fixed name and are overwritten
    on each run.

.EXAMPLE
    .\collect_npm_packages.ps1
    Collects npm packages inventory and writes JSON and log files.

.EXAMPLE
    .\collect_npm_packages.ps1 -AddDate
    Same as above but with timestamped output file names.

.NOTES
    Author: Jean-Marc ALBERT
    Date: 2026-04-27
    Version: 1.0
#>

param(
    [switch]$AddDate
)

function Test-IsRemoteOps {
    return [bool]$Env:S1_OUTPUT_DIR_PATH
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [switch]$IsError = $false,
        [switch]$IsSuccess = $false,
        [switch]$IsInfo = $false
    )

    $logTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$logTimestamp] $Message"

    if ($IsError) {
        $logMessage = "[$logTimestamp][ERROR] $Message"
        Write-Host $logMessage -ForegroundColor Red
    }
    elseif ($IsSuccess) {
        $logMessage = "[$logTimestamp][SUCCESS] $Message"
        Write-Host $logMessage -ForegroundColor Green
    }
    elseif ($IsInfo) {
        $logMessage = "[$logTimestamp][INFO] $Message"
        Write-Host $logMessage -ForegroundColor Yellow
    }
    else {
        Write-Host $logMessage
    }

    if ($script:LogFilePath) {
        $logMessage | Out-File -Append -FilePath $script:LogFilePath
    }
}

function Get-OSInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $hostname = $env:COMPUTERNAME
    $version = $os.Version
    $buildNumber = $os.BuildNumber

    $osVersion = switch -Regex ($version) {
        '^10\.0\.22' { "11" }
        '^10\.0' { "10" }
        '^6\.3' { "8.1" }
        '^6\.2' { "8" }
        '^6\.1' { "7" }
        default { $version }
    }

    return [PSCustomObject]@{
        RecordType             = "EndpointInfo"
        EndpointHostname       = $hostname
        EndpointOS             = "Windows"
        EndpointOSVersion      = $osVersion
        EndpointOSBuild        = $buildNumber
        EndpointCollectionDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

function Get-UserProfiles {
    $usersPath = "C:\Users"
    $excludedProfiles = @('Default', 'Public', 'All Users', 'Default User')

    if (-not (Test-Path $usersPath -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -Path $usersPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $excludedProfiles -and $_.Name -notmatch '^\..*' })
}

function Read-PackageJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageJsonPath
    )

    if (-not (Test-Path $PackageJsonPath -PathType Leaf)) { return $null }

    try {
        return Get-Content -Path $PackageJsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-Log -Message "Unable to parse package.json at '$PackageJsonPath': $($_.Exception.Message)" -IsError
        return $null
    }
}

function Get-PackageAuthor {
    param ($Package)

    if (-not $Package -or -not $Package.author) { return $null }

    if ($Package.author -is [string]) {
        return $Package.author
    }

    if ($Package.author.name) {
        return [string]$Package.author.name
    }

    return $null
}

function Resolve-NodeVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NodeModulesPath
    )

    # Try to infer the Node.js version from the path (nvm / fnm / volta patterns)
    if ($NodeModulesPath -match '[\\/]v?(\d+\.\d+\.\d+)[\\/]') {
        return $Matches[1]
    }

    # For system installs, try to read the node.exe version nearby
    $nodeExe = Join-Path (Split-Path $NodeModulesPath -Parent) "node.exe"
    if (Test-Path $nodeExe -PathType Leaf) {
        try {
            $versionInfo = (Get-Item $nodeExe).VersionInfo
            if ($versionInfo.ProductVersion) {
                return $versionInfo.ProductVersion
            }
        }
        catch { }
    }

    return $null
}

function Get-NpmPackagesFromPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NodeModulesPath,
        [Parameter(Mandatory = $true)]
        [string]$Scope,
        [Parameter(Mandatory = $true)]
        [string]$Username,
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $results = @()
    if (-not (Test-Path $NodeModulesPath -PathType Container)) { return $results }

    $nodeVersion = Resolve-NodeVersion -NodeModulesPath $NodeModulesPath

    $folders = @(Get-ChildItem -Path $NodeModulesPath -Directory -ErrorAction SilentlyContinue)
    foreach ($folder in $folders) {
        # Skip internal npm directories
        if ($folder.Name -eq '.package-lock.json' -or $folder.Name -eq '.cache') { continue }

        if ($folder.Name.StartsWith('@')) {
            # Scoped packages: @scope/package
            $scopedFolders = @(Get-ChildItem -Path $folder.FullName -Directory -ErrorAction SilentlyContinue)
            foreach ($scopedFolder in $scopedFolders) {
                $packageJsonPath = Join-Path $scopedFolder.FullName "package.json"
                $package = Read-PackageJson -PackageJsonPath $packageJsonPath
                $record = Build-PackageRecord -Folder $scopedFolder -Package $package -PackageJsonPath $packageJsonPath `
                    -Scope $Scope -Username $Username -Source $Source -NodeVersion $nodeVersion `
                    -NamePrefix "$($folder.Name)/"
                if ($record) { $results += $record }
            }
        }
        else {
            $packageJsonPath = Join-Path $folder.FullName "package.json"
            $package = Read-PackageJson -PackageJsonPath $packageJsonPath
            $record = Build-PackageRecord -Folder $folder -Package $package -PackageJsonPath $packageJsonPath `
                -Scope $Scope -Username $Username -Source $Source -NodeVersion $nodeVersion
            if ($record) { $results += $record }
        }
    }

    return $results
}

function Build-PackageRecord {
    param (
        [Parameter(Mandatory = $true)]$Folder,
        $Package,
        [string]$PackageJsonPath,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$NodeVersion,
        [string]$NamePrefix = ""
    )

    $name        = if ($Package -and $Package.name) { [string]$Package.name } else { "$NamePrefix$($Folder.Name)" }
    $version     = if ($Package -and $Package.version) { [string]$Package.version } else { "Unknown" }
    $description = if ($Package -and $Package.description) { [string]$Package.description } else { $null }
    $author      = Get-PackageAuthor -Package $Package
    $license     = if ($Package -and $Package.license) { [string]$Package.license } else { $null }
    $homepage    = if ($Package -and $Package.homepage) { [string]$Package.homepage } else { $null }

    # Skip npm itself in system node_modules — it's bundled with Node, not user-installed
    if ($name -eq 'npm' -and $Scope -eq 'SystemGlobal') { return $null }

    $hasBin = $false
    if ($Package -and $Package.bin) {
        $hasBin = $true
    }

    $record = [PSCustomObject]@{
        RecordType           = "PackageInfo"
        PackageScope         = $Scope
        PackageSource        = $Source
        PackageUser          = $Username
        PackageName          = $name
        PackageVersion       = $version
        PackageDescription   = $description
        PackageAuthor        = $author
        PackageLicense       = $license
        PackageHomepage      = $homepage
        PackageHasBin        = $hasBin
        PackageNodeVersion   = $nodeVersion
        PackageInstallPath   = $Folder.FullName
        PackageManifestPath  = if (Test-Path $PackageJsonPath -PathType Leaf) { $PackageJsonPath } else { $null }
        PackageInstallDate   = $Folder.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
        PackageLastModified  = $Folder.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    }

    Write-Log -Message "[DISCOVERY] $Scope | $name@$version | User: $Username | Source: $Source" -IsSuccess
    return $record
}

function Get-SystemGlobalPackages {
    $results = @()

    # Common system-wide Node.js install locations
    $systemPaths = @(
        "$Env:ProgramFiles\nodejs\node_modules",
        "${Env:ProgramFiles(x86)}\nodejs\node_modules"
    )

    foreach ($path in $systemPaths) {
        if (Test-Path $path -PathType Container) {
            Write-Log -Message "Scanning system global: $path" -IsInfo
            $results += Get-NpmPackagesFromPath -NodeModulesPath $path -Scope "SystemGlobal" `
                -Username "SYSTEM" -Source "nodejs"
        }
    }

    return $results
}

function Get-UserGlobalPackages {
    param (
        [Parameter(Mandatory = $true)]
        [array]$UserProfiles
    )

    $results = @()

    foreach ($userProfile in $UserProfiles) {
        $username = $userProfile.Name

        # 1. Default npm global prefix: %APPDATA%\npm\node_modules
        $npmGlobalPath = Join-Path $userProfile.FullName "AppData\Roaming\npm\node_modules"
        if (Test-Path $npmGlobalPath -PathType Container) {
            Write-Log -Message "Scanning npm global for user '$username': $npmGlobalPath" -IsInfo
            $results += Get-NpmPackagesFromPath -NodeModulesPath $npmGlobalPath -Scope "UserGlobal" `
                -Username $username -Source "npm"
        }

        # 2. nvm for Windows: %APPDATA%\nvm\<version>\node_modules
        $nvmRoot = Join-Path $userProfile.FullName "AppData\Roaming\nvm"
        if (Test-Path $nvmRoot -PathType Container) {
            $versionDirs = @(Get-ChildItem -Path $nvmRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -or $_.Name -match '^v\d+' })
            foreach ($versionDir in $versionDirs) {
                $nodeModulesPath = Join-Path $versionDir.FullName "node_modules"
                if (Test-Path $nodeModulesPath -PathType Container) {
                    Write-Log -Message "Scanning nvm ($($versionDir.Name)) for user '$username': $nodeModulesPath" -IsInfo
                    $results += Get-NpmPackagesFromPath -NodeModulesPath $nodeModulesPath -Scope "UserGlobal" `
                        -Username $username -Source "nvm/$($versionDir.Name)"
                }
            }
        }

        # 3. fnm: %LOCALAPPDATA%\fnm_multishells and %APPDATA%\fnm\node-versions
        $fnmVersionsRoot = Join-Path $userProfile.FullName "AppData\Roaming\fnm\node-versions"
        if (Test-Path $fnmVersionsRoot -PathType Container) {
            $versionDirs = @(Get-ChildItem -Path $fnmVersionsRoot -Directory -ErrorAction SilentlyContinue)
            foreach ($versionDir in $versionDirs) {
                $nodeModulesPath = Join-Path $versionDir.FullName "installation\lib\node_modules"
                if (-not (Test-Path $nodeModulesPath -PathType Container)) {
                    $nodeModulesPath = Join-Path $versionDir.FullName "installation\node_modules"
                }
                if (Test-Path $nodeModulesPath -PathType Container) {
                    Write-Log -Message "Scanning fnm ($($versionDir.Name)) for user '$username': $nodeModulesPath" -IsInfo
                    $results += Get-NpmPackagesFromPath -NodeModulesPath $nodeModulesPath -Scope "UserGlobal" `
                        -Username $username -Source "fnm/$($versionDir.Name)"
                }
            }
        }

        # 4. Volta: %LOCALAPPDATA%\Volta\tools\image\packages
        $voltaPackagesRoot = Join-Path $userProfile.FullName "AppData\Local\Volta\tools\image\packages"
        if (Test-Path $voltaPackagesRoot -PathType Container) {
            Write-Log -Message "Scanning Volta for user '$username': $voltaPackagesRoot" -IsInfo
            $voltaFolders = @(Get-ChildItem -Path $voltaPackagesRoot -Directory -ErrorAction SilentlyContinue)
            foreach ($voltaFolder in $voltaFolders) {
                $packageJsonPath = Join-Path $voltaFolder.FullName "package.json"
                if (Test-Path $packageJsonPath -PathType Leaf) {
                    $package = Read-PackageJson -PackageJsonPath $packageJsonPath
                    $record = Build-PackageRecord -Folder $voltaFolder -Package $package -PackageJsonPath $packageJsonPath `
                        -Scope "UserGlobal" -Username $username -Source "volta"
                    if ($record) { $results += $record }
                }
                else {
                    # Volta often stores versioned subdirectories
                    $subDirs = @(Get-ChildItem -Path $voltaFolder.FullName -Directory -ErrorAction SilentlyContinue)
                    foreach ($subDir in $subDirs) {
                        $subPkgJson = Join-Path $subDir.FullName "package.json"
                        if (Test-Path $subPkgJson -PathType Leaf) {
                            $package = Read-PackageJson -PackageJsonPath $subPkgJson
                            $record = Build-PackageRecord -Folder $subDir -Package $package -PackageJsonPath $subPkgJson `
                                -Scope "UserGlobal" -Username $username -Source "volta"
                            if ($record) { $results += $record }
                        }
                    }
                }
            }
        }
    }

    return $results
}

# --- Main script logic ---
if (-not (Test-IsAdmin)) {
    Write-Log -Message "WARNING: Script is not running with administrator privileges. Some user profiles may be inaccessible." -IsInfo
}
else {
    Write-Log -Message "Running with administrator privileges." -IsInfo
}

if (Test-IsRemoteOps) {
    $outputFile = Join-Path $Env:S1_OUTPUT_DIR_PATH "NPM_Packages_Inventory.json"
    $script:LogFilePath = Join-Path $Env:S1_OUTPUT_DIR_PATH "NPM_Packages_Inventory.log"
}
else {
    if ($AddDate) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $outputFile = Join-Path $Env:TEMP "NPM_Packages_Inventory_$timestamp.json"
        $script:LogFilePath = Join-Path $Env:TEMP "NPM_Packages_Inventory_$timestamp.log"
    }
    else {
        $outputFile = Join-Path $Env:TEMP "NPM_Packages_Inventory.json"
        $script:LogFilePath = Join-Path $Env:TEMP "NPM_Packages_Inventory.log"
    }
}

Write-Log -Message "Starting npm packages inventory..."
Write-Log -Message "Output file: $outputFile"
Write-Log -Message "Log file: $script:LogFilePath"

$userProfiles = Get-UserProfiles
Write-Log -Message "Found $($userProfiles.Count) user profile(s) to scan."

$allPackages = @()
$allPackages += Get-SystemGlobalPackages
$allPackages += Get-UserGlobalPackages -UserProfiles $userProfiles

Write-Log -Message "Total packages found: $($allPackages.Count)"

$osMetadata = Get-OSInfo
$finalResults = @($osMetadata) + $allPackages

$jsonOutput = $finalResults | ConvertTo-Json -Depth 10 -Compress:$false
$jsonOutput = [regex]::Replace($jsonOutput, '\\u([0-9A-Fa-f]{4})', { [char]([int]"0x$($args[0].Groups[1].Value)") })
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outputFile, $jsonOutput, $utf8NoBom)

if ($allPackages.Count -gt 0) {
    Write-Log -Message "Inventory completed successfully. JSON saved at: $outputFile" -IsSuccess
}
else {
    Write-Log -Message "No npm packages found. Metadata-only JSON saved at: $outputFile" -IsInfo
}
