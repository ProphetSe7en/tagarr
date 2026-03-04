#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr List — List-Based Movie Tagger
# Version: 1.0.0
#
# Tags movies in Radarr based on external lists from TMDb or Trakt.
# Matches list entries against existing Radarr movies by TMDb ID.
# Optionally adds missing movies to Radarr.
#
# Features:
#   TAGGING    — Tag existing movies that appear on configured lists
#   PROVIDERS  — TMDb lists and Trakt lists supported
#   ADD        — Optionally add missing movies to Radarr (monitored/unmonitored)
#   SYNC       — Optionally tag in a secondary Radarr instance
#   DRY-RUN    — Preview what would happen (default mode)
#   BULK API   — Uses /movie/editor for fast batch tagging
#
# Usage:
#   ./tagarr_list.sh               # Dry-run (default, shows what would happen)
#   ./tagarr_list.sh --live        # Execute tagging and additions
#
# Configuration: tagarr_list.conf
#
# Author: prophetSe7en
#
# WARNING: This script modifies tags and can add movies to Radarr. Always run
# with --dry-run first (default) and review output before using --live.
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
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--live|--dry-run]"
            exit 1
            ;;
    esac
done

########################################
# LOGGING
########################################

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    echo "$msg"
    if [ "${ENABLE_LOGGING:-true}" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
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

########################################
# LIST FETCHERS
########################################

# Fetch TMDb list — returns one TMDb ID per line
fetch_tmdb_list() {
    local list_id="$1"
    local page=1
    local total_pages=1
    local all_ids=""

    while [ "$page" -le "$total_pages" ]; do
        local response
        response=$(curl -s "https://api.themoviedb.org/3/list/${list_id}?api_key=${TMDB_API_KEY}&page=${page}")

        local page_ids
        page_ids=$(echo "$response" | jq -r '.items[].id' 2>/dev/null || true)
        all_ids="${all_ids}${page_ids}"$'\n'

        if [ "$page" -eq 1 ]; then
            total_pages=$(echo "$response" | jq -r '.total_pages // 1')
            local total_results
            total_results=$(echo "$response" | jq -r '.total_results // 0')
            log "INFO" "  TMDb list: $total_results movies ($total_pages pages)"
        fi

        page=$((page + 1))
    done

    # Output clean IDs (one per line, no blanks)
    echo "$all_ids" | grep -v '^$' || true
}

# Fetch Trakt list — returns one TMDb ID per line
fetch_trakt_list() {
    local list_path="$1"  # format: "user/list-slug"
    local user="${list_path%%/*}"
    local slug="${list_path#*/}"

    if [ -z "$TRAKT_CLIENT_ID" ]; then
        log "ERROR" "  TRAKT_CLIENT_ID not set in config"
        return 1
    fi

    local response
    response=$(curl -s \
        -H "Content-Type: application/json" \
        -H "trakt-api-version: 2" \
        -H "trakt-api-key: ${TRAKT_CLIENT_ID}" \
        "https://api.trakt.tv/users/${user}/lists/${slug}/items/movies")

    local tmdb_ids
    tmdb_ids=$(echo "$response" | jq -r '.[].movie.ids.tmdb // empty' 2>/dev/null || true)

    local count
    count=$(echo "$tmdb_ids" | grep -c -v '^$' || echo 0)
    log "INFO" "  Trakt list: $count movies"

    echo "$tmdb_ids" | grep -v '^$' || true
}

########################################
# INSTANCE TAGGER
########################################

# Tag movies in a Radarr instance from a list of TMDb IDs
# Returns "tagged:already:not_found:added" stats
tag_instance() {
    local instance_name="$1"
    local radarr_url="$2"
    local radarr_api_key="$3"
    local tag_name="$4"
    local is_primary="$5"
    shift 5
    # Remaining args are TMDb IDs
    local tmdb_ids=("$@")

    local tagged=0
    local already=0
    local not_found=0
    local added=0

    # Fetch all movies (one call)
    local all_movies
    all_movies=$(curl -s "${radarr_url}/api/v3/movie?apikey=${radarr_api_key}")

    # Build TMDb→ID lookup
    declare -A radarr_by_tmdb
    while IFS=$'\t' read -r mid mtmdb mtags; do
        [ -n "$mtmdb" ] && [ "$mtmdb" != "null" ] && radarr_by_tmdb["$mtmdb"]="$mid:$mtags"
    done < <(echo "$all_movies" | jq -r '.[] | [.id, .tmdbId, (.tags|tostring)] | @tsv')

    # Get or create tag
    local existing_tags
    existing_tags=$(curl -s "${radarr_url}/api/v3/tag?apikey=${radarr_api_key}")
    local tag_id
    tag_id=$(echo "$existing_tags" | jq -r --arg t "$tag_name" '.[] | select(.label==$t).id' | head -n1)

    if [ -z "$tag_id" ] || [ "$tag_id" = "null" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "  [DRY-RUN] Would create tag '$tag_name' in $instance_name"
            tag_id="999999"
        else
            tag_id=$(curl -s -X POST -H "Content-Type: application/json" \
                -d "{\"label\":\"${tag_name}\"}" \
                "${radarr_url}/api/v3/tag?apikey=${radarr_api_key}" | jq -r '.id')
            log "INFO" "  Created tag '$tag_name' (ID: $tag_id) in $instance_name"
        fi
    else
        log "INFO" "  Using tag '$tag_name' (ID: $tag_id) in $instance_name"
    fi

    # Collect movie IDs to tag in bulk
    declare -a to_tag_ids=()
    declare -a to_tag_titles=()

    for tmdb_id in "${tmdb_ids[@]}"; do
        [ -z "$tmdb_id" ] && continue

        local lookup="${radarr_by_tmdb[$tmdb_id]:-}"

        if [ -z "$lookup" ]; then
            # Movie not in Radarr
            if [ "$is_primary" = "true" ] && [ "${ADD_MISSING_MOVIES:-false}" = "true" ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    log "INFO" "  [DRY-RUN] Would add TMDb:$tmdb_id (monitored: ${ADD_MONITORED:-false})"
                    added=$((added + 1))
                else
                    # Fetch movie info from TMDb for Radarr
                    local lookup_result
                    lookup_result=$(curl -s "${radarr_url}/api/v3/movie/lookup/tmdb?tmdbId=${tmdb_id}&apikey=${radarr_api_key}")

                    if [ -n "$lookup_result" ] && [ "$lookup_result" != "null" ] && [ "$lookup_result" != "[]" ]; then
                        local add_title
                        add_title=$(echo "$lookup_result" | jq -r '.title // "Unknown"')

                        # Build add payload
                        local add_payload
                        add_payload=$(echo "$lookup_result" | jq \
                            --arg root "${ADD_ROOT_FOLDER}" \
                            --argjson qp "${ADD_QUALITY_PROFILE_ID:-1}" \
                            --argjson mon "${ADD_MONITORED:-false}" \
                            --argjson tagid "$tag_id" \
                            '{
                                title: .title,
                                tmdbId: .tmdbId,
                                year: .year,
                                qualityProfileId: $qp,
                                rootFolderPath: $root,
                                monitored: $mon,
                                tags: [$tagid],
                                addOptions: { searchForMovie: $mon },
                                images: .images
                            }')

                        local add_response
                        add_response=$(curl -s -w "\n%{http_code}" -X POST \
                            -H "Content-Type: application/json" \
                            -d "$add_payload" \
                            "${radarr_url}/api/v3/movie?apikey=${radarr_api_key}")

                        local add_http_code
                        add_http_code=$(echo "$add_response" | tail -1)

                        if [ "$add_http_code" = "201" ] || [ "$add_http_code" = "200" ]; then
                            log "INFO" "  [ADDED] $add_title (TMDb:$tmdb_id, monitored: ${ADD_MONITORED:-false})"
                            added=$((added + 1))
                        else
                            log "WARN" "  [FAIL] Could not add TMDb:$tmdb_id (HTTP $add_http_code)"
                        fi
                    else
                        log "WARN" "  [FAIL] TMDb:$tmdb_id not found via Radarr lookup"
                    fi
                fi
            else
                not_found=$((not_found + 1))
            fi
            continue
        fi

        local movie_id="${lookup%%:*}"
        local movie_tags="${lookup#*:}"

        # Check if already has tag
        if echo "$movie_tags" | grep -q "\b${tag_id}\b" 2>/dev/null; then
            already=$((already + 1))
        else
            to_tag_ids+=("$movie_id")
            tagged=$((tagged + 1))
        fi
    done

    # Bulk tag via /movie/editor
    if [ ${#to_tag_ids[@]} -gt 0 ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "  [DRY-RUN] Would tag ${#to_tag_ids[@]} movies in $instance_name"
        else
            local ids_json
            ids_json=$(printf '%s\n' "${to_tag_ids[@]}" | jq -s '.')

            curl -s -X PUT -H "Content-Type: application/json" \
                -d "{\"movieIds\":${ids_json},\"tags\":[${tag_id}],\"applyTags\":\"add\"}" \
                "${radarr_url}/api/v3/movie/editor?apikey=${radarr_api_key}" >/dev/null

            log "INFO" "  Tagged ${#to_tag_ids[@]} movies in $instance_name"
        fi
    fi

    echo "${tagged}:${already}:${not_found}:${added}"
}

########################################
# MAIN
########################################

log "INFO" "========================================"
log "INFO" "Tagarr List v${SCRIPT_VERSION}"
log "INFO" "========================================"

if [ "$DRY_RUN" = "true" ]; then
    log "INFO" "Mode: DRY-RUN (use --live to execute)"
else
    log "INFO" "Mode: LIVE"
fi

log "INFO" "Primary: $PRIMARY_RADARR_NAME"
if [ "${ENABLE_SECONDARY:-false}" = "true" ]; then
    log "INFO" "Secondary: $SECONDARY_RADARR_NAME"
fi
log "INFO" "Lists: ${#LISTS[@]}"
log "INFO" "Add missing movies: ${ADD_MISSING_MOVIES:-false}"
if [ "${ADD_MISSING_MOVIES:-false}" = "true" ]; then
    log "INFO" "Add monitored: ${ADD_MONITORED:-false}"
fi
log "INFO" ""

START_TIME=$(date +%s)

# Test primary connection
log "INFO" "Testing connection to $PRIMARY_RADARR_NAME..."
if ! curl -s -f "${PRIMARY_RADARR_URL}/api/v3/system/status?apikey=${PRIMARY_RADARR_API_KEY}" > /dev/null; then
    log "ERROR" "Cannot connect to $PRIMARY_RADARR_NAME"
    exit 1
fi
log "INFO" "Connected"

# Test secondary connection
if [ "${ENABLE_SECONDARY:-false}" = "true" ]; then
    log "INFO" "Testing connection to $SECONDARY_RADARR_NAME..."
    if ! curl -s -f "${SECONDARY_RADARR_URL}/api/v3/system/status?apikey=${SECONDARY_RADARR_API_KEY}" > /dev/null; then
        log "WARN" "Cannot connect to $SECONDARY_RADARR_NAME — disabling"
        ENABLE_SECONDARY=false
    else
        log "INFO" "Connected"
    fi
fi

log "INFO" ""

# Global counters
TOTAL_TAGGED=0
TOTAL_ALREADY=0
TOTAL_NOT_FOUND=0
TOTAL_ADDED=0

# Process each list
for list_config in "${LISTS[@]}"; do
    PROVIDER=$(echo "$list_config" | cut -d: -f1)
    LIST_ID=$(echo "$list_config" | cut -d: -f2)
    TAG_NAME=$(echo "$list_config" | cut -d: -f3)
    DISPLAY_NAME=$(echo "$list_config" | cut -d: -f4-)
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$TAG_NAME"

    # For trakt, list_id contains a slash (user/slug), so reconstruct
    if [ "$PROVIDER" = "trakt" ]; then
        # Format: "trakt:user/slug:tag:display"
        # cut -d: -f2 only gets "user/slug" which is correct
        LIST_ID=$(echo "$list_config" | cut -d: -f2)
    fi

    log "INFO" "========================================"
    log "INFO" "List: $DISPLAY_NAME ($PROVIDER)"
    log "INFO" "========================================"

    # Fetch TMDb IDs from list
    declare -a tmdb_ids=()

    case "$PROVIDER" in
        tmdb)
            while IFS= read -r id; do
                [ -n "$id" ] && tmdb_ids+=("$id")
            done < <(fetch_tmdb_list "$LIST_ID")
            ;;
        trakt)
            while IFS= read -r id; do
                [ -n "$id" ] && tmdb_ids+=("$id")
            done < <(fetch_trakt_list "$LIST_ID")
            ;;
        *)
            log "ERROR" "Unknown provider: $PROVIDER"
            continue
            ;;
    esac

    if [ ${#tmdb_ids[@]} -eq 0 ]; then
        log "WARN" "  No movies found in list — skipping"
        continue
    fi

    # Tag in primary
    log "INFO" ""
    log "INFO" "  Processing $PRIMARY_RADARR_NAME..."
    primary_stats=$(tag_instance "$PRIMARY_RADARR_NAME" "$PRIMARY_RADARR_URL" "$PRIMARY_RADARR_API_KEY" \
        "$TAG_NAME" "true" "${tmdb_ids[@]}")

    p_tagged=$(echo "$primary_stats" | cut -d: -f1)
    p_already=$(echo "$primary_stats" | cut -d: -f2)
    p_not_found=$(echo "$primary_stats" | cut -d: -f3)
    p_added=$(echo "$primary_stats" | cut -d: -f4)

    log "INFO" "  Results: tagged=$p_tagged, already=$p_already, not_found=$p_not_found, added=$p_added"

    # Tag in secondary (tagging only, no movie addition)
    if [ "${ENABLE_SECONDARY:-false}" = "true" ]; then
        log "INFO" ""
        log "INFO" "  Processing $SECONDARY_RADARR_NAME..."
        secondary_stats=$(tag_instance "$SECONDARY_RADARR_NAME" "$SECONDARY_RADARR_URL" "$SECONDARY_RADARR_API_KEY" \
            "$TAG_NAME" "false" "${tmdb_ids[@]}")

        s_tagged=$(echo "$secondary_stats" | cut -d: -f1)
        s_already=$(echo "$secondary_stats" | cut -d: -f2)
        s_not_found=$(echo "$secondary_stats" | cut -d: -f3)

        log "INFO" "  Results: tagged=$s_tagged, already=$s_already, not_found=$s_not_found"
    fi

    TOTAL_TAGGED=$((TOTAL_TAGGED + p_tagged))
    TOTAL_ALREADY=$((TOTAL_ALREADY + p_already))
    TOTAL_NOT_FOUND=$((TOTAL_NOT_FOUND + p_not_found))
    TOTAL_ADDED=$((TOTAL_ADDED + p_added))

    unset tmdb_ids
    log "INFO" ""
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "INFO" "========================================"
log "INFO" "Summary"
log "INFO" "========================================"
log "INFO" "Tagged: $TOTAL_TAGGED"
log "INFO" "Already tagged: $TOTAL_ALREADY"
log "INFO" "Not in Radarr: $TOTAL_NOT_FOUND"
if [ "${ADD_MISSING_MOVIES:-false}" = "true" ]; then
    log "INFO" "Added to Radarr: $TOTAL_ADDED"
fi
if [ "$DRY_RUN" = "true" ]; then
    log "INFO" "Mode: DRY-RUN (no changes made)"
fi
log "INFO" "Completed in ${DURATION}s"
log "INFO" "========================================"
