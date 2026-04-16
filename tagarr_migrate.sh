#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Tagarr — Config Migration Tool
#
# Migrates any tagarr config file to the latest format.
#
# What it does:
#   - Detects which config type from the filename (tagarr.conf,
#     tagarr_import.conf, tagarr_recover.conf, etc.)
#   - Downloads the matching conf.sample from GitHub automatically
#   - Creates a NEW config with all your values preserved:
#     API keys, release groups (including discovered ones), webhooks,
#     quality/audio filters, recovery settings, etc.
#   - Adds any new settings with safe defaults
#   - Lists which new settings were added so you can review them
#
# What it does NOT do:
#   - Never modifies your original config file (backed up to .old)
#   - Never enables new features automatically
#
# Requirements:
#   - curl (for downloading from GitHub)
#   - Your existing tagarr config file (any version)
#
# Usage:
#   ./tagarr_migrate.sh /path/to/tagarr_import.conf
#   ./tagarr_migrate.sh /path/to/tagarr.conf
#   ./tagarr_migrate.sh /path/to/tagarr_recover.conf
#   ./tagarr_migrate.sh --no-update /path/to/any_tagarr_config.conf
#
#   --no-update  Skip automatic self-update from GitHub
#
# Supported configs:
#   tagarr.conf, tagarr_import.conf, tagarr_import_sonarr.conf,
#   tagarr_recover.conf, tagarr_remove.conf, tagarr_rename.conf,
#   tagarr_list.conf
#
# Output:
#   Backs up your config to .old, then replaces it with the migrated
#   version. To review or roll back:
#     diff tagarr_import.conf.old tagarr_import.conf
#     mv tagarr_import.conf.old tagarr_import.conf
#
# Author: prophetSe7en
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
GITHUB_BASE="https://raw.githubusercontent.com/ProphetSe7en/tagarr/main"
SELF_URL="${GITHUB_BASE}/tagarr_migrate.sh"

# --- Parse flags ---
NO_UPDATE=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-update) NO_UPDATE=true ;;
        --all) RUN_ALL=true ;;
        --help|-h)
            echo "Usage: $0 [--all] [--no-update] [/path/to/tagarr_config.conf]"
            echo ""
            echo "Migrates any tagarr config to the latest format."
            echo "The config type is detected from the filename."
            echo ""
            echo "Options:"
            echo "  --all          Migrate all tagarr configs in the directory"
            echo "  --no-update    Skip automatic self-update from GitHub"
            echo ""
            echo "Supported: tagarr.conf, tagarr_import.conf,"
            echo "  tagarr_import_sonarr.conf, tagarr_recover.conf,"
            echo "  tagarr_remove.conf, tagarr_rename.conf, tagarr_list.conf,"
            echo "  tagarr_migrate.conf (opt-in script auto-update)"
            exit 0
            ;;
        *) ARGS+=("$arg") ;;
    esac
done
OLD_CONFIG="${ARGS[0]:-}"
RUN_ALL="${RUN_ALL:-false}"

# --- Self-update: check for newer version of this script ---
# Runs BEFORE config detection so old scripts get auto-detect on re-exec
if [ "$NO_UPDATE" = "false" ] && [ "${TAGARR_MIGRATE_NO_UPDATE:-}" != "1" ]; then
    latest=$(mktemp)
    if curl -fsSL "$SELF_URL" -o "$latest" 2>/dev/null; then
        if ! cmp -s "$SCRIPT_PATH" "$latest"; then
            echo "Updating migration script to latest version..."
            cp "$latest" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            rm -f "$latest"
            TAGARR_MIGRATE_NO_UPDATE=1 exec "$SCRIPT_PATH" "$@"
        fi
    fi
    rm -f "$latest"
fi

# --- Auto-update tagarr scripts (opt-in via tagarr_migrate.conf) ---
# Reads AUTOUPDATE_<SCRIPT>=true flags; only runs when config exists.
# Guarded against --all recursion via TAGARR_MIGRATE_SKIP_AUTO_UPDATE.
auto_update_scripts() {
    local migrate_conf="${SCRIPT_DIR}/tagarr_migrate.conf"
    [ -f "$migrate_conf" ] || return 0

    if ! command -v jq >/dev/null 2>&1; then
        echo "WARN: auto-update skipped — jq is required but not installed"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$migrate_conf"

    local versions_url="${GITHUB_BASE}/versions.json"
    local remote_manifest
    remote_manifest=$(curl -fsSL --max-time 5 "$versions_url" 2>/dev/null) || {
        echo "WARN: auto-update skipped — failed to fetch versions.json"
        return 0
    }

    local -a updated=() skipped=() failed=()
    local any_enabled=false

    # Each entry: "<script>|<flag_var>|<dir_var>"
    local entries=(
        "tagarr.sh|AUTOUPDATE_TAGARR|AUTOUPDATE_TAGARR_DIR"
        "tagarr_import.sh|AUTOUPDATE_TAGARR_IMPORT|AUTOUPDATE_TAGARR_IMPORT_DIR"
        "tagarr_import_sonarr.sh|AUTOUPDATE_TAGARR_IMPORT_SONARR|AUTOUPDATE_TAGARR_IMPORT_SONARR_DIR"
        "tagarr_list.sh|AUTOUPDATE_TAGARR_LIST|AUTOUPDATE_TAGARR_LIST_DIR"
        "tagarr_recover.sh|AUTOUPDATE_TAGARR_RECOVER|AUTOUPDATE_TAGARR_RECOVER_DIR"
        "tagarr_remove.sh|AUTOUPDATE_TAGARR_REMOVE|AUTOUPDATE_TAGARR_REMOVE_DIR"
        "tagarr_rename.sh|AUTOUPDATE_TAGARR_RENAME|AUTOUPDATE_TAGARR_RENAME_DIR"
    )

    local entry script flag_var dir_var enabled target_dir script_path
    local local_version remote_version tmp
    for entry in "${entries[@]}"; do
        IFS='|' read -r script flag_var dir_var <<<"$entry"

        enabled="${!flag_var:-false}"
        [ "$enabled" = "true" ] || continue
        any_enabled=true

        target_dir="${!dir_var:-}"
        [ -z "$target_dir" ] && target_dir="$SCRIPT_DIR"

        script_path="${target_dir}/${script}"
        if [ ! -f "$script_path" ]; then
            skipped+=("$script (not found at $target_dir)")
            continue
        fi

        local_version=$(grep -E '^SCRIPT_VERSION=' "$script_path" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        remote_version=$(echo "$remote_manifest" | jq -r --arg s "$script" '.[$s] // ""')

        if [ -z "$remote_version" ]; then
            skipped+=("$script (not listed in versions.json)")
            continue
        fi

        if [ "$local_version" = "$remote_version" ]; then
            skipped+=("$script (v$local_version — already current)")
            continue
        fi

        # Only update when remote is strictly newer (sort -V version sort)
        if [ "$(printf '%s\n%s\n' "$remote_version" "$local_version" | sort -V 2>/dev/null | tail -1)" != "$remote_version" ]; then
            skipped+=("$script (local v$local_version ahead of remote v$remote_version)")
            continue
        fi

        echo "Updating $script: v$local_version -> v$remote_version ($target_dir)"
        tmp=$(mktemp)
        if ! curl -fsSL "${GITHUB_BASE}/${script}" -o "$tmp" 2>/dev/null; then
            failed+=("$script (download failed)")
            rm -f "$tmp"
            continue
        fi
        # Sanity: downloaded file must be a script
        if ! head -1 "$tmp" | grep -q '^#!'; then
            failed+=("$script (downloaded file not a script)")
            rm -f "$tmp"
            continue
        fi

        cp "$script_path" "${script_path}.old"
        # Overwrite in place to preserve existing permissions/ownership
        cat "$tmp" > "$script_path"
        rm -f "$tmp"
        updated+=("$script: v$local_version -> v$remote_version")
    done

    [ "$any_enabled" = "false" ] && return 0

    echo ""
    echo "Script auto-update summary:"
    if [ ${#updated[@]} -gt 0 ]; then
        echo "  Updated (${#updated[@]}):"
        for x in "${updated[@]}"; do echo "    - $x"; done
        echo "  Previous versions backed up with .old suffix."
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        echo "  Skipped (${#skipped[@]}):"
        for x in "${skipped[@]}"; do echo "    - $x"; done
    fi
    if [ ${#failed[@]} -gt 0 ]; then
        echo "  Failed (${#failed[@]}):"
        for x in "${failed[@]}"; do echo "    - $x"; done
    fi
    echo ""
}

if [ "${TAGARR_MIGRATE_SKIP_AUTO_UPDATE:-}" != "1" ]; then
    auto_update_scripts
    # Discovery notice for the opt-in auto-update feature. Shown once per
    # invocation when tagarr_migrate.conf does not exist. Silent once the
    # user has opted in (or deliberately ignored by keeping a commented
    # copy in place). Guarded from --all recursion by the outer check.
    if [ ! -f "${SCRIPT_DIR}/tagarr_migrate.conf" ]; then
        echo "Tip: opt-in auto-update of tagarr scripts is available."
        echo "See: https://raw.githubusercontent.com/ProphetSe7en/tagarr/main/tagarr_migrate.conf.sample"
        echo ""
    fi
fi

# --- Handle --all: migrate every tagarr*.conf in script directory ---
if [ "$RUN_ALL" = "true" ]; then
    configs=()
    for f in "${SCRIPT_DIR}"/tagarr*.conf; do
        [ -f "$f" ] && configs+=("$f")
    done
    if [ ${#configs[@]} -eq 0 ]; then
        echo "No tagarr configs found in $(basename "$SCRIPT_DIR")."
        exit 1
    fi
    echo "Migrating ${#configs[@]} configs..."
    echo ""
    update_flag=""
    [ "$NO_UPDATE" = "true" ] && update_flag="--no-update"
    for f in "${configs[@]}"; do
        TAGARR_MIGRATE_NO_UPDATE=1 TAGARR_MIGRATE_SKIP_AUTO_UPDATE=1 "$SCRIPT_PATH" $update_flag "$f"
        echo ""
    done
    exit 0
fi

# Auto-detect: if no config given, look for tagarr*.conf in script directory
if [ -z "$OLD_CONFIG" ]; then
    configs=()
    for f in "${SCRIPT_DIR}"/tagarr*.conf; do
        [ -f "$f" ] && configs+=("$f")
    done
    if [ ${#configs[@]} -eq 1 ]; then
        OLD_CONFIG="${configs[0]}"
        echo "Auto-detected: $(basename "$OLD_CONFIG")"
    elif [ ${#configs[@]} -gt 1 ]; then
        echo "Multiple configs found in $(basename "$SCRIPT_DIR"):"
        for f in "${configs[@]}"; do
            echo "  $(basename "$f")"
        done
        echo ""
        echo "Specify which one, or use --all to migrate all:"
        echo "  $0 tagarr_import.conf"
        echo "  $0 --all"
        exit 1
    else
        echo "Usage: $0 [--all] [--no-update] /path/to/tagarr_config.conf"
        exit 1
    fi
fi

if [ ! -f "$OLD_CONFIG" ]; then
    echo "ERROR: Config not found: $OLD_CONFIG"
    echo ""
    echo "Usage: $0 /path/to/tagarr_config.conf"
    exit 1
fi

# --- Determine sample filename from config filename ---
config_basename=$(basename "$OLD_CONFIG")
sample_name="${config_basename%.conf}.conf.sample"

# Validate it's a known tagarr config
case "$config_basename" in
    tagarr.conf|tagarr_import.conf|tagarr_import_sonarr.conf|\
    tagarr_recover.conf|tagarr_remove.conf|tagarr_rename.conf|\
    tagarr_list.conf|tagarr_migrate.conf)
        ;;
    *)
        echo "ERROR: Unrecognized config file: $config_basename"
        echo ""
        echo "Supported: tagarr.conf, tagarr_import.conf,"
        echo "  tagarr_import_sonarr.conf, tagarr_recover.conf,"
        echo "  tagarr_remove.conf, tagarr_rename.conf, tagarr_list.conf,"
        echo "  tagarr_migrate.conf"
        exit 1
        ;;
esac

SAMPLE_URL="${GITHUB_BASE}/${sample_name}"

echo "Tagarr — Config Migration"
echo "=========================="
echo ""

# --- Check local config version before downloading ---
old_version=$(sed -n 's/^# Config version:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' "$OLD_CONFIG" 2>/dev/null | head -1)
[ -z "$old_version" ] && old_version="unknown"

echo "Checking for updates ($config_basename)..."

# Download just the header to read the version (fast)
remote_header=$(curl -fsSL "$SAMPLE_URL" 2>/dev/null | head -5 || true)
remote_version=$(echo "$remote_header" | sed -n 's/^# Config version:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p' | head -1)
[ -z "$remote_version" ] && remote_version="unknown"

if [ "$old_version" = "$remote_version" ] && [ "$old_version" != "unknown" ]; then
    echo ""
    echo "Config is already up to date (version $old_version). Nothing to do."
    exit 0
fi

# --- Download full sample from GitHub ---
echo "Downloading latest $sample_name (version $remote_version)..."

SAMPLE_FILE=$(mktemp)
trap 'rm -f "$SAMPLE_FILE"' EXIT

if ! curl -fsSL "$SAMPLE_URL" -o "$SAMPLE_FILE" 2>/dev/null; then
    echo "ERROR: Failed to download sample config from:"
    echo "  $SAMPLE_URL"
    echo ""
    echo "Check your internet connection, or download manually from:"
    echo "  https://github.com/ProphetSe7en/tagarr/blob/main/${sample_name}"
    exit 1
fi

# Verify it looks like a valid config sample
if ! grep -q '# ========== CONFIGURATION ==========' "$SAMPLE_FILE"; then
    echo "ERROR: Downloaded file doesn't look like a valid config sample"
    exit 1
fi

BACKUP_FILE="${OLD_CONFIG}.old"
OUTPUT_FILE="$OLD_CONFIG"
new_version="$remote_version"

echo "Done!"
echo ""
echo "Config:  $OLD_CONFIG (version: $old_version)"
echo "Sample:  $sample_name (version: $new_version)"
echo "Backup:  $BACKUP_FILE"
echo ""

# --- Discover array variable names from sample ---
declare -A ARRAY_VARS
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=\( ]]; then
        ARRAY_VARS["${BASH_REMATCH[1]}"]=1
    fi
done < "$SAMPLE_FILE"

# --- Extract array blocks from old config ---
declare -A old_arrays
for arr_name in "${!ARRAY_VARS[@]}"; do
    block=""
    in_block=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*${arr_name}=\( ]]; then
            in_block=true
            block="${arr_name}=("$'\n'
            continue
        fi
        if [ "$in_block" = "true" ]; then
            block+="${line}"$'\n'
            if [[ "$line" =~ ^[[:space:]]*\) ]]; then
                in_block=false
            fi
        fi
    done < "$OLD_CONFIG"
    old_arrays[$arr_name]="$block"
done

# --- Discover scalar variable names from sample ---
SCALAR_VARS=()
in_array=false
while IFS= read -r line; do
    # Track array blocks to skip them
    if [[ "$line" =~ ^[[:space:]]*[A-Z_]+=\( ]]; then
        in_array=true
        continue
    fi
    if [ "$in_array" = "true" ]; then
        [[ "$line" =~ ^[[:space:]]*\) ]] && in_array=false
        continue
    fi
    # Scalar variable assignment
    if [[ "$line" =~ ^[[:space:]]*([A-Z_]+)= ]]; then
        SCALAR_VARS+=("${BASH_REMATCH[1]}")
    fi
done < "$SAMPLE_FILE"

# --- Read scalar values from old config as raw text ---
declare -A old_raw_values
declare -A old_has_var
_in_old_array=false
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    # Track array blocks to skip their contents
    if [[ "$line" =~ ^[[:space:]]*[A-Z_]+=\( ]]; then
        _in_old_array=true
        continue
    fi
    if [ "$_in_old_array" = "true" ]; then
        [[ "$line" =~ ^[[:space:]]*\) ]] && _in_old_array=false
        continue
    fi
    if [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=(.*) ]]; then
        var_name="${BASH_REMATCH[1]}"
        var_value="${BASH_REMATCH[2]}"
        # Strip inline comment (but not # inside quotes)
        var_value=$(echo "$var_value" | sed 's/[[:space:]]*#[^"]*$//')
        # Strip surrounding quotes
        var_value="${var_value#\"}"
        var_value="${var_value%\"}"
        old_raw_values[$var_name]="$var_value"
        old_has_var[$var_name]=1
    fi
done < "$OLD_CONFIG"

# --- Build output: sample template with old values substituted ---
new_vars=()
output=""
skip_array=""

while IFS= read -r line; do
    # Handle array blocks — replace with old values if they exist
    if [ -n "$skip_array" ]; then
        if [[ "$line" =~ ^[[:space:]]*\) ]]; then
            [ -z "${old_arrays[$skip_array]:-}" ] && output+="${line}"$'\n'
            skip_array=""
        else
            [ -z "${old_arrays[$skip_array]:-}" ] && output+="${line}"$'\n'
        fi
        continue
    fi

    # Detect start of array block
    array_matched=false
    for arr_name in "${!ARRAY_VARS[@]}"; do
        if [[ "$line" =~ ^[[:space:]]*${arr_name}=\( ]]; then
            array_matched=true
            if [ -n "${old_arrays[$arr_name]:-}" ]; then
                output+="${old_arrays[$arr_name]}"
            else
                output+="${line}"$'\n'
            fi
            skip_array="$arr_name"
            break
        fi
    done
    if [ "$array_matched" = "true" ]; then
        continue
    fi

    # Replace scalar variable assignments with old values
    matched=false
    for var in "${SCALAR_VARS[@]}"; do
        if [[ "$line" =~ ^[[:space:]]*${var}= ]]; then
            matched=true
            if [ -n "${old_has_var[$var]:-}" ]; then
                inline_comment=""
                if [[ "$line" =~ [[:space:]]+(#.*)$ ]]; then
                    inline_comment="  ${BASH_REMATCH[1]}"
                fi
                old_value="${old_raw_values[$var]:-}"
                if [[ "$old_value" =~ ^(true|false)$ ]]; then
                    output+="${var}=${old_value}${inline_comment}"$'\n'
                else
                    output+="${var}=\"${old_value}\"${inline_comment}"$'\n'
                fi
            else
                output+="${line}"$'\n'
                new_vars+=("$var")
            fi
            break
        fi
    done

    # Pass through comments and blank lines unchanged
    if [ "$matched" = "false" ]; then
        output+="${line}"$'\n'
    fi
done < "$SAMPLE_FILE"

# --- Write output ---
# Backup original, then overwrite in place to preserve permissions/ownership
# (mv from mktemp would drop perms to mktemp's 600 default)
cp "$OLD_CONFIG" "$BACKUP_FILE"
printf '%s' "$output" > "$OUTPUT_FILE"

echo "Migration complete!"
echo ""

if [ ${#new_vars[@]} -gt 0 ]; then
    echo "New settings added (using defaults):"
    for var in "${new_vars[@]}"; do
        sample_val=$(grep -E "^[[:space:]]*${var}=" "$SAMPLE_FILE" | head -1 | sed "s/^[[:space:]]*${var}=//; s/[[:space:]]*#.*//" | tr -d '"')
        echo "  $var = $sample_val"
    done
    echo ""
fi

echo "Your original config has been backed up to:"
echo "  $BACKUP_FILE"
echo ""
echo "To review what changed:"
echo "  diff \"$BACKUP_FILE\" \"$OUTPUT_FILE\""
echo ""
echo "To roll back:"
echo "  mv \"$BACKUP_FILE\" \"$OUTPUT_FILE\""
