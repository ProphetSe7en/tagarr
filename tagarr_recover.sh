#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr Recover — Release Group Recovery from Grab History
# Version: 2.0.0
#
# Scans movies/episodes in Radarr or Sonarr where the release group is
# missing or unknown, and recovers it from the grab history. This fixes
# media where the indexer had the correct release group but the actual
# filename did not include it (e.g., 126811 releases).
#
# Supports both Radarr (movies) and Sonarr (series/episodes) via the
# --app flag. Default: radarr.
#
# !! WARNING: STANDALONE SCRIPT ONLY !!
# This script is NOT a Connect handler. Do NOT add it as a Custom Script
# in Radarr/Sonarr > Settings > Connect. It does not read event variables
# and will malfunction if triggered by events.
# For automatic recovery on import, use:
#   - tagarr_import.sh (Radarr — includes tagging + discovery)
#   - tagarr_import_sonarr.sh (Sonarr — recovery only)
#
# NOTE: Recovery requires grab history with a release group. Media without
# any grab history (e.g., manually imported files) cannot be recovered.
#
# Features:
#   RECOVER    — Restore missing releaseGroup from grab history
#   VERIFY     — 5-point safety chain:
#                1. Blanks only — never overwrites existing releaseGroup
#                2. Filename check — flags files where the filename already
#                   contains a release group that the app missed
#                3. Import-verified grab — only uses grabs that were actually
#                   imported (skips failed downloads)
#                4. Non-empty — releaseGroup from history must have a value
#                5. Title+year match — sourceTitle must match metadata
#   RENAME     — Trigger file rename after fix (optional)
#   DUAL       — Process both primary and secondary instances
#   DRY-RUN    — Preview what would be fixed (default mode)
#   MULTI-APP  — Supports Radarr (movies) and Sonarr (series/episodes)
#
# Usage:
#   ./tagarr_recover.sh                         # Dry-run, both apps (default)
#   ./tagarr_recover.sh --app radarr            # Dry-run, Radarr only
#   ./tagarr_recover.sh --app sonarr --live     # Execute fixes in Sonarr
#   ./tagarr_recover.sh --live --no-rename      # Fix without renaming files
#   ./tagarr_recover.sh --instance primary      # Primary instance only
#   ./tagarr_recover.sh --app sonarr --series 5 # Single series by ID
#
# Configuration: tagarr_recover.conf
#
# Author: prophetSe7en
#
# WARNING: Modifies file metadata and optionally renames files.
# Always run with --dry-run first (default) and review output before using --live.
# -----------------------------------------------------------------------------

set -euo pipefail
SCRIPT_VERSION="2.0.0"

########################################
# CONFIG LOADING
########################################

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_NAME="$(basename "$0" .sh)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config not found: $CONFIG_FILE"
    exit 1
fi

########################################
# ARGUMENT HANDLING
########################################

DRY_RUN="${ENABLE_DRY_RUN:-true}"
RENAME="${ENABLE_RENAME:-true}"
INSTANCE="both"
ITEM_FILTER=""
DEBUG=false
APP_TYPE="${DEFAULT_APP:-both}"

show_help() {
    cat <<'HELP'
Usage: tagarr_recover.sh [OPTIONS]

Recover missing release groups from Radarr/Sonarr grab history.

Options:
  --app TYPE             Application: radarr, sonarr, both (default: both)
  --dry-run              Preview what would be fixed (default)
  --live                 Execute the fixes
  --instance TYPE        Which instance to process: primary, secondary, both (default: both)
  --movie ID             Process a single movie by Radarr movie ID (radarr only)
  --series ID            Process a single series by Sonarr series ID (sonarr only)
  --no-rename            Skip file rename even in live mode
  --debug                Dump full data for each item (file JSON, history events)
  --help                 Show this help message

Examples:
  ./tagarr_recover.sh                          # Dry-run, both apps (default)
  ./tagarr_recover.sh --app radarr             # Dry-run, Radarr only
  ./tagarr_recover.sh --app sonarr --live      # Fix Sonarr episodes
  ./tagarr_recover.sh --live --no-rename       # Fix without renaming
  ./tagarr_recover.sh --instance primary       # Primary only
  ./tagarr_recover.sh --movie 123              # Single movie by ID
  ./tagarr_recover.sh --app sonarr --series 5  # Single series by ID
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --app requires a value (radarr|sonarr|both)"
                exit 1
            fi
            APP_TYPE="$2"
            shift 2
            ;;
        --live)
            DRY_RUN=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-rename)
            RENAME=false
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --instance)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --instance requires a value (primary|secondary|both)"
                exit 1
            fi
            INSTANCE="$2"
            shift 2
            ;;
        --movie)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --movie requires a Radarr movie ID"
                exit 1
            fi
            ITEM_FILTER="$2"
            APP_TYPE="radarr"
            shift 2
            ;;
        --series)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --series requires a Sonarr series ID"
                exit 1
            fi
            ITEM_FILTER="$2"
            APP_TYPE="sonarr"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--app radarr|sonarr|both] [--live|--dry-run] [--instance primary|secondary|both] [--movie ID] [--series ID] [--no-rename] [--help]"
            exit 1
            ;;
    esac
done

# Validate --app value
case "$APP_TYPE" in
    radarr|sonarr|both) ;;
    *) echo "ERROR: Invalid --app value '$APP_TYPE' (must be radarr|sonarr|both)"; exit 1 ;;
esac

# Validate --instance value
case "$INSTANCE" in
    primary|secondary|both) ;;
    *) echo "ERROR: Invalid --instance value '$INSTANCE' (must be primary|secondary|both)"; exit 1 ;;
esac

# --movie/--series with --instance both is ambiguous (IDs are per-instance)
if [ -n "$ITEM_FILTER" ] && [ "$INSTANCE" = "both" ]; then
    INSTANCE="primary"
fi

# --movie/--series requires a specific app (not both)
if [ -n "$ITEM_FILTER" ] && [ "$APP_TYPE" = "both" ]; then
    echo "ERROR: --movie/--series requires --app radarr or --app sonarr (not both)"
    exit 1
fi

########################################
# TERMINAL COLORS
########################################

if [ -t 1 ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    GREEN="" YELLOW="" RED="" CYAN="" NC=""
fi

########################################
# LOGGING
########################################

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    echo -e "$msg"
    if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
        # Strip ANSI escape codes for clean log file
        echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    fi
}

# Ensure log directory exists
if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi

# Log rotation — 2 MiB
if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 2097152 ]; then
        [ -f "${LOG_FILE}.old" ] && rm "${LOG_FILE}.old"
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log "INFO" "Log rotated"
    fi
fi

################################################################################
# UPDATE CHECK
################################################################################

UPDATE_AVAILABLE=""
_check_for_update() {
    local versions_url="https://raw.githubusercontent.com/ProphetSe7en/tagarr/main/versions.json"
    local script_name
    script_name="$(basename "$0")"
    local remote_json
    remote_json=$(curl -fsSL --max-time 5 "$versions_url" 2>/dev/null) || return 0
    local latest
    latest=$(echo "$remote_json" | jq -r --arg s "$script_name" '.[$s] // ""' 2>/dev/null) || return 0
    if [ -n "$latest" ] && [ "$latest" != "$SCRIPT_VERSION" ]; then
        UPDATE_AVAILABLE="$latest"
        log "INFO" "Update available: v${latest} (current: v${SCRIPT_VERSION})"
    fi
}
_check_for_update

DISCORD_FOOTER="Tagarr Recover v${SCRIPT_VERSION} by ProphetSe7en"
[ -n "$UPDATE_AVAILABLE" ] && DISCORD_FOOTER="${DISCORD_FOOTER} • Update available (v${UPDATE_AVAILABLE})"

################################################################################
# FILENAME RELEASE GROUP EXTRACTION
################################################################################

# Extracts the release group from a media filename by parsing the text after
# the last hyphen before the file extension. Filters out known non-group
# patterns (codecs, resolutions, audio fragments).
#
# Returns group name via stdout (exit 0) or nothing (exit 1).
#
# Examples:
#   Movie.Name.2024.WEB-DL.h265-FLUX.mkv             → FLUX
#   Movie Name 2024 WEB-DL h265-FLUX.mkv              → FLUX
#   Movie.Name.2024.WEBDL-2160p.DTS-HD.MA.7.1.h265.mkv → (none)
#   Movie.Name.2024.WEB-DL.DTS-HD.MA.7.1.H.265.mkv   → (none)
extract_group_from_filename() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    # Remove video extension
    local base="${filename%.*}"

    # No hyphen = no group
    [[ "$base" != *-* ]] && return 1

    # Text after last hyphen
    local candidate="${base##*-}"

    # Must be non-empty
    [ -z "$candidate" ] && return 1

    # Must be a single token (no dots or spaces — those indicate multi-part
    # codec/audio remnants like "HD.MA.7.1.DV.h265" from DTS-HD split)
    [[ "$candidate" == *.* ]] && return 1
    [[ "$candidate" == *" "* ]] && return 1

    # Skip known non-group patterns (case-insensitive)
    local lower="${candidate,,}"
    case "$lower" in
        h264|h265|x264|x265|hevc|avc|vc1|remux) return 1 ;;
        dl|hd) return 1 ;;  # From WEB-DL, DTS-HD
    esac

    # Skip resolution patterns (2160p, 1080p, etc.)
    [[ "$lower" =~ ^[0-9]+(p|i)$ ]] && return 1

    echo "$candidate"
    return 0
}

################################################################################
# IMPORT-VERIFIED GRAB LOOKUP
################################################################################

# Finds the most recent grab that produced the current file.
# Walks history events newest-to-oldest, looking for the FIRST (newest)
# import event and its matching grab:
#
#   1. Find the newest import event — this produced the current file
#   2. Find its matching grab by downloadId
#   3. If the grab has a releaseGroup, return it
#   4. If no matching grab exists (pruned) or group is empty, stop — do NOT
#      fall through to older grabs (they belong to previous files)
#
# This prevents recovering a release group from an old grab when the
# current file was imported by a different, newer grab that has no group.
#
# Verification priority:
#   1. downloadId match (grab+import share same ID) — strongest
#   2. Title+year match (fallback when downloadId missing/mismatched)
#
# Returns releaseGroup via stdout (exit 0) or nothing (exit 1).
# Return codes: 0 = found group (echoed), 1 = no verified grab, 2 = verified but empty group
find_imported_grab_group() {
    local history_json="$1"
    local movie_title="$2"
    local movie_year="$3"

    local event_count
    event_count=$(echo "$history_json" | jq '(. // []) | length' 2>/dev/null) || event_count=0
    [ "$event_count" -eq 0 ] && return 1

    # Pre-process all events into tab-separated lines (single jq call)
    # Sorted newest first for walk-back logic
    # Fields: eventType, releaseGroup, sourceTitle, downloadId
    # Note: empty fields use sentinel __NONE__ to prevent bash read
    # from collapsing consecutive tabs (IFS=tab treats adjacent tabs as one)
    local events_tsv
    events_tsv=$(echo "$history_json" | jq -r '
        (. // []) | sort_by(.date) | reverse | .[] |
        [
            .eventType,
            ((.data.releaseGroup // .data.ReleaseGroup // "" | if . == "" then "__NONE__" else . end)),
            (.sourceTitle // ""),
            ((.downloadId // "" | if . == "" then "__NONE__" else . end))
        ] | @tsv
    ') || return 1

    # Step 1: Find the newest import event and its downloadId
    local newest_import_dlid="__NONE__"
    local found_import=false

    while IFS=$'\t' read -r event_type grab_rg source_title dl_id; do
        case "$event_type" in
            downloadFolderImported|movieFileImported|episodeFileImported)
                newest_import_dlid="$dl_id"
                found_import=true
                break
                ;;
        esac
    done <<< "$events_tsv"

    # No import in history at all
    [ "$found_import" = "false" ] && return 1

    # Step 2: Find the grab that matches this import
    while IFS=$'\t' read -r event_type grab_rg source_title dl_id; do
        [ "$event_type" != "grabbed" ] && continue

        # Strategy A: downloadId match (strongest — grab produced this import)
        if [ "$dl_id" != "__NONE__" ] && [ "$newest_import_dlid" != "__NONE__" ] && \
           [ "$dl_id" = "$newest_import_dlid" ]; then
            if [ "$grab_rg" = "__NONE__" ]; then
                return 2  # Verified grab, but no release group
            fi
            echo "$grab_rg"
            return 0
        fi

        # Strategy B: Title+year verification (fallback when downloadId doesn't match)
        # Only consider grabs that DON'T have a downloadId matching a DIFFERENT import
        # (those belong to older files)
        if [ "$dl_id" != "__NONE__" ] && [ "$newest_import_dlid" != "__NONE__" ] && \
           [ "$dl_id" != "$newest_import_dlid" ]; then
            # This grab's downloadId matches a different import — skip it
            continue
        fi

        # downloadId missing on one or both sides — use title+year as fallback
        local source_lower="${source_title,,}"
        local title_lower="${movie_title,,}"
        local title_word
        title_word=$(echo "$title_lower" | sed -E 's/^(the|a|an) //' | awk '{print $1}')

        local year_valid=false title_valid=false
        [ -n "$movie_year" ] && [ "$movie_year" != "0" ] && [ "$movie_year" != "null" ] && year_valid=true
        [ -n "$title_word" ] && [ "${#title_word}" -ge 3 ] && title_valid=true

        local year_match=false title_match=false
        if [ "$year_valid" = "true" ] && \
           echo "$source_title" | grep -wq "$movie_year"; then
            year_match=true
        fi
        if [ "$title_valid" = "true" ] && \
           echo "$source_lower" | grep -Fqi "$title_word"; then
            title_match=true
        fi

        local verified=false
        if [ "$year_valid" = "true" ] && [ "$title_valid" = "true" ]; then
            [ "$year_match" = "true" ] && [ "$title_match" = "true" ] && verified=true
        else
            [ "$year_match" = "true" ] || [ "$title_match" = "true" ] && verified=true
        fi

        if [ "$verified" = "true" ]; then
            if [ "$grab_rg" = "__NONE__" ]; then
                return 2
            fi
            echo "$grab_rg"
            return 0
        fi
    done <<< "$events_tsv"

    # No matching grab found for the newest import (grab may be pruned)
    return 1
}

################################################################################
# DISCORD NOTIFICATIONS
################################################################################

send_discord_summary() {
    local instance_name="$1"
    local total="$2"
    local fixed="$3"
    local no_history="$4"
    local failed_verify="$5"
    local mode="$6"
    local duration="$7"
    local flagged="${8:-0}"
    local no_group="${9:-0}"

    if [ "${DISCORD_ENABLED:-false}" != "true" ] || [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        return 0
    fi

    local color
    if [ "$mode" = "DRY-RUN" ]; then
        color=3447003   # Blue
    elif [ "$fixed" -gt 0 ]; then
        color=3066993   # Green
    else
        color=9807270   # Grey
    fi

    local mode_value="$mode"
    [ "$mode" = "LIVE" ] && [ "$RENAME" = "true" ] && mode_value="LIVE + Rename"

    # Build fields dynamically — only show categories with hits
    local fields_json='[]'
    fields_json=$(echo "$fields_json" | jq \
        --arg mode "$mode_value" \
        --arg total "$total" \
        '. += [
            { name: "Mode", value: $mode, inline: true },
            { name: "Missing Groups", value: $total, inline: true }
        ]')
    [ "$fixed" -gt 0 ] && fields_json=$(echo "$fields_json" | jq --arg v "$fixed" '. += [{ name: "Fixed", value: $v, inline: true }]')
    [ "$flagged" -gt 0 ] && fields_json=$(echo "$fields_json" | jq --arg v "$flagged" '. += [{ name: "Flagged", value: $v, inline: true }]')
    [ "$no_group" -gt 0 ] && fields_json=$(echo "$fields_json" | jq --arg v "$no_group" '. += [{ name: "No-RlsGroup", value: $v, inline: true }]')
    [ "$no_history" -gt 0 ] && fields_json=$(echo "$fields_json" | jq --arg v "$no_history" '. += [{ name: "No History", value: $v, inline: true }]')
    [ "$failed_verify" -gt 0 ] && fields_json=$(echo "$fields_json" | jq --arg v "$failed_verify" '. += [{ name: "Failed Verify", value: $v, inline: true }]')
    fields_json=$(echo "$fields_json" | jq --arg v "Completed in ${duration}s" '. += [{ name: "Runtime", value: $v, inline: true }]')

    local payload
    payload=$(jq -n \
        --arg title "Recover — ${instance_name} (${APP_TYPE^})" \
        --argjson color "$color" \
        --argjson fields "$fields_json" \
        --arg footer_text "$DISCORD_FOOTER" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: { text: $footer_text },
                timestamp: $timestamp
            }]
        }')

    local response http_code
    response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload")
    http_code=$(echo "$response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log "INFO" "Discord summary sent"
    else
        log "WARN" "Discord summary failed (HTTP $http_code)"
    fi
}

# Send a chunked movie list to Discord (matches tagarr pattern)
# Uses plain content messages with code blocks, chunked at 1800 chars
send_discord_item_list() {
    local title="$1"
    local content="$2"
    local color="$3"

    if [ "${DISCORD_ENABLED:-false}" != "true" ] || [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        return 0
    fi

    [ -z "$content" ] && return 0

    local max_content_size=1800

    if [ ${#content} -le "$max_content_size" ]; then
        # Single message — use embed with code block description
        local payload
        payload=$(jq -n \
            --arg title "$title" \
            --arg description "$(printf '\`\`\`\n%s\n\`\`\`' "$content")" \
            --argjson color "$color" \
            '{embeds: [{title: $title, description: $description, color: $color}]}')

        curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null 2>&1 || true
        sleep 0.5
    else
        # Multiple chunks
        local lines=()
        while IFS= read -r line; do
            lines+=("$line")
        done <<< "$content"

        local current_chunk="" chunk_num=1

        for line in "${lines[@]}"; do
            local test_chunk="${current_chunk}${line}"$'\n'

            if [ ${#test_chunk} -gt "$max_content_size" ] && [ -n "$current_chunk" ]; then
                # Send current chunk
                local chunk_title="${title} (part ${chunk_num})"
                local payload
                payload=$(jq -n \
                    --arg title "$chunk_title" \
                    --arg description "$(printf '\`\`\`\n%s\n\`\`\`' "$current_chunk")" \
                    --argjson color "$color" \
                    '{embeds: [{title: $title, description: $description, color: $color}]}')

                curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
                    -H "Content-Type: application/json" \
                    -d "$payload" > /dev/null 2>&1 || true
                sleep 0.5

                chunk_num=$((chunk_num + 1))
                current_chunk="${line}"$'\n'
            else
                current_chunk="$test_chunk"
            fi
        done

        # Send final chunk
        if [ -n "$current_chunk" ]; then
            local chunk_title="${title}"
            [ "$chunk_num" -gt 1 ] && chunk_title="${title} (part ${chunk_num})"
            local payload
            payload=$(jq -n \
                --arg title "$chunk_title" \
                --arg description "$(printf '\`\`\`\n%s\n\`\`\`' "$current_chunk")" \
                --argjson color "$color" \
                '{embeds: [{title: $title, description: $description, color: $color}]}')

            curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -d "$payload" > /dev/null 2>&1 || true
            sleep 0.5
        fi

        log "INFO" "Discord movie list sent ($chunk_num parts)"
    fi
}

################################################################################
# INSTANCE PROCESSOR
################################################################################

################################################################################
# ITEM PROCESSING — shared logic for a single file (movie or episode)
################################################################################

# Processes one item (movie or episodefile) through the safety chain and fix.
# Sets counters and list variables in the caller's scope.
process_item() {
    local api_url="$1"
    local api_key="$2"
    local item_title="$3"
    local item_year="$4"
    local file_id="$5"
    local rel_path="$6"
    local history_json="$7"       # Pre-fetched history JSON array
    local rename_payload="$8"
    local item_label="$9"         # Display label: "Title (2024)" or "Title — S01E05"
    local file_endpoint="${10}"   # "moviefile" or "episodefile"

    # SAFETY CHECK 1: Does the filename already contain a release group?
    local filename_group=""
    if [ -n "$rel_path" ]; then
        filename_group=$(extract_group_from_filename "$rel_path") || true
    fi

    if [ -n "$filename_group" ]; then
        log "INFO" "  ${YELLOW}Filename has release group '${filename_group}' but app has none — flagged${NC}"
        log "INFO" "  File: $rel_path"
        flagged=$((flagged + 1))
        flagged_items+="${item_label} — '${filename_group}' in filename"$'\n'
        return 0
    fi

    # SAFETY CHECK 2: Verify history exists
    if [ -z "$history_json" ] || [ "$history_json" = "null" ] || [ "$history_json" = "[]" ] || \
       ! echo "$history_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
        no_history=$((no_history + 1))
        log "INFO" "  No history — skipped"
        skipped_items+="${item_label} — no history"$'\n'
        return 0
    fi

    # Debug: dump all data
    if [ "$DEBUG" = "true" ]; then
        local event_count
        event_count=$(echo "$history_json" | jq 'length' 2>/dev/null) || event_count=0
        log "DEBUG" "  ======== DEBUG ========"
        log "DEBUG" "  Item: $item_label"
        log "DEBUG" "  File ID: $file_id"
        log "DEBUG" "  Relative Path: $rel_path"
        log "DEBUG" "  Filename Group Extract: '${filename_group:-none}'"
        log "DEBUG" ""
        # File API (direct)
        local debug_mf
        debug_mf=$(curl -s -f "${api_url}/${file_endpoint}/${file_id}?apikey=${api_key}" 2>/dev/null) || debug_mf=""
        if [ -n "$debug_mf" ] && [ "$debug_mf" != "null" ]; then
            log "DEBUG" "  --- File API ---"
            log "DEBUG" "  releaseGroup:  $(echo "$debug_mf" | jq -r '.releaseGroup // "null"')"
            log "DEBUG" "  sceneName:     $(echo "$debug_mf" | jq -r '.sceneName // "null"')"
            log "DEBUG" "  quality.name:  $(echo "$debug_mf" | jq -r '.quality.quality.name // "null"')"
            log "DEBUG" "  quality.source: $(echo "$debug_mf" | jq -r '.quality.quality.source // "null"')"
            log "DEBUG" "  dateAdded:     $(echo "$debug_mf" | jq -r '.dateAdded // "null"')"
        fi
        log "DEBUG" ""
        log "DEBUG" "  --- History ($event_count events, newest first) ---"
        echo "$history_json" | jq -r '
            (. // []) | sort_by(.date) | reverse | to_entries[] |
            "  [\(.key)] \(.value.date)  \(.value.eventType)" +
            "\n        sourceTitle:  \(.value.sourceTitle // "<none>")" +
            "\n        releaseGroup: \(.value.data.releaseGroup // .value.data.ReleaseGroup // "<none>")" +
            "\n        downloadId:   \(.value.downloadId // "<none>")" +
            "\n        quality:      \(.value.quality.quality.name // "<none>")" +
            ""
        ' 2>/dev/null | while IFS= read -r line; do
            log "DEBUG" "$line"
        done
        log "DEBUG" "  --- End History ---"
    fi

    # SAFETY CHECK 3-5: Find import-verified grab with title+year match
    local fixed_rg="" find_rc=0
    fixed_rg=$(find_imported_grab_group "$history_json" "$item_title" "$item_year") || find_rc=$?

    if [ "$DEBUG" = "true" ]; then
        log "DEBUG" "  find_imported_grab_group result: rg='${fixed_rg}' rc=${find_rc}"
    fi

    if [ -z "$fixed_rg" ]; then
        if [ "$find_rc" -eq 2 ]; then
            no_group=$((no_group + 1))
            log "INFO" "  Grab verified — No-RlsGroup"
            skipped_items+="${item_label} — No-RlsGroup"$'\n'
        else
            failed_verify=$((failed_verify + 1))
            log "INFO" "  No verified grab found — skipped"
            skipped_items+="${item_label} — no verified grab"$'\n'
        fi
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "  ${YELLOW}[DRY-RUN]${NC} Would fix: releaseGroup → '${GREEN}${fixed_rg}${NC}'"
        fixed=$((fixed + 1))
        fixed_items+="${item_label} → ${fixed_rg}"$'\n'
    else
        # Fetch full file object for PUT
        local file_json
        file_json=$(curl -s -f "${api_url}/${file_endpoint}/${file_id}?apikey=${api_key}") || file_json=""

        if [ -z "$file_json" ] || [ "$file_json" = "null" ]; then
            log "WARN" "  Failed to fetch file object — skipped"
            failed_verify=$((failed_verify + 1))
            skipped_items+="${item_label} — fetch failed"$'\n'
            return 0
        fi

        # Patch releaseGroup and PUT
        local updated_file
        updated_file=$(echo "$file_json" | jq --arg rg "$fixed_rg" '.releaseGroup = $rg') || {
            log "WARN" "  Failed to patch JSON — skipped"
            failed_verify=$((failed_verify + 1))
            skipped_items+="${item_label} — JSON patch failed"$'\n'
            return 0
        }

        local put_response put_http
        put_response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X PUT \
            "${api_url}/${file_endpoint}/${file_id}?apikey=${api_key}" \
            -H "Content-Type: application/json" \
            -d "$updated_file") || put_response="HTTP_CODE:000"
        put_http=$(echo "$put_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

        if [ "$put_http" = "200" ] || [ "$put_http" = "202" ]; then
            log "INFO" "  ${GREEN}Fixed:${NC} releaseGroup → '${fixed_rg}'"
            fixed=$((fixed + 1))
            fixed_items+="${item_label} → ${fixed_rg}"$'\n'

            if [ "$RENAME" = "true" ]; then
                local rename_response rename_http_code
                rename_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
                    "${api_url}/command?apikey=${api_key}" \
                    -H "Content-Type: application/json" \
                    -d "$rename_payload")
                rename_http_code=$(echo "$rename_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)
                if [ "$rename_http_code" = "200" ] || [ "$rename_http_code" = "201" ]; then
                    log "INFO" "  Rename triggered"
                else
                    log "WARN" "  Rename failed (HTTP $rename_http_code)"
                fi
                sleep 0.5
            fi
        else
            log "WARN" "  PUT failed (HTTP $put_http)"
            failed_verify=$((failed_verify + 1))
            skipped_items+="${item_label} — PUT failed (HTTP $put_http)"$'\n'
        fi
    fi
}

################################################################################
# INSTANCE PROCESSOR
################################################################################

process_instance() {
    local instance_name="$1"
    local base_url="$2"
    local api_key="$3"
    local api_url="${base_url}/api/v3"

    log "INFO" ""
    log "INFO" "========================================"
    log "INFO" "Processing: $instance_name"
    log "INFO" "========================================"

    # Sanity check
    log "INFO" "Testing connection..."
    if ! curl -s -f "${api_url}/system/status?apikey=${api_key}" > /dev/null; then
        log "ERROR" "Cannot connect to $instance_name at ${base_url}"
        return 1
    fi
    log "INFO" "Connected"

    local instance_start
    instance_start=$(date +%s)

    # Shared counters (modified by process_item)
    local fixed=0 no_history=0 failed_verify=0 no_group=0 flagged=0 processed=0
    local fixed_items="" skipped_items="" flagged_items=""
    local affected_count=0

    if [ "$APP_TYPE" = "radarr" ]; then
        _process_radarr "$api_url" "$api_key" "$instance_name"
    else
        _process_sonarr "$api_url" "$api_key" "$instance_name"
    fi

    local instance_end
    instance_end=$(date +%s)
    local instance_duration=$((instance_end - instance_start))

    log "INFO" ""
    log "INFO" "----------------------------------------"
    log "INFO" "$instance_name summary:"
    log "INFO" "  Affected:       $affected_count"
    [ "$fixed" -gt 0 ] && log "INFO" "  Fixed:          $fixed"
    [ "$flagged" -gt 0 ] && log "INFO" "  Flagged:        $flagged"
    [ "$no_group" -gt 0 ] && log "INFO" "  No-RlsGroup:    $no_group"
    [ "$no_history" -gt 0 ] && log "INFO" "  No history:     $no_history"
    [ "$failed_verify" -gt 0 ] && log "INFO" "  Failed verify:  $failed_verify"
    log "INFO" "----------------------------------------"

    local item_type
    item_type=$([ "$APP_TYPE" = "radarr" ] && echo "movies" || echo "episodes")

    # Discord: summary embed
    local mode_label
    mode_label=$([ "$DRY_RUN" = "true" ] && echo "DRY-RUN" || echo "LIVE")
    send_discord_summary "$instance_name" "$affected_count" "$fixed" "$no_history" "$failed_verify" \
        "$mode_label" "$instance_duration" "$flagged" "$no_group"
    sleep 0.5

    # Discord: fixed list
    if [ -n "$fixed_items" ]; then
        local fixed_title
        if [ "$DRY_RUN" = "true" ]; then
            fixed_title="Would Fix (${fixed} ${item_type})"
        else
            fixed_title="Fixed (${fixed} ${item_type})"
        fi
        send_discord_item_list "$fixed_title" "$fixed_items" 3066993  # Green
    fi

    # Discord: flagged list (group found in filename but app has none)
    if [ -n "$flagged_items" ]; then
        send_discord_item_list "Flagged — Group in Filename (${flagged} ${item_type})" "$flagged_items" 15105570  # Amber
    fi

    # Discord: skipped list
    if [ -n "$skipped_items" ]; then
        local skip_count=$((no_history + failed_verify + no_group))
        send_discord_item_list "Skipped (${skip_count} ${item_type})" "$skipped_items" 9807270  # Grey
    fi

    # Reminder after live fixes
    if [ "$DRY_RUN" = "false" ] && [ "$fixed" -gt 0 ]; then
        log "INFO" ""
        if [ "$APP_TYPE" = "radarr" ]; then
            log "INFO" "${CYAN}Tip:${NC} Run tagarr.sh to tag the ${fixed} movies with corrected release groups"
        else
            log "INFO" "${CYAN}Tip:${NC} ${fixed} episodes fixed with corrected release groups"
        fi
    fi
}

################################################################################
# RADARR PROCESSOR
################################################################################

_process_radarr() {
    local api_url="$1"
    local api_key="$2"
    local instance_name="$3"

    # Fetch movies
    local movies_json
    if [ -n "$ITEM_FILTER" ]; then
        log "INFO" "Fetching movie ID $ITEM_FILTER..."
        local single_movie
        single_movie=$(curl -s -f "${api_url}/movie/${ITEM_FILTER}?apikey=${api_key}") || {
            log "ERROR" "Failed to fetch movie $ITEM_FILTER from $instance_name"
            return 1
        }

        if [ -z "$single_movie" ] || [ "$single_movie" = "null" ]; then
            log "ERROR" "Movie $ITEM_FILTER not found in $instance_name"
            return 1
        fi

        local movie_title_display
        movie_title_display=$(echo "$single_movie" | jq -r '.title // "unknown"')
        log "INFO" "Movie: $movie_title_display"

        movies_json="[${single_movie}]"
    else
        log "INFO" "Fetching movies..."
        movies_json=$(curl -s -f "${api_url}/movie?apikey=${api_key}") || {
            log "ERROR" "Failed to fetch movies from $instance_name"
            return 1
        }

        if [ -z "$movies_json" ] || ! echo "$movies_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
            log "ERROR" "Invalid movie response from $instance_name"
            return 1
        fi

        local total
        total=$(echo "$movies_json" | jq 'length')
        log "INFO" "Total movies: $total"
    fi

    # Filter to movies with files but empty/missing releaseGroup
    local affected_json
    affected_json=$(echo "$movies_json" | jq '[.[] | select(
        .hasFile == true and
        (.movieFile.releaseGroup == null or
         .movieFile.releaseGroup == "" or
         .movieFile.releaseGroup == "Unknown")
    )]')

    affected_count=$(echo "$affected_json" | jq 'length')
    log "INFO" "Missing releaseGroup: $affected_count"

    if [ "$affected_count" -eq 0 ]; then
        log "INFO" "No movies need fixing in $instance_name"
        return 0
    fi

    log "INFO" ""

    while IFS= read -r movie; do
        processed=$((processed + 1))

        local movie_id movie_title movie_year moviefile_id rel_path
        movie_id=$(echo "$movie" | jq -r '.id')
        movie_title=$(echo "$movie" | jq -r '.title')
        movie_year=$(echo "$movie" | jq -r '.year')
        moviefile_id=$(echo "$movie" | jq -r '.movieFile.id // ""')
        rel_path=$(echo "$movie" | jq -r '.movieFile.relativePath // ""')

        log "INFO" "[${processed}/${affected_count}] ${movie_title} (${movie_year})"

        if [ -z "$moviefile_id" ] || [ "$moviefile_id" = "null" ]; then
            log "INFO" "  No moviefile ID — skipped"
            failed_verify=$((failed_verify + 1))
            skipped_items+="${movie_title} (${movie_year}) — no moviefile ID"$'\n'
            continue
        fi

        # Fetch history for this movie
        # Handle both bare array and paginated object responses
        local movie_history_raw movie_history
        movie_history_raw=$(curl -s -f "${api_url}/history/movie?movieId=${movie_id}&apikey=${api_key}") || movie_history_raw="[]"
        movie_history=$(echo "$movie_history_raw" | jq 'if type == "object" then (.records // []) else (. // []) end') || movie_history="[]"

        local rename_payload="{\"name\":\"RenameFiles\",\"movieId\":${movie_id},\"files\":[${moviefile_id}]}"
        local item_label="${movie_title} (${movie_year})"

        process_item "$api_url" "$api_key" "$movie_title" "$movie_year" \
            "$moviefile_id" "$rel_path" "$movie_history" "$rename_payload" \
            "$item_label" "moviefile"
    done < <(echo "$affected_json" | jq -c '.[]')
}

################################################################################
# SONARR PROCESSOR
################################################################################

_process_sonarr() {
    local api_url="$1"
    local api_key="$2"
    local instance_name="$3"

    # Fetch series
    local series_json
    if [ -n "$ITEM_FILTER" ]; then
        log "INFO" "Fetching series ID $ITEM_FILTER..."
        local single_series
        single_series=$(curl -s -f "${api_url}/series/${ITEM_FILTER}?apikey=${api_key}") || {
            log "ERROR" "Failed to fetch series $ITEM_FILTER from $instance_name"
            return 1
        }

        if [ -z "$single_series" ] || [ "$single_series" = "null" ]; then
            log "ERROR" "Series $ITEM_FILTER not found in $instance_name"
            return 1
        fi

        local series_title_display
        series_title_display=$(echo "$single_series" | jq -r '.title // "unknown"')
        log "INFO" "Series: $series_title_display"

        series_json="[${single_series}]"
    else
        log "INFO" "Fetching series..."
        series_json=$(curl -s -f "${api_url}/series?apikey=${api_key}") || {
            log "ERROR" "Failed to fetch series from $instance_name"
            return 1
        }

        if [ -z "$series_json" ] || ! echo "$series_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
            log "ERROR" "Invalid series response from $instance_name"
            return 1
        fi

        local total_series
        total_series=$(echo "$series_json" | jq 'length')
        log "INFO" "Total series: $total_series"
    fi

    # Process each series — fetch its episodefiles and check for missing releaseGroup
    local series_count
    series_count=$(echo "$series_json" | jq 'length')
    local series_idx=0

    while IFS= read -r series; do
        series_idx=$((series_idx + 1))

        local series_id series_title series_year
        series_id=$(echo "$series" | jq -r '.id')
        series_title=$(echo "$series" | jq -r '.title')
        series_year=$(echo "$series" | jq -r '.year')

        # Fetch episodefiles for this series
        local epfiles_json
        epfiles_json=$(curl -s -f "${api_url}/episodefile?seriesId=${series_id}&apikey=${api_key}") || epfiles_json="[]"

        if [ -z "$epfiles_json" ] || ! echo "$epfiles_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
            continue
        fi

        # Filter to episodefiles with empty/missing releaseGroup
        local affected_epfiles
        affected_epfiles=$(echo "$epfiles_json" | jq '[.[] | select(
            .releaseGroup == null or
            .releaseGroup == "" or
            .releaseGroup == "Unknown"
        )]')

        local ep_affected_count
        ep_affected_count=$(echo "$affected_epfiles" | jq 'length')

        [ "$ep_affected_count" -eq 0 ] && continue

        log "INFO" "[${series_idx}/${series_count}] ${series_title} (${series_year}) — ${ep_affected_count} files missing releaseGroup"

        # Add to total
        affected_count=$((affected_count + ep_affected_count))

        # Fetch history for entire series (one call, covers all episodes)
        # Handle both bare array and paginated object responses
        local series_history_raw series_history
        series_history_raw=$(curl -s -f "${api_url}/history/series?seriesId=${series_id}&apikey=${api_key}") || series_history_raw="[]"
        series_history=$(echo "$series_history_raw" | jq 'if type == "object" then (.records // []) else (. // []) end') || series_history="[]"

        while IFS= read -r epfile; do
            processed=$((processed + 1))

            local epfile_id season_num rel_path_ep episode_ids
            epfile_id=$(echo "$epfile" | jq -r '.id')
            season_num=$(echo "$epfile" | jq -r '.seasonNumber')
            rel_path_ep=$(echo "$epfile" | jq -r '.relativePath // ""')

            # Build episode label from relativePath (e.g., "S01E05", "S01E05E06", "S01E05-E06")
            local ep_label=""
            if [ -n "$rel_path_ep" ]; then
                ep_label=$(echo "$rel_path_ep" | grep -oEi 'S[0-9]+E[0-9]+([E-][0-9]+)*' | head -1 | tr '[:lower:]' '[:upper:]')
            fi
            [ -z "$ep_label" ] && ep_label="S$(printf '%02d' "$season_num")"

            local item_label="${series_title} — ${ep_label}"

            log "INFO" "  [${processed}] ${item_label}"

            if [ -z "$epfile_id" ] || [ "$epfile_id" = "null" ]; then
                log "INFO" "    No episodefile ID — skipped"
                failed_verify=$((failed_verify + 1))
                skipped_items+="${item_label} — no episodefile ID"$'\n'
                continue
            fi

            # Filter series history to events relevant to this episode file.
            # Strategy: match by episodeId (from the episodefile's episodes array),
            # then fall back to sourceTitle pattern matching (e.g., "S01E05").
            local ep_episode_ids
            ep_episode_ids=$(echo "$epfile" | jq -r '[(.episodes // [])[].id // empty]') 2>/dev/null || ep_episode_ids="[]"
            [ -z "$ep_episode_ids" ] && ep_episode_ids="[]"

            local ep_history
            ep_history=$(echo "$series_history" | jq --argjson eids "$ep_episode_ids" '
                [.[] | select(
                    (.episodeId // -1) as $eid |
                    ($eids | index($eid)) != null
                )]
            ' 2>/dev/null) || ep_history="[]"

            # Fallback: match sourceTitle by episode pattern (e.g., S01E05)
            if [ "$(echo "$ep_history" | jq 'length')" -eq 0 ] && [ -n "$ep_label" ]; then
                ep_history=$(echo "$series_history" | jq --arg pat "$ep_label" '
                    [.[] | select(.sourceTitle // "" | ascii_downcase | contains($pat | ascii_downcase))]
                ' 2>/dev/null) || ep_history="[]"
            fi

            local rename_payload="{\"name\":\"RenameFiles\",\"seriesId\":${series_id},\"files\":[${epfile_id}]}"

            process_item "$api_url" "$api_key" "$series_title" "$series_year" \
                "$epfile_id" "$rel_path_ep" "$ep_history" \
                "$rename_payload" "$item_label" "episodefile"
        done < <(echo "$affected_epfiles" | jq -c '.[]')

    done < <(echo "$series_json" | jq -c '.[]')

    if [ "$affected_count" -eq 0 ]; then
        log "INFO" "No episodes need fixing in $instance_name"
    fi
}

################################################################################
# MAIN
################################################################################

log "INFO" "========================================"
log "INFO" "Tagarr Recover v${SCRIPT_VERSION}"
log "INFO" "========================================"

if [ "$DRY_RUN" = "true" ]; then
    log "INFO" "Mode: ${YELLOW}DRY-RUN${NC} (use --live to execute)"
else
    log "INFO" "Mode: ${GREEN}LIVE${NC}"
fi
log "INFO" "App: ${APP_TYPE^}"
log "INFO" "Rename: $RENAME"
log "INFO" "Instance: $INSTANCE"
[ "$DEBUG" = "true" ] && log "INFO" "Debug: ${YELLOW}ENABLED${NC}"
if [ -n "$ITEM_FILTER" ]; then
    log "INFO" "Filter: $ITEM_FILTER (single $([ "$APP_TYPE" = "radarr" ] && echo "movie" || echo "series") mode)"
fi

# Run instances for a given app type
_run_app() {
    local app="$1"
    APP_TYPE="$app"

    local pri_name pri_url pri_key sec_enabled sec_name sec_url sec_key
    if [ "$app" = "radarr" ]; then
        pri_name="${PRIMARY_RADARR_NAME:-}"
        pri_url="${PRIMARY_RADARR_URL:-}"
        pri_key="${PRIMARY_RADARR_API_KEY:-}"
        sec_enabled="${ENABLE_SECONDARY_RADARR:-${ENABLE_SECONDARY:-false}}"
        sec_name="${SECONDARY_RADARR_NAME:-}"
        sec_url="${SECONDARY_RADARR_URL:-}"
        sec_key="${SECONDARY_RADARR_API_KEY:-}"
    else
        pri_name="${PRIMARY_SONARR_NAME:-}"
        pri_url="${PRIMARY_SONARR_URL:-}"
        pri_key="${PRIMARY_SONARR_API_KEY:-}"
        sec_enabled="${ENABLE_SECONDARY_SONARR:-false}"
        sec_name="${SECONDARY_SONARR_NAME:-}"
        sec_url="${SECONDARY_SONARR_URL:-}"
        sec_key="${SECONDARY_SONARR_API_KEY:-}"
    fi

    if [ -z "$pri_url" ] || [ -z "$pri_key" ]; then
        log "WARN" "No ${app^} instance configured — skipping"
        return 0
    fi

    if [ "$INSTANCE" = "primary" ] || [ "$INSTANCE" = "both" ]; then
        process_instance "$pri_name" "$pri_url" "$pri_key" || \
            log "ERROR" "${app^} primary instance failed — continuing"
    fi

    if [ "$INSTANCE" = "secondary" ] || [ "$INSTANCE" = "both" ]; then
        if [ "$sec_enabled" = "true" ]; then
            process_instance "$sec_name" "$sec_url" "$sec_key" || \
                log "ERROR" "${app^} secondary instance failed — continuing"
        else
            [ "$INSTANCE" = "secondary" ] && log "WARN" "${app^} secondary instance not enabled in config"
        fi
    fi
}

START_TIME=$(date +%s)

# Process requested app(s)
if [ "$APP_TYPE" = "both" ]; then
    _run_app "radarr"
    _run_app "sonarr"
else
    _run_app "$APP_TYPE"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "INFO" ""
log "INFO" "========================================"
log "INFO" "Completed in ${DURATION}s"
log "INFO" "========================================"
