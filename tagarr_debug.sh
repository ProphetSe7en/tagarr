#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Tagarr Debug — Radarr Connect Event Inspector
#
# Logs ALL environment variables and API data available during a Connect event.
# Install as a Radarr Connect handler alongside tagarr_import.sh to see exactly
# what data Radarr provides at the moment the event fires.
#
# Setup:
#   Radarr > Settings > Connect > Custom Script
#   Path: /scripts/tagarr_debug.sh
#   Events: On Download, On Upgrade
#
# Output: /config/scripts/tagarr_debug.log (inside Radarr container)
# -----------------------------------------------------------------------------

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="${SCRIPT_DIR}/tagarr_debug.log"

# Radarr API config (same as import script)
RADARR_URL="http://192.168.86.22:7979"
RADARR_API_KEY="eaf913a9fc8542e3bf135881e98fb6a7"
RADARR_API="${RADARR_URL}/api/v3"

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
log "TAGARR DEBUG — Event captured at $NOW"
divider

########################################
# SECTION 1: ALL RADARR ENV VARIABLES
########################################

log ""
log "--- SECTION 1: RADARR ENVIRONMENT VARIABLES ---"
log ""

# Capture all radarr_* env vars (sorted)
env_count=0
while IFS= read -r line; do
    log "  $line"
    env_count=$((env_count + 1))
done < <(env | grep -i '^radarr_' | sort)

log ""
log "Total radarr_* variables: $env_count"

# Highlight the key ones explicitly
log ""
log "--- KEY VARIABLES (explicit) ---"
log "  radarr_eventtype            = ${radarr_eventtype:-<not set>}"
log "  radarr_movie_id             = ${radarr_movie_id:-<not set>}"
log "  radarr_movie_title          = ${radarr_movie_title:-<not set>}"
log "  radarr_movie_year           = ${radarr_movie_year:-<not set>}"
log "  radarr_movie_tmdbid         = ${radarr_movie_tmdbid:-<not set>}"
log "  radarr_moviefile_id         = ${radarr_moviefile_id:-<not set>}"
log "  radarr_moviefile_relativepath = ${radarr_moviefile_relativepath:-<not set>}"
log "  radarr_moviefile_path       = ${radarr_moviefile_path:-<not set>}"
log "  radarr_moviefile_scenename  = ${radarr_moviefile_scenename:-<not set>}"
log "  radarr_moviefile_releasegroup = ${radarr_moviefile_releasegroup:-<not set>}"
log "  radarr_release_releasegroup = ${radarr_release_releasegroup:-<not set>}"
log "  radarr_release_title        = ${radarr_release_title:-<not set>}"
log "  radarr_release_quality      = ${radarr_release_quality:-<not set>}"
log "  radarr_release_indexer      = ${radarr_release_indexer:-<not set>}"
log "  radarr_download_id          = ${radarr_download_id:-<not set>}"
log "  radarr_download_client      = ${radarr_download_client:-<not set>}"
log "  radarr_isupgrade            = ${radarr_isupgrade:-<not set>}"
log "  radarr_deletedrelativepaths = ${radarr_deletedrelativepaths:-<not set>}"
log "  radarr_deletedpaths         = ${radarr_deletedpaths:-<not set>}"

MOVIE_ID="${radarr_movie_id:-0}"

if [ "$MOVIE_ID" = "0" ] || [ -z "$MOVIE_ID" ]; then
    log ""
    log "ERROR: No movie ID — cannot query API. Is this a Test event?"
    divider
    exit 0
fi

########################################
# SECTION 2: MOVIE API RESPONSE
########################################

log ""
log "--- SECTION 2: MOVIE API RESPONSE ---"
log ""

movie_json=$(curl -s "${RADARR_API}/movie/${MOVIE_ID}?apikey=${RADARR_API_KEY}")

if [ -n "$movie_json" ] && [ "$movie_json" != "null" ]; then
    # Movie basics
    log "  title         = $(echo "$movie_json" | jq -r '.title // "null"')"
    log "  year          = $(echo "$movie_json" | jq -r '.year // "null"')"
    log "  tmdbId        = $(echo "$movie_json" | jq -r '.tmdbId // "null"')"
    log "  hasFile       = $(echo "$movie_json" | jq -r '.hasFile // "null"')"

    # MovieFile details
    log ""
    log "  --- movieFile ---"
    log "  movieFile.id            = $(echo "$movie_json" | jq -r '.movieFile.id // "null"')"
    log "  movieFile.relativePath  = $(echo "$movie_json" | jq -r '.movieFile.relativePath // "null"')"
    log "  movieFile.path          = $(echo "$movie_json" | jq -r '.movieFile.path // "null"')"
    log "  movieFile.releaseGroup  = $(echo "$movie_json" | jq -r '.movieFile.releaseGroup // "null"')"
    log "  movieFile.sceneName     = $(echo "$movie_json" | jq -r '.movieFile.sceneName // "null"')"
    log "  movieFile.edition       = $(echo "$movie_json" | jq -r '.movieFile.edition // "null"')"
    log "  movieFile.quality.name  = $(echo "$movie_json" | jq -r '.movieFile.quality.quality.name // "null"')"
    log "  movieFile.quality.source = $(echo "$movie_json" | jq -r '.movieFile.quality.quality.source // "null"')"
    log "  movieFile.dateAdded     = $(echo "$movie_json" | jq -r '.movieFile.dateAdded // "null"')"
    log "  movieFile.mediaInfo.audioCodec = $(echo "$movie_json" | jq -r '.movieFile.mediaInfo.audioCodec // "null"')"

    MOVIEFILE_ID=$(echo "$movie_json" | jq -r '.movieFile.id // ""')
else
    log "  ERROR: Failed to fetch movie API response"
    MOVIEFILE_ID=""
fi

########################################
# SECTION 3: MOVIEFILE API (direct)
########################################

if [ -n "$MOVIEFILE_ID" ] && [ "$MOVIEFILE_ID" != "null" ]; then
    log ""
    log "--- SECTION 3: MOVIEFILE API (direct fetch) ---"
    log ""

    moviefile_json=$(curl -s "${RADARR_API}/moviefile/${MOVIEFILE_ID}?apikey=${RADARR_API_KEY}")

    if [ -n "$moviefile_json" ] && [ "$moviefile_json" != "null" ]; then
        log "  id            = $(echo "$moviefile_json" | jq -r '.id // "null"')"
        log "  relativePath  = $(echo "$moviefile_json" | jq -r '.relativePath // "null"')"
        log "  releaseGroup  = $(echo "$moviefile_json" | jq -r '.releaseGroup // "null"')"
        log "  sceneName     = $(echo "$moviefile_json" | jq -r '.sceneName // "null"')"
        log "  dateAdded     = $(echo "$moviefile_json" | jq -r '.dateAdded // "null"')"
    else
        log "  ERROR: Failed to fetch moviefile"
    fi
fi

########################################
# SECTION 4: FULL HISTORY WITH TIMESTAMPS
########################################

log ""
log "--- SECTION 4: MOVIE HISTORY (all events, newest first) ---"
log ""

history_json=$(curl -s "${RADARR_API}/history/movie?movieId=${MOVIE_ID}&apikey=${RADARR_API_KEY}")

if [ -n "$history_json" ] && [ "$history_json" != "null" ] && [ "$history_json" != "[]" ]; then
    event_count=$(echo "$history_json" | jq 'length')
    log "  Total history events: $event_count"
    log ""

    # Output each event with full detail
    echo "$history_json" | jq -r '
        sort_by(.date) | reverse | to_entries[] |
        "  [\(.key)] \(.value.date)  \(.value.eventType)" +
        "\n        sourceTitle:    \(.value.sourceTitle // "<none>")" +
        "\n        releaseGroup:   \(.value.data.releaseGroup // "<none>")" +
        "\n        downloadId:     \(.value.downloadId // "<none>")" +
        "\n        quality:        \(.value.quality.quality.name // "<none>")" +
        "\n        droppedPath:    \(.value.data.droppedPath // "<n/a>")" +
        "\n        importedPath:   \(.value.data.importedPath // "<n/a>")" +
        "\n        reason:         \(.value.data.reason // "<n/a>")" +
        "\n        message:        \(.value.data.message // "<n/a>")" +
        ""
    ' | while IFS= read -r line; do
        log "$line"
    done
else
    log "  No history found"
fi

########################################
# SECTION 5: TIMING ANALYSIS
########################################

log ""
log "--- SECTION 5: TIMING ANALYSIS ---"
log ""

# Script execution time vs history event times
log "  Script running at: $NOW (server local time)"

if [ -n "$history_json" ] && [ "$history_json" != "null" ] && [ "$history_json" != "[]" ]; then
    # Show the newest 5 events with age relative to now
    log ""
    log "  Newest events vs script execution:"
    echo "$history_json" | jq -r '
        sort_by(.date) | reverse | .[:5][] |
        "\(.date) | \(.eventType) | rg=\(.data.releaseGroup // "<none>") | dl=\(.downloadId // "<none>")"
    ' | while IFS= read -r line; do
        log "    $line"
    done

    # Check: does the newest import have a matching grab with the same downloadId?
    log ""
    log "  --- downloadId chain analysis ---"

    newest_import_dlid=$(echo "$history_json" | jq -r '
        sort_by(.date) | reverse |
        [.[] | select(.eventType == "downloadFolderImported" or .eventType == "movieFileImported")] |
        .[0].downloadId // "<none>"
    ')
    log "  Newest import downloadId: $newest_import_dlid"

    if [ "$newest_import_dlid" != "<none>" ] && [ -n "$newest_import_dlid" ]; then
        matching_grab=$(echo "$history_json" | jq -r --arg dlid "$newest_import_dlid" '
            [.[] | select(.eventType == "grabbed" and .downloadId == $dlid)] |
            .[0] // null |
            if . == null then "<no matching grab>"
            else "date=\(.date) rg=\(.data.releaseGroup // "<none>") src=\(.sourceTitle // "<none>")"
            end
        ')
        log "  Matching grab:            $matching_grab"
    fi

    # Also check: what does the env var downloadId match?
    env_dlid="${radarr_download_id:-}"
    if [ -n "$env_dlid" ]; then
        log ""
        log "  --- env var download_id chain ---"
        log "  radarr_download_id: $env_dlid"
        env_grab=$(echo "$history_json" | jq -r --arg dlid "$env_dlid" '
            [.[] | select(.eventType == "grabbed" and .downloadId == $dlid)] |
            .[0] // null |
            if . == null then "<no matching grab>"
            else "date=\(.date) rg=\(.data.releaseGroup // "<none>") src=\(.sourceTitle // "<none>")"
            end
        ')
        log "  Matching grab:      $env_grab"
    else
        log ""
        log "  radarr_download_id: <not set>"
    fi
fi

########################################
# SECTION 6: WHAT IMPORT SCRIPT WOULD DO
########################################

log ""
log "--- SECTION 6: IMPORT SCRIPT DECISION SIMULATION ---"
log ""

api_rg=$(echo "$movie_json" | jq -r '.movieFile.releaseGroup // ""' 2>/dev/null)
event_rg="${radarr_release_releasegroup:-}"
file_rg="${radarr_moviefile_releasegroup:-}"

log "  Source priority:"
log "    1. radarr_release_releasegroup (event var): '${event_rg:-<empty>}'"
log "    2. radarr_moviefile_releasegroup (file var): '${file_rg:-<empty>}'"
log "    3. movieFile.releaseGroup (API):             '${api_rg:-<empty>}'"

if [ -n "$event_rg" ] && [ "$event_rg" != "null" ]; then
    log ""
    log "  -> Event var available: '$event_rg'"
    if [ -z "$api_rg" ] || [ "$api_rg" = "Unknown" ] || [ "$api_rg" = "null" ]; then
        log "  -> API has empty/Unknown -> import script WOULD use event var and patch"
    else
        log "  -> API already has '$api_rg' -> import script would use API value (no recover)"
    fi
else
    log ""
    log "  -> Event var is EMPTY"
    if [ -z "$api_rg" ] || [ "$api_rg" = "Unknown" ] || [ "$api_rg" = "null" ]; then
        log "  -> API also empty/Unknown -> RECOVER FROM HISTORY would trigger"
        log "  !! This is where the wrong release group gets picked up"
    else
        log "  -> API has '$api_rg' -> no recover needed"
    fi
fi

divider
log "END OF DEBUG CAPTURE"
divider
log ""
