#Requires -Version 5.0

<#
.SYNOPSIS
    Collect download URLs from Zone.Identifier ADS in user Downloads folders.

.DESCRIPTION
    This script scans all local user download folders, including multilingual folder
    name variants and registry-defined Downloads paths, then extracts HostUrl and
    ReferrerUrl from the Zone.Identifier alternate data stream (ADS) for each file.

    The output JSON follows the same global structure used by other collectors:
    first record is endpoint metadata (RecordType = EndpointInfo), followed by
    per-file records (RecordType = DownloadedFileInfo).

    Output destination:
    - RemoteOps: $Env:S1_OUTPUT_DIR_PATH
    - Local: $Env:TEMP

.PARAMETER AddDate
    When specified, appends a timestamp (yyyy-MM-dd_HHmmss) to the output file names
    in local mode. Without this switch, output files use a fixed name and are overwritten
    on each run.

.EXAMPLE
    .\collect_download_urls_from_zone_identifier.ps1

.EXAMPLE
    .\collect_download_urls_from_zone_identifier.ps1 -AddDate

.NOTES
    Author: Jean-Marc ALBERT
    Date: 2026-02-19
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
    $excludedProfiles = @('Default', 'Public', 'All Users', 'Default User', 'defaultuser0')

    if (-not (Test-Path $usersPath -PathType Container)) {
        return @()
    }

    $profileDirs = @(Get-ChildItem -Path $usersPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $excludedProfiles -and $_.Name -notmatch '^\..*' })

    $sidByPath = @{}
    try {
        $cimProfiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { $_.LocalPath -like "C:\Users\*" -and -not $_.Special }

        foreach ($cimUserProfile in $cimProfiles) {
            $sidByPath[$cimUserProfile.LocalPath.TrimEnd('\')] = $cimUserProfile.SID
        }
    }
    catch {
        Write-Log -Message "Unable to query Win32_UserProfile SIDs: $($_.Exception.Message)" -IsError
    }

    foreach ($profileDir in $profileDirs) {
        [PSCustomObject]@{
            Name     = $profileDir.Name
            FullName = $profileDir.FullName
            SID      = $sidByPath[$profileDir.FullName.TrimEnd('\')]
        }
    }
}

function Resolve-UserPathTemplate {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Template,
        [Parameter(Mandatory = $true)]
        [string]$UserProfilePath
    )

    if ([string]::IsNullOrWhiteSpace($Template)) {
        return $null
    }

    $expanded = $Template
    $userName = Split-Path -Path $UserProfilePath -Leaf
    $homeDrive = Split-Path -Path $UserProfilePath -Qualifier
    $homePath = $UserProfilePath.Substring($homeDrive.Length)

    $expanded = $expanded -replace '(?i)%USERPROFILE%', [Regex]::Escape($UserProfilePath).Replace('\\', '\')
    $expanded = $expanded -replace '(?i)%HOMEDRIVE%', [Regex]::Escape($homeDrive).Replace('\\', '\')
    $expanded = $expanded -replace '(?i)%HOMEPATH%', [Regex]::Escape($homePath).Replace('\\', '\')
    $expanded = $expanded -replace '(?i)%USERNAME%', [Regex]::Escape($userName).Replace('\\', '\')

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
    }
    catch { }

    return $expanded
}

function Get-DownloadsFoldersForUser {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$UserProfile
    )

    $candidates = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $basePath = $UserProfile.FullName

    # ASCII-only fallback names to avoid encoding issues on endpoints.
    # Multilingual coverage is primarily handled by the Known Folder GUID registry lookup.
    $downloadFolderNames = @(
        "Downloads", "Download", "Telechargements", "Descargas", "Baixadas", "Baixados",
        "Herunterladen", "Heruntergeladene Dateien", "Scaricati", "Nedladdningar", "Pobrane",
        "Zagruzki", "Xiazai", "Daunrodo"
    )

    foreach ($folderName in $downloadFolderNames) {
        [void]$candidates.Add((Join-Path $basePath $folderName))
        [void]$candidates.Add((Join-Path $basePath ("OneDrive\" + $folderName)))
    }

    if ($UserProfile.SID) {
        $downloadsKnownFolderGuid = "{374DE290-123F-4565-9164-39C4925E467B}"
        $shellFoldersKey = "Registry::HKEY_USERS\$($UserProfile.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        if (Test-Path $shellFoldersKey) {
            try {
                $shellFolders = Get-ItemProperty -Path $shellFoldersKey -ErrorAction Stop
                $downloadPathTemplate = $shellFolders.$downloadsKnownFolderGuid
                $resolved = Resolve-UserPathTemplate -Template $downloadPathTemplate -UserProfilePath $basePath
                if ($resolved) {
                    [void]$candidates.Add($resolved)
                }
            }
            catch {
                Write-Log -Message "Failed to resolve registry Downloads path for '$($UserProfile.Name)': $($_.Exception.Message)" -IsError
            }
        }
    }

    return @($candidates | Where-Object { Test-Path $_ -PathType Container })
}

function ConvertFrom-ZoneIdentifierContent {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $parsed = @{
        ZoneId      = $null
        ReferrerUrl = $null
        HostUrl     = $null
    }

    foreach ($rawLine in ($Content -split "`r?`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('[')) { continue }
        if ($line -notmatch '=') { continue }

        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { continue }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()

        switch -Regex ($key) {
            '^ZoneId$' { $parsed.ZoneId = $value; continue }
            '^ReferrerUrl$' { $parsed.ReferrerUrl = $value; continue }
            '^HostUrl$' { $parsed.HostUrl = $value; continue }
        }
    }

    return $parsed
}

function Get-UrlDomain {
    param (
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    try {
        return ([uri]$Url).Host
    }
    catch {
        return $null
    }
}

function Get-DownloadedFilesZoneInfo {
    param (
        [Parameter(Mandatory = $true)]
        [array]$UserProfiles
    )

    $results = @()
    Write-Log -Message "Scanning user Downloads folders for Zone.Identifier ADS..." -IsInfo

    foreach ($userProfile in $UserProfiles) {
        $downloadsFolders = Get-DownloadsFoldersForUser -UserProfile $userProfile
        if ($downloadsFolders.Count -eq 0) {
            Write-Log -Message "No Downloads folder found for user '$($userProfile.Name)'." -IsInfo
            continue
        }

        foreach ($downloadsFolder in $downloadsFolders) {
            Write-Log -Message "Scanning '$downloadsFolder' for user '$($userProfile.Name)'..." -IsInfo

            try {
                $files = Get-ChildItem -Path $downloadsFolder -File -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log -Message "Failed to enumerate files in '$downloadsFolder': $($_.Exception.Message)" -IsError
                continue
            }

            foreach ($file in $files) {
                $zoneContent = $null
                try {
                    $zoneContent = Get-Content -Path $file.FullName -Stream "Zone.Identifier" -Raw -ErrorAction Stop
                }
                catch {
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($zoneContent)) { continue }
                $parsedZone = ConvertFrom-ZoneIdentifierContent -Content $zoneContent
                if (-not $parsedZone.HostUrl -and -not $parsedZone.ReferrerUrl) { continue }

                $result = [PSCustomObject]@{
                    RecordType                  = "DownloadedFileInfo"
                    DownloadedFileUser          = $userProfile.Name
                    DownloadedFilePath          = $file.FullName
                    DownloadedFileName          = $file.Name
                    DownloadedFileExtension     = $file.Extension
                    DownloadedFileSize          = $file.Length
                    DownloadedFileCreated       = $file.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
                    DownloadedFileModified      = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                    DownloadedFileDownloadFolder = $downloadsFolder
                    DownloadedFileZoneId        = $parsedZone.ZoneId
                    DownloadedFileHostUrl       = $parsedZone.HostUrl
                    DownloadedFileHostDomain    = Get-UrlDomain -Url $parsedZone.HostUrl
                    DownloadedFileReferrerUrl   = $parsedZone.ReferrerUrl
                    DownloadedFileReferrerDomain = Get-UrlDomain -Url $parsedZone.ReferrerUrl
                }

                $results += $result
                Write-Log -Message "[DISCOVERY] $($userProfile.Name) | $($file.Name) | HostUrl: $($parsedZone.HostUrl)" -IsSuccess
            }
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

if (Test-IsRemoteOps) {
    $outputFile = Join-Path $Env:S1_OUTPUT_DIR_PATH "Downloaded_Files_ZoneIdentifier_Inventory.json"
    $script:LogFilePath = Join-Path $Env:S1_OUTPUT_DIR_PATH "Downloaded_Files_ZoneIdentifier_Inventory.log"
}
else {
    if ($AddDate) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $outputFile = Join-Path $Env:TEMP "Downloaded_Files_ZoneIdentifier_Inventory_$timestamp.json"
        $script:LogFilePath = Join-Path $Env:TEMP "Downloaded_Files_ZoneIdentifier_Inventory_$timestamp.log"
    }
    else {
        $outputFile = Join-Path $Env:TEMP "Downloaded_Files_ZoneIdentifier_Inventory.json"
        $script:LogFilePath = Join-Path $Env:TEMP "Downloaded_Files_ZoneIdentifier_Inventory.log"
    }
}

Write-Log -Message "Starting Zone.Identifier ADS inventory..."
Write-Log -Message "Output file: $outputFile"
Write-Log -Message "Log file: $script:LogFilePath"

$userProfiles = @(Get-UserProfiles)
Write-Log -Message "Found $($userProfiles.Count) user profile(s) to scan."

$downloadedFiles = Get-DownloadedFilesZoneInfo -UserProfiles $userProfiles
Write-Log -Message "Total downloaded files with URL metadata found: $($downloadedFiles.Count)"

$osMetadata = Get-OSInfo
$finalResults = @($osMetadata) + $downloadedFiles

$jsonOutput = $finalResults | ConvertTo-Json -Depth 8 -Compress:$false
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outputFile, $jsonOutput, $utf8NoBom)

if ($downloadedFiles.Count -gt 0) {
    Write-Log -Message "Inventory completed successfully. JSON saved at: $outputFile" -IsSuccess
}
else {
    Write-Log -Message "No files with Zone.Identifier URL metadata found. Metadata-only JSON saved at: $outputFile" -IsInfo
}
