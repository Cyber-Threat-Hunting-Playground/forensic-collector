#Requires -Version 5.0

<#
.SYNOPSIS
    Collect clipboard content and metadata on Windows.

.DESCRIPTION
    This script collects the current Windows clipboard content and metadata
    using built-in PowerShell/.NET APIs only.

    Output JSON format:
    - First object: endpoint metadata (RecordType = EndpointInfo)
    - Second object: clipboard record (RecordType = ClipboardInfo)

    Output destination:
    - RemoteOps: $Env:S1_OUTPUT_DIR_PATH
    - Local: $Env:TEMP

.PARAMETER AddDate
    When specified, appends a timestamp (yyyy-MM-dd_HHmmss) to the output file names
    in local mode. Without this switch, output files use a fixed name and are overwritten
    on each run.

.EXAMPLE
    .\collect_clipboard_content_and_metadata.ps1

.EXAMPLE
    .\collect_clipboard_content_and_metadata.ps1 -AddDate

.NOTES
    Author: Jean-Marc ALBERT (powered by AI)
    Date: 2026-02-19
    Version: 1.0
#>

param(
    [switch]$AddDate
)

function Test-IsRemoteOps {
    return [bool]$Env:S1_OUTPUT_DIR_PATH
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

function Get-StringHash {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) { return $null }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ClipboardSequenceNumber {
    try {
        if (-not ([System.Management.Automation.PSTypeName]"Win32ClipboardNative").Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32ClipboardNative
{
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
"@
        }
        return [uint32][Win32ClipboardNative]::GetClipboardSequenceNumber()
    }
    catch {
        return $null
    }
}

function Invoke-InStaRunspace {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $runspace = $null
    $ps = $null
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = "STA"
        $runspace.ThreadOptions = "ReuseThread"
        $runspace.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($ScriptBlock.ToString())
        return $ps.Invoke()
    }
    finally {
        if ($ps) { $ps.Dispose() }
        if ($runspace) { $runspace.Close(); $runspace.Dispose() }
    }
}

function Get-ClipboardInfo {
    $collectionDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $sequenceNumber = Get-ClipboardSequenceNumber

    # Use STA runspace for reliable clipboard access on all host contexts.
    $staResult = $null
    $clipboardError = $null
    try {
        $staResult = Invoke-InStaRunspace -ScriptBlock {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing

            $dataObj = [System.Windows.Forms.Clipboard]::GetDataObject()
            $availableFormats = @()
            if ($dataObj) {
                $availableFormats = @($dataObj.GetFormats($true))
            }

            $text = $null
            if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::UnicodeText)) {
                $text = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
            }

            $html = $null
            if ([System.Windows.Forms.Clipboard]::ContainsData([System.Windows.Forms.DataFormats]::Html)) {
                $html = [string][System.Windows.Forms.Clipboard]::GetData([System.Windows.Forms.DataFormats]::Html)
            }

            $rtf = $null
            if ([System.Windows.Forms.Clipboard]::ContainsText([System.Windows.Forms.TextDataFormat]::Rtf)) {
                $rtf = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::Rtf)
            }

            $fileList = @()
            if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
                $sc = [System.Windows.Forms.Clipboard]::GetFileDropList()
                foreach ($path in $sc) { $fileList += [string]$path }
            }

            $imageWidth = $null
            $imageHeight = $null
            $imagePixelFormat = $null
            if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                if ($img) {
                    $imageWidth = $img.Width
                    $imageHeight = $img.Height
                    $imagePixelFormat = [string]$img.PixelFormat
                    $img.Dispose()
                }
            }

            [PSCustomObject]@{
                AvailableFormats  = $availableFormats
                Text              = $text
                Html              = $html
                Rtf               = $rtf
                FileList          = $fileList
                ContainsAudio     = [System.Windows.Forms.Clipboard]::ContainsAudio()
                ContainsImage     = [System.Windows.Forms.Clipboard]::ContainsImage()
                ImageWidth        = $imageWidth
                ImageHeight       = $imageHeight
                ImagePixelFormat  = $imagePixelFormat
            }
        }
    }
    catch {
        $clipboardError = $_.Exception.Message
    }

    $clipboard = if ($staResult -and $staResult.Count -gt 0) { $staResult[0] } else { $null }

    $text = if ($clipboard) { [string]$clipboard.Text } else { $null }
    $html = if ($clipboard) { [string]$clipboard.Html } else { $null }
    $rtf = if ($clipboard) { [string]$clipboard.Rtf } else { $null }
    $fileList = if ($clipboard) { @($clipboard.FileList) } else { @() }
    $formats = if ($clipboard) { @($clipboard.AvailableFormats) } else { @() }

    $htmlSourceUrl = $null
    if ($html -and $html -match '(?mi)^SourceURL:(.+)$') {
        $htmlSourceUrl = $Matches[1].Trim()
    }

    $fileDetails = @()
    foreach ($filePath in $fileList) {
        $exists = Test-Path -LiteralPath $filePath -PathType Leaf
        $size = $null
        $modified = $null
        if ($exists) {
            try {
                $fileItem = Get-Item -LiteralPath $filePath -ErrorAction Stop
                $size = $fileItem.Length
                $modified = $fileItem.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            }
            catch { }
        }

        $fileDetails += [PSCustomObject]@{
            Path         = $filePath
            Exists       = [bool]$exists
            Size         = $size
            LastModified = $modified
        }
    }

    return [PSCustomObject]@{
        RecordType                      = "ClipboardInfo"
        ClipboardCollectionDate         = $collectionDate
        ClipboardSequenceNumber         = $sequenceNumber
        ClipboardReadSuccess            = [bool]($null -eq $clipboardError)
        ClipboardReadError              = $clipboardError
        ClipboardAvailableFormats       = $formats
        ClipboardFormatCount            = $formats.Count
        ClipboardContainsText           = [bool](-not [string]::IsNullOrEmpty($text))
        ClipboardTextLength             = if ($text) { $text.Length } else { 0 }
        ClipboardTextSha256             = Get-StringHash -Value $text
        ClipboardTextPreview            = if ($text) { $text.Substring(0, [Math]::Min($text.Length, 1000)) } else { $null }
        ClipboardContainsHtml           = [bool](-not [string]::IsNullOrEmpty($html))
        ClipboardHtmlLength             = if ($html) { $html.Length } else { 0 }
        ClipboardHtmlSha256             = Get-StringHash -Value $html
        ClipboardHtmlSourceUrl          = $htmlSourceUrl
        ClipboardContainsRtf            = [bool](-not [string]::IsNullOrEmpty($rtf))
        ClipboardRtfLength              = if ($rtf) { $rtf.Length } else { 0 }
        ClipboardRtfSha256              = Get-StringHash -Value $rtf
        ClipboardContainsFileDropList   = [bool]($fileList.Count -gt 0)
        ClipboardFileCount              = $fileList.Count
        ClipboardFiles                  = $fileList
        ClipboardFileDetails            = $fileDetails
        ClipboardContainsImage          = if ($clipboard) { [bool]$clipboard.ContainsImage } else { $false }
        ClipboardImageWidth             = if ($clipboard) { $clipboard.ImageWidth } else { $null }
        ClipboardImageHeight            = if ($clipboard) { $clipboard.ImageHeight } else { $null }
        ClipboardImagePixelFormat       = if ($clipboard) { $clipboard.ImagePixelFormat } else { $null }
        ClipboardContainsAudio          = if ($clipboard) { [bool]$clipboard.ContainsAudio } else { $false }
    }
}

# Main script logic
if (Test-IsRemoteOps) {
    $outputFile = Join-Path $Env:S1_OUTPUT_DIR_PATH "Clipboard_Content_Metadata_Inventory.json"
    $script:LogFilePath = Join-Path $Env:S1_OUTPUT_DIR_PATH "Clipboard_Content_Metadata_Inventory.log"
}
else {
    if ($AddDate) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $outputFile = Join-Path $Env:TEMP "Clipboard_Content_Metadata_Inventory_$timestamp.json"
        $script:LogFilePath = Join-Path $Env:TEMP "Clipboard_Content_Metadata_Inventory_$timestamp.log"
    }
    else {
        $outputFile = Join-Path $Env:TEMP "Clipboard_Content_Metadata_Inventory.json"
        $script:LogFilePath = Join-Path $Env:TEMP "Clipboard_Content_Metadata_Inventory.log"
    }
}

Write-Log -Message "Starting clipboard content and metadata inventory..."
Write-Log -Message "Output file: $outputFile"
Write-Log -Message "Log file: $script:LogFilePath"

$osMetadata = Get-OSInfo
$clipboardInfo = Get-ClipboardInfo
$finalResults = @($osMetadata, $clipboardInfo)

$jsonOutput = $finalResults | ConvertTo-Json -Depth 10 -Compress:$false
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outputFile, $jsonOutput, $utf8NoBom)

if ($clipboardInfo.ClipboardReadSuccess) {
    Write-Log -Message "Clipboard inventory completed successfully. JSON saved at: $outputFile" -IsSuccess
}
else {
    Write-Log -Message "Clipboard inventory completed with errors ('$($clipboardInfo.ClipboardReadError)'). JSON saved at: $outputFile" -IsInfo
}
