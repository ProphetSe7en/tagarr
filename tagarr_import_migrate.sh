#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Tagarr Import — Config Migration Tool
#
# Migrates an existing tagarr_import.conf to the latest format.
#
# What it does:
#   - Downloads the latest conf.sample from GitHub automatically
#   - Creates a NEW config with all your values preserved:
#     API keys, release groups (including discovered ones), webhooks,
#     quality/audio filters, recovery settings, etc.
#   - Adds any new settings (like grab rename, scene detection,
#     IMAX/Open Matte toggles) with safe defaults
#   - Lists which new settings were added so you can review them
#
# What it does NOT do:
#   - Never modifies your original config file
#   - Never enables new features automatically (grab rename defaults to off)
#
# Requirements:
#   - curl (for downloading the latest sample from GitHub)
#   - Your existing tagarr_import.conf (any version)
#
# Usage:
#   ./tagarr_import_migrate.sh /path/to/your/tagarr_import.conf
#   ./tagarr_import_migrate.sh --no-update /path/to/your/tagarr_import.conf
#
#   --no-update  Skip automatic self-update from GitHub
#
#   If no path is given, it looks for tagarr_import.conf in the script directory.
#
# Output:
#   Backs up your config to tagarr_import.conf.old, then replaces it
#   with the migrated version. To review or roll back:
#     diff tagarr_import.conf.old tagarr_import.conf
#     mv tagarr_import.conf.old tagarr_import.conf
#
# Author: prophetSe7en
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
GITHUB_BASE="https://raw.githubusercontent.com/ProphetSe7en/tagarr/main"
SAMPLE_URL="${GITHUB_BASE}/tagarr_import.conf.sample"
SELF_URL="${GITHUB_BASE}/tagarr_import_migrate.sh"
# --- Parse flags ---
NO_UPDATE=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-update) NO_UPDATE=true ;;
        --help|-h)
            echo "Usage: $0 [--no-update] [/path/to/tagarr_import.conf]"
            echo ""
            echo "Options:"
            echo "  --no-update    Skip automatic self-update from GitHub"
            exit 0
            ;;
        *) ARGS+=("$arg") ;;
    esac
done
OLD_CONFIG="${ARGS[0]:-${SCRIPT_DIR}/tagarr_import.conf}"

# --- Self-update: check for newer version of this script ---
if [ "$NO_UPDATE" = "false" ] && [ "${TAGARR_MIGRATE_NO_UPDATE:-}" != "1" ]; then
    latest=$(mktemp)
    if curl -fsSL "$SELF_URL" -o "$latest" 2>/dev/null; then
        if ! cmp -s "$SCRIPT_PATH" "$latest"; then
            echo "Updating migration script to latest version..."
            cp "$latest" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            rm -f "$latest"
            # Re-run with same arguments, skip update check to prevent loop
            TAGARR_MIGRATE_NO_UPDATE=1 exec "$SCRIPT_PATH" "$@"
        fi
    fi
    rm -f "$latest"
fi

if [ ! -f "$OLD_CONFIG" ]; then
    echo "ERROR: Config not found: $OLD_CONFIG"
    echo ""
    echo "Usage: $0 /path/to/tagarr_import.conf"
    exit 1
fi

# --- Download latest sample from GitHub ---
echo "Tagarr Import — Config Migration"
echo "================================="
echo ""
echo "Downloading latest config template from GitHub..."

SAMPLE_FILE=$(mktemp)
trap 'rm -f "$SAMPLE_FILE"' EXIT

if ! curl -fsSL "$SAMPLE_URL" -o "$SAMPLE_FILE" 2>/dev/null; then
    echo "ERROR: Failed to download sample config from:"
    echo "  $SAMPLE_URL"
    echo ""
    echo "Check your internet connection, or download manually from:"
    echo "  https://github.com/ProphetSe7en/tagarr/blob/main/tagarr_import.conf.sample"
    exit 1
fi

# Verify it looks like a valid config sample
if ! grep -q "PRIMARY_RADARR_URL" "$SAMPLE_FILE"; then
    echo "ERROR: Downloaded file doesn't look like a valid config sample"
    exit 1
fi

BACKUP_FILE="${OLD_CONFIG}.old"
OUTPUT_FILE="$OLD_CONFIG"

# Read config versions
old_version=$(grep -oP '^# Config version:\s*\K[\d.]+' "$OLD_CONFIG" 2>/dev/null || echo "unknown")
new_version=$(grep -oP '^# Config version:\s*\K[\d.]+' "$SAMPLE_FILE" 2>/dev/null || echo "unknown")

echo "Done!"
echo ""
echo "Config:  $OLD_CONFIG (version: $old_version)"
echo "Sample:  version $new_version"
echo "Backup:  $BACKUP_FILE"

if [ "$old_version" = "$new_version" ] && [ "$old_version" != "unknown" ]; then
    echo ""
    echo "Config is already up to date (version $old_version). Nothing to do."
    exit 0
fi
echo ""

# --- Extract RELEASE_GROUPS from old config (full block including comments) ---
old_release_groups=""
in_rg_block=false
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*RELEASE_GROUPS=\( ]]; then
        in_rg_block=true
        old_release_groups="RELEASE_GROUPS=("$'\n'
        continue
    fi
    if [ "$in_rg_block" = "true" ]; then
        old_release_groups+="${line}"$'\n'
        if [[ "$line" =~ ^\) ]]; then
            in_rg_block=false
        fi
    fi
done < "$OLD_CONFIG"

# --- Extract QBIT_CLIENTS from old config ---
old_qbit_clients=""
in_qbit_block=false
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*QBIT_CLIENTS=\( ]]; then
        in_qbit_block=true
        old_qbit_clients="QBIT_CLIENTS=("$'\n'
        continue
    fi
    if [ "$in_qbit_block" = "true" ]; then
        old_qbit_clients+="${line}"$'\n'
        if [[ "$line" =~ ^\) ]]; then
            in_qbit_block=false
        fi
    fi
done < "$OLD_CONFIG"

# --- Read scalar values as raw text (no eval — preserves ${SCRIPT_DIR} etc.) ---
declare -A old_raw_values
while IFS= read -r line; do
    # Skip comments, blank lines, array lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ [\(\)] ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Z_]+)=(.*) ]]; then
        var_name="${BASH_REMATCH[1]}"
        var_value="${BASH_REMATCH[2]}"
        # Strip inline comment (but not # inside quotes)
        var_value=$(echo "$var_value" | sed 's/[[:space:]]*#[^"]*$//')
        # Strip surrounding quotes
        var_value="${var_value#\"}"
        var_value="${var_value%\"}"
        old_raw_values[$var_name]="$var_value"
    fi
done < "$OLD_CONFIG"

# --- List of all scalar variables to migrate ---
# If the variable existed in the old config, use its value.
# If not, keep the sample default.
SCALAR_VARS=(
    PRIMARY_RADARR_URL
    PRIMARY_RADARR_API_KEY
    PRIMARY_RADARR_NAME
    ENABLE_SYNC_TO_SECONDARY
    SECONDARY_RADARR_URL
    SECONDARY_RADARR_API_KEY
    SECONDARY_RADARR_NAME
    ENABLE_QUALITY_FILTER
    ENABLE_MA_WEBDL
    ENABLE_PLAY_WEBDL
    ENABLE_AUDIO_FILTER
    ENABLE_TRUEHD
    ENABLE_TRUEHD_ATMOS
    ENABLE_DTS_X
    ENABLE_DTS_HD_MA
    ENABLE_RECOVER
    ENABLE_GRAB_RENAME
    GRAB_RENAME_EXCLUDE_SCENE
    GRAB_RENAME_IMAX
    GRAB_RENAME_OPEN_MATTE
    ENABLE_DISCOVERY
    AUTO_TAG_DISCOVERED
    DISCORD_ENABLED
    DISCORD_WEBHOOK_URL
    ENABLE_DEBUG
    ENABLE_LOGGING
    LOG_FILE
)

# --- Check which variables exist in old config ---
declare -A old_has_var
for var in "${SCALAR_VARS[@]}"; do
    if grep -qE "^[[:space:]]*${var}=" "$OLD_CONFIG"; then
        old_has_var[$var]=1
    fi
done

# --- Build output: sample template with old values substituted ---
new_vars=()
output=""
skip_rg=false
skip_qbit=false

while IFS= read -r line; do
    # Replace RELEASE_GROUPS block with old one
    if [[ "$line" =~ ^[[:space:]]*RELEASE_GROUPS=\( ]]; then
        if [ -n "$old_release_groups" ]; then
            output+="${old_release_groups}"
        else
            output+="${line}"$'\n'
        fi
        skip_rg=true
        continue
    fi
    if [ "$skip_rg" = "true" ]; then
        if [[ "$line" =~ ^\) ]]; then
            [ -z "$old_release_groups" ] && output+="${line}"$'\n'
            skip_rg=false
        else
            [ -z "$old_release_groups" ] && output+="${line}"$'\n'
        fi
        continue
    fi

    # Replace QBIT_CLIENTS block with old one
    if [[ "$line" =~ ^[[:space:]]*QBIT_CLIENTS=\( ]]; then
        if [ -n "$old_qbit_clients" ]; then
            output+="${old_qbit_clients}"
        else
            output+="${line}"$'\n'
        fi
        skip_qbit=true
        continue
    fi
    if [ "$skip_qbit" = "true" ]; then
        if [[ "$line" =~ ^\) ]]; then
            [ -z "$old_qbit_clients" ] && output+="${line}"$'\n'
            skip_qbit=false
        else
            [ -z "$old_qbit_clients" ] && output+="${line}"$'\n'
        fi
        continue
    fi

    # Replace scalar variable assignments with old values
    matched=false
    for var in "${SCALAR_VARS[@]}"; do
        if [[ "$line" =~ ^[[:space:]]*${var}= ]]; then
            matched=true
            if [ -n "${old_has_var[$var]:-}" ]; then
                # Preserve old value — extract inline comment from sample
                inline_comment=""
                if [[ "$line" =~ [[:space:]]+(#.*)$ ]]; then
                    inline_comment="  ${BASH_REMATCH[1]}"
                fi
                old_value="${old_raw_values[$var]:-}"
                # Quote strings, don't quote booleans/paths-with-vars
                if [[ "$old_value" =~ ^(true|false)$ ]]; then
                    output+="${var}=${old_value}${inline_comment}"$'\n'
                else
                    output+="${var}=\"${old_value}\"${inline_comment}"$'\n'
                fi
            else
                # New variable — keep sample default, flag as new
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
TEMP_OUTPUT=$(mktemp)
printf '%s' "$output" > "$TEMP_OUTPUT"

# Backup original, replace with new
cp "$OLD_CONFIG" "$BACKUP_FILE"
mv "$TEMP_OUTPUT" "$OUTPUT_FILE"

echo "Migration complete!"
echo ""

if [ ${#new_vars[@]} -gt 0 ]; then
    echo "New settings added (using defaults):"
    for var in "${new_vars[@]}"; do
        # Get the default value from the sample
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
