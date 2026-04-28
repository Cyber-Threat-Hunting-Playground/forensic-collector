#!/bin/bash

# ==============================================================================
# SCRIPT: collect_npm_packages_macos.sh
# DESCRIPTION: Collect installed npm packages on macOS.
# AUTHOR: Jean-Marc ALBERT
# DATE: 2026-04-27
# VERSION: 1.0
#
# OBJECTIVE:
#   Inventory npm packages installed system-wide and per-user from
#   user profiles and export a JSON file matching the Windows collector schema.
#
# SCANNED LOCATIONS:
#   - System-wide: /usr/local/lib/node_modules, /opt/homebrew/lib/node_modules
#   - Per-user npm prefix: ~/npm-global/node_modules, ~/.npm-global/node_modules
#   - Per-user nvm: ~/.nvm/versions/node/<version>/lib/node_modules
#   - Per-user fnm: ~/Library/Application Support/fnm/node-versions/<v>/installation/lib/node_modules
#   - Per-user Volta: ~/.volta/tools/image/packages
#
# BUILT-IN TOOLS ONLY (no Python, jq, or brew):
#   bash, find, plutil, stat, date, sw_vers, hostname/scutil, sed, tr
# ==============================================================================

ADD_DATE=false
for arg in "$@"; do
    case "$arg" in
        --add-date) ADD_DATE=true ;;
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

function json_extract_raw {
    local key_path="$1"
    local json_file="$2"
    local value
    value=$(plutil -extract "$key_path" raw -o - "$json_file" 2>/dev/null)
    if [[ -z "$value" ]] && [[ -f "$json_file" ]]; then
        local key
        if [[ "$key_path" == *.* ]]; then
            local parent="${key_path%.*}"
            key="${key_path##*.}"
            local content
            content=$(tr -d '\n' < "$json_file" 2>/dev/null)
            value=$(echo "$content" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{[^}]*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        else
            key="$key_path"
            value=$(sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" 2>/dev/null | head -1)
        fi
    fi
    echo "$value"
}

function json_has_key {
    local key="$1"
    local json_file="$2"
    if [[ ! -f "$json_file" ]]; then
        return 1
    fi
    plutil -extract "$key" raw -o - "$json_file" &>/dev/null && return 0
    tr -d '\n' < "$json_file" 2>/dev/null | grep -q "\"$key\"" 2>/dev/null
}

function get_author_string {
    local json_file="$1"
    local author
    author=$(plutil -extract "author" raw -o - "$json_file" 2>/dev/null)
    if [[ -n "$author" ]]; then
        echo "$author"
        return
    fi
    author=$(plutil -extract "author.name" raw -o - "$json_file" 2>/dev/null)
    if [[ -n "$author" ]]; then
        echo "$author"
        return
    fi
    author=$(sed -n 's/.*"author"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" 2>/dev/null | head -1)
    echo "$author"
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

function resolve_node_version {
    local node_modules_path="$1"
    if [[ "$node_modules_path" =~ /v?([0-9]+\.[0-9]+\.[0-9]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    local node_exe
    node_exe="$(dirname "$(dirname "$node_modules_path")")/bin/node"
    if [[ -x "$node_exe" ]]; then
        local v
        v=$("$node_exe" --version 2>/dev/null)
        v="${v#v}"
        echo "$v"
        return
    fi
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

function build_package_record {
    local pkg_dir="$1"
    local scope="$2"
    local username="$3"
    local source="$4"
    local node_version="$5"
    local name_prefix="$6"

    local folder_name
    folder_name=$(basename "$pkg_dir")
    local package_json="$pkg_dir/package.json"

    local name="" version="" description="" author="" license="" homepage=""
    local has_bin="false"

    if [[ -f "$package_json" ]]; then
        name=$(json_extract_raw "name" "$package_json")
        version=$(json_extract_raw "version" "$package_json")
        description=$(json_extract_raw "description" "$package_json")
        author=$(get_author_string "$package_json")
        license=$(json_extract_raw "license" "$package_json")
        homepage=$(json_extract_raw "homepage" "$package_json")
        if json_has_key "bin" "$package_json"; then
            has_bin="true"
        fi
    fi

    if [[ -z "$name" ]]; then
        name="${name_prefix}${folder_name}"
    fi
    if [[ -z "$version" ]]; then
        version="Unknown"
    fi

    # Skip bundled npm in system node_modules
    if [[ "$name" == "npm" && "$scope" == "SystemGlobal" ]]; then
        return
    fi

    local install_date last_modified
    install_date=$(get_creation_timestamp "$pkg_dir")
    last_modified=$(get_modified_timestamp "$pkg_dir")

    local manifest_path_json
    if [[ -f "$package_json" ]]; then
        manifest_path_json="\"$(json_escape "$package_json")\""
    else
        manifest_path_json="null"
    fi

    local record
    record="{"
    record+="\"RecordType\":\"PackageInfo\","
    record+="\"PackageScope\":\"$(json_escape "$scope")\","
    record+="\"PackageSource\":\"$(json_escape "$source")\","
    record+="\"PackageUser\":\"$(json_escape "$username")\","
    record+="\"PackageName\":\"$(json_escape "$name")\","
    record+="\"PackageVersion\":\"$(json_escape "$version")\","
    record+="\"PackageDescription\":$(json_nullable_string "$description"),"
    record+="\"PackageAuthor\":$(json_nullable_string "$author"),"
    record+="\"PackageLicense\":$(json_nullable_string "$license"),"
    record+="\"PackageHomepage\":$(json_nullable_string "$homepage"),"
    record+="\"PackageHasBin\":$has_bin,"
    record+="\"PackageNodeVersion\":$(json_nullable_string "$node_version"),"
    record+="\"PackageInstallPath\":\"$(json_escape "$pkg_dir")\","
    record+="\"PackageManifestPath\":$manifest_path_json,"
    record+="\"PackageInstallDate\":\"$(json_escape "$install_date")\","
    record+="\"PackageLastModified\":\"$(json_escape "$last_modified")\""
    record+="}"

    ALL_RECORDS+=("$record")
    write_log "[DISCOVERY] $scope | $name@$version | User: $username | Source: $source" "SUCCESS"
}

function scan_node_modules {
    local node_modules_path="$1"
    local scope="$2"
    local username="$3"
    local source="$4"

    if [[ ! -d "$node_modules_path" ]]; then
        return
    fi

    local node_version
    node_version=$(resolve_node_version "$node_modules_path")

    local pkg_dir folder_name
    for pkg_dir in "$node_modules_path"/*/; do
        [[ -d "$pkg_dir" ]] || continue
        folder_name=$(basename "$pkg_dir")

        # Skip internal directories
        case "$folder_name" in
            .package-lock.json|.cache|.staging) continue ;;
        esac

        if [[ "$folder_name" == @* ]]; then
            # Scoped packages
            local scoped_dir
            for scoped_dir in "$pkg_dir"*/; do
                [[ -d "$scoped_dir" ]] || continue
                build_package_record "$scoped_dir" "$scope" "$username" "$source" "$node_version" ""
            done
        else
            build_package_record "$pkg_dir" "$scope" "$username" "$source" "$node_version" ""
        fi
    done
}

function scan_system_global {
    local system_paths=(
        "/usr/local/lib/node_modules"
        "/opt/homebrew/lib/node_modules"
    )

    for path in "${system_paths[@]}"; do
        if [[ -d "$path" ]]; then
            write_log "Scanning system global: $path"
            scan_node_modules "$path" "SystemGlobal" "SYSTEM" "nodejs"
        fi
    done
}

function scan_user_packages {
    local user_dirs=("$@")

    local user_dir user_name
    for user_dir in "${user_dirs[@]}"; do
        user_name=$(basename "$user_dir")

        # 1. Default npm global prefix variants
        local npm_paths=(
            "$user_dir/.npm-global/lib/node_modules"
            "$user_dir/npm-global/lib/node_modules"
            "$user_dir/.npm-packages/lib/node_modules"
        )
        for npm_path in "${npm_paths[@]}"; do
            if [[ -d "$npm_path" ]]; then
                write_log "Scanning npm global for user '$user_name': $npm_path"
                scan_node_modules "$npm_path" "UserGlobal" "$user_name" "npm"
            fi
        done

        # 2. nvm: ~/.nvm/versions/node/<version>/lib/node_modules
        local nvm_root="$user_dir/.nvm/versions/node"
        if [[ -d "$nvm_root" ]]; then
            local version_dir
            for version_dir in "$nvm_root"/*/; do
                [[ -d "$version_dir" ]] || continue
                local nm_path="$version_dir/lib/node_modules"
                if [[ -d "$nm_path" ]]; then
                    local ver_name
                    ver_name=$(basename "$version_dir")
                    write_log "Scanning nvm ($ver_name) for user '$user_name': $nm_path"
                    scan_node_modules "$nm_path" "UserGlobal" "$user_name" "nvm/$ver_name"
                fi
            done
        fi

        # 3. fnm: ~/Library/Application Support/fnm/node-versions/<v>/installation/lib/node_modules
        local fnm_root="$user_dir/Library/Application Support/fnm/node-versions"
        if [[ -d "$fnm_root" ]]; then
            local version_dir
            for version_dir in "$fnm_root"/*/; do
                [[ -d "$version_dir" ]] || continue
                local nm_path="$version_dir/installation/lib/node_modules"
                if [[ -d "$nm_path" ]]; then
                    local ver_name
                    ver_name=$(basename "$version_dir")
                    write_log "Scanning fnm ($ver_name) for user '$user_name': $nm_path"
                    scan_node_modules "$nm_path" "UserGlobal" "$user_name" "fnm/$ver_name"
                fi
            done
        fi

        # 4. Volta: ~/.volta/tools/image/packages
        local volta_root="$user_dir/.volta/tools/image/packages"
        if [[ -d "$volta_root" ]]; then
            write_log "Scanning Volta for user '$user_name': $volta_root"
            local volta_dir
            for volta_dir in "$volta_root"/*/; do
                [[ -d "$volta_dir" ]] || continue
                if [[ -f "$volta_dir/package.json" ]]; then
                    local node_version
                    node_version=$(resolve_node_version "$volta_dir")
                    build_package_record "$volta_dir" "UserGlobal" "$user_name" "volta" "$node_version" ""
                else
                    local sub_dir
                    for sub_dir in "$volta_dir"*/; do
                        [[ -d "$sub_dir" ]] || continue
                        if [[ -f "$sub_dir/package.json" ]]; then
                            local node_version
                            node_version=$(resolve_node_version "$sub_dir")
                            build_package_record "$sub_dir" "UserGlobal" "$user_name" "volta" "$node_version" ""
                        fi
                    done
                fi
            done
        fi
    done
}

# --- MAIN ---
if test_is_remote_ops; then
    OUTPUT_FILE="$S1_OUTPUT_DIR_PATH/NPM_Packages_Inventory.json"
    LOG_FILE="$S1_OUTPUT_DIR_PATH/NPM_Packages_Inventory.log"
elif [[ "$ADD_DATE" == true ]]; then
    timestamp=$(date "+%Y-%m-%d_%H%M%S")
    OUTPUT_FILE="${TMPDIR:-/tmp}/NPM_Packages_Inventory_${timestamp}.json"
    LOG_FILE="${TMPDIR:-/tmp}/NPM_Packages_Inventory_${timestamp}.log"
else
    OUTPUT_FILE="${TMPDIR:-/tmp}/NPM_Packages_Inventory.json"
    LOG_FILE="${TMPDIR:-/tmp}/NPM_Packages_Inventory.log"
fi

touch "$LOG_FILE" 2>/dev/null

if [[ $EUID -ne 0 ]]; then
    write_log "WARNING: Script is not running as root. Some user profiles may be inaccessible." "INFO"
else
    write_log "Running with root privileges." "INFO"
fi

write_log "Starting npm packages inventory..."
write_log "Output file: $OUTPUT_FILE"
write_log "Log file: $LOG_FILE"

ALL_RECORDS=()
ALL_RECORDS+=("$(get_os_info_json)")

USER_DIRS=()
while IFS= read -r user_dir; do
    USER_DIRS+=("$user_dir")
done < <(collect_user_dirs)

write_log "Found ${#USER_DIRS[@]} user profile(s) to scan."

scan_system_global
scan_user_packages "${USER_DIRS[@]}"

package_count=$(( ${#ALL_RECORDS[@]} - 1 ))
if [[ $package_count -lt 0 ]]; then
    package_count=0
fi
write_log "Total packages found: $package_count"

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

if [[ $package_count -gt 0 ]]; then
    write_log "Inventory completed successfully. JSON saved at: $OUTPUT_FILE" "SUCCESS"
else
    write_log "No npm packages found. Metadata-only JSON saved at: $OUTPUT_FILE" "INFO"
fi
