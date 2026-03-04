#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr Rename — Bulk Tag Rename Tool
# Version: 1.0.0
#
# Renames tags in one or two Radarr instances by creating a new tag,
# migrating all movies from old to new via the bulk /movie/editor API,
# and optionally deleting the old tag definition.
#
# Features:
#   RENAME     — Create new tag, migrate movies, remove old tag
#   DUAL       — Process both primary and secondary instances
#   DRY-RUN    — Preview what would be renamed (default mode)
#   CLEANUP    — Optionally delete old tag definitions after migration
#
# Usage:
#   ./tagarr_rename.sh             # Dry-run (default, shows what would happen)
#   ./tagarr_rename.sh --live      # Execute renames
#
# Configuration: tagarr_rename.conf
#
# Author: prophetSe7en
#
# WARNING: Always run with --dry-run first (default) to preview changes.
# Old tag definitions are deleted after rename when DELETE_OLD_TAGS=true.
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

    if [ ${#TAG_RENAMES[@]} -eq 0 ]; then
        log "INFO" "No renames configured"
        return 0
    fi

    log "INFO" "Renames: ${#TAG_RENAMES[@]} operations"
    log "INFO" "Delete old tags: $DELETE_OLD_TAGS"
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

    local total_renamed=0
    local operations_success=0
    local operations_failed=0

    for rename_pair in "${TAG_RENAMES[@]}"; do
        local old_tag="${rename_pair%%:*}"
        local new_tag="${rename_pair#*:}"

        log "INFO" "Rename: '$old_tag' -> '$new_tag'"

        # Get old tag ID
        local old_tag_id
        old_tag_id=$(echo "$all_tags" | jq -r --arg tag "$old_tag" '.[] | select(.label == $tag) | .id')

        if [ -z "$old_tag_id" ]; then
            log "WARN" "  Old tag '$old_tag' not found — skipping"
            operations_failed=$((operations_failed + 1))
            continue
        fi

        log "INFO" "  Old tag ID: $old_tag_id"

        # Check if new tag already exists
        local new_tag_id
        new_tag_id=$(echo "$all_tags" | jq -r --arg tag "$new_tag" '.[] | select(.label == $tag) | .id')

        if [ -n "$new_tag_id" ]; then
            log "INFO" "  New tag '$new_tag' already exists (ID: $new_tag_id)"
        else
            if [ "$DRY_RUN" = "true" ]; then
                log "INFO" "  [DRY-RUN] Would create tag '$new_tag'"
                new_tag_id="999999"
            else
                log "INFO" "  Creating tag '$new_tag'..."
                local new_tag_response
                new_tag_response=$(curl -s -X POST "${radarr_url}/api/v3/tag?apikey=${radarr_api_key}" \
                    -H "Content-Type: application/json" \
                    -d "{\"label\": \"${new_tag}\"}")

                new_tag_id=$(echo "$new_tag_response" | jq -r 'if type == "array" then .[0].id else .id end // empty')

                if [ -z "$new_tag_id" ] || [ "$new_tag_id" = "null" ]; then
                    log "ERROR" "  Failed to create tag '$new_tag'"
                    log "ERROR" "  Response: $new_tag_response"
                    operations_failed=$((operations_failed + 1))
                    continue
                fi

                log "INFO" "  Created tag (ID: $new_tag_id)"

                # Refresh tags after creation
                all_tags=$(curl -s "${radarr_url}/api/v3/tag?apikey=${radarr_api_key}")
            fi
        fi

        # Find movies with old tag
        local movie_ids
        movie_ids=$(echo "$all_movies" | jq -r --argjson tid "$old_tag_id" '.[] | select(.tags | index($tid)) | .id')

        if [ -z "$movie_ids" ]; then
            log "INFO" "  No movies have old tag"

            if [ "$DELETE_OLD_TAGS" = "true" ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    log "INFO" "  [DRY-RUN] Would delete old tag definition"
                else
                    curl -s -X DELETE "${radarr_url}/api/v3/tag/${old_tag_id}?apikey=${radarr_api_key}" >/dev/null
                    log "INFO" "  Deleted old tag definition"
                fi
            fi

            operations_success=$((operations_success + 1))
            continue
        fi

        local movie_array movies_count
        movie_array=$(echo "$movie_ids" | jq -s '.')
        movies_count=$(echo "$movie_ids" | wc -l)

        log "INFO" "  Found $movies_count movies with old tag"

        if [ "$DRY_RUN" = "true" ]; then
            log "INFO" "  [DRY-RUN] Would add '$new_tag' to $movies_count movies"
            log "INFO" "  [DRY-RUN] Would remove '$old_tag' from $movies_count movies"
            if [ "$DELETE_OLD_TAGS" = "true" ]; then
                log "INFO" "  [DRY-RUN] Would delete old tag definition"
            fi
        else
            # Step 1: Add new tag
            log "INFO" "  Step 1/3: Adding '$new_tag' to $movies_count movies..."
            curl -s -X PUT -H "Content-Type: application/json" \
                -d "{\"movieIds\": $movie_array, \"tags\": [$new_tag_id], \"applyTags\": \"add\"}" \
                "${radarr_url}/api/v3/movie/editor?apikey=${radarr_api_key}" >/dev/null
            log "INFO" "  Done"

            # Step 2: Remove old tag
            log "INFO" "  Step 2/3: Removing '$old_tag' from $movies_count movies..."
            curl -s -X PUT -H "Content-Type: application/json" \
                -d "{\"movieIds\": $movie_array, \"tags\": [$old_tag_id], \"applyTags\": \"remove\"}" \
                "${radarr_url}/api/v3/movie/editor?apikey=${radarr_api_key}" >/dev/null
            log "INFO" "  Done"

            # Step 3: Delete old tag definition
            if [ "$DELETE_OLD_TAGS" = "true" ]; then
                log "INFO" "  Step 3/3: Deleting old tag definition..."
                curl -s -X DELETE "${radarr_url}/api/v3/tag/${old_tag_id}?apikey=${radarr_api_key}" >/dev/null
                log "INFO" "  Done"
            else
                log "INFO" "  Step 3/3: Keeping old tag (DELETE_OLD_TAGS=false)"
            fi

            total_renamed=$((total_renamed + movies_count))
        fi

        operations_success=$((operations_success + 1))
    done

    log "INFO" ""
    log "INFO" "Summary for $instance_name:"
    log "INFO" "  Successful: $operations_success"
    log "INFO" "  Failed: $operations_failed"
    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "  Mode: DRY-RUN (no changes made)"
    else
        log "INFO" "  Movies updated: $total_renamed"
    fi
}

########################################
# MAIN
########################################

log "INFO" "========================================"
log "INFO" "Tagarr Rename v${SCRIPT_VERSION}"
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
