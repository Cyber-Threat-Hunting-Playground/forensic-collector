#Requires -Version 5.0

<#
.SYNOPSIS
    Collect installed Visual Studio Code extensions from Windows user profiles.

.DESCRIPTION
    This script scans local Windows user profiles to inventory extensions installed
    for Visual Studio Code and Visual Studio Code - Insiders.

    It exports results as JSON with endpoint metadata as the first record, then one
    record per extension. Output is written to:
    - $Env:S1_OUTPUT_DIR_PATH when running in RemoteOps context
    - $Env:TEMP when running locally

    No external dependencies are required.

.EXAMPLE
    .\collect_vscode_extensions.ps1
    Collects VS Code extension inventory and writes JSON and log files.

.NOTES
    Author: Jean-Marc ALBERT
    Date: 2026-02-18
    Version: 1.0
#>

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
        RecordType              = "EndpointInfo"
        EndpointHostname        = $hostname
        EndpointOS              = "Windows"
        EndpointOSVersion       = $osVersion
        EndpointOSBuild         = $buildNumber
        EndpointCollectionDate  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
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

function ConvertFrom-ExtensionFolderName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderName
    )

    # Extension folders usually look like publisher.name-1.2.3
    if ($FolderName -match '^(?<Id>.+)-(?<Version>\d[\w\.\-\+]*?)$') {
        return @{
            ExtensionIdGuess = $Matches.Id
            VersionGuess = $Matches.Version
        }
    }

    return @{
        ExtensionIdGuess = $FolderName
        VersionGuess = $null
    }
}

function Get-VSCodeExtensions {
    param (
        [Parameter(Mandatory = $true)]
        [array]$UserProfiles,
        [Parameter(Mandatory = $true)]
        [string]$ProductName,
        [Parameter(Mandatory = $true)]
        [string]$RelativeExtensionsPath
    )

    $results = @()
    Write-Log -Message "Scanning $ProductName extensions..." -IsInfo

    foreach ($userProfile in $UserProfiles) {
        $extensionsRoot = Join-Path $userProfile.FullName $RelativeExtensionsPath
        if (-not (Test-Path $extensionsRoot -PathType Container)) { continue }

        try {
            $extensionFolders = @(Get-ChildItem -Path $extensionsRoot -Directory -ErrorAction SilentlyContinue)
            foreach ($folder in $extensionFolders) {
                $folderHints = ConvertFrom-ExtensionFolderName -FolderName $folder.Name
                $packageJsonPath = Join-Path $folder.FullName "package.json"
                $package = $null

                if (Test-Path $packageJsonPath -PathType Leaf) {
                    try {
                        $package = Get-Content -Path $packageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    }
                    catch {
                        Write-Log -Message "Unable to parse package.json for '$($folder.FullName)': $($_.Exception.Message)" -IsError
                    }
                }

                $publisher = if ($package -and $package.publisher) { [string]$package.publisher } else { $null }
                $name = if ($package -and $package.name) { [string]$package.name } else { $null }
                $displayName = if ($package -and $package.displayName) { [string]$package.displayName } else { $null }
                $version = if ($package -and $package.version) { [string]$package.version } elseif ($folderHints.VersionGuess) { [string]$folderHints.VersionGuess } else { "Unknown" }
                $extensionId = if ($publisher -and $name) { "$publisher.$name" } else { [string]$folderHints.ExtensionIdGuess }
                $engineVersion = if ($package -and $package.engines -and $package.engines.vscode) { [string]$package.engines.vscode } else { $null }
                if ($engineVersion) {
                    # Normalize semver expression for dashboard readability:
                    # remove leading caret operator (e.g. "^1.90.0" -> "1.90.0").
                    $engineVersion = ($engineVersion -replace '^\^+', '').Trim()
                }
                $categories = if ($package -and $package.categories) { @($package.categories) } else { @() }
                $description = if ($package -and $package.description) { [string]$package.description } else { $null }

                $record = [PSCustomObject]@{
                    RecordType                    = "ExtensionInfo"
                    ExtensionPlatform             = "Visual Studio Code"
                    ExtensionProduct              = $ProductName
                    ExtensionUser                 = $userProfile.Name
                    ExtensionID                   = $extensionId
                    ExtensionName                 = if ($displayName) { $displayName } elseif ($name) { $name } else { $folder.Name }
                    ExtensionPublisher            = $publisher
                    ExtensionVersion              = $version
                    ExtensionDescription          = $description
                    ExtensionCategories           = $categories
                    ExtensionEngineVSCode         = $engineVersion
                    ExtensionInstallPath          = $folder.FullName
                    ExtensionManifestPath         = if (Test-Path $packageJsonPath -PathType Leaf) { $packageJsonPath } else { $null }
                    ExtensionInstallDate          = $folder.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
                    ExtensionLastModified         = $folder.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                }

                $results += $record
                Write-Log -Message "[DISCOVERY] $ProductName | $($record.ExtensionName) | User: $($userProfile.Name) | Version: $($record.ExtensionVersion)" -IsSuccess
            }
        }
        catch {
            Write-Log -Message "Error processing '$extensionsRoot': $($_.Exception.Message)" -IsError
        }
    }

    return $results
}

# Main script logic
if (-not (Test-IsAdmin)) {
    Write-Log -Message "WARNING: Script is not running with administrator privileges. Some user profiles may be inaccessible." -IsInfo
}
else {
    Write-Log -Message "Running with administrator privileges." -IsInfo
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
if (Test-IsRemoteOps) {
    $outputFile = Join-Path $Env:S1_OUTPUT_DIR_PATH "VSCode_Extensions_Inventory.json"
    $script:LogFilePath = Join-Path $Env:S1_OUTPUT_DIR_PATH "VSCode_Extensions_Inventory.log"
}
else {
    $outputFile = Join-Path $Env:TEMP "VSCode_Extensions_Inventory_$timestamp.json"
    $script:LogFilePath = Join-Path $Env:TEMP "VSCode_Extensions_Inventory_$timestamp.log"
}

Write-Log -Message "Starting Visual Studio Code extension inventory..."
Write-Log -Message "Output file: $outputFile"
Write-Log -Message "Log file: $script:LogFilePath"

$userProfiles = Get-UserProfiles
Write-Log -Message "Found $($userProfiles.Count) user profile(s) to scan."

$allExtensions = @()
$allExtensions += Get-VSCodeExtensions -UserProfiles $userProfiles -ProductName "VS Code" -RelativeExtensionsPath ".vscode\extensions"
$allExtensions += Get-VSCodeExtensions -UserProfiles $userProfiles -ProductName "VS Code - Insiders" -RelativeExtensionsPath ".vscode-insiders\extensions"

Write-Log -Message "Total extensions found: $($allExtensions.Count)"

$osMetadata = Get-OSInfo
$finalResults = @($osMetadata) + $allExtensions

$jsonOutput = $finalResults | ConvertTo-Json -Depth 10 -Compress:$false
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outputFile, $jsonOutput, $utf8NoBom)

if ($allExtensions.Count -gt 0) {
    Write-Log -Message "Inventory completed successfully. JSON saved at: $outputFile" -IsSuccess
}
else {
    Write-Log -Message "No Visual Studio Code extensions found. Metadata-only JSON saved at: $outputFile" -IsInfo
}

