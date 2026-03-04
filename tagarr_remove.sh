#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr Remove — Bulk Tag Removal Tool
# Version: 1.0.0
#
# Removes specified tags from movies in one or two Radarr instances.
# Optionally deletes the tag definitions themselves after removal.
# Uses the /movie/editor bulk API for fast batch operations.
#
# Features:
#   REMOVE     — Strip tags from all movies that have them
#   DELETE     — Optionally delete tag definitions from Radarr
#   DUAL       — Process both primary and secondary instances
#   DRY-RUN    — Preview what would be removed (default mode)
#
# Usage:
#   ./tagarr_remove.sh             # Dry-run (default, shows what would happen)
#   ./tagarr_remove.sh --live      # Execute removals
#
# Configuration: tagarr_remove.conf
#
# Author: prophetSe7en
#
# WARNING: Removes tags from movies and optionally deletes tag definitions.
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
# INSTANCE PROCESSOR
########################################

process_instance() {
    local instance_name="$1"
    local radarr_url="$2"
    local radarr_api_key="$3"

    log "INFO" ""
    log "INFO" "========================================"
    log "INFO" "Processing: $instance_name"
    log "INFO" "========================================"

    if [ ${#TAGS_TO_REMOVE[@]} -eq 0 ]; then
        log "INFO" "No tags configured for removal"
        return 0
    fi

    log "INFO" "Tags to remove: ${TAGS_TO_REMOVE[*]}"
    log "INFO" "Delete definitions: $DELETE_TAG_DEFINITIONS"
    log "INFO" ""

    # Test connection
    log "INFO" "Testing connection..."
    if ! curl -s -f "${radarr_url}/api/v3/system/status?apikey=${radarr_api_key}" > /dev/null; then
        log "ERROR" "Cannot connect to $instance_name at ${radarr_url}"
        return 1
    fi
    log "INFO" "Connected"

    # Fetch tags and movies
    log "INFO" "Fetching tags and movies..."
    local all_tags all_movies total
    all_tags=$(curl -s "${radarr_url}/api/v3/tag?apikey=${radarr_api_key}")
    all_movies=$(curl -s "${radarr_url}/api/v3/movie?apikey=${radarr_api_key}")
    total=$(echo "$all_movies" | jq 'length')
    log "INFO" "Found $total movies"
    log "INFO" ""

    local total_removed=0
    local tags_found=0
    local tags_not_found=0
    local tags_deleted=0

    for tag_name in "${TAGS_TO_REMOVE[@]}"; do
        log "INFO" "Tag: $tag_name"

        # Get tag ID
        local tag_id
        tag_id=$(echo "$all_tags" | jq -r --arg tag "$tag_name" '.[] | select(.label == $tag) | .id')

        if [ -z "$tag_id" ]; then
            log "INFO" "  Not found — skipping"
            tags_not_found=$((tags_not_found + 1))
            continue
        fi

        tags_found=$((tags_found + 1))
        log "INFO" "  ID: $tag_id"

        # Find movies with this tag
        local movie_ids
        movie_ids=$(echo "$all_movies" | jq -r --argjson tid "$tag_id" '.[] | select(.tags | index($tid)) | .id')

        if [ -z "$movie_ids" ]; then
            log "INFO" "  No movies have this tag"

            if [ "$DELETE_TAG_DEFINITIONS" = "true" ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    log "INFO" "  [DRY-RUN] Would delete tag definition"
                else
                    curl -s -X DELETE "${radarr_url}/api/v3/tag/${tag_id}?apikey=${radarr_api_key}" >/dev/null
                    log "INFO" "  Deleted tag definition"
                    tags_deleted=$((tags_deleted + 1))
                fi
            fi
            continue
        fi

        local movie_array movies_count
        movie_array=$(echo "$movie_ids" | jq -s '.')
        movies_count=$(echo "$movie_ids" | wc -l)

        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "  [DRY-RUN] Would remove from $movies_count movies"

            if [ "$DELETE_TAG_DEFINITIONS" = "true" ]; then
                log "INFO" "  [DRY-RUN] Would delete tag definition"
            fi
        else
            # Bulk remove
            curl -s -X PUT -H "Content-Type: application/json" \
                -d "{\"movieIds\": $movie_array, \"tags\": [$tag_id], \"applyTags\": \"remove\"}" \
                "${radarr_url}/api/v3/movie/editor?apikey=${radarr_api_key}" >/dev/null

            log "INFO" "  Removed from $movies_count movies"
            total_removed=$((total_removed + movies_count))

            if [ "$DELETE_TAG_DEFINITIONS" = "true" ]; then
                curl -s -X DELETE "${radarr_url}/api/v3/tag/${tag_id}?apikey=${radarr_api_key}" >/dev/null
                log "INFO" "  Deleted tag definition"
                tags_deleted=$((tags_deleted + 1))
            fi
        fi
    done

    log "INFO" ""
    log "INFO" "Summary for $instance_name:"
    log "INFO" "  Tags found: $tags_found"
    log "INFO" "  Tags not found: $tags_not_found"
    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "  Mode: DRY-RUN (no changes made)"
    else
        log "INFO" "  Movies untagged: $total_removed"
        log "INFO" "  Definitions deleted: $tags_deleted"
    fi
}

########################################
# MAIN
########################################

log "INFO" "========================================"
log "INFO" "Tagarr Remove v${SCRIPT_VERSION}"
log "INFO" "========================================"

if [ "$DRY_RUN" = "true" ]; then
    log "INFO" "Mode: DRY-RUN (use --live to execute)"
else
    log "INFO" "Mode: LIVE"
fi

START_TIME=$(date +%s)

# Process primary
process_instance "$PRIMARY_RADARR_NAME" "$PRIMARY_RADARR_URL" "$PRIMARY_RADARR_API_KEY"

# Process secondary
if [ "${ENABLE_SECONDARY:-false}" = "true" ]; then
    process_instance "$SECONDARY_RADARR_NAME" "$SECONDARY_RADARR_URL" "$SECONDARY_RADARR_API_KEY"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "INFO" ""
log "INFO" "========================================"
log "INFO" "Completed in ${DURATION}s"
log "INFO" "========================================"
