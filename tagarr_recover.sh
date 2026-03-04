#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr Recover — Release Group Recovery from Grab History
# Version: 1.0.0
#
# Scans movies in Radarr where the release group is missing or unknown,
# and recovers it from the grab history. This fixes movies where the
# indexer had the correct release group but the actual filename did not
# include it (e.g., 126811 releases).
#
# Features:
#   RECOVER    — Restore missing releaseGroup from grab history
#   VERIFY     — 5-point safety chain:
#                1. Blanks only — never overwrites existing releaseGroup
#                2. Filename check — flags movies where the filename already
#                   contains a release group that Radarr missed
#                3. Import-verified grab — only uses grabs that were actually
#                   imported (skips failed downloads)
#                4. Non-empty — releaseGroup from history must have a value
#                5. Title+year match — sourceTitle must match movie metadata
#   RENAME     — Trigger Radarr file rename after fix (optional)
#   DUAL       — Process both primary and secondary instances
#   DRY-RUN    — Preview what would be fixed (default mode)
#
# Usage:
#   ./tagarr_recover.sh                     # Dry-run (default)
#   ./tagarr_recover.sh --live              # Execute fixes
#   ./tagarr_recover.sh --live --no-rename  # Fix without renaming files
#   ./tagarr_recover.sh --instance primary  # Primary instance only
#
# Configuration: tagarr_recover.conf
#
# Author: prophetSe7en
#
# WARNING: Modifies moviefile metadata in Radarr and optionally renames files.
# Always run with --dry-run first (default) and review output before using --live.
# -----------------------------------------------------------------------------

set -euo pipefail
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

########################################
# ARGUMENT HANDLING
########################################

DRY_RUN="${ENABLE_DRY_RUN:-true}"
RENAME="${ENABLE_RENAME:-true}"
INSTANCE="both"
MOVIE_FILTER=""

show_help() {
    cat <<'HELP'
Usage: tagarr_recover.sh [OPTIONS]

Recover missing release groups from Radarr grab history.

Options:
  --dry-run              Preview what would be fixed (default)
  --live                 Execute the fixes
  --instance TYPE        Which instance to process: primary, secondary, both (default: both)
  --movie ID             Process a single movie by Radarr movie ID
  --no-rename            Skip file rename even in live mode
  --help                 Show this help message

Examples:
  ./tagarr_recover.sh                      # Dry-run, both instances
  ./tagarr_recover.sh --live               # Fix + rename, both instances
  ./tagarr_recover.sh --live --no-rename   # Fix without renaming
  ./tagarr_recover.sh --instance primary   # Primary only
  ./tagarr_recover.sh --movie 123          # Single movie by ID
  ./tagarr_recover.sh --movie 123 --live   # Fix single movie
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
            MOVIE_FILTER="$2"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--live|--dry-run] [--instance primary|secondary|both] [--movie ID] [--no-rename] [--help]"
            exit 1
            ;;
    esac
done

# Validate --instance value
case "$INSTANCE" in
    primary|secondary|both) ;;
    *) echo "ERROR: Invalid --instance value '$INSTANCE' (must be primary|secondary|both)"; exit 1 ;;
esac

# --movie with --instance both is ambiguous (IDs are per-instance)
if [ -n "$MOVIE_FILTER" ] && [ "$INSTANCE" = "both" ]; then
    INSTANCE="primary"
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

# Finds the most recent grab that was actually imported (not failed).
# Walks ALL history events newest-to-oldest, tracking what happened after
# each grab:
#
#   import after grab  → grab produced the current file → USE its releaseGroup
#   failure after grab → grab never imported → SKIP, try older grabs
#   nothing after grab → unverified (in-progress? pruned?) → SKIP
#
# Also verifies title+year match between grab sourceTitle and movie metadata.
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
    # Note: empty releaseGroup uses sentinel __NONE__ to prevent bash read
    # from collapsing consecutive tabs (IFS=tab treats adjacent tabs as one)
    local events_tsv
    events_tsv=$(echo "$history_json" | jq -r '
        (. // []) | sort_by(.date) | reverse | .[] |
        [.eventType, ((.data.releaseGroup // "" | if . == "" then "__NONE__" else . end)), (.sourceTitle // "")] | @tsv
    ') || return 1

    # State tracks what happened AFTER the grab we're about to see
    local state="unknown"
    local found_empty_verified=false

    while IFS=$'\t' read -r event_type grab_rg source_title; do
        case "$event_type" in
            downloadFolderImported|movieFileImported)
                state="imported"
                ;;
            downloadFailed)
                state="failed"
                ;;
            grabbed)
                # Skip grabs that were followed by a failure
                if [ "$state" = "failed" ]; then
                    state="unknown"
                    continue
                fi

                # Skip unverified grabs (no import event found after this grab)
                if [ "$state" != "imported" ]; then
                    state="unknown"
                    continue
                fi

                # This grab was followed by a successful import
                # Check if releaseGroup is empty — track but continue looking
                if [ "$grab_rg" = "__NONE__" ]; then
                    found_empty_verified=true
                    state="unknown"
                    continue
                fi

                # Title+year verification — require BOTH when both are available
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

                # Require both year+title when both checks are possible
                local verified=false
                if [ "$year_valid" = "true" ] && [ "$title_valid" = "true" ]; then
                    # Both available — require both
                    [ "$year_match" = "true" ] && [ "$title_match" = "true" ] && verified=true
                else
                    # One unavailable — accept either
                    [ "$year_match" = "true" ] || [ "$title_match" = "true" ] && verified=true
                fi

                if [ "$verified" = "true" ]; then
                    echo "$grab_rg"
                    return 0
                fi

                # Title didn't match — try older grabs
                state="unknown"
                ;;
            *)
                # movieFileDeleted, movieFileRenamed, etc. — ignore
                ;;
        esac
    done <<< "$events_tsv"

    # Distinguish: verified grab with empty group vs no verified grab at all
    if [ "$found_empty_verified" = "true" ]; then
        return 2
    fi

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
        --arg title "Recover — ${instance_name}" \
        --argjson color "$color" \
        --argjson fields "$fields_json" \
        --arg footer_text "Tagarr Recover v${SCRIPT_VERSION} by ProphetSe7en • $(date '+%d-%m-%Y %H:%M')" \
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
send_discord_movie_list() {
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

    # Fetch movies
    local movies_json
    if [ -n "$MOVIE_FILTER" ]; then
        # Single movie mode — fetch by ID
        log "INFO" "Fetching movie ID $MOVIE_FILTER..."
        local single_movie
        single_movie=$(curl -s -f "${api_url}/movie/${MOVIE_FILTER}?apikey=${api_key}") || {
            log "ERROR" "Failed to fetch movie $MOVIE_FILTER from $instance_name"
            return 1
        }

        if [ -z "$single_movie" ] || [ "$single_movie" = "null" ]; then
            log "ERROR" "Movie $MOVIE_FILTER not found in $instance_name"
            return 1
        fi

        local movie_title_display
        movie_title_display=$(echo "$single_movie" | jq -r '.title // "unknown"')
        log "INFO" "Movie: $movie_title_display"

        # Wrap in array for uniform processing
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

    local affected_count
    affected_count=$(echo "$affected_json" | jq 'length')

    log "INFO" "Missing releaseGroup: $affected_count"

    if [ "$affected_count" -eq 0 ]; then
        log "INFO" "No movies need fixing in $instance_name"
        send_discord_summary "$instance_name" "0" "0" "0" "0" \
            "$([ "$DRY_RUN" = "true" ] && echo "DRY-RUN" || echo "LIVE")" "0" "0"
        return 0
    fi

    log "INFO" ""

    local fixed=0 no_history=0 failed_verify=0 no_group=0 flagged=0 processed=0

    # Movie lists for Discord notification
    local fixed_movies=""
    local skipped_movies=""
    local flagged_movies=""

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
            skipped_movies+="${movie_title} (${movie_year}) — no moviefile ID"$'\n'
            continue
        fi

        # SAFETY CHECK 1: Does the filename already contain a release group?
        # If yes, Radarr should have detected it — flag for manual review
        local filename_group=""
        if [ -n "$rel_path" ]; then
            filename_group=$(extract_group_from_filename "$rel_path") || true
        fi

        if [ -n "$filename_group" ]; then
            log "INFO" "  ${YELLOW}Filename has release group '${filename_group}' but Radarr has none — flagged${NC}"
            log "INFO" "  File: $rel_path"
            flagged=$((flagged + 1))
            flagged_movies+="${movie_title} (${movie_year}) — '${filename_group}' in filename"$'\n'
            continue
        fi

        # SAFETY CHECK 2: Query ALL history (not just grabs) for import verification
        local history_json
        history_json=$(curl -s -f "${api_url}/history/movie?movieId=${movie_id}&apikey=${api_key}") || history_json=""

        if [ -z "$history_json" ] || [ "$history_json" = "null" ] || [ "$history_json" = "[]" ] || \
           ! echo "$history_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
            no_history=$((no_history + 1))
            log "INFO" "  No history — skipped"
            skipped_movies+="${movie_title} (${movie_year}) — no history"$'\n'
            continue
        fi

        # SAFETY CHECK 3-5: Find import-verified grab with title+year match
        local fixed_rg="" find_rc=0
        fixed_rg=$(find_imported_grab_group "$history_json" "$movie_title" "$movie_year") || find_rc=$?

        if [ -z "$fixed_rg" ]; then
            if [ "$find_rc" -eq 2 ]; then
                no_group=$((no_group + 1))
                log "INFO" "  Grab verified — No-RlsGroup"
                skipped_movies+="${movie_title} (${movie_year}) — No-RlsGroup"$'\n'
            else
                failed_verify=$((failed_verify + 1))
                log "INFO" "  No verified grab found — skipped"
                skipped_movies+="${movie_title} (${movie_year}) — no verified grab"$'\n'
            fi
            continue
        fi

        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "  ${YELLOW}[DRY-RUN]${NC} Would fix: releaseGroup → '${GREEN}${fixed_rg}${NC}'"
            fixed=$((fixed + 1))
            fixed_movies+="${movie_title} (${movie_year}) → ${fixed_rg}"$'\n'
        else
            # Fetch full moviefile object for PUT
            local moviefile_json
            moviefile_json=$(curl -s -f "${api_url}/moviefile/${moviefile_id}?apikey=${api_key}") || moviefile_json=""

            if [ -z "$moviefile_json" ] || [ "$moviefile_json" = "null" ]; then
                log "WARN" "  Failed to fetch moviefile — skipped"
                failed_verify=$((failed_verify + 1))
                skipped_movies+="${movie_title} (${movie_year}) — fetch failed"$'\n'
                continue
            fi

            # Patch releaseGroup and PUT
            local updated_mf
            updated_mf=$(echo "$moviefile_json" | jq --arg rg "$fixed_rg" '.releaseGroup = $rg') || {
                log "WARN" "  Failed to patch JSON — skipped"
                failed_verify=$((failed_verify + 1))
                skipped_movies+="${movie_title} (${movie_year}) — JSON patch failed"$'\n'
                continue
            }

            local put_response put_http
            put_response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X PUT \
                "${api_url}/moviefile/${moviefile_id}?apikey=${api_key}" \
                -H "Content-Type: application/json" \
                -d "$updated_mf") || put_response="HTTP_CODE:000"
            put_http=$(echo "$put_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

            if [ "$put_http" = "200" ] || [ "$put_http" = "202" ]; then
                log "INFO" "  ${GREEN}Fixed:${NC} releaseGroup → '${fixed_rg}'"
                fixed=$((fixed + 1))
                fixed_movies+="${movie_title} (${movie_year}) → ${fixed_rg}"$'\n'

                if [ "$RENAME" = "true" ]; then
                    local rename_response rename_http_code
                    rename_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
                        "${api_url}/command?apikey=${api_key}" \
                        -H "Content-Type: application/json" \
                        -d "{\"name\":\"RenameFiles\",\"movieId\":${movie_id},\"files\":[${moviefile_id}]}")
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
                skipped_movies+="${movie_title} (${movie_year}) — PUT failed (HTTP $put_http)"$'\n'
            fi
        fi
    done < <(echo "$affected_json" | jq -c '.[]')

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

    # Discord: summary embed
    local mode_label
    mode_label=$([ "$DRY_RUN" = "true" ] && echo "DRY-RUN" || echo "LIVE")
    send_discord_summary "$instance_name" "$affected_count" "$fixed" "$no_history" "$failed_verify" \
        "$mode_label" "$instance_duration" "$flagged" "$no_group"
    sleep 0.5

    # Discord: fixed movie list
    if [ -n "$fixed_movies" ]; then
        local fixed_title
        if [ "$DRY_RUN" = "true" ]; then
            fixed_title="Would Fix (${fixed} movies)"
        else
            fixed_title="Fixed (${fixed} movies)"
        fi
        send_discord_movie_list "$fixed_title" "$fixed_movies" 3066993  # Green
    fi

    # Discord: flagged movie list (group found in filename but Radarr has none)
    if [ -n "$flagged_movies" ]; then
        send_discord_movie_list "Flagged — Group in Filename (${flagged} movies)" "$flagged_movies" 15105570  # Amber
    fi

    # Discord: skipped movie list (only if there are skipped movies)
    if [ -n "$skipped_movies" ]; then
        local skip_count=$((no_history + failed_verify + no_group))
        send_discord_movie_list "Skipped (${skip_count} movies)" "$skipped_movies" 9807270  # Grey
    fi

    # Reminder: run tagarr.sh after live fixes
    if [ "$DRY_RUN" = "false" ] && [ "$fixed" -gt 0 ]; then
        log "INFO" ""
        log "INFO" "${CYAN}Tip:${NC} Run tagarr.sh to tag the ${fixed} movies with corrected release groups"
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
log "INFO" "Rename: $RENAME"
log "INFO" "Instance: $INSTANCE"
[ -n "$MOVIE_FILTER" ] && log "INFO" "Movie: $MOVIE_FILTER (single movie mode)"

START_TIME=$(date +%s)

# Process requested instances
if [ "$INSTANCE" = "primary" ] || [ "$INSTANCE" = "both" ]; then
    process_instance "$PRIMARY_RADARR_NAME" "$PRIMARY_RADARR_URL" "$PRIMARY_RADARR_API_KEY" || \
        log "ERROR" "Primary instance failed — continuing"
fi

if [ "$INSTANCE" = "secondary" ] || [ "$INSTANCE" = "both" ]; then
    if [ "${ENABLE_SECONDARY:-false}" = "true" ]; then
        process_instance "$SECONDARY_RADARR_NAME" "$SECONDARY_RADARR_URL" "$SECONDARY_RADARR_API_KEY" || \
            log "ERROR" "Secondary instance failed — continuing"
    else
        [ "$INSTANCE" = "secondary" ] && log "WARN" "Secondary instance not enabled in config"
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "INFO" ""
log "INFO" "========================================"
log "INFO" "Completed in ${DURATION}s"
log "INFO" "========================================"
