#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr Import Sonarr — Release Group Recovery on Import
# Version: 1.0.0
#
# Sonarr Connect handler that recovers missing release groups on import
# and upgrade events. When an episode arrives with an empty/unknown release
# group, the script looks up the grab history using the download ID and
# patches the episodefile with the correct group.
#
# This solves the scoring loop problem where some trackers use different
# names for the torrent vs the actual file — Sonarr grabs based on the
# torrent name (with release group), but the file doesn't include it,
# causing CF scores to drop and Sonarr to grab again.
#
# Setup:
#   Sonarr > Settings > Connect > Custom Script
#   Path: /scripts/tagarr_import_sonarr.sh
#   Events: On File Import, On Upgrade
#
# Configuration: tagarr_import_sonarr.conf
#
# Author: prophetSe7en
#
# WARNING: Runs automatically on every import/upgrade event.
# Test with a single episode before enabling as a Sonarr Connect handler.
# -----------------------------------------------------------------------------

SCRIPT_VERSION="1.0.0"

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

# Constructed API URL
SONARR_API_URL="${SONARR_URL}/api/v3"

########################################
# EVENT VARIABLES FROM SONARR
########################################

EVENT_TYPE="${sonarr_eventtype:-Test}"
SERIES_ID="${sonarr_series_id:-0}"
EPISODE_FILE_ID="${sonarr_episodefile_id:-}"
EPISODE_FILE_RELATIVE="${sonarr_episodefile_relativepath:-}"
RELEASE_GROUP_FROM_FILE="${sonarr_episodefile_releasegroup:-}"
DOWNLOAD_ID_FROM_EVENT="${sonarr_download_id:-}"
SEASON_NUMBER="${sonarr_release_seasonnumber:-}"
EPISODE_NUMBERS="${sonarr_release_episodenumbers:-}"

################################################################################
# LOGGING AND LOG ROTATION
################################################################################

log() {
    if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    fi
}

# Ensure log directory exists
if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi

if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 2097152 ]; then
        [ -f "${LOG_FILE}.old" ] && rm "${LOG_FILE}.old"
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log "INFO" "Log rotated - previous log saved as ${LOG_FILE}.old"
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
    # Only alert when remote is strictly newer than local (sort -V = version sort).
    # Prevents "update available: older-version" if local runs ahead of versions.json.
    if [ -n "$latest" ] && [ "$latest" != "$SCRIPT_VERSION" ] && \
       [ "$(printf '%s\n%s\n' "$latest" "$SCRIPT_VERSION" | sort -V 2>/dev/null | tail -1)" = "$latest" ]; then
        UPDATE_AVAILABLE="$latest"
        log "INFO" "Update available: v${latest} (current: v${SCRIPT_VERSION})"
    fi
}
_check_for_update

DISCORD_FOOTER="Tagarr Import Sonarr v${SCRIPT_VERSION} by ProphetSe7en"
[ -n "$UPDATE_AVAILABLE" ] && DISCORD_FOOTER="${DISCORD_FOOTER} • Update available (v${UPDATE_AVAILABLE})"

################################################################################
# HANDLE TEST EVENT (early exit — no API calls needed)
################################################################################

if [ "$EVENT_TYPE" = "Test" ]; then
    log "INFO" "============================================"
    log "INFO" "Tagarr Import Sonarr v${SCRIPT_VERSION}"
    log "INFO" "Event: Test"
    log "INFO" "============================================"

    if [ "${DISCORD_ENABLED:-false}" = "true" ] && [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        log "INFO" "Sending Discord test notification..."
        payload=$(jq -n \
            --argjson color 16753920 \
            --arg footer_text "$DISCORD_FOOTER" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
            '{
                embeds: [{
                    title: "Tagarr Import Sonarr v'"${SCRIPT_VERSION}"' — Test OK",
                    color: $color,
                    fields: [
                        { name: "Status", value: "Connection successful", inline: true }
                    ],
                    footer: { text: $footer_text },
                    timestamp: $timestamp
                }]
            }')

        response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$payload")

        http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
            log "INFO" "Discord test notification sent successfully"
        else
            log "WARN" "Discord test notification failed (HTTP $http_code)"
        fi
    fi

    log "INFO" "Script completed successfully"
    exit 0
fi

################################################################################
# RELEASE GROUP RECOVERY VIA DOWNLOAD ID
################################################################################

fix_release_group_from_history() {
    local series_id="$1"
    local series_title="$2"
    local current_rg="$3"
    local episodefile_id="$4"
    local download_id="$5"

    # Only act on empty/Unknown release groups
    if [ -n "$current_rg" ] && [ "$current_rg" != "Unknown" ] && [ "$current_rg" != "null" ]; then
        return 1
    fi

    log "INFO" "Release group missing/unknown — attempting recovery via downloadId..."

    # Must have a downloadId to match against
    if [ -z "$download_id" ]; then
        log "INFO" "No downloadId available — cannot recover"
        return 1
    fi

    # Query history for this series (filter to grabs for performance)
    # Handle both bare array and paginated object responses
    local history_raw history_json
    history_raw=$(curl -s -f "${SONARR_API_URL}/history/series?seriesId=${series_id}&eventType=grabbed&apikey=${SONARR_API_KEY}") || history_raw=""
    history_json=$(echo "$history_raw" | jq 'if type == "object" then (.records // []) else (. // []) end' 2>/dev/null) || history_json=""

    if [ -z "$history_json" ] || [ "$history_json" = "null" ] || [ "$history_json" = "[]" ] || \
       ! echo "$history_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
        log "INFO" "No history found for series"
        return 1
    fi

    # Find grab with matching downloadId — exact match, no walking/guessing
    local grab_rg
    grab_rg=$(echo "$history_json" | jq -r --arg dlid "$download_id" '
        [.[] | select(.eventType == "grabbed" and .downloadId == $dlid)] |
        .[0].data.releaseGroup // .[0].data.ReleaseGroup // ""
    ') || grab_rg=""

    if [ -z "$grab_rg" ]; then
        log "INFO" "No grab found with downloadId $download_id"
        return 1
    fi

    log "INFO" "Found releaseGroup '$grab_rg' from grab with downloadId $download_id"

    if [ -z "$episodefile_id" ] || [ "$episodefile_id" = "null" ]; then
        log "WARN" "Cannot determine episodeFile ID — skipping fix"
        return 1
    fi

    # Fetch full episodefile object for PUT
    local epfile_json
    epfile_json=$(curl -s -f "${SONARR_API_URL}/episodefile/${episodefile_id}?apikey=${SONARR_API_KEY}") || epfile_json=""

    if [ -z "$epfile_json" ] || [ "$epfile_json" = "null" ]; then
        log "WARN" "Failed to fetch episodefile object — skipping fix"
        return 1
    fi

    # Patch releaseGroup and PUT
    local updated_epfile
    updated_epfile=$(echo "$epfile_json" | jq --arg rg "$grab_rg" '.releaseGroup = $rg')

    local put_response put_http_code
    put_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
        "${SONARR_API_URL}/episodefile/${episodefile_id}?apikey=${SONARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$updated_epfile")
    put_http_code=$(echo "$put_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

    if [ "$put_http_code" != "200" ] && [ "$put_http_code" != "202" ]; then
        log "WARN" "Failed to update episodefile releaseGroup (HTTP $put_http_code)"
        return 1
    fi

    log "INFO" "Fixed releaseGroup: '$grab_rg' applied to episodefile $episodefile_id"

    # Trigger rename so the file reflects the corrected releaseGroup
    if [ "${ENABLE_RENAME:-true}" = "true" ]; then
        local rename_response rename_http_code
        rename_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
            "${SONARR_API_URL}/command?apikey=${SONARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"RenameFiles\",\"seriesId\":${series_id},\"files\":[${episodefile_id}]}")
        rename_http_code=$(echo "$rename_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

        if [ "$rename_http_code" = "200" ] || [ "$rename_http_code" = "201" ]; then
            log "INFO" "Rename command triggered for series $series_id"
        else
            log "WARN" "Rename command failed (HTTP $rename_http_code) — file may need manual rename"
        fi
    fi

    RECOVER_RESULT="$grab_rg"
    return 0
}

################################################################################
# MAIN SCRIPT
################################################################################

log "INFO" "============================================"
log "INFO" "Tagarr Import Sonarr v${SCRIPT_VERSION}"
log "INFO" "Event: $EVENT_TYPE"
log "INFO" "============================================"

# Only process import events (Sonarr uses "Download" for both new and upgrades)
case "$EVENT_TYPE" in
    Download) ;;
    *)
        log "INFO" "Event type '$EVENT_TYPE' not handled — exiting"
        exit 0
        ;;
esac

# Get series details from Sonarr
log "INFO" "Fetching series details (ID: $SERIES_ID)..."
series_json=$(curl -s -f "${SONARR_API_URL}/series/${SERIES_ID}?apikey=${SONARR_API_KEY}") || {
    log "ERROR" "Failed to fetch series details from Sonarr"
    exit 1
}

if [ -z "$series_json" ] || [ "$series_json" = "null" ]; then
    log "ERROR" "Series $SERIES_ID not found in Sonarr"
    exit 1
fi

SERIES_TITLE=$(echo "$series_json" | jq -r '.title')
SERIES_YEAR=$(echo "$series_json" | jq -r '.year')

# Build episode label for display
EP_LABEL=""
if [ -n "$SEASON_NUMBER" ] && [ -n "$EPISODE_NUMBERS" ]; then
    EP_LABEL="S$(printf '%02d' "$SEASON_NUMBER")E$(printf '%02d' "$(echo "$EPISODE_NUMBERS" | cut -d, -f1)")"
elif [ -n "$EPISODE_FILE_RELATIVE" ]; then
    EP_LABEL=$(echo "$EPISODE_FILE_RELATIVE" | grep -oEi 'S[0-9]+E[0-9]+(-E[0-9]+)?' | head -1 | tr '[:lower:]' '[:upper:]')
fi
[ -z "$EP_LABEL" ] && EP_LABEL="unknown episode"

log "INFO" "Series: $SERIES_TITLE ($SERIES_YEAR)"
log "INFO" "Episode: $EP_LABEL"
log "INFO" "File: $EPISODE_FILE_RELATIVE"

# Get poster URL for Discord notification (Sonarr uses images array)
SERIES_POSTER_URL=""
poster_from_images=$(echo "$series_json" | jq -r '.images[] | select(.coverType == "poster") | .remoteUrl // .url // "" | select(length > 0)' | head -1)
if [ -n "$poster_from_images" ] && [ "$poster_from_images" != "null" ]; then
    SERIES_POSTER_URL="$poster_from_images"
fi

# Resolve release group — priority chain:
# 1. sonarr_episodefile_releasegroup (direct from Sonarr Connect event)
# 2. episodefile.releaseGroup (API)
# 3. downloadId → grab history lookup (exact match)

RELEASE_GROUP=""
RECOVER_RESULT=""

# Source 1: Sonarr Connect env var
if [ -n "$RELEASE_GROUP_FROM_FILE" ] && [ "$RELEASE_GROUP_FROM_FILE" != "null" ] && [ "$RELEASE_GROUP_FROM_FILE" != "Unknown" ]; then
    RELEASE_GROUP="$RELEASE_GROUP_FROM_FILE"
    log "INFO" "Release group from event: '$RELEASE_GROUP'"
fi

# Source 2: API (if env var was empty)
if [ -z "$RELEASE_GROUP" ] && [ -n "$EPISODE_FILE_ID" ]; then
    local_rg=$(curl -s "${SONARR_API_URL}/episodefile/${EPISODE_FILE_ID}?apikey=${SONARR_API_KEY}" | jq -r '.releaseGroup // ""')
    if [ -n "$local_rg" ] && [ "$local_rg" != "Unknown" ] && [ "$local_rg" != "null" ]; then
        RELEASE_GROUP="$local_rg"
        log "INFO" "Release group from API: '$RELEASE_GROUP'"
    fi
fi

# Source 3: Recovery from grab history via downloadId
if [ -z "$RELEASE_GROUP" ] && [ "${ENABLE_RECOVER:-true}" = "true" ]; then
    if fix_release_group_from_history "$SERIES_ID" "$SERIES_TITLE" "$RELEASE_GROUP" "$EPISODE_FILE_ID" "$DOWNLOAD_ID_FROM_EVENT"; then
        RELEASE_GROUP="$RECOVER_RESULT"
        log "INFO" "Proceeding with recovered releaseGroup: $RECOVER_RESULT"
    fi
fi

################################################################################
# SUMMARY
################################################################################

log "INFO" "============================================"
log "INFO" "Summary:"
if [ -n "$RECOVER_RESULT" ]; then
    log "INFO" "  Release Group Fixed: $RECOVER_RESULT"
elif [ -n "$RELEASE_GROUP" ]; then
    log "INFO" "  Release Group: $RELEASE_GROUP (already present)"
else
    log "INFO" "  No release group available — nothing to recover"
fi
log "INFO" "============================================"

################################################################################
# DISCORD NOTIFICATION (only when recovery happened)
################################################################################

if [ "${DISCORD_ENABLED:-false}" = "true" ] && [ -n "$RECOVER_RESULT" ]; then
    log "INFO" "Sending Discord notification..."

    notif_title="Release Group Fixed — ${SERIES_TITLE} ${EP_LABEL}"
    notif_color=3066993  # Green

    fields_json='[]'

    fields_json=$(echo "$fields_json" | jq \
        --arg instance "${SONARR_NAME:-Sonarr}" \
        --arg recovered "$RECOVER_RESULT" \
        --arg episode "$EP_LABEL" \
        --arg event_type "$EVENT_TYPE" \
        --arg filename "$EPISODE_FILE_RELATIVE" \
        '. += [
            { name: "Instance", value: $instance, inline: true },
            { name: "Release Group Fixed", value: $recovered, inline: true },
            { name: "Episode", value: $episode, inline: true },
            { name: "Event", value: $event_type, inline: true },
            { name: "Filename", value: $filename, inline: false }
        ]')

    payload=$(jq -n \
        --arg title "$notif_title" \
        --argjson color "$notif_color" \
        --arg poster_url "${SERIES_POSTER_URL:-}" \
        --argjson fields "$fields_json" \
        --arg footer_text "$DISCORD_FOOTER" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: { text: $footer_text },
                timestamp: $timestamp,
                thumbnail: { url: $poster_url }
            }]
        }')

    response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload")

    http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log "INFO" "Discord notification sent successfully"
    else
        log "WARN" "Discord notification failed (HTTP $http_code)"
    fi
elif [ "${DISCORD_ENABLED:-false}" = "true" ]; then
    log "INFO" "Nothing recovered — skipping Discord notification"
fi

log "INFO" "Script completed successfully"
exit 0
