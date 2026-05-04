#Requires -Version 5.0

<#
.SYNOPSIS
    Collect forensic-relevant events from Visual Studio Code and Cursor log files.

.DESCRIPTION
    This script scans local Windows user profiles to find log files for VS Code,
    VS Code Insiders, VSCodium, and Cursor IDE. It parses sharedprocess.log,
    renderer.log, main.log, network.log, and network-shared.log for DFIR-relevant
    events including extension installs/updates/removals, signature verifications,
    extension host lifecycle, auto-update triggers, IDE update states, and network
    request errors.

    It exports results as JSON with endpoint metadata as the first record, then one
    record per parsed event. Output is written to:
    - $Env:S1_OUTPUT_DIR_PATH when running in RemoteOps context
    - $Env:TEMP when running locally

    No external dependencies are required.

.PARAMETER AddDate
    When specified, appends a timestamp (yyyy-MM-dd_HHmmss) to the output file names
    in local mode. Without this switch, output files use a fixed name and are overwritten
    on each run.

.EXAMPLE
    .\collect_ide_logs.ps1
    Collects IDE log events and writes JSON and log files.

.EXAMPLE
    .\collect_ide_logs.ps1 -AddDate
    Same as above but with timestamped output file names.

.NOTES
    Author: Jean-Marc ALBERT
    Date: 2026-05-04
    Version: 1.1
#>

param(
    [switch]$AddDate
)

# --- Helpers ---------------------------------------------------------------

function Test-IsRemoteOps { return [bool]$Env:S1_OUTPUT_DIR_PATH }

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param ([Parameter(Mandatory)]
        [string]$Message,
        [switch]$IsError, [switch]$IsSuccess, [switch]$IsInfo)

    $t = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if     ($IsError)   { $m = "[$t][ERROR] $Message";   Write-Host $m -ForegroundColor Red }
    elseif ($IsSuccess) { $m = "[$t][SUCCESS] $Message"; Write-Host $m -ForegroundColor Green }
    elseif ($IsInfo)    { $m = "[$t][INFO] $Message";    Write-Host $m -ForegroundColor Yellow }
    else                { $m = "[$t] $Message";          Write-Host $m }

    if ($script:LogFilePath) { $m | Out-File -Append -FilePath $script:LogFilePath }
}

function Get-UserProfiles {
    $p = "C:\Users"
    $x = @('Default','Public','All Users','Default User')
    if (-not (Test-Path $p -PathType Container)) { return @() }
    return @(Get-ChildItem $p -Directory -EA SilentlyContinue |
        Where-Object { $_.Name -notin $x -and $_.Name -notmatch '^\..*' })
}

# --- JSON string builders (inline, no PSCustomObject) ----------------------

function JE ([string]$s) {
    if ($null -eq $s) { return 'null' }
    $s = $s.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n').Replace("`t",'\t')
    return "`"$s`""
}

function JI ([string]$v) {
    if ([string]::IsNullOrEmpty($v)) { return 'null' }
    return $v
}

function JB ([string]$v) {
    if ([string]::IsNullOrEmpty($v)) { return 'null' }
    return $v
}

function Get-EndpointInfoJson {
    $v = [System.Environment]::OSVersion.Version
    $vStr = "$($v.Major).$($v.Minor).$($v.Build)"
    $b = "$($v.Build)"
    $ov = switch -Regex ($vStr) { '^10\.0\.22' {"11"} '^10\.0' {"10"} '^6\.3' {"8.1"} '^6\.2' {"8"} '^6\.1' {"7"} default {$vStr} }
    $d = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    return "{`"RecordType`":$(JE 'EndpointInfo'),`"EndpointHostname`":$(JE $env:COMPUTERNAME),`"EndpointOS`":$(JE 'Windows'),`"EndpointOSVersion`":$(JE $ov),`"EndpointOSBuild`":$(JE $b),`"EndpointCollectionDate`":$(JE $d)}"
}

# --- Inline JSON field extraction from log payloads ------------------------

function Get-JStr ([string]$J,[string]$P,[string]$K) {
    if ($P -and $J -match "`"$P`"\s*:\s*\{[^}]*`"$K`"\s*:\s*`"([^`"]*)`"") { return $Matches[1] }
    if (-not $P -and $J -match "`"$K`"\s*:\s*`"([^`"]*)`"") { return $Matches[1] }
    return $null
}
function Get-JInt ([string]$J,[string]$K) { if ($J -match "`"$K`"\s*:\s*(\d+)") { return $Matches[1] } return $null }
function Get-JBool ([string]$J,[string]$K) { if ($J -match "`"$K`"\s*:\s*(true|false)") { return $Matches[1] } return $null }

# --- Products & timestamp regex --------------------------------------------

$script:Products = @(
    @{ Name="Visual Studio Code";          Rel="AppData\Roaming\Code\logs" }
    @{ Name="Visual Studio Code Insiders"; Rel="AppData\Roaming\Code - Insiders\logs" }
    @{ Name="VSCodium";                    Rel="AppData\Roaming\VSCodium\logs" }
    @{ Name="Cursor";                      Rel="AppData\Roaming\Cursor\logs" }
)

$script:TsRx = '(?<ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)'

# Pre-filter patterns for Select-String
$script:SpFilter  = 'Installing extension:|Uninstalling extension:|Extension installed successfully:|Extension signature verification result|Extracted extension to|Deleted marked for removal|Deleted stale auto-update|Marked extension as removed|Error while installing the extension'
$script:RenFilter = 'Auto updating outdated extensions|Settings Sync: Account status changed|Started local extension host with pid'
$script:MainFilter = 'update#setState|Extension host with pid'

# --- Build a common JSON prefix -------------------------------------------
function JP ([string]$rt,[string]$pn,[string]$un,[string]$sid,[string]$src,[string]$fp,[string]$ts,[string]$lvl) {
    return "{`"RecordType`":$(JE $rt),`"LogPlatform`":$(JE $pn),`"LogUser`":$(JE $un),`"LogSession`":$(JE $sid),`"LogSource`":$(JE $src),`"LogSourcePath`":$(JE $fp),`"LogTimestamp`":$(JE $ts),`"LogLevel`":$(JE $lvl)"
}

# --- Parse sharedprocess.log ----------------------------------------------

function Parse-SP ([string]$F,[string]$P,[string]$U,[string]$S) {
    if (-not (Test-Path $F -PathType Leaf)) { return }
    if ((Get-Item $F).Length -eq 0) { return }
    $c0 = $script:R.Count
    try { $hits = @(Select-String -Path $F -Pattern $script:SpFilter -EA Stop) }
    catch { Write-Log "Unable to read '$F': $($_.Exception.Message)" -IsError; return }

    foreach ($h in $hits) {
        $l = $h.Line; $j = $null

        if ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Installing extension:\s+(?<id>\S+)\s+(?<jn>\{.+\})\s*$") {
            $jn = $Matches['jn']
            $j = "$(JP 'ExtensionInstall' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogOperation`":$(JI (Get-JInt $jn 'operation')),`"LogProductVersion`":$(JE (Get-JStr $jn 'productVersion' 'version')),`"LogIsBuiltin`":$(JB (Get-JBool $jn 'isBuiltin')),`"LogIsApplicationScoped`":$(JB (Get-JBool $jn 'isApplicationScoped')),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Uninstalling extension:\s+(?<id>\S+)\s+(?<jn>\{.+\})\s*$") {
            $jn = $Matches['jn']
            $j = "$(JP 'ExtensionUninstall' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogProductVersion`":$(JE (Get-JStr $jn 'productVersion' 'version')),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Extension installed successfully:\s+(?<id>\S+)") {
            $j = "$(JP 'ExtensionInstallSuccess' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Extension signature verification result for (?<id>\S+?):\s+(?<rs>.+)$") {
            $j = "$(JP 'ExtensionSignatureVerification' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogVerificationResult`":$(JE $Matches['rs'].Trim()),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Extracted extension to (?<ep>\S+):\s+(?<id>\S+)") {
            $j = "$(JP 'ExtensionExtracted' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogExtractPath`":$(JE $Matches['ep']),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Deleted marked for removal extension from disk (?<id>\S+)\s+(?<dp>.+)$") {
            $j = "$(JP 'ExtensionDeleted' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogDeletedPath`":$(JE $Matches['dp'].Trim()),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Deleted stale auto-update builtin extension from disk (?<id>\S+)\s+(?<dp>.+)$") {
            $j = "$(JP 'ExtensionStaleDeleted' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogDeletedPath`":$(JE $Matches['dp'].Trim()),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Marked extension as removed (?<ef>.+)$") {
            $j = "$(JP 'ExtensionMarkedRemoved' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionFolder`":$(JE $Matches['ef'].Trim()),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>error)\]\s+Error while installing the extension (?<id>\S+)\s+(?<em>.+)$") {
            $j = "$(JP 'ExtensionInstallError' $P $U $S 'sharedprocess.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionID`":$(JE $Matches['id']),`"LogErrorMessage`":$(JE $Matches['em'].Trim()),`"LogRawLine`":$(JE $l)}"
        }

        if ($j) { $script:R.Add($j) }
    }
    $n = $script:R.Count - $c0
    if ($n -gt 0) { Write-Log "[DISCOVERY] $P | sharedprocess.log | Session: $S | User: $U | Events: $n" -IsSuccess }
}

# --- Parse renderer.log ---------------------------------------------------

function Parse-Ren ([string]$F,[string]$P,[string]$U,[string]$S) {
    if (-not (Test-Path $F -PathType Leaf)) { return }
    if ((Get-Item $F).Length -eq 0) { return }
    $c0 = $script:R.Count
    try { $hits = @(Select-String -Path $F -Pattern $script:RenFilter -EA Stop) }
    catch { Write-Log "Unable to read '$F': $($_.Exception.Message)" -IsError; return }

    foreach ($h in $hits) {
        $l = $h.Line; $j = $null

        if ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Auto updating outdated extensions\.\s+(?<el>.+)$") {
            $j = "$(JP 'AutoUpdateExtensions' $P $U $S 'renderer.log' $F $Matches['ts'] $Matches['lv']),`"LogExtensionList`":$(JE $Matches['el'].Trim()),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Settings Sync: Account status changed\s*(?<dt>.*)$") {
            $j = "$(JP 'SettingsSyncStatus' $P $U $S 'renderer.log' $F $Matches['ts'] $Matches['lv']),`"LogDetail`":$(JE $Matches['dt'].Trim()),`"LogRawLine`":$(JE $l)}"
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Started local extension host with pid (?<pd>\d+)") {
            $j = "$(JP 'ExtensionHostStarted' $P $U $S 'renderer.log' $F $Matches['ts'] $Matches['lv']),`"LogPID`":$(JE $Matches['pd']),`"LogRawLine`":$(JE $l)}"
        }

        if ($j) { $script:R.Add($j) }
    }
    $n = $script:R.Count - $c0
    if ($n -gt 0) { Write-Log "[DISCOVERY] $P | renderer.log | Session: $S | User: $U | Events: $n" -IsSuccess }
}

# --- Parse main.log -------------------------------------------------------

function Parse-Main ([string]$F,[string]$P,[string]$U,[string]$S) {
    if (-not (Test-Path $F -PathType Leaf)) { return }
    if ((Get-Item $F).Length -eq 0) { return }
    $c0 = $script:R.Count
    try { $hits = @(Select-String -Path $F -Pattern $script:MainFilter -EA Stop) }
    catch { Write-Log "Unable to read '$F': $($_.Exception.Message)" -IsError; return }

    $lastSt = $null
    foreach ($h in $hits) {
        $l = $h.Line; $j = $null

        if ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+update#setState\s+(?<st>\S+)") {
            $st = $Matches['st']
            if ($st -ne $lastSt) {
                $j = "$(JP 'IDEUpdateState' $P $U $S 'main.log' $F $Matches['ts'] $Matches['lv']),`"LogUpdateState`":$(JE $st),`"LogRawLine`":$(JE $l)}"
                $lastSt = $st
            }
        }
        elseif ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+Extension host with pid (?<pd>\d+) exited with code:\s*(?<ec>\S+),\s*signal:\s*(?<sg>\S+)") {
            $j = "$(JP 'ExtensionHostExited' $P $U $S 'main.log' $F $Matches['ts'] $Matches['lv']),`"LogPID`":$(JE $Matches['pd']),`"LogExitCode`":$(JE $Matches['ec']),`"LogSignal`":$(JE $Matches['sg']),`"LogRawLine`":$(JE $l)}"
        }

        if ($j) { $script:R.Add($j) }
    }
    $n = $script:R.Count - $c0
    if ($n -gt 0) { Write-Log "[DISCOVERY] $P | main.log | Session: $S | User: $U | Events: $n" -IsSuccess }
}

# --- Parse network.log / network-shared.log --------------------------------

function Parse-Net ([string]$F,[string]$P,[string]$U,[string]$S,[string]$LN) {
    if (-not (Test-Path $F -PathType Leaf)) { return }
    if ((Get-Item $F).Length -eq 0) { return }
    $c0 = $script:R.Count

    try { $lines = [System.IO.File]::ReadAllLines($F) }
    catch {
        try { $lines = @(Get-Content $F -EA Stop) }
        catch { Write-Log "Unable to read '$F': $($_.Exception.Message)" -IsError; return }
    }

    foreach ($l in $lines) {
        if ($l -match "^$($script:TsRx)\s+\[(?<lv>\w+)\]\s+#(?<sq>\d+):\s+(?<url>\S+)\s+-\s+(?<dt>.+)$") {
            $ts = $Matches['ts']; $lv = $Matches['lv']; $sq = $Matches['sq']; $url = $Matches['url']
            $dt = $Matches['dt']; $meth = $null; $et = $null; $msg = $dt
            if ($dt -match '^(?<e>\S+)\s+(?<m>GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)\s+(?<mg>.+)$') {
                $et = $Matches['e']; $meth = $Matches['m']; $msg = $Matches['mg']
            } elseif ($dt -match '^(?<e>\S+)\s+(?<m>GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)\s*$') {
                $et = $Matches['e']; $meth = $Matches['m']; $msg = $null
            }
            $j = "$(JP 'NetworkRequest' $P $U $S $LN $F $ts $lv),`"LogRequestSeq`":$(JE $sq),`"LogRequestURL`":$(JE $url),`"LogRequestMethod`":$(JE $meth),`"LogRequestErrorType`":$(JE $et),`"LogRequestMessage`":$(JE $msg),`"LogRawLine`":$(JE $l)}"
            $script:R.Add($j)
        }
    }
    $n = $script:R.Count - $c0
    if ($n -gt 0) { Write-Log "[DISCOVERY] $P | $LN | Session: $S | User: $U | Events: $n" -IsSuccess }
}

# --- Orchestrator ----------------------------------------------------------

function Collect-All ([array]$Profiles) {
    foreach ($prod in $script:Products) {
        $pn = $prod.Name; $rp = $prod.Rel
        Write-Log "Scanning $pn logs..." -IsInfo

        foreach ($up in $Profiles) {
            $lr = Join-Path $up.FullName $rp
            if (-not (Test-Path $lr -PathType Container)) { continue }
            $sessions = @(Get-ChildItem $lr -Directory -EA SilentlyContinue)

            foreach ($sd in $sessions) {
                $sid = $sd.Name; $un = $up.Name

                Parse-SP   (Join-Path $sd.FullName "sharedprocess.log") $pn $un $sid
                Parse-Main (Join-Path $sd.FullName "main.log")          $pn $un $sid
                Parse-Net  (Join-Path $sd.FullName "network-shared.log") $pn $un $sid "network-shared.log"

                foreach ($wd in @(Get-ChildItem $sd.FullName -Directory -Filter "window*" -EA SilentlyContinue)) {
                    Parse-Ren (Join-Path $wd.FullName "renderer.log") $pn $un $sid
                    Parse-Net (Join-Path $wd.FullName "network.log")  $pn $un $sid "network.log"
                }
            }
        }
    }
}

# --- MAIN ------------------------------------------------------------------

if (-not (Test-IsAdmin)) {
    Write-Log "WARNING: Script is not running with administrator privileges. Some user profiles may be inaccessible." -IsInfo
} else {
    Write-Log "Running with administrator privileges." -IsInfo
}

if (Test-IsRemoteOps) {
    $outputFile = Join-Path $Env:S1_OUTPUT_DIR_PATH "IDE_Logs_Inventory.json"
    $script:LogFilePath = Join-Path $Env:S1_OUTPUT_DIR_PATH "IDE_Logs_Inventory.log"
}
else {
    if ($AddDate) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $outputFile = Join-Path $Env:TEMP "IDE_Logs_Inventory_$timestamp.json"
        $script:LogFilePath = Join-Path $Env:TEMP "IDE_Logs_Inventory_$timestamp.log"
    }
    else {
        $outputFile = Join-Path $Env:TEMP "IDE_Logs_Inventory.json"
        $script:LogFilePath = Join-Path $Env:TEMP "IDE_Logs_Inventory.log"
    }
}

Write-Log "Starting IDE log event collection..."
Write-Log "Output file: $outputFile"
Write-Log "Log file: $script:LogFilePath"

$ups = Get-UserProfiles
Write-Log "Found $($ups.Count) user profile(s) to scan."

$script:R = New-Object System.Collections.Generic.List[string]
Collect-All $ups

Write-Log "Total events found: $($script:R.Count)"
Write-Log "Writing JSON output..." -IsInfo

$ei = Get-EndpointInfoJson
$sb = New-Object System.Text.StringBuilder (1024 * 512)
[void]$sb.AppendLine("[")
[void]$sb.Append($ei)
foreach ($rec in $script:R) {
    [void]$sb.Append(",`n")
    [void]$sb.Append($rec)
}
[void]$sb.AppendLine("`n]")
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outputFile, $sb.ToString(), $utf8)

if ($script:R.Count -gt 0) {
    Write-Log "Collection completed successfully. JSON saved at: $outputFile" -IsSuccess
} else {
    Write-Log "No IDE log events found. Metadata-only JSON saved at: $outputFile" -IsInfo
}
