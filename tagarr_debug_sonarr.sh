#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Tagarr Debug Sonarr — Sonarr Connect Event Inspector
#
# Logs ALL environment variables and API data available during a Connect event.
# Install as a Sonarr Connect handler to see exactly what data Sonarr provides
# at the moment each event fires.
#
# Setup:
#   Sonarr > Settings > Connect > Custom Script
#   Path: /scripts/tagarr_debug_sonarr.sh
#   Events: Enable ALL events you want to inspect
#
# Output: tagarr_debug_sonarr.log (same directory as script)
# -----------------------------------------------------------------------------

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="${SCRIPT_DIR}/tagarr_debug_sonarr.log"

# Sonarr API config — update these for your instance
SONARR_URL="http://localhost:8989"
SONARR_API_KEY="your-api-key-here"
SONARR_API="${SONARR_URL}/api/v3"

NOW=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "[$NOW] $1" >> "$LOG_FILE"
}

divider() {
    log "$(printf '=%.0s' {1..80})"
}

# Rotate log if > 1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)" -gt 1048576 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

divider
log "TAGARR DEBUG SONARR — Event captured at $NOW"
divider

########################################
# SECTION 1: ALL SONARR ENV VARIABLES
########################################

log ""
log "--- SECTION 1: SONARR ENVIRONMENT VARIABLES ---"
log ""

# Capture all sonarr_* env vars (sorted)
env_count=0
while IFS= read -r line; do
    log "  $line"
    env_count=$((env_count + 1))
done < <(env | grep -i '^sonarr_' | sort)

log ""
log "Total sonarr_* variables: $env_count"

# Highlight the key ones explicitly
log ""
log "--- KEY VARIABLES (explicit) ---"
log "  sonarr_eventtype              = ${sonarr_eventtype:-<not set>}"
log "  sonarr_series_id              = ${sonarr_series_id:-<not set>}"
log "  sonarr_series_title           = ${sonarr_series_title:-<not set>}"
log "  sonarr_series_tvdbid          = ${sonarr_series_tvdbid:-<not set>}"
log "  sonarr_series_type            = ${sonarr_series_type:-<not set>}"
log "  sonarr_episodefile_id         = ${sonarr_episodefile_id:-<not set>}"
log "  sonarr_episodefile_relativepath = ${sonarr_episodefile_relativepath:-<not set>}"
log "  sonarr_episodefile_path       = ${sonarr_episodefile_path:-<not set>}"
log "  sonarr_episodefile_scenename  = ${sonarr_episodefile_scenename:-<not set>}"
log "  sonarr_episodefile_releasegroup = ${sonarr_episodefile_releasegroup:-<not set>}"
log "  sonarr_episodefile_quality    = ${sonarr_episodefile_quality:-<not set>}"
log "  sonarr_release_releasegroup   = ${sonarr_release_releasegroup:-<not set>}"
log "  sonarr_release_title          = ${sonarr_release_title:-<not set>}"
log "  sonarr_release_quality        = ${sonarr_release_quality:-<not set>}"
log "  sonarr_release_seasonnumber   = ${sonarr_release_seasonnumber:-<not set>}"
log "  sonarr_release_episodenumbers = ${sonarr_release_episodenumbers:-<not set>}"
log "  sonarr_download_id            = ${sonarr_download_id:-<not set>}"
log "  sonarr_download_client        = ${sonarr_download_client:-<not set>}"
log "  sonarr_isupgrade              = ${sonarr_isupgrade:-<not set>}"
log "  sonarr_deletedrelativepaths   = ${sonarr_deletedrelativepaths:-<not set>}"
log "  sonarr_deletedpaths           = ${sonarr_deletedpaths:-<not set>}"

SERIES_ID="${sonarr_series_id:-0}"
EPISODE_FILE_ID="${sonarr_episodefile_id:-}"

if [ "$SERIES_ID" = "0" ] || [ -z "$SERIES_ID" ]; then
    log ""
    log "NOTE: No series ID — this may be a Test event or event without series context"
    divider
    log "END OF DEBUG CAPTURE"
    divider
    log ""
    exit 0
fi

########################################
# SECTION 2: SERIES API RESPONSE
########################################

log ""
log "--- SECTION 2: SERIES API RESPONSE ---"
log ""

series_json=$(curl -s "${SONARR_API}/series/${SERIES_ID}?apikey=${SONARR_API_KEY}")

if [ -n "$series_json" ] && [ "$series_json" != "null" ]; then
    log "  title         = $(echo "$series_json" | jq -r '.title // "null"')"
    log "  year          = $(echo "$series_json" | jq -r '.year // "null"')"
    log "  tvdbId        = $(echo "$series_json" | jq -r '.tvdbId // "null"')"
    log "  imdbId        = $(echo "$series_json" | jq -r '.imdbId // "null"')"
    log "  seriesType    = $(echo "$series_json" | jq -r '.seriesType // "null"')"
    log "  status        = $(echo "$series_json" | jq -r '.status // "null"')"
    log "  episodeCount  = $(echo "$series_json" | jq -r '.statistics.episodeCount // "null"')"
    log "  tags          = $(echo "$series_json" | jq -c '.tags // []')"
else
    log "  ERROR: Failed to fetch series API response"
fi

########################################
# SECTION 3: EPISODE FILE API (direct)
########################################

if [ -n "$EPISODE_FILE_ID" ] && [ "$EPISODE_FILE_ID" != "0" ]; then
    log ""
    log "--- SECTION 3: EPISODE FILE API (direct fetch) ---"
    log ""

    episodefile_json=$(curl -s "${SONARR_API}/episodefile/${EPISODE_FILE_ID}?apikey=${SONARR_API_KEY}")

    if [ -n "$episodefile_json" ] && [ "$episodefile_json" != "null" ]; then
        log "  id            = $(echo "$episodefile_json" | jq -r '.id // "null"')"
        log "  relativePath  = $(echo "$episodefile_json" | jq -r '.relativePath // "null"')"
        log "  releaseGroup  = $(echo "$episodefile_json" | jq -r '.releaseGroup // "null"')"
        log "  sceneName     = $(echo "$episodefile_json" | jq -r '.sceneName // "null"')"
        log "  dateAdded     = $(echo "$episodefile_json" | jq -r '.dateAdded // "null"')"
        log "  quality       = $(echo "$episodefile_json" | jq -r '.quality.quality.name // "null"')"
        log "  audioCodec    = $(echo "$episodefile_json" | jq -r '.mediaInfo.audioCodec // "null"')"
        log "  audioChannels = $(echo "$episodefile_json" | jq -r '.mediaInfo.audioChannels // "null"')"
    else
        log "  ERROR: Failed to fetch episode file (may have been deleted)"
    fi
else
    log ""
    log "--- SECTION 3: EPISODE FILE API ---"
    log ""
    log "  SKIPPED: No episodefile_id available for this event"
fi

########################################
# SECTION 4: SERIES HISTORY
########################################

log ""
log "--- SECTION 4: SERIES HISTORY (recent events, newest first) ---"
log ""

# Sonarr history endpoint — get recent events for this series
history_raw=$(curl -s "${SONARR_API}/history/series?seriesId=${SERIES_ID}&eventType=grabbed&apikey=${SONARR_API_KEY}")
history_json=$(echo "$history_raw" | jq 'if type == "object" then (.records // []) else (. // []) end' 2>/dev/null) || history_json=""

if [ -n "$history_json" ] && [ "$history_json" != "null" ] && [ "$history_json" != "[]" ]; then
    event_count=$(echo "$history_json" | jq 'length')
    log "  Total grab events: $event_count"
    log ""

    # Show newest 10 grabs
    echo "$history_json" | jq -r '
        sort_by(.date) | reverse | .[:10][] |
        "  \(.date)  grabbed" +
        "\n        sourceTitle:    \(.sourceTitle // "<none>")" +
        "\n        releaseGroup:   \(.data.releaseGroup // .data.ReleaseGroup // "<none>")" +
        "\n        downloadId:     \(.downloadId // "<none>")" +
        "\n        quality:        \(.quality.quality.name // "<none>")" +
        ""
    ' | while IFS= read -r line; do
        log "$line"
    done
else
    log "  No grab history found"
fi

########################################
# SECTION 5: DOWNLOAD ID CHAIN ANALYSIS
########################################

log ""
log "--- SECTION 5: DOWNLOAD ID CHAIN ANALYSIS ---"
log ""

env_dlid="${sonarr_download_id:-}"
if [ -n "$env_dlid" ]; then
    log "  sonarr_download_id: $env_dlid"

    if [ -n "$history_json" ] && [ "$history_json" != "null" ] && [ "$history_json" != "[]" ]; then
        env_grab=$(echo "$history_json" | jq -r --arg dlid "$env_dlid" '
            [.[] | select(.downloadId == $dlid)] |
            .[0] // null |
            if . == null then "<no matching grab>"
            else "date=\(.date) rg=\(.data.releaseGroup // .data.ReleaseGroup // "<none>") src=\(.sourceTitle // "<none>")"
            end
        ')
        log "  Matching grab: $env_grab"
    else
        log "  No history to search"
    fi
else
    log "  sonarr_download_id: <not set>"
fi

########################################
# SECTION 6: RECOVERY DECISION SIMULATION
########################################

log ""
log "--- SECTION 6: IMPORT SCRIPT DECISION SIMULATION ---"
log ""

event_rg="${sonarr_episodefile_releasegroup:-}"
api_rg=""
if [ -n "$episodefile_json" ] && [ "$episodefile_json" != "null" ]; then
    api_rg=$(echo "$episodefile_json" | jq -r '.releaseGroup // ""' 2>/dev/null)
fi

log "  Source priority:"
log "    1. sonarr_episodefile_releasegroup (event var): '${event_rg:-<empty>}'"
log "    2. episodefile.releaseGroup (API):              '${api_rg:-<empty>}'"
log "    3. Download ID recovery (grab history):         depends on above"

if [ -n "$event_rg" ] && [ "$event_rg" != "null" ] && [ "$event_rg" != "Unknown" ]; then
    log ""
    log "  -> Event var has release group: '$event_rg'"
    log "  -> Import script would use this value — NO recovery needed"
elif [ -n "$api_rg" ] && [ "$api_rg" != "null" ] && [ "$api_rg" != "Unknown" ] && [ "$api_rg" != "" ]; then
    log ""
    log "  -> Event var empty, but API has: '$api_rg'"
    log "  -> Import script would use API value — NO recovery needed"
else
    log ""
    log "  -> Both event var and API are empty/Unknown"
    if [ -n "$env_dlid" ]; then
        log "  -> RECOVERY WOULD TRIGGER using download ID: $env_dlid"
    else
        log "  -> No download ID available — CANNOT RECOVER"
    fi
fi

divider
log "END OF DEBUG CAPTURE"
divider
log ""
