#!/bin/bash

# ==============================================================================
# SCRIPT: collect_ide_logs_macos.sh
# DESCRIPTION: Collect forensic-relevant events from VS Code and Cursor logs
#              on macOS.
# AUTHOR: Jean-Marc ALBERT
# DATE: 2026-05-04
# VERSION: 1.0
#
# OBJECTIVE:
#   Parse sharedprocess.log, renderer.log, main.log, network.log, and
#   network-shared.log from VS Code, VS Code Insiders, VSCodium, and Cursor
#   IDE log directories for each local user. Export DFIR-relevant events
#   (extension installs/updates/removals, signature verifications, extension
#   host lifecycle, auto-update triggers, IDE update states, network request
#   errors) as JSON that matches the Windows collector schema.
#
# BUILT-IN TOOLS ONLY (no Python, jq, or brew):
#   bash, grep, sed, stat, date, sw_vers, hostname/scutil, find, tr
# ==============================================================================

ADD_DATE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --add-date) ADD_DATE=true; shift ;;
        *) shift ;;
    esac
done

LOG_FILE=""

function test_is_remote_ops {
    [[ -n "$S1_OUTPUT_DIR_PATH" ]]
}

function write_log {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_message="[$timestamp] [$level] $message"

    echo "$log_message" >&2
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_message" >> "$LOG_FILE"
    fi
}

function json_escape {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}

function json_nullable_string {
    local value="$1"
    if [[ -z "$value" ]]; then
        echo "null"
    else
        echo "\"$(json_escape "$value")\""
    fi
}

function get_os_info_json {
    local hostname
    hostname=$(scutil --get ComputerName 2>/dev/null || hostname)
    local os_version
    os_version=$(sw_vers -productVersion 2>/dev/null)
    local os_build
    os_build=$(sw_vers -buildVersion 2>/dev/null)
    local collection_date
    collection_date=$(date "+%Y-%m-%d %H:%M:%S")

    echo "{\"RecordType\":\"EndpointInfo\",\"EndpointHostname\":\"$(json_escape "$hostname")\",\"EndpointOS\":\"macOS\",\"EndpointOSVersion\":\"$(json_escape "$os_version")\",\"EndpointOSBuild\":\"$(json_escape "$os_build")\",\"EndpointCollectionDate\":\"$collection_date\"}"
}

function collect_user_dirs {
    local users_root="/Users"
    if [[ ! -d "$users_root" ]]; then
        return
    fi

    local user_dir user_name
    for user_dir in "$users_root"/*; do
        [[ -d "$user_dir" ]] || continue
        user_name=$(basename "$user_dir")
        case "$user_name" in
            Shared|Guest|.localized) continue ;;
            .* ) continue ;;
        esac
        echo "$user_dir"
    done
}

# ---------------------------------------------------------------------------
# Inline JSON field extraction from log-line JSON payloads.
# Lightweight sed-based parsing; no external JSON tools needed.
# ---------------------------------------------------------------------------
function json_field_string {
    local json="$1" parent="$2" key="$3"
    local value=""
    if [[ -n "$parent" ]]; then
        value=$(echo "$json" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    else
        value=$(echo "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    echo "$value"
}

function json_field_int {
    local json="$1" key="$2"
    echo "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1
}

function json_field_bool {
    local json="$1" key="$2"
    echo "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Emit a JSON record. All fields are positional to avoid subshell overhead.
# ---------------------------------------------------------------------------
function emit_record {
    local record="$1"
    ALL_RECORDS+=("$record")
}

# ---------------------------------------------------------------------------
# Parse sharedprocess.log
# ---------------------------------------------------------------------------
function parse_sharedprocess_log {
    local file_path="$1" product_name="$2" user_name="$3" session_id="$4"

    [[ -f "$file_path" ]] || return
    [[ -s "$file_path" ]] || return

    local count_before=${#ALL_RECORDS[@]}
    local line ts lvl ext_id json_payload

    while IFS= read -r line; do
        # Installing extension: <id> {JSON}
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Installing\ extension:[[:space:]]+([^[:space:]]+)[[:space:]]+(\{.+\})$ ]]; then
            ts="${BASH_REMATCH[1]}"
            lvl="${BASH_REMATCH[2]}"
            ext_id="${BASH_REMATCH[3]}"
            json_payload="${BASH_REMATCH[4]}"

            local op=$(json_field_int "$json_payload" "operation")
            local pv=$(json_field_string "$json_payload" "productVersion" "version")
            local bi=$(json_field_bool "$json_payload" "isBuiltin")
            local as=$(json_field_bool "$json_payload" "isApplicationScoped")

            local r="{"
            r+="\"RecordType\":\"ExtensionInstall\","
            r+="\"LogPlatform\":\"$(json_escape "$product_name")\","
            r+="\"LogUser\":\"$(json_escape "$user_name")\","
            r+="\"LogSession\":\"$(json_escape "$session_id")\","
            r+="\"LogSource\":\"sharedprocess.log\","
            r+="\"LogSourcePath\":\"$(json_escape "$file_path")\","
            r+="\"LogTimestamp\":\"$(json_escape "$ts")\","
            r+="\"LogLevel\":\"$(json_escape "$lvl")\","
            r+="\"LogExtensionID\":\"$(json_escape "$ext_id")\","
            r+="\"LogOperation\":${op:-null},"
            r+="\"LogProductVersion\":$(json_nullable_string "$pv"),"
            r+="\"LogIsBuiltin\":${bi:-null},"
            r+="\"LogIsApplicationScoped\":${as:-null},"
            r+="\"LogRawLine\":\"$(json_escape "$line")\""
            r+="}"
            emit_record "$r"

        # Uninstalling extension: <id> {JSON}
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Uninstalling\ extension:[[:space:]]+([^[:space:]]+)[[:space:]]+(\{.+\})$ ]]; then
            ts="${BASH_REMATCH[1]}"
            lvl="${BASH_REMATCH[2]}"
            ext_id="${BASH_REMATCH[3]}"
            json_payload="${BASH_REMATCH[4]}"
            local pv=$(json_field_string "$json_payload" "productVersion" "version")

            local r="{"
            r+="\"RecordType\":\"ExtensionUninstall\","
            r+="\"LogPlatform\":\"$(json_escape "$product_name")\","
            r+="\"LogUser\":\"$(json_escape "$user_name")\","
            r+="\"LogSession\":\"$(json_escape "$session_id")\","
            r+="\"LogSource\":\"sharedprocess.log\","
            r+="\"LogSourcePath\":\"$(json_escape "$file_path")\","
            r+="\"LogTimestamp\":\"$(json_escape "$ts")\","
            r+="\"LogLevel\":\"$(json_escape "$lvl")\","
            r+="\"LogExtensionID\":\"$(json_escape "$ext_id")\","
            r+="\"LogProductVersion\":$(json_nullable_string "$pv"),"
            r+="\"LogRawLine\":\"$(json_escape "$line")\""
            r+="}"
            emit_record "$r"

        # Extension installed successfully: <id>
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Extension\ installed\ successfully:[[:space:]]+([^[:space:]]+) ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; ext_id="${BASH_REMATCH[3]}"
            local r="{\"RecordType\":\"ExtensionInstallSuccess\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionID\":\"$(json_escape "$ext_id")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Extension signature verification result
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Extension\ signature\ verification\ result\ for\ ([^:]+):[[:space:]]+(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; ext_id="${BASH_REMATCH[3]}"; local vr="${BASH_REMATCH[4]}"
            local r="{\"RecordType\":\"ExtensionSignatureVerification\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionID\":\"$(json_escape "$ext_id")\",\"LogVerificationResult\":\"$(json_escape "$vr")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Extracted extension to <path>: <id>
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Extracted\ extension\ to\ ([^:]+):[[:space:]]+([^[:space:]]+) ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local ep="${BASH_REMATCH[3]}"; ext_id="${BASH_REMATCH[4]}"
            local r="{\"RecordType\":\"ExtensionExtracted\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionID\":\"$(json_escape "$ext_id")\",\"LogExtractPath\":\"$(json_escape "$ep")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Deleted marked for removal extension from disk
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Deleted\ marked\ for\ removal\ extension\ from\ disk\ ([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; ext_id="${BASH_REMATCH[3]}"; local dp="${BASH_REMATCH[4]}"
            local r="{\"RecordType\":\"ExtensionDeleted\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionID\":\"$(json_escape "$ext_id")\",\"LogDeletedPath\":\"$(json_escape "$dp")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Deleted stale auto-update builtin extension from disk
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Deleted\ stale\ auto-update\ builtin\ extension\ from\ disk\ ([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; ext_id="${BASH_REMATCH[3]}"; local dp="${BASH_REMATCH[4]}"
            local r="{\"RecordType\":\"ExtensionStaleDeleted\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionID\":\"$(json_escape "$ext_id")\",\"LogDeletedPath\":\"$(json_escape "$dp")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Marked extension as removed <folder>
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Marked\ extension\ as\ removed\ (.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local ef="${BASH_REMATCH[3]}"
            local r="{\"RecordType\":\"ExtensionMarkedRemoved\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionFolder\":\"$(json_escape "$ef")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Error while installing the extension
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[(error)\][[:space:]]+Error\ while\ installing\ the\ extension\ ([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; ext_id="${BASH_REMATCH[3]}"; local em="${BASH_REMATCH[4]}"
            local r="{\"RecordType\":\"ExtensionInstallError\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"sharedprocess.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionID\":\"$(json_escape "$ext_id")\",\"LogErrorMessage\":\"$(json_escape "$em")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"
        fi
    done < "$file_path"

    local found=$(( ${#ALL_RECORDS[@]} - count_before ))
    if [[ $found -gt 0 ]]; then
        write_log "[DISCOVERY] $product_name | sharedprocess.log | Session: $session_id | User: $user_name | Events: $found" "SUCCESS"
    fi
}

# ---------------------------------------------------------------------------
# Parse renderer.log (found under window*/ subfolders)
# ---------------------------------------------------------------------------
function parse_renderer_log {
    local file_path="$1" product_name="$2" user_name="$3" session_id="$4"

    [[ -f "$file_path" ]] || return
    [[ -s "$file_path" ]] || return

    local count_before=${#ALL_RECORDS[@]}
    local line ts lvl

    while IFS= read -r line; do
        # Auto updating outdated extensions
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Auto\ updating\ outdated\ extensions\.[[:space:]]+(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local el="${BASH_REMATCH[3]}"
            local r="{\"RecordType\":\"AutoUpdateExtensions\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"renderer.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogExtensionList\":\"$(json_escape "$el")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Settings Sync: Account status changed
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Settings\ Sync:\ Account\ status\ changed(.*) ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local detail="${BASH_REMATCH[3]}"
            detail="${detail#"${detail%%[![:space:]]*}"}"
            local r="{\"RecordType\":\"SettingsSyncStatus\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"renderer.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogDetail\":\"$(json_escape "$detail")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"

        # Started local extension host with pid
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Started\ local\ extension\ host\ with\ pid\ ([0-9]+) ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local pid="${BASH_REMATCH[3]}"
            local r="{\"RecordType\":\"ExtensionHostStarted\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"renderer.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogPID\":\"$pid\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"
        fi
    done < "$file_path"

    local found=$(( ${#ALL_RECORDS[@]} - count_before ))
    if [[ $found -gt 0 ]]; then
        write_log "[DISCOVERY] $product_name | renderer.log | Session: $session_id | User: $user_name | Events: $found" "SUCCESS"
    fi
}

# ---------------------------------------------------------------------------
# Parse main.log
# ---------------------------------------------------------------------------
function parse_main_log {
    local file_path="$1" product_name="$2" user_name="$3" session_id="$4"

    [[ -f "$file_path" ]] || return
    [[ -s "$file_path" ]] || return

    local count_before=${#ALL_RECORDS[@]}
    local line ts lvl last_state=""

    while IFS= read -r line; do
        # update#setState <state> (deduplicate consecutive identical states)
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+update\#setState[[:space:]]+([^[:space:]]+) ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local state="${BASH_REMATCH[3]}"
            if [[ "$state" != "$last_state" ]]; then
                local r="{\"RecordType\":\"IDEUpdateState\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"main.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogUpdateState\":\"$(json_escape "$state")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
                emit_record "$r"
                last_state="$state"
            fi

        # Extension host with pid <pid> exited
        elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+Extension\ host\ with\ pid\ ([0-9]+)\ exited\ with\ code:[[:space:]]*([^,]+),\ signal:[[:space:]]*([^[:space:]]+) ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; local pid="${BASH_REMATCH[3]}"; local ec="${BASH_REMATCH[4]}"; local sig="${BASH_REMATCH[5]}"
            local r="{\"RecordType\":\"ExtensionHostExited\",\"LogPlatform\":\"$(json_escape "$product_name")\",\"LogUser\":\"$(json_escape "$user_name")\",\"LogSession\":\"$(json_escape "$session_id")\",\"LogSource\":\"main.log\",\"LogSourcePath\":\"$(json_escape "$file_path")\",\"LogTimestamp\":\"$(json_escape "$ts")\",\"LogLevel\":\"$(json_escape "$lvl")\",\"LogPID\":\"$pid\",\"LogExitCode\":\"$(json_escape "$ec")\",\"LogSignal\":\"$(json_escape "$sig")\",\"LogRawLine\":\"$(json_escape "$line")\"}"
            emit_record "$r"
        fi
    done < "$file_path"

    local found=$(( ${#ALL_RECORDS[@]} - count_before ))
    if [[ $found -gt 0 ]]; then
        write_log "[DISCOVERY] $product_name | main.log | Session: $session_id | User: $user_name | Events: $found" "SUCCESS"
    fi
}

# ---------------------------------------------------------------------------
# Parse network.log / network-shared.log
# Format: 2026-04-16 14:34:03.722 [error] #64: <url> - error GET <message>
# ---------------------------------------------------------------------------
function parse_network_log {
    local file_path="$1" product_name="$2" user_name="$3" session_id="$4" log_name="$5"

    [[ -f "$file_path" ]] || return
    [[ -s "$file_path" ]] || return

    local count_before=${#ALL_RECORDS[@]}
    local line ts lvl seq url detail method error_type msg

    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[[:space:]]+\[([a-zA-Z]+)\][[:space:]]+\#([0-9]+):[[:space:]]+([^[:space:]]+)[[:space:]]+-[[:space:]]+(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"; lvl="${BASH_REMATCH[2]}"; seq="${BASH_REMATCH[3]}"; url="${BASH_REMATCH[4]}"; detail="${BASH_REMATCH[5]}"
            method=""; error_type=""; msg="$detail"

            if [[ "$detail" =~ ^([^[:space:]]+)[[:space:]]+(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)[[:space:]]+(.+)$ ]]; then
                error_type="${BASH_REMATCH[1]}"; method="${BASH_REMATCH[2]}"; msg="${BASH_REMATCH[3]}"
            elif [[ "$detail" =~ ^([^[:space:]]+)[[:space:]]+(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)[[:space:]]*$ ]]; then
                error_type="${BASH_REMATCH[1]}"; method="${BASH_REMATCH[2]}"; msg=""
            fi

            local r="{"
            r+="\"RecordType\":\"NetworkRequest\","
            r+="\"LogPlatform\":\"$(json_escape "$product_name")\","
            r+="\"LogUser\":\"$(json_escape "$user_name")\","
            r+="\"LogSession\":\"$(json_escape "$session_id")\","
            r+="\"LogSource\":\"$(json_escape "$log_name")\","
            r+="\"LogSourcePath\":\"$(json_escape "$file_path")\","
            r+="\"LogTimestamp\":\"$(json_escape "$ts")\","
            r+="\"LogLevel\":\"$(json_escape "$lvl")\","
            r+="\"LogRequestSeq\":\"$seq\","
            r+="\"LogRequestURL\":\"$(json_escape "$url")\","
            r+="\"LogRequestMethod\":$(json_nullable_string "$method"),"
            r+="\"LogRequestErrorType\":$(json_nullable_string "$error_type"),"
            r+="\"LogRequestMessage\":$(json_nullable_string "$msg"),"
            r+="\"LogRawLine\":\"$(json_escape "$line")\""
            r+="}"
            emit_record "$r"
        fi
    done < "$file_path"

    local found=$(( ${#ALL_RECORDS[@]} - count_before ))
    if [[ $found -gt 0 ]]; then
        write_log "[DISCOVERY] $product_name | $log_name | Session: $session_id | User: $user_name | Events: $found" "SUCCESS"
    fi
}

# ---------------------------------------------------------------------------
# Scan a product's log directory for a given user
# ---------------------------------------------------------------------------
function scan_product_logs {
    local product_name="$1" logs_root="$2" user_name="$3"

    [[ -d "$logs_root" ]] || return

    local session_dir session_id
    for session_dir in "$logs_root"/*/; do
        [[ -d "$session_dir" ]] || continue
        session_id=$(basename "$session_dir")

        parse_sharedprocess_log "$session_dir/sharedprocess.log" "$product_name" "$user_name" "$session_id"
        parse_main_log "$session_dir/main.log" "$product_name" "$user_name" "$session_id"
        parse_network_log "$session_dir/network-shared.log" "$product_name" "$user_name" "$session_id" "network-shared.log"

        local win_dir
        for win_dir in "$session_dir"window*/; do
            [[ -d "$win_dir" ]] || continue
            parse_renderer_log "${win_dir}renderer.log" "$product_name" "$user_name" "$session_id"
            parse_network_log "${win_dir}network.log" "$product_name" "$user_name" "$session_id" "network.log"
        done
    done
}

# --- MAIN ---
if test_is_remote_ops; then
    OUTPUT_FILE="$S1_OUTPUT_DIR_PATH/IDE_Logs_Inventory.json"
    LOG_FILE="$S1_OUTPUT_DIR_PATH/IDE_Logs_Inventory.log"
elif [[ "$ADD_DATE" == true ]]; then
    timestamp=$(date "+%Y-%m-%d_%H%M%S")
    OUTPUT_FILE="${TMPDIR:-/tmp}/IDE_Logs_Inventory_${timestamp}.json"
    LOG_FILE="${TMPDIR:-/tmp}/IDE_Logs_Inventory_${timestamp}.log"
else
    OUTPUT_FILE="${TMPDIR:-/tmp}/IDE_Logs_Inventory.json"
    LOG_FILE="${TMPDIR:-/tmp}/IDE_Logs_Inventory.log"
fi

touch "$LOG_FILE" 2>/dev/null

if [[ $EUID -ne 0 ]]; then
    write_log "WARNING: Script is not running as root. Some user profiles may be inaccessible." "INFO"
else
    write_log "Running with root privileges." "INFO"
fi

write_log "Starting IDE log event collection..."
write_log "Output file: $OUTPUT_FILE"
write_log "Log file: $LOG_FILE"

ALL_RECORDS=()
ALL_RECORDS+=("$(get_os_info_json)")

USER_DIRS=()
while IFS= read -r user_dir; do
    USER_DIRS+=("$user_dir")
done < <(collect_user_dirs)

write_log "Found ${#USER_DIRS[@]} user profile(s) to scan."

# Product definitions: (product_name, relative_path_under_user_home)
declare -a PRODUCTS=(
    "Visual Studio Code|Library/Application Support/Code/logs"
    "Visual Studio Code Insiders|Library/Application Support/Code - Insiders/logs"
    "VSCodium|Library/Application Support/VSCodium/logs"
    "Cursor|Library/Application Support/Cursor/logs"
)

for product_def in "${PRODUCTS[@]}"; do
    IFS='|' read -r product_name rel_path <<< "$product_def"
    write_log "Scanning $product_name logs..." "INFO"

    for user_dir in "${USER_DIRS[@]}"; do
        user_name=$(basename "$user_dir")
        logs_root="$user_dir/$rel_path"
        scan_product_logs "$product_name" "$logs_root" "$user_name"
    done
done

event_count=$(( ${#ALL_RECORDS[@]} - 1 ))
if [[ $event_count -lt 0 ]]; then
    event_count=0
fi
write_log "Total events found: $event_count"

{
    echo "["
    for i in "${!ALL_RECORDS[@]}"; do
        if [[ "$i" -gt 0 ]]; then
            echo ","
        fi
        echo "${ALL_RECORDS[$i]}"
    done
    echo "]"
} > "$OUTPUT_FILE"

if [[ $event_count -gt 0 ]]; then
    write_log "Collection completed successfully. JSON saved at: $OUTPUT_FILE" "SUCCESS"
else
    write_log "No IDE log events found. Metadata-only JSON saved at: $OUTPUT_FILE" "INFO"
fi
