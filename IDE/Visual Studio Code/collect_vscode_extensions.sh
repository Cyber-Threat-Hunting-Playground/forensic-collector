#!/bin/bash

# ==============================================================================
# SCRIPT: collect_vscode_extensions.sh
# DESCRIPTION: Collect installed Visual Studio Code extensions on macOS.
# AUTHOR: Jean-Marc ALBERT
# DATE: 2026-02-18
# VERSION: 1.0
#
# OBJECTIVE:
#   Inventory VS Code extensions from user profiles and export a JSON file that
#   matches the Windows collector schema.
#
# BUILT-IN TOOLS ONLY:
#   bash, find, plutil, stat, date, sw_vers, hostname/scutil
# ==============================================================================

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

    # Keep stdout clean for JSON generation.
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

function plutil_extract_raw {
    local key_path="$1"
    local json_file="$2"
    plutil -extract "$key_path" raw -o - "$json_file" 2>/dev/null || true
}

function plutil_extract_array_json {
    local key_path="$1"
    local json_file="$2"
    local value
    value=$(plutil -extract "$key_path" json -o - "$json_file" 2>/dev/null | tr -d '\n')
    if [[ "$value" =~ ^\[.*\]$ ]]; then
        echo "$value"
    else
        echo "[]"
    fi
}

function normalize_engine_version {
    local version="$1"
    # Match Windows collector behavior: do not keep leading caret operators.
    version="${version#"${version%%[!^]*}"}"
    echo "$version"
}

function get_creation_timestamp {
    local path="$1"
    local created
    created=$(stat -f "%SB" -t "%Y-%m-%d %H:%M:%S" "$path" 2>/dev/null)
    if [[ -z "$created" || "$created" == "Jan  1 00:00:00 1970" ]]; then
        created=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$path" 2>/dev/null)
    fi
    echo "$created"
}

function get_modified_timestamp {
    local path="$1"
    stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$path" 2>/dev/null
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

function collect_vscode_extensions_for_product {
    local product_name="$1"
    local relative_path="$2"
    local -a user_dirs=("$@")
    user_dirs=("${user_dirs[@]:2}")

    write_log "Scanning $product_name extensions..."

    local user_dir user_name extensions_root ext_dir folder_name
    for user_dir in "${user_dirs[@]}"; do
        user_name=$(basename "$user_dir")
        extensions_root="$user_dir/$relative_path"
        [[ -d "$extensions_root" ]] || continue

        while IFS= read -r ext_dir; do
            folder_name=$(basename "$ext_dir")
            local id_guess="$folder_name"
            local version_guess=""

            if [[ "$folder_name" =~ ^(.+)-([0-9][A-Za-z0-9._+-]*)$ ]]; then
                id_guess="${BASH_REMATCH[1]}"
                version_guess="${BASH_REMATCH[2]}"
            fi

            local package_json="$ext_dir/package.json"
            local publisher="" name="" display_name="" version="" description="" engine=""
            local categories_json="[]"

            if [[ -f "$package_json" ]]; then
                publisher=$(plutil_extract_raw "publisher" "$package_json")
                name=$(plutil_extract_raw "name" "$package_json")
                display_name=$(plutil_extract_raw "displayName" "$package_json")
                version=$(plutil_extract_raw "version" "$package_json")
                description=$(plutil_extract_raw "description" "$package_json")
                engine=$(plutil_extract_raw "engines.vscode" "$package_json")
                categories_json=$(plutil_extract_array_json "categories" "$package_json")
            else
                write_log "package.json missing for '$ext_dir'" "ERROR"
            fi

            engine=$(normalize_engine_version "$engine")

            if [[ -z "$version" ]]; then
                version="$version_guess"
            fi
            if [[ -z "$version" ]]; then
                version="Unknown"
            fi

            local extension_id
            if [[ -n "$publisher" && -n "$name" ]]; then
                extension_id="$publisher.$name"
            else
                extension_id="$id_guess"
            fi

            local extension_name
            if [[ -n "$display_name" ]]; then
                extension_name="$display_name"
            elif [[ -n "$name" ]]; then
                extension_name="$name"
            else
                extension_name="$folder_name"
            fi

            local install_date last_modified
            install_date=$(get_creation_timestamp "$ext_dir")
            last_modified=$(get_modified_timestamp "$ext_dir")

            local manifest_path_json
            if [[ -f "$package_json" ]]; then
                manifest_path_json="\"$(json_escape "$package_json")\""
            else
                manifest_path_json="null"
            fi

            local record
            record="{"
            record+="\"RecordType\":\"ExtensionInfo\","
            record+="\"ExtensionPlatform\":\"Visual Studio Code\","
            record+="\"ExtensionProduct\":\"$(json_escape "$product_name")\","
            record+="\"ExtensionUser\":\"$(json_escape "$user_name")\","
            record+="\"ExtensionID\":\"$(json_escape "$extension_id")\","
            record+="\"ExtensionName\":\"$(json_escape "$extension_name")\","
            record+="\"ExtensionPublisher\":$(json_nullable_string "$publisher"),"
            record+="\"ExtensionVersion\":\"$(json_escape "$version")\","
            record+="\"ExtensionDescription\":$(json_nullable_string "$description"),"
            record+="\"ExtensionCategories\":$categories_json,"
            record+="\"ExtensionEngineVSCode\":$(json_nullable_string "$engine"),"
            record+="\"ExtensionInstallPath\":\"$(json_escape "$ext_dir")\","
            record+="\"ExtensionManifestPath\":$manifest_path_json,"
            record+="\"ExtensionInstallDate\":\"$(json_escape "$install_date")\","
            record+="\"ExtensionLastModified\":\"$(json_escape "$last_modified")\""
            record+="}"

            ALL_RECORDS+=("$record")
            write_log "[DISCOVERY] $product_name | $extension_name | User: $user_name | Version: $version" "SUCCESS"
        done < <(find "$extensions_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    done
}

# --- MAIN ---
timestamp=$(date "+%Y-%m-%d_%H%M%S")
if test_is_remote_ops; then
    OUTPUT_FILE="$S1_OUTPUT_DIR_PATH/VSCode_Extensions_Inventory.json"
    LOG_FILE="$S1_OUTPUT_DIR_PATH/VSCode_Extensions_Inventory.log"
else
    OUTPUT_FILE="${TMPDIR:-/tmp}/VSCode_Extensions_Inventory_${timestamp}.json"
    LOG_FILE="${TMPDIR:-/tmp}/VSCode_Extensions_Inventory_${timestamp}.log"
fi

touch "$LOG_FILE" 2>/dev/null

if [[ $EUID -ne 0 ]]; then
    write_log "WARNING: Script is not running as root. Some user profiles may be inaccessible." "INFO"
else
    write_log "Running with root privileges." "INFO"
fi

write_log "Starting Visual Studio Code extension inventory..."
write_log "Output file: $OUTPUT_FILE"
write_log "Log file: $LOG_FILE"

ALL_RECORDS=()
ALL_RECORDS+=("$(get_os_info_json)")

USER_DIRS=()
while IFS= read -r user_dir; do
    USER_DIRS+=("$user_dir")
done < <(collect_user_dirs)

write_log "Found ${#USER_DIRS[@]} user profile(s) to scan."

collect_vscode_extensions_for_product "VS Code" ".vscode/extensions" "${USER_DIRS[@]}"
collect_vscode_extensions_for_product "VS Code - Insiders" ".vscode-insiders/extensions" "${USER_DIRS[@]}"

extension_count=$(( ${#ALL_RECORDS[@]} - 1 ))
if [[ $extension_count -lt 0 ]]; then
    extension_count=0
fi
write_log "Total extensions found: $extension_count"

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

if [[ $extension_count -gt 0 ]]; then
    write_log "Inventory completed successfully. JSON saved at: $OUTPUT_FILE" "SUCCESS"
else
    write_log "No Visual Studio Code extensions found. Metadata-only JSON saved at: $OUTPUT_FILE" "INFO"
fi


