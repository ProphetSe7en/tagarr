#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tagarr — Radarr Release Group Tagger with Discovery
# Version: 1.2.0
#
# Scans movies in one or two Radarr instances and tags them based on release
# group, quality source (MA/Play WEB-DL), and lossless audio codec (TrueHD,
# TrueHD Atmos, DTS-X, DTS-HD MA). Optionally syncs tags to a secondary
# Radarr instance and cleans up orphaned/empty tags.
#
# Features:
#   TAGGING    — Match movies by release group + quality + audio filters
#   SYNC       — Mirror tags to a secondary Radarr instance (optional)
#   DISCOVERY  — Auto-detect new release groups that pass all filters but
#                aren't in the config yet. Writes them as commented entries
#                for manual review and activation. (optional)
#   CLEANUP    — Remove tags with 0 movies at end of run (optional)
#   DEBUG      — Detailed per-movie file/quality/audio breakdown (optional)
#
# Usage:
#   tagarr.sh [OPTIONS]
#
# Options:
#   --help       Show this help message and exit
#   --dry-run    Simulate all changes without modifying Radarr
#   --tag NAME   Only process specific tags (comma-separated)
#   --discover   Run discovery only — scan for new release groups without
#                tagging or modifying any tags. Discovered groups are written
#                to the config as commented entries, logged, and sent to
#                Discord (if enabled). Implies --dry-run for tagging only.
#
# Based on tag_and_sync.sh v5.4.1. Configuration: tagarr.conf
#
# Author: prophetSe7en
#
# WARNING: This script creates and applies tags in Radarr. Review your config
# and test with ENABLE_DEBUG=true before scheduling unattended runs.
# -----------------------------------------------------------------------------

set -euo pipefail
SCRIPT_VERSION="1.2.0"

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
# DISCOVERY PRE-LOOP SETUP
########################################

# Build set of ALL known release groups from config (active + commented)
declare -A known_release_groups
known_release_groups[_]=1; unset "known_release_groups[_]"
while IFS= read -r line; do
    if [[ "$line" =~ \"([^:\"]+):[^:\"]+:[^:\"]+:[^:\"]+\" ]]; then
        known_release_groups["${BASH_REMATCH[1],,}"]=1
    fi
done < "$CONFIG_FILE"

# Will be populated during the main loop
# Seed + unset dummy key so bash treats these as "set" even when empty (required for set -u)
declare -A discovered_groups  # key=lowercase rg, value="DisplayName|quality_detail|audio_detail"
discovered_groups[_]=1; unset "discovered_groups[_]"

########################################
# ARGUMENT HANDLING
########################################

DRY_RUN=false
DISCOVER_ONLY=false
SELECTED_TAGS=()

show_help() {
  sed -n '/^# Usage:/,/^# Based on/{ /^# Based on/d; s/^# \?//p }' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --discover)
      DISCOVER_ONLY=true
      DRY_RUN=true
      ENABLE_DISCOVERY=true
      shift
      ;;
    --tag)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --tag requires a value"
        exit 1
      fi
      IFS=',' read -ra SELECTED_TAGS <<< "$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1 (use --help for usage)"
      exit 1
      ;;
  esac
done

########################################
# TERMINAL COLORS
########################################

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"

########################################
# UTILITIES
########################################

log() {
  local msg="$1"
  echo -e "$msg"
  if [ "$ENABLE_LOGGING" = "true" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    if [ -f "$LOG_FILE" ]; then
      local size
      size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
      if (( size > 2097152 )); then
        mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
      fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
  fi
}

format_duration() {
  local t="$1"
  local h=$((t/3600))
  local m=$(((t%3600)/60))
  local s=$((t%60))
  ((h>0)) && printf "%dh %dm %ds" "$h" "$m" "$s" && return
  ((m>0)) && printf "%dm %ds" "$m" "$s" && return
  printf "%ds" "$s"
}

########################################
# DISCORD NOTIFICATION FUNCTIONS
########################################

send_discord_summary() {
  local total_primary_tagged=$1
  local total_primary_untagged=$2
  local total_secondary_tagged=$3
  local total_secondary_untagged=$4
  local runtime=$5
  local dry_run_status=$6

  if [ "$DISCORD_ENABLED" != "true" ]; then
    return 0
  fi

  log "${CYAN}Sending Discord summary notification...${RESET}"

  local notif_color=16753920  # Orange (0xFFA500)
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  local footer_text="Tagarr v${SCRIPT_VERSION} by ProphetSe7en • $(date '+%d-%m-%Y %H:%M')"

  # Build primary field value with actual newline
  local primary_value="Tagged: ${total_primary_tagged}
Untagged: ${total_primary_untagged}"

  # Build secondary field value (if enabled) with actual newline
  local secondary_value=""
  if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    secondary_value="Tagged: ${total_secondary_tagged}
Untagged: ${total_secondary_untagged}"
  fi

  # Build runtime value
  local runtime_value="Completed in ${runtime} | Dry-run: ${dry_run_status}"

  # Build JSON payload
  local payload
  if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    payload=$(jq -n \
      --argjson color "$notif_color" \
      --arg title "Tagarr v${SCRIPT_VERSION}" \
      --arg primary_name "Primary (${PRIMARY_RADARR_NAME})" \
      --arg primary_value "$primary_value" \
      --arg secondary_name "Secondary (${SECONDARY_RADARR_NAME})" \
      --arg secondary_value "$secondary_value" \
      --arg runtime_value "$runtime_value" \
      --arg footer_text "$footer_text" \
      --arg timestamp "$timestamp" \
      '{
        embeds: [{
          title: $title,
          color: $color,
          fields: [
            {
              name: $primary_name,
              value: $primary_value,
              inline: true
            },
            {
              name: $secondary_name,
              value: $secondary_value,
              inline: true
            },
            {
              name: "Runtime",
              value: $runtime_value,
              inline: false
            }
          ],
          footer: {
            text: $footer_text
          },
          timestamp: $timestamp
        }]
      }')
  else
    # Only primary instance
    payload=$(jq -n \
      --argjson color "$notif_color" \
      --arg title "Tagarr v${SCRIPT_VERSION}" \
      --arg primary_name "Primary (${PRIMARY_RADARR_NAME})" \
      --arg primary_value "$primary_value" \
      --arg runtime_value "$runtime_value" \
      --arg footer_text "$footer_text" \
      --arg timestamp "$timestamp" \
      '{
        embeds: [{
          title: $title,
          color: $color,
          fields: [
            {
              name: $primary_name,
              value: $primary_value,
              inline: true
            },
            {
              name: "Runtime",
              value: $runtime_value,
              inline: false
            }
          ],
          footer: {
            text: $footer_text
          },
          timestamp: $timestamp
        }]
      }')
  fi

  local response
  response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1)

  local http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

  if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
    log "${GREEN}Discord summary sent successfully${RESET}"
  else
    log "${YELLOW}Discord summary failed (HTTP $http_code)${RESET}"
  fi

  sleep 0.1
}

send_discord_movie_list() {
  local title=$1
  local content=$2

  if [ "$DISCORD_ENABLED" != "true" ]; then
    return 0
  fi

  if [ -z "$content" ]; then
    return 0
  fi

  log "${CYAN}Sending Discord ${title} list...${RESET}"

  # Convert \n to actual newlines
  content=$(echo -e "$content")

  # Calculate max size for content (reserve space for formatting)
  local max_content_size=1800
  local content_length=${#content}

  if [ "$content_length" -le "$max_content_size" ]; then
    # Send as single message
    local full_message="**${title}:**
\`\`\`
${content}
\`\`\`"

    local payload=$(jq -n --arg content "$full_message" '{content: $content}')

    local response
    response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>&1)

    local http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
      log "${GREEN}✓ Discord ${title} sent successfully${RESET}"
    else
      log "${RED}✗ Discord ${title} failed (HTTP ${http_code})${RESET}"
    fi
  else
    # Need to split into multiple messages
    log "${YELLOW}Content too long (${content_length} chars), splitting into chunks...${RESET}"

    # Split by newlines into array
    local lines=()
    while IFS= read -r line; do
      lines+=("$line")
    done <<< "$content"

    local chunk_num=1
    local current_chunk=""
    local line_count=0

    for line in "${lines[@]}"; do
      local test_chunk="${current_chunk}${line}
"

      if [ ${#test_chunk} -gt "$max_content_size" ] && [ -n "$current_chunk" ]; then
        # Send current chunk
        local message="**${title}:** (part ${chunk_num})
\`\`\`
${current_chunk}\`\`\`"

        log "${CYAN}Sending chunk ${chunk_num} (${#current_chunk} chars, ${line_count} lines)${RESET}"

        local payload=$(jq -n --arg content "$message" '{content: $content}')

        local response
        response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
          -H "Content-Type: application/json" \
          -d "$payload" 2>&1)

        local http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
          log "${GREEN}✓ Chunk ${chunk_num} sent successfully${RESET}"
        else
          log "${RED}✗ Chunk ${chunk_num} failed (HTTP ${http_code})${RESET}"
        fi

        chunk_num=$((chunk_num + 1))
        current_chunk="${line}
"
        line_count=1
        sleep 0.15
      else
        current_chunk="$test_chunk"
        line_count=$((line_count + 1))
      fi
    done

    # Send final chunk if any content remains
    if [ -n "$current_chunk" ]; then
      local message
      if [ "$chunk_num" -eq 1 ]; then
        message="**${title}:**
\`\`\`
${current_chunk}\`\`\`"
      else
        message="**${title}:** (part ${chunk_num})
\`\`\`
${current_chunk}\`\`\`"
      fi

      log "${CYAN}Sending final chunk ${chunk_num} (${#current_chunk} chars, ${line_count} lines)${RESET}"

      local payload=$(jq -n --arg content "$message" '{content: $content}')

      local response
      response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

      local http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

      if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log "${GREEN}✓ Final chunk ${chunk_num} sent successfully${RESET}"
      else
        log "${RED}✗ Final chunk ${chunk_num} failed (HTTP ${http_code})${RESET}"
      fi
    fi
  fi

  sleep 0.1
}

send_discord_discovery() {
  local group_count=$1
  local movie_count=$2
  local discovery_text=$3

  if [ "$DISCORD_ENABLED" != "true" ] || [ "$group_count" -eq 0 ]; then
    return 0
  fi

  log "${CYAN}Sending Discord discovery notification...${RESET}"

  local notif_color=16766720  # Gold (0xFFD700)
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  local footer_text="Tagarr v${SCRIPT_VERSION} by ProphetSe7en • $(date '+%d-%m-%Y %H:%M')"

  local payload
  payload=$(jq -n \
    --argjson color "$notif_color" \
    --arg title "Discovered: ${group_count} groups | ${movie_count} movies" \
    --arg description "$discovery_text" \
    --arg footer_text "$footer_text" \
    --arg timestamp "$timestamp" \
    '{
      embeds: [{
        title: $title,
        description: $description,
        color: $color,
        footer: {
          text: $footer_text
        },
        timestamp: $timestamp
      }]
    }')

  local response
  response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" -X POST "$DISCORD_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1)

  local http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)

  if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
    log "${GREEN}Discord discovery notification sent successfully${RESET}"
  else
    log "${YELLOW}Discord discovery notification failed (HTTP $http_code)${RESET}"
  fi

  sleep 0.1
}

########################################
# OPTIONAL --tag FILTERING
########################################

if (( ${#SELECTED_TAGS[@]} > 0 )); then
  filtered=()
  for cfg in "${RELEASE_GROUPS[@]}"; do
    IFS=':' read -r search tag_name display_name mode <<< "$cfg"
    for sel in "${SELECTED_TAGS[@]}"; do
      [[ "$tag_name" == "$sel" ]] && filtered+=("$cfg")
    done
  done
  (( ${#filtered[@]} == 0 )) && { echo "ERROR: No matching release-groups found for --tag"; exit 1; }
  RELEASE_GROUPS=("${filtered[@]}")
fi

########################################
# FILTER FUNCTIONS
########################################

check_quality_match() {
  local f="$1"
  [ "$ENABLE_QUALITY_FILTER" != "true" ] && return 0

  # Match MA/Play WEB-DL patterns across naming schemes:
  #   Standard:  MA.WEB-DL  MA-WEBDL  MA_WEB.DL
  #   Bracket:   [MA][WEBDL-2160p]  [MA][WEB-DL]
  # Separator between source and WEB: . - _ ][ or ]\s*[
  # Uses word boundaries (\b) to prevent "AMZN" matching as "MA" or "IMAX" as "MA"

  if [ "$ENABLE_MA_WEBDL" = "true" ]; then
    if echo "$f" | grep -Eqi '\bma(\]?\s*\[?|[._-])web([-.]?dl)?'; then
      return 0
    fi
  fi

  if [ "$ENABLE_PLAY_WEBDL" = "true" ]; then
    if echo "$f" | grep -Eqi '\bplay(\]?\s*\[?|[._-])web([-.]?dl)?'; then
      return 0
    fi
  fi

  return 1
}

check_audio_match() {
  local f="$1"
  [ "$ENABLE_AUDIO_FILTER" != "true" ] && return 0

  # STRICT: Reject transcoded/upmixed/encoded audio first
  # Uses word boundaries to avoid false positives
  if echo "$f" | grep -Eqi '\b(upmix|encode|transcode|lossy|converted|re-?encode)\b'; then
    return 1
  fi

  # TrueHD checks - RESPECTS CONFIGURATION
  # Only matches if explicitly enabled
  if [ "$ENABLE_TRUEHD_ATMOS" = "true" ] || [ "$ENABLE_TRUEHD" = "true" ]; then
    if echo "$f" | grep -Eqi '\btruehd\b'; then
      if echo "$f" | grep -Eqi '\batmos\b'; then
        # TrueHD Atmos - only pass if Atmos is enabled
        [ "$ENABLE_TRUEHD_ATMOS" = "true" ] && return 0
      else
        # TrueHD (non-Atmos) - only pass if non-Atmos is enabled
        [ "$ENABLE_TRUEHD" = "true" ] && return 0
      fi
    fi
  fi

  # DTS:X check with word boundary
  if [ "$ENABLE_DTS_X" = "true" ]; then
    if echo "$f" | grep -Eqi '\bdts[._-]?x\b'; then
      return 0
    fi
  fi

  # DTS-HD MA check - supports various separators
  if [ "$ENABLE_DTS_HD_MA" = "true" ]; then
    # Match: DTS-HD.MA or DTS-HD MA or DTS.HD.MA or DTS_HD_MA etc
    if echo "$f" | grep -Eqi '\bdts[._ -]?hd[._ -]?ma\b'; then
      return 0
    fi
  fi

  return 1
}

########################################
# MAIN ENGINE
########################################

main() {
  local start_ts
  start_ts=$(date +%s)

  log ""
  log "${CYAN}Tagarr v${SCRIPT_VERSION}${RESET}"
  log "Primary:   ${PRIMARY_RADARR_NAME}"
  if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    log "Secondary: ${SECONDARY_RADARR_NAME}"
  else
    log "Secondary: disabled"
  fi

  if (( ${#SELECTED_TAGS[@]} > 0 )); then
    log "Selected tags: ${SELECTED_TAGS[*]}"
  fi

  if [ "$DRY_RUN" = true ]; then
    log "${YELLOW}MODE: DRY-RUN (no changes will be made)${RESET}"
  else
    log "${GREEN}MODE: LIVE (changes will be applied)${RESET}"
  fi

  if [ "${ENABLE_DISCOVERY:-false}" = "true" ]; then
    log "Discovery: ${GREEN}enabled${RESET} (${#known_release_groups[@]} known groups)"
    # Prepare discovery log buffer (written sorted at end of run)
    if [ -n "${DISCOVERY_LOG_FILE:-}" ]; then
      mkdir -p "$(dirname "$DISCOVERY_LOG_FILE")"
    fi
    declare -a discovery_log_buffer=()
    discovery_log_buffer+=("_"); unset "discovery_log_buffer[0]"
    declare -A discovery_log_counts=()
    discovery_log_counts[_]=1; unset "discovery_log_counts[_]"
  else
    log "Discovery: disabled"
  fi
  log ""

  ########################################
  # SANITY CHECKS
  ########################################

  if ! curl -s -f "${PRIMARY_RADARR_URL}/api/v3/system/status?apikey=${PRIMARY_RADARR_API_KEY}" >/dev/null; then
    log "${RED}ERROR: Cannot connect to primary Radarr${RESET}"
    exit 1
  fi

  local secondary_movies_json=""
  declare -A secondary_by_tmdb

  if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    if curl -s -f "${SECONDARY_RADARR_URL}/api/v3/system/status?apikey=${SECONDARY_RADARR_API_KEY}" >/dev/null; then
      log "Fetching movies from ${SECONDARY_RADARR_NAME}..."
      secondary_movies_json=$(curl -s "${SECONDARY_RADARR_URL}/api/v3/movie?apikey=${SECONDARY_RADARR_API_KEY}")

      if [ -z "$secondary_movies_json" ] || [ "$secondary_movies_json" = "null" ]; then
        log "${RED}ERROR: Failed to fetch movies from ${SECONDARY_RADARR_NAME}${RESET}"
        ENABLE_SYNC_TO_SECONDARY=false
      else
        local sec_total
        sec_total=$(echo "$secondary_movies_json" | jq -r 'length')
        log "Found $sec_total movies in ${SECONDARY_RADARR_NAME}"

        log "Building secondary lookup hashmap..."
        while IFS=$'\t' read -r sid stmdb stags; do
          if [ -n "$stmdb" ] && [ "$stmdb" != "null" ]; then
            secondary_by_tmdb["$stmdb"]="$sid:$stags"
          fi
        done < <(echo "$secondary_movies_json" | jq -r '(. // []) | .[] | [.id, .tmdbId, ((.tags // [])|tostring)] | @tsv')

        log "Built hashmap with ${#secondary_by_tmdb[@]} entries (TMDb → ID:tags)"

        if [ "${#secondary_by_tmdb[@]}" -eq 0 ]; then
          log "${YELLOW}WARNING: Secondary hashmap is empty! Secondary sync will not work.${RESET}"
        fi
        log ""
      fi

    else
      log "${YELLOW}WARNING: Cannot connect to secondary Radarr, disabling sync${RESET}"
      ENABLE_SYNC_TO_SECONDARY=false
    fi
  fi

  ########################################
  # FETCH MOVIES
  ########################################

  local movies_json
  movies_json=$(curl -s "${PRIMARY_RADARR_URL}/api/v3/movie?apikey=${PRIMARY_RADARR_API_KEY}")

  local total_movies
  total_movies=$(echo "$movies_json" | jq 'length')

  local movies_with_files
  movies_with_files=$(echo "$movies_json" | jq '[.[] | select(.hasFile == true)] | length')

  log "Found $total_movies movies in ${PRIMARY_RADARR_NAME} ($movies_with_files with files)"
  log ""

  ########################################
  # RESOLVE TAG IDS
  ########################################

  declare -A primary_tag_ids
  declare -A secondary_tag_ids

  local existing_primary_tags
  existing_primary_tags=$(curl -s "${PRIMARY_RADARR_URL}/api/v3/tag?apikey=${PRIMARY_RADARR_API_KEY}")

  local existing_secondary_tags=""
  if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    existing_secondary_tags=$(curl -s "${SECONDARY_RADARR_URL}/api/v3/tag?apikey=${SECONDARY_RADARR_API_KEY}")
  fi

  for cfg in "${RELEASE_GROUPS[@]}"; do
    IFS=':' read -r search tag_name display_name mode <<< "$cfg"

    # PRIMARY TAG — lookup only, no creation (tags are created lazily when needed)
    local pid
    pid=$(echo "$existing_primary_tags" | jq -r --arg t "$tag_name" '(. // []) | .[] | select(.label==$t).id' | head -n1)

    if [[ -n "$pid" && "$pid" != "null" ]]; then
      log "Using existing tag '$tag_name' (ID: $pid) in ${PRIMARY_RADARR_NAME}"
      primary_tag_ids["$tag_name"]="$pid"
    else
      log "Tag '$tag_name' not found in ${PRIMARY_RADARR_NAME} (will create if needed)"
      primary_tag_ids["$tag_name"]=""
    fi

    # SECONDARY TAG — lookup only
    if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
      local sid
      sid=$(echo "$existing_secondary_tags" | jq -r --arg t "$tag_name" '(. // []) | .[] | select(.label==$t).id' | head -n1)

      if [[ -n "$sid" && "$sid" != "null" ]]; then
        log "Using existing tag '$tag_name' (ID: $sid) in ${SECONDARY_RADARR_NAME}"
        secondary_tag_ids["$tag_name"]="$sid"
      else
        log "Tag '$tag_name' not found in ${SECONDARY_RADARR_NAME} (will create if needed)"
        secondary_tag_ids["$tag_name"]=""
      fi
    fi
  done

  log ""

  ########################################
  # STATS + BATCH STRUCTURES
  ########################################

  declare -A stats_primary_matched
  declare -A stats_primary_tagged
  declare -A stats_primary_existing
  declare -A stats_primary_untagged

  declare -A stats_secondary_tagged
  declare -A stats_secondary_existing
  declare -A stats_secondary_untagged
  declare -A stats_secondary_not_found

  declare -A tagged_titles_array
  declare -A untagged_titles_array
  declare -A notfound_titles_array

  # Array to track which specific movies were tagged in secondary (for Discord accuracy)
  declare -A tagged_in_secondary_array

  # Array to track which specific movies were untagged in secondary (for Discord accuracy)
  declare -A untagged_in_secondary_array

  # NEW: Debug logging arrays
  declare -A debug_tagged_files
  declare -A debug_untagged_files

  declare -A primary_tag_status
  declare -A primary_to_add
  declare -A primary_to_remove
  declare -A secondary_to_add
  declare -A secondary_to_remove

  ########################################
  # C‑ENGINE — SINGLE PASS
  ########################################

  local processed=0

  while IFS= read -r movie; do
    local has_file
    has_file=$(echo "$movie" | jq -r '.hasFile')
    [ "$has_file" != "true" ] && continue

    processed=$((processed + 1))
    if (( processed % PROGRESS_INTERVAL == 0 )); then
      log "Progress: $processed / $movies_with_files"
    fi

    # Single jq call for all basic fields (+ rg_original for discovery display)
    local movie_id movie_title movie_year tmdb_id rel scene rg rg_original
    IFS=$'\t' read -r movie_id movie_title movie_year tmdb_id rel scene rg rg_original <<< "$(
      echo "$movie" | jq -r '[
        .id,
        .title,
        .year,
        .tmdbId,
        (.movieFile.relativePath // "" | ascii_downcase),
        (.movieFile.sceneName // "" | ascii_downcase),
        (.movieFile.releaseGroup // "" | ascii_downcase),
        (.movieFile.releaseGroup // "")
      ] | @tsv'
    )"

    local tags_array
    tags_array=$(echo "$movie" | jq -c '(.tags // [])')

    # Build combined string for QUALITY/AUDIO filters
    # Use ALL available data for maximum information
    local combined_for_filters="$rel $scene $rg"

    # Track which tags this movie SHOULD have
    declare -A should_have_these_tags

    for cfg in "${RELEASE_GROUPS[@]}"; do
      IFS=':' read -r search tag_name display_name mode <<< "$cfg"
      should_have_these_tags["$tag_name"]=false
    done

    # Now check each tag to determine if movie should have it
    for cfg in "${RELEASE_GROUPS[@]}"; do
      IFS=':' read -r search tag_name display_name mode <<< "$cfg"

      local search_lower="${search,,}"
      local rel_lower="${rel,,}"
      local scene_lower="${scene,,}"
      local rg_lower="${rg,,}"

      # Check each field individually with word boundaries
      # This prevents "sic" from matching inside "jurassic"
      # Priority order: releaseGroup > sceneName > relativePath
      local match=false
      local match_location=""

      if [ -n "$rg_lower" ] && echo "$rg_lower" | grep -Eqi "\b$search_lower\b"; then
        match=true
        match_location="releaseGroup field"
      elif [ -n "$scene_lower" ] && echo "$scene_lower" | grep -Eqi "\b$search_lower\b"; then
        match=true
        match_location="sceneName"
      elif [ -n "$rel_lower" ] && echo "$rel_lower" | grep -Eqi "\b$search_lower\b"; then
        match=true
        match_location="relativePath"
      fi

      # Only count matched movies in stats
      if [ "$match" = true ]; then
        stats_primary_matched["$tag_name"]=$(( ${stats_primary_matched["$tag_name"]:-0} + 1 ))
      fi

      local should_have=false
      local quality_result="N/A"
      local audio_result="N/A"
      local quality_detail=""
      local audio_detail=""

      # Determine if movie SHOULD have this tag
      if [ "$match" = true ]; then
        if [ "$mode" = "simple" ]; then
          should_have=true
          quality_result="N/A (simple mode)"
          audio_result="N/A (simple mode)"
        else
          local q_ok=false a_ok=false
          # Use combined_for_filters (all data) for quality/audio matching
          if check_quality_match "$combined_for_filters"; then
            q_ok=true
            quality_result="PASS"
            # Detect which quality
            if echo "$combined_for_filters" | grep -Eqi '\bma(\]?\s*\[?|[._-])web'; then
              quality_detail="MA WEB-DL"
            elif echo "$combined_for_filters" | grep -Eqi '\bplay(\]?\s*\[?|[._-])web'; then
              quality_detail="Play WEB-DL"
            else
              quality_detail="Unknown"
            fi
          else
            quality_result="FAIL"
            # Detect why it failed
            if echo "$combined_for_filters" | grep -Eqi '\bamzn(\]?\s*\[?|[._-])web'; then
              quality_detail="AMZN (not MA/Play)"
            elif echo "$combined_for_filters" | grep -Eqi '\bnf(\]?\s*\[?|[._-])web'; then
              quality_detail="Netflix (not MA/Play)"
            elif echo "$combined_for_filters" | grep -Eqi '\bweb'; then
              quality_detail="Plain WEB-DL (no MA/Play prefix)"
            else
              quality_detail="No WEB-DL source"
            fi
          fi

          if check_audio_match "$combined_for_filters"; then
            a_ok=true
            audio_result="PASS"
            # Detect which audio
            if echo "$combined_for_filters" | grep -Eqi '\btruehd\b.*\batmos\b|\batmos\b.*\btruehd\b'; then
              audio_detail="TrueHD Atmos"
            elif echo "$combined_for_filters" | grep -Eqi '\bdts[._-]?x\b'; then
              audio_detail="DTS-X"
            elif echo "$combined_for_filters" | grep -Eqi '\btruehd\b'; then
              audio_detail="TrueHD"
            elif echo "$combined_for_filters" | grep -Eqi '\bdts[._ -]?hd[._ -]?ma\b'; then
              audio_detail="DTS-HD.MA"
            else
              audio_detail="Lossless audio"
            fi
          else
            audio_result="FAIL"
            # Detect why it failed
            if echo "$combined_for_filters" | grep -Eqi '\beac3\b|\bdd\+'; then
              audio_detail="EAC3/DD+ (lossy)"
            elif echo "$combined_for_filters" | grep -Eqi '\baac\b'; then
              audio_detail="AAC (lossy)"
            elif echo "$combined_for_filters" | grep -Eqi '\bac3\b'; then
              audio_detail="AC3 (lossy)"
            else
              audio_detail="No lossless audio"
            fi
          fi

          if [ "$q_ok" = true ] && [ "$a_ok" = true ]; then
            should_have=true
          fi
        fi
      fi

      # Update our tracking
      should_have_these_tags["$tag_name"]=$should_have

      # Store for secondary orphan cleanup
      if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ] && [ -n "$tmdb_id" ] && [ "$tmdb_id" != "null" ]; then
        primary_tag_status["${tmdb_id}:${tag_name}"]="$should_have"
      fi

      # Check if movie currently HAS this tag
      local primary_tag_id="${primary_tag_ids[$tag_name]:-}"
      local has_tag="false"
      if [ -n "$primary_tag_id" ]; then
        has_tag=$(echo "$tags_array" | jq --argjson id "$primary_tag_id" 'index($id) != null')
      fi

      # Add/Keep/Remove logic
      if [ "$should_have" = true ]; then
        # Movie SHOULD have tag
        if [ "$has_tag" = "true" ]; then
          # Already has it - keep it
          stats_primary_existing["$tag_name"]=$(( ${stats_primary_existing["$tag_name"]:-0} + 1 ))
        else
          # Doesn't have it - add it
          primary_to_add["$tag_name"]+="$movie_id "
          stats_primary_tagged["$tag_name"]=$(( ${stats_primary_tagged["$tag_name"]:-0} + 1 ))
          tagged_titles_array["${tag_name}_${stats_primary_tagged[$tag_name]}"]="${movie_title} (${movie_year})"

          # DEBUG: Log full details with actual values
          local idx=${stats_primary_tagged[$tag_name]}
          local q_display="$quality_result"
          local a_display="$audio_result"
          if [ -n "$quality_detail" ]; then
            q_display="$quality_result ($quality_detail)"
          fi
          if [ -n "$audio_detail" ]; then
            a_display="$audio_result ($audio_detail)"
          fi
          local debug_info="FILE: $rel\nSCENE: ${scene:-none}\nRELEASE_GROUP: ${rg:-none}\nMATCH: $match_location\nQUALITY: $q_display\nAUDIO: $a_display"
          debug_tagged_files["${tag_name}_${idx}"]="${movie_title} (${movie_year})|${PRIMARY_RADARR_NAME}|${debug_info}"
        fi
      else
        # Movie should NOT have tag
        if [ "$has_tag" = "true" ]; then
          # Has it but shouldn't - remove it
          primary_to_remove["$tag_name"]+="$movie_id "
          stats_primary_untagged["$tag_name"]=$(( ${stats_primary_untagged["$tag_name"]:-0} + 1 ))

          # Determine reason for removal
          local reason=""
          if [ "$match" = false ]; then
            reason="Wrong release group"
          else
            if [ "$mode" = "filtered" ]; then
              local q_ok=false a_ok=false
              # Use combined_for_filters for quality/audio checks
              check_quality_match "$combined_for_filters" && q_ok=true
              check_audio_match "$combined_for_filters" && a_ok=true

              if [ "$q_ok" = false ] && [ "$a_ok" = false ]; then
                reason="Failed quality & audio"
              elif [ "$q_ok" = false ]; then
                reason="Failed quality"
              elif [ "$a_ok" = false ]; then
                reason="Failed audio"
              else
                reason="Unknown filter issue"
              fi
            else
              reason="Mode mismatch"
            fi
          fi

          untagged_titles_array["primary_${tag_name}_${stats_primary_untagged[$tag_name]}"]="${movie_title} (${movie_year})|${PRIMARY_RADARR_NAME}|${reason}"

          # DEBUG: Log full details with actual values
          local idx=${stats_primary_untagged[$tag_name]}
          local q_display="$quality_result"
          local a_display="$audio_result"
          if [ -n "$quality_detail" ]; then
            q_display="$quality_result ($quality_detail)"
          fi
          if [ -n "$audio_detail" ]; then
            a_display="$audio_result ($audio_detail)"
          fi
          local debug_info="FILE: $rel\nSCENE: ${scene:-none}\nRELEASE_GROUP: ${rg:-none}\nMATCH: ${match}/${match_location}\nQUALITY: $q_display\nAUDIO: $a_display\nREASON: $reason"
          debug_untagged_files["primary_${tag_name}_${idx}"]="${movie_title} (${movie_year})|${PRIMARY_RADARR_NAME}|${debug_info}"
        fi
      fi

      ########################################
      # SECONDARY SYNC (v4.4.0 structure + v2.1 grep method)
      ########################################

      if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ] && [ -n "$tmdb_id" ] && [ "$tmdb_id" != "null" ]; then
        local sec_data="${secondary_by_tmdb[$tmdb_id]:-}"

        # DEBUG: Log first 3 movies for TheFarm
        if [ "${ENABLE_DEBUG:-false}" = "true" ] && [ "$tag_name" = "thefarm" ] && [ "$should_have" = true ]; then
          local debug_count=$(( ${stats_secondary_tagged[$tag_name]:-0} + ${stats_secondary_existing[$tag_name]:-0} ))
          if [ "$debug_count" -lt 3 ]; then
            log "  DEBUG: ${movie_title} (TMDb:$tmdb_id)"
            if [ -n "$sec_data" ]; then
              log "    Found in secondary: $sec_data"
            else
              log "    NOT found in secondary hashmap!"
            fi
          fi
        fi

        if [ -n "$sec_data" ]; then
          local sec_id sec_tags
          sec_id="${sec_data%%:*}"
          sec_tags="${sec_data#*:}"

          local secondary_tag_id="${secondary_tag_ids[$tag_name]:-}"
          local sec_has_tag=false

          # DEBUG: Log tag checking for first 3
          if [ "${ENABLE_DEBUG:-false}" = "true" ] && [ "$tag_name" = "thefarm" ] && [ "$should_have" = true ]; then
            local debug_count=$(( ${stats_secondary_tagged[$tag_name]:-0} + ${stats_secondary_existing[$tag_name]:-0} ))
            if [ "$debug_count" -lt 3 ]; then
              log "    Checking for tag ID $secondary_tag_id in: $sec_tags"
            fi
          fi

          # Use grep with word boundaries (v2.1 method that works)
          if [ -n "$secondary_tag_id" ] && echo "$sec_tags" | grep -q "\b${secondary_tag_id}\b"; then
            sec_has_tag=true
          fi

          # DEBUG: Log result
          if [ "${ENABLE_DEBUG:-false}" = "true" ] && [ "$tag_name" = "thefarm" ] && [ "$should_have" = true ]; then
            local debug_count=$(( ${stats_secondary_tagged[$tag_name]:-0} + ${stats_secondary_existing[$tag_name]:-0} ))
            if [ "$debug_count" -lt 3 ]; then
              if [ "$sec_has_tag" = true ]; then
                log "    → Already has tag (will keep)"
              else
                log "    → Does NOT have tag (will add)"
              fi
            fi
          fi

          if [ "$should_have" = true ]; then
            if [ "$sec_has_tag" = true ]; then
              stats_secondary_existing["$tag_name"]=$(( ${stats_secondary_existing["$tag_name"]:-0} + 1 ))
              # Mark that this movie exists in secondary
              tagged_in_secondary_array["${tag_name}_${movie_title} (${movie_year})"]="true"
            else
              secondary_to_add["$tag_name"]+="$sec_id "
              stats_secondary_tagged["$tag_name"]=$(( ${stats_secondary_tagged["$tag_name"]:-0} + 1 ))
              # Mark that this movie will be tagged in secondary
              tagged_in_secondary_array["${tag_name}_${movie_title} (${movie_year})"]="true"
            fi
          else
            if [ "$sec_has_tag" = true ]; then
              secondary_to_remove["$tag_name"]+="$sec_id "
              stats_secondary_untagged["$tag_name"]=$(( ${stats_secondary_untagged["$tag_name"]:-0} + 1 ))

              local reason=""
              if [ "$match" = false ]; then
                reason="Wrong release group"
              else
                if [ "$mode" = "filtered" ]; then
                  local q_ok=false a_ok=false
                  check_quality_match "$combined_for_filters" && q_ok=true
                  check_audio_match "$combined_for_filters" && a_ok=true

                  if [ "$q_ok" = false ] && [ "$a_ok" = false ]; then
                    reason="Failed quality & audio"
                  elif [ "$q_ok" = false ]; then
                    reason="Failed quality"
                  elif [ "$a_ok" = false ]; then
                    reason="Failed audio"
                  else
                    reason="Unknown filter issue"
                  fi
                else
                  reason="Mode mismatch"
                fi
              fi

              untagged_titles_array["secondary_${tag_name}_${stats_secondary_untagged[$tag_name]}"]="${movie_title} (${movie_year})|${SECONDARY_RADARR_NAME}|${reason}"
              # Mark that this movie was untagged in secondary
              untagged_in_secondary_array["${tag_name}_${movie_title} (${movie_year})"]="true"
            fi
          fi

        else
          if [ "$should_have" = true ]; then
            stats_secondary_not_found["$tag_name"]=$(( ${stats_secondary_not_found["$tag_name"]:-0} + 1 ))
            notfound_titles_array["${tag_name}_${stats_secondary_not_found[$tag_name]}"]="${movie_title} (${movie_year})"
          fi
        fi
      fi

    done

    ########################################
    # DISCOVERY CHECK (after all configured groups checked)
    ########################################

    if [ "${ENABLE_DISCOVERY:-false}" = "true" ] && [ -n "$rg" ] && [ "$rg" != "null" ]; then
      local rg_lower="${rg,,}"

      # Skip if already known (active or commented in config)
      if [ -z "${known_release_groups[$rg_lower]:-}" ]; then
        # Run quality + audio filters on combined data
        local disc_quality_detail=""
        local disc_audio_detail=""
        local disc_q_ok=false
        local disc_a_ok=false

        if check_quality_match "$combined_for_filters"; then
          disc_q_ok=true
          if echo "$combined_for_filters" | grep -Eqi '\bma(\]?\s*\[?|[._-])web'; then
            disc_quality_detail="MA WEB-DL"
          elif echo "$combined_for_filters" | grep -Eqi '\bplay(\]?\s*\[?|[._-])web'; then
            disc_quality_detail="Play WEB-DL"
          else
            disc_quality_detail="Unknown WEB-DL"
          fi
        fi

        if check_audio_match "$combined_for_filters"; then
          disc_a_ok=true
          if echo "$combined_for_filters" | grep -Eqi '\btruehd\b.*\batmos\b|\batmos\b.*\btruehd\b'; then
            disc_audio_detail="TrueHD Atmos"
          elif echo "$combined_for_filters" | grep -Eqi '\bdts[._-]?x\b'; then
            disc_audio_detail="DTS-X"
          elif echo "$combined_for_filters" | grep -Eqi '\btruehd\b'; then
            disc_audio_detail="TrueHD"
          elif echo "$combined_for_filters" | grep -Eqi '\bdts[._ -]?hd[._ -]?ma\b'; then
            disc_audio_detail="DTS-HD.MA"
          else
            disc_audio_detail="Lossless audio"
          fi
        fi

        if [ "$disc_q_ok" = true ] && [ "$disc_a_ok" = true ]; then
          # Use original case from Radarr for display name
          local display_name_disc="${rg_original}"
          [ -z "$display_name_disc" ] && display_name_disc="$rg"

          # First time seeing this group — register it
          if [ -z "${discovered_groups[$rg_lower]:-}" ]; then
            discovered_groups["$rg_lower"]="${display_name_disc}|${disc_quality_detail}|${disc_audio_detail}"
            log "${MAGENTA}  DISCOVERED: ${display_name_disc} (${disc_quality_detail} + ${disc_audio_detail}) — ${movie_title} (${movie_year})${RESET}"
          fi

          # Buffer for discovery log (written sorted at end of run)
          if [ -n "${DISCOVERY_LOG_FILE:-}" ]; then
            discovery_log_buffer+=("${display_name_disc}  |  ${movie_title} (${movie_year})  |  ${disc_quality_detail}  |  ${disc_audio_detail}  |  ${rel}")
            discovery_log_counts["${display_name_disc}"]=$(( ${discovery_log_counts["${display_name_disc}"]:-0} + 1 ))
          fi
        fi
      fi
    fi

  done < <(echo "$movies_json" | jq -c '(. // []) | .[]')

  if [ "$DISCOVER_ONLY" = true ]; then
    log ""
    log "${CYAN}Discovery-only mode — skipping tag changes${RESET}"
  else

  ########################################
  # SECONDARY ORPHANED TAG CLEANUP
  ########################################

  if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    log ""
    log "${CYAN}Checking secondary for orphaned tags...${RESET}"

    local orphan_count=0

    while IFS= read -r sec_movie; do
      local sec_movie_id sec_tmdb_id sec_title sec_year
      read -r sec_movie_id sec_tmdb_id sec_title sec_year <<< "$(
        echo "$sec_movie" | jq -r '[.id, .tmdbId, .title, .year] | @tsv'
      )"

      local sec_tags_array
      sec_tags_array=$(echo "$sec_movie" | jq -c '(.tags // [])')

      [ -z "$sec_tmdb_id" ] || [ "$sec_tmdb_id" = "null" ] && continue

      for cfg in "${RELEASE_GROUPS[@]}"; do
        IFS=':' read -r search tag_name display_name mode <<< "$cfg"

        local secondary_tag_id="${secondary_tag_ids[$tag_name]:-}"
        [ -z "$secondary_tag_id" ] && continue

        local sec_has_this_tag
        sec_has_this_tag=$(echo "$sec_tags_array" | jq --argjson id "$secondary_tag_id" 'index($id) != null')

        [ "$sec_has_this_tag" != "true" ] && continue

        # Check if primary says this movie should have this tag
        local primary_status="${primary_tag_status[${sec_tmdb_id}:${tag_name}]:-unknown}"

        if [ "$primary_status" = "false" ] || [ "$primary_status" = "unknown" ]; then
          # Secondary has tag but primary doesn't want it
          orphan_count=$((orphan_count + 1))

          local already_queued=false
          if [[ " ${secondary_to_remove[$tag_name]:-} " == *" $sec_movie_id "* ]]; then
            already_queued=true
          fi

          if [ "$already_queued" = false ]; then
            secondary_to_remove["$tag_name"]+="$sec_movie_id "
            stats_secondary_untagged["$tag_name"]=$(( ${stats_secondary_untagged["$tag_name"]:-0} + 1 ))

            local reason="Orphaned tag (not in primary or doesn't match criteria)"
            local idx=${stats_secondary_untagged[$tag_name]}
            untagged_titles_array["orphan_${tag_name}_${idx}"]="${sec_title} (${sec_year})|${SECONDARY_RADARR_NAME}|${reason}"

            # DEBUG
            debug_untagged_files["orphan_${tag_name}_${idx}"]="${sec_title} (${sec_year})|${SECONDARY_RADARR_NAME}|ORPHANED: Film not found in primary or doesn't match criteria\nPRIMARY_STATUS: ${primary_status}"
          fi
        fi
      done

    done < <(echo "$secondary_movies_json" | jq -c '(. // []) | .[]')

    log "Found $orphan_count orphaned tags in ${SECONDARY_RADARR_NAME}"
  fi

  ########################################
  # APPLY TAG CHANGES
  ########################################

  log ""
  log "${CYAN}Applying tag changes...${RESET}"

  for cfg in "${RELEASE_GROUPS[@]}"; do
    IFS=':' read -r search tag_name display_name mode <<< "$cfg"

    local primary_tag_id="${primary_tag_ids[$tag_name]:-}"
    local secondary_tag_id="${secondary_tag_ids[$tag_name]:-}"

    local p_add="${primary_to_add[$tag_name]:-}"
    local p_remove="${primary_to_remove[$tag_name]:-}"
    local s_add="${secondary_to_add[$tag_name]:-}"
    local s_remove="${secondary_to_remove[$tag_name]:-}"

    # PRIMARY ADD — create tag lazily if it doesn't exist yet
    if [ -n "$p_add" ]; then
      if [ -z "$primary_tag_id" ]; then
        if [ "$DRY_RUN" = false ]; then
          primary_tag_id=$(curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"label\":\"${tag_name}\"}" \
            "${PRIMARY_RADARR_URL}/api/v3/tag?apikey=${PRIMARY_RADARR_API_KEY}" | jq -r '.id')
          primary_tag_ids["$tag_name"]="$primary_tag_id"
          log "Created tag '$tag_name' in ${PRIMARY_RADARR_NAME} (ID: $primary_tag_id)"
        else
          primary_tag_id="999999"
          primary_tag_ids["$tag_name"]="999999"
          log "[DRY-RUN] Would create tag '$tag_name' in ${PRIMARY_RADARR_NAME}"
        fi
      fi
      local ids_json
      ids_json=$(printf '%s\n' $p_add | jq -s '.')
      if [ "$DRY_RUN" = false ]; then
        curl -s -X PUT -H "Content-Type: application/json" \
          -d "{\"movieIds\":${ids_json},\"tags\":[${primary_tag_id}],\"applyTags\":\"add\"}" \
          "${PRIMARY_RADARR_URL}/api/v3/movie/editor?apikey=${PRIMARY_RADARR_API_KEY}" >/dev/null
      fi
    fi

    # PRIMARY REMOVE — only if tag exists in Radarr
    if [ -n "$p_remove" ] && [ -n "$primary_tag_id" ]; then
      local ids_json2
      ids_json2=$(printf '%s\n' $p_remove | jq -s '.')
      if [ "$DRY_RUN" = false ]; then
        curl -s -X PUT -H "Content-Type: application/json" \
          -d "{\"movieIds\":${ids_json2},\"tags\":[${primary_tag_id}],\"applyTags\":\"remove\"}" \
          "${PRIMARY_RADARR_URL}/api/v3/movie/editor?apikey=${PRIMARY_RADARR_API_KEY}" >/dev/null
      fi
    fi

    ########################################
    # SECONDARY SYNC APPLY
    ########################################

    if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then

      # SECONDARY ADD — create tag lazily if it doesn't exist yet
      if [ -n "$s_add" ]; then
        if [ -z "$secondary_tag_id" ]; then
          if [ "$DRY_RUN" = false ]; then
            secondary_tag_id=$(curl -s -X POST -H "Content-Type: application/json" \
              -d "{\"label\":\"${tag_name}\"}" \
              "${SECONDARY_RADARR_URL}/api/v3/tag?apikey=${SECONDARY_RADARR_API_KEY}" | jq -r '.id')
            secondary_tag_ids["$tag_name"]="$secondary_tag_id"
            log "Created tag '$tag_name' in ${SECONDARY_RADARR_NAME} (ID: $secondary_tag_id)"
          else
            secondary_tag_id="999999"
            secondary_tag_ids["$tag_name"]="999999"
            log "[DRY-RUN] Would create tag '$tag_name' in ${SECONDARY_RADARR_NAME}"
          fi
        fi
        local s_ids_json
        s_ids_json=$(printf '%s\n' $s_add | jq -s '.')
        if [ "$DRY_RUN" = false ]; then
          curl -s -X PUT -H "Content-Type: application/json" \
            -d "{\"movieIds\":${s_ids_json},\"tags\":[${secondary_tag_id}],\"applyTags\":\"add\"}" \
            "${SECONDARY_RADARR_URL}/api/v3/movie/editor?apikey=${SECONDARY_RADARR_API_KEY}" >/dev/null
        fi
      fi

      # SECONDARY REMOVE — only if tag exists in Radarr
      if [ -n "$s_remove" ] && [ -n "$secondary_tag_id" ]; then
        local s_ids_json2
        s_ids_json2=$(printf '%s\n' $s_remove | jq -s '.')
        if [ "$DRY_RUN" = false ]; then
          curl -s -X PUT -H "Content-Type: application/json" \
            -d "{\"movieIds\":${s_ids_json2},\"tags\":[${secondary_tag_id}],\"applyTags\":\"remove\"}" \
            "${SECONDARY_RADARR_URL}/api/v3/movie/editor?apikey=${SECONDARY_RADARR_API_KEY}" >/dev/null
        fi
      fi

    fi

  done

  fi  # end DISCOVER_ONLY gate

  ########################################
  # WRITE DISCOVERIES TO CONFIG
  ########################################

  if [ "${ENABLE_DISCOVERY:-false}" = "true" ] && [ ${#discovered_groups[@]} -gt 0 ]; then
    log ""
    log "${CYAN}Writing ${#discovered_groups[@]} discovered groups to config...${RESET}"

    local today
    today=$(date '+%Y-%m-%d')

    if [ "$DRY_RUN" = true ] && [ "$DISCOVER_ONLY" = false ]; then
      log "${YELLOW}[DRY-RUN] Would write ${#discovered_groups[@]} discovered groups to config:${RESET}"
      for rg_key in "${!discovered_groups[@]}"; do
        local disc_data="${discovered_groups[$rg_key]}"
        local disc_display="${disc_data%%|*}"
        local disc_rest="${disc_data#*|}"
        local disc_quality="${disc_rest%%|*}"
        local disc_audio="${disc_rest#*|}"
        log "  #\"${rg_key}:${rg_key}:${disc_display}:filtered\"              # Discovered ${today}: ${disc_quality} + ${disc_audio}"
      done
    else
      # Find insertion point: locate RELEASE_GROUPS=( line, then find closing )
      local rg_start_line
      rg_start_line=$(grep -n 'RELEASE_GROUPS=(' "$CONFIG_FILE" | head -n1 | cut -d: -f1)

      if [ -n "$rg_start_line" ]; then
        # Find the closing ) after RELEASE_GROUPS=(
        local rg_close_line
        rg_close_line=$(tail -n +"$rg_start_line" "$CONFIG_FILE" | grep -n '^)' | head -n1 | cut -d: -f1)

        if [ -n "$rg_close_line" ]; then
          # Convert to absolute line number
          rg_close_line=$(( rg_start_line + rg_close_line - 1 ))

          # Build the insertion text
          local insert_text=""
          for rg_key in $(printf '%s\n' "${!discovered_groups[@]}" | sort); do
            local disc_data="${discovered_groups[$rg_key]}"
            local disc_display="${disc_data%%|*}"
            local disc_rest="${disc_data#*|}"
            local disc_quality="${disc_rest%%|*}"
            local disc_audio="${disc_rest#*|}"
            insert_text+="    #\"${rg_key}:${rg_key}:${disc_display}:filtered\"              # Discovered ${today}: ${disc_quality} + ${disc_audio}"$'\n'
          done

          # Insert before the closing )
          local tmp_file="${CONFIG_FILE}.tmp"
          {
            head -n $(( rg_close_line - 1 )) "$CONFIG_FILE"
            printf '%s' "$insert_text"
            tail -n +"$rg_close_line" "$CONFIG_FILE"
          } > "$tmp_file"
          mv "$tmp_file" "$CONFIG_FILE"

          log "${GREEN}✓ Wrote ${#discovered_groups[@]} discovered groups to config${RESET}"
        else
          log "${RED}ERROR: Could not find closing ) for RELEASE_GROUPS in config${RESET}"
        fi
      else
        log "${RED}ERROR: Could not find RELEASE_GROUPS=( in config${RESET}"
      fi
    fi
  fi

  ########################################
  # SUMMARY
  ########################################

  local end_ts
  end_ts=$(date +%s)
  local duration=$(( end_ts - start_ts ))
  local duration_formatted
  duration_formatted=$(format_duration "$duration")

  log ""
  log "${CYAN}Summary:${RESET}"
  log "Script version: v${SCRIPT_VERSION}"
  log "Runtime: ${duration_formatted}"
  log "Dry-run: ${DRY_RUN}"
  log ""

  ########################################
  # SUMMARY OUTPUT (per release group)
  ########################################

  for cfg in "${RELEASE_GROUPS[@]}"; do
    IFS=':' read -r search tag_name display_name mode <<< "$cfg"

    local pm=${stats_primary_matched["$tag_name"]:-0}
    local pt=${stats_primary_tagged["$tag_name"]:-0}
    local pe=${stats_primary_existing["$tag_name"]:-0}
    local pu=${stats_primary_untagged["$tag_name"]:-0}

    local st=${stats_secondary_tagged["$tag_name"]:-0}
    local se=${stats_secondary_existing["$tag_name"]:-0}
    local su=${stats_secondary_untagged["$tag_name"]:-0}
    local sn=${stats_secondary_not_found["$tag_name"]:-0}

    # Build sorted lists (for terminal output only)
    local tagged_list=""
    local untagged_list=""
    local notfound_list=""

    if (( pt > 0 )); then
      for ((i=1; i<=pt; i++)); do
        tagged_list+="- ${tagged_titles_array[${tag_name}_${i}]}"$'\n'
      done
      tagged_list=$(printf '%s' "$tagged_list" | sort)
    fi

    if (( pu > 0 )) || (( su > 0 )); then
      # Primary untagged
      if (( pu > 0 )); then
        for ((i=1; i<=pu; i++)); do
          local entry="${untagged_titles_array[primary_${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"
            local rest="${entry#*|}"
            local instance_part="${rest%%|*}"
            local reason_part="${rest#*|}"
            untagged_list+="- ${movie_part} → ${instance_part} → ${reason_part}"$'\n'
          fi
        done
      fi

      # Secondary untagged
      if (( su > 0 )); then
        for ((i=1; i<=su; i++)); do
          local entry="${untagged_titles_array[secondary_${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"
            local rest="${entry#*|}"
            local instance_part="${rest%%|*}"
            local reason_part="${rest#*|}"
            untagged_list+="- ${movie_part} → ${instance_part} → ${reason_part}"$'\n'
          fi
        done
      fi

      # Orphaned tags
      for key in "${!untagged_titles_array[@]}"; do
        if [[ "$key" == orphan_${tag_name}_* ]]; then
          local entry="${untagged_titles_array[$key]}"
          local movie_part="${entry%%|*}"
          local rest="${entry#*|}"
          local instance_part="${rest%%|*}"
          local reason_part="${rest#*|}"
          untagged_list+="- ${movie_part} → ${instance_part} → ${reason_part}"$'\n'
        fi
      done

      untagged_list=$(printf '%s' "$untagged_list" | sort)
    fi

    if (( sn > 0 )); then
      for ((i=1; i<=sn; i++)); do
        notfound_list+="- ${notfound_titles_array[${tag_name}_${i}]}"$'\n'
      done
      notfound_list=$(printf '%s' "$notfound_list" | sort)
    fi

    # TERMINAL OUTPUT (detailed)
    log ""
    log "${CYAN}${display_name}${RESET}"
    log "${GREEN}${PRIMARY_RADARR_NAME}:${RESET} ${pm} matched → ${pt} tagged, ${pe} existing, ${pu} untagged"

    if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
      log "${BLUE}${SECONDARY_RADARR_NAME}:${RESET} ${pm} matched → ${st} tagged, ${se} existing, ${su} untagged, ${sn} not found"
    fi

    log "Mode: ${mode}"

    # TAGGED MOVIES (terminal only)
    if [ -n "$tagged_list" ]; then
      log ""
      log "${GREEN}Tagged movies:${RESET}"
      printf '%s\n' "$tagged_list"
    fi

    # UNTAGGED MOVIES (terminal only)
    if [ -n "$untagged_list" ]; then
      log ""
      log "${YELLOW}Untagged movies:${RESET}"
      printf '%s\n' "$untagged_list"
    fi

    # NOT FOUND IN SECONDARY (terminal only)
    if [ -n "$notfound_list" ] && [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
      log ""
      log "${RED}Not found in ${SECONDARY_RADARR_NAME}:${RESET}"
      printf '%s\n' "$notfound_list"
    fi
  done

  ########################################
  # DISCOVERY SUMMARY (terminal)
  ########################################

  if [ "${ENABLE_DISCOVERY:-false}" = "true" ] && [ ${#discovered_groups[@]} -gt 0 ]; then
    log ""
    log "${MAGENTA}========================================${RESET}"
    log "${MAGENTA}DISCOVERED RELEASE GROUPS (${#discovered_groups[@]})${RESET}"
    log "${MAGENTA}========================================${RESET}"
    log ""

    for rg_key in $(printf '%s\n' "${!discovered_groups[@]}" | sort); do
      local disc_data="${discovered_groups[$rg_key]}"
      local disc_display="${disc_data%%|*}"
      local disc_rest="${disc_data#*|}"
      local disc_quality="${disc_rest%%|*}"
      local disc_audio="${disc_rest#*|}"
      log "${MAGENTA}  ${disc_display}${RESET} — ${disc_quality} + ${disc_audio}"
    done

    log ""
    if [ "$DRY_RUN" = true ]; then
      log "${YELLOW}[DRY-RUN] Discoveries NOT written to config${RESET}"
    else
      log "${GREEN}✓ All discoveries written to config (commented out for review)${RESET}"
    fi
    # Write discovery log (sorted by group, with summary)
    if [ -n "${DISCOVERY_LOG_FILE:-}" ] && [ ${#discovery_log_buffer[@]} -gt 0 ]; then
      # Rotate discovery log at 2 MiB (same threshold as main log)
      if [ -f "$DISCOVERY_LOG_FILE" ]; then
        local disc_size
        disc_size=$(stat -c%s "$DISCOVERY_LOG_FILE" 2>/dev/null || echo 0)
        if (( disc_size > 2097152 )); then
          mv "$DISCOVERY_LOG_FILE" "${DISCOVERY_LOG_FILE}.old" 2>/dev/null || true
        fi
      fi
      {
        echo ""
        echo "========================================"
        echo "Discovery Run: $(date '+%Y-%m-%d %H:%M:%S')  |  Mode: $([ "$DRY_RUN" = true ] && echo 'DRY-RUN' || echo 'LIVE')  |  Known groups: ${#known_release_groups[@]}"
        echo "========================================"
        echo ""

        # Summary
        echo "SUMMARY: ${#discovered_groups[@]} groups, ${#discovery_log_buffer[@]} movies"
        echo ""
        for grp in $(printf '%s\n' "${!discovery_log_counts[@]}" | sort); do
          printf "  %-20s %d movies\n" "$grp" "${discovery_log_counts[$grp]}"
        done
        echo ""
        echo "RlsGrp  |  Movie  |  Quality  |  Audio  |  Filename"
        echo "--------|---------|-----------|---------|----------"

        # Sort buffer by first field (group name)
        printf '%s\n' "${discovery_log_buffer[@]}" | sort
        echo ""
      } >> "$DISCOVERY_LOG_FILE"
      log "Discovery log: ${DISCOVERY_LOG_FILE}"
    fi
  elif [ "${ENABLE_DISCOVERY:-false}" = "true" ]; then
    log ""
    log "${MAGENTA}Discovery: No new release groups found${RESET}"
  fi

  ########################################
  # BUILD TOTALS (across all release groups)
  ########################################

  local total_primary_tagged=0
  local total_primary_removed=0
  local total_primary_kept=0
  local total_secondary_tagged=0
  local total_secondary_removed=0
  local total_secondary_kept=0
  local total_secondary_notfound=0

  for cfg in "${RELEASE_GROUPS[@]}"; do
    IFS=':' read -r search tag_name display_name mode <<< "$cfg"
    total_primary_tagged=$((total_primary_tagged + ${stats_primary_tagged["$tag_name"]:-0}))
    total_primary_removed=$((total_primary_removed + ${stats_primary_untagged["$tag_name"]:-0}))
    total_primary_kept=$((total_primary_kept + ${stats_primary_existing["$tag_name"]:-0}))
    total_secondary_tagged=$((total_secondary_tagged + ${stats_secondary_tagged["$tag_name"]:-0}))
    total_secondary_removed=$((total_secondary_removed + ${stats_secondary_untagged["$tag_name"]:-0}))
    total_secondary_kept=$((total_secondary_kept + ${stats_secondary_existing["$tag_name"]:-0}))
    total_secondary_notfound=$((total_secondary_notfound + ${stats_secondary_not_found["$tag_name"]:-0}))
  done

  log ""
  log "========================================"

  ########################################
  # DEBUG SUMMARY (optional — controlled by ENABLE_DEBUG in config)
  ########################################

  if [ "${ENABLE_DEBUG:-false}" = "true" ]; then

  log ""
  log "${MAGENTA}========================================${RESET}"
  log "${MAGENTA}DEBUG SUMMARY - DETAILED FILE INFORMATION${RESET}"
  log "${MAGENTA}========================================${RESET}"
  log ""

  for cfg in "${RELEASE_GROUPS[@]}"; do
    IFS=':' read -r search tag_name display_name mode <<< "$cfg"

    local pt=${stats_primary_tagged["$tag_name"]:-0}
    local pu=${stats_primary_untagged["$tag_name"]:-0}
    local su=${stats_secondary_untagged["$tag_name"]:-0}

    # Count orphans
    local orphan_count=0
    for key in "${!debug_untagged_files[@]}"; do
      if [[ "$key" == orphan_${tag_name}_* ]]; then
        orphan_count=$((orphan_count + 1))
      fi
    done

    local total_untagged=$((pu + su + orphan_count))

    if (( pt > 0 )) || (( total_untagged > 0 )); then
      log "${CYAN}═══ ${display_name} (${tag_name}) ═══${RESET}"
      log ""

      # TAGGED FILES
      if (( pt > 0 )); then
        log "${GREEN}TAGGED FILES (${pt}):${RESET}"
        log ""
        for ((i=1; i<=pt; i++)); do
          local entry="${debug_tagged_files[${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"
            local rest="${entry#*|}"
            local instance_part="${rest%%|*}"
            local debug_part="${rest#*|}"

            log "${GREEN}  ✓ ${movie_part} (${instance_part})${RESET}"
            echo -e "$debug_part" | while IFS= read -r line; do
              log "    $line"
            done
            log ""
          fi
        done
      fi

      # UNTAGGED FILES
      if (( total_untagged > 0 )); then
        log "${YELLOW}UNTAGGED FILES (${total_untagged}):${RESET}"
        log ""

        # Primary untagged
        for ((i=1; i<=pu; i++)); do
          local entry="${debug_untagged_files[primary_${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"
            local rest="${entry#*|}"
            local instance_part="${rest%%|*}"
            local debug_part="${rest#*|}"

            log "${YELLOW}  ✗ ${movie_part} (${instance_part})${RESET}"
            echo -e "$debug_part" | while IFS= read -r line; do
              log "    $line"
            done
            log ""
          fi
        done

        # Secondary untagged
        for ((i=1; i<=su; i++)); do
          local entry="${debug_untagged_files[secondary_${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"
            local rest="${entry#*|}"
            local instance_part="${rest%%|*}"
            local debug_part="${rest#*|}"

            log "${YELLOW}  ✗ ${movie_part} (${instance_part})${RESET}"
            echo -e "$debug_part" | while IFS= read -r line; do
              log "    $line"
            done
            log ""
          fi
        done

        # Orphans
        for key in "${!debug_untagged_files[@]}"; do
          if [[ "$key" == orphan_${tag_name}_* ]]; then
            local entry="${debug_untagged_files[$key]}"
            local movie_part="${entry%%|*}"
            local rest="${entry#*|}"
            local instance_part="${rest%%|*}"
            local debug_part="${rest#*|}"

            log "${YELLOW}  ✗ ${movie_part} (${instance_part}) [ORPHAN]${RESET}"
            echo -e "$debug_part" | while IFS= read -r line; do
              log "    $line"
            done
            log ""
          fi
        done
      fi

      log ""
    fi
  done

  log "${MAGENTA}========================================${RESET}"
  log "${MAGENTA}END DEBUG SUMMARY${RESET}"
  log "${MAGENTA}========================================${RESET}"

  fi  # ENABLE_DEBUG

  ########################################
  # DISCORD NOTIFICATIONS
  ########################################

  if [ "$DISCORD_ENABLED" = "true" ]; then
    log ""
    log "${CYAN}========================================${RESET}"
    log "${CYAN}SENDING DISCORD NOTIFICATIONS${RESET}"
    log "${CYAN}========================================${RESET}"

    # Send summary embed
    send_discord_summary \
      "$total_primary_tagged" \
      "$total_primary_removed" \
      "$total_secondary_tagged" \
      "$total_secondary_removed" \
      "$duration_formatted" \
      "$DRY_RUN"

    # Send discovery notification (gold embed)
    if [ "${ENABLE_DISCOVERY:-false}" = "true" ] && [ ${#discovered_groups[@]} -gt 0 ]; then
      local total_disc_movies=0
      local discovery_list=""
      for grp in $(printf '%s\n' "${!discovery_log_counts[@]}" | sort); do
        local cnt="${discovery_log_counts[$grp]}"
        total_disc_movies=$((total_disc_movies + cnt))
        printf -v line "%-20s %d movies" "$grp" "$cnt"
        discovery_list+="${line}"$'\n'
      done

      local discovery_text="\`\`\`"$'\n'"${discovery_list}\`\`\`"
      if [ "$DRY_RUN" = true ]; then
        discovery_text+="_Dry-run: not written to config_"
      else
        discovery_text+="_Written to config (commented out for review)_"
      fi

      send_discord_discovery "${#discovered_groups[@]}" "$total_disc_movies" "$discovery_text"
    fi

    # Build tagged movies grouped by release group
    declare -A grouped_tagged_movies
    for cfg in "${RELEASE_GROUPS[@]}"; do
      IFS=':' read -r search tag_name display_name mode <<< "$cfg"
      local pt=${stats_primary_tagged["$tag_name"]:-0}

      if (( pt > 0 )); then
        for ((i=1; i<=pt; i++)); do
          local movie_title="${tagged_titles_array[${tag_name}_${i}]:-}"
          if [ -n "$movie_title" ]; then
            # Check if THIS SPECIFIC MOVIE was tagged in secondary
            local line="$movie_title"

            if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
              if [ "${tagged_in_secondary_array[${tag_name}_${movie_title}]:-}" = "true" ]; then
                line="${line} ✓"
              fi
            fi

            grouped_tagged_movies["$display_name"]+="${line}
"
          fi
        done
      fi
    done

    # Build untagged movies grouped by release group
    declare -A grouped_untagged_movies
    for cfg in "${RELEASE_GROUPS[@]}"; do
      IFS=':' read -r search tag_name display_name mode <<< "$cfg"
      local pu=${stats_primary_untagged["$tag_name"]:-0}
      local su=${stats_secondary_untagged["$tag_name"]:-0}

      # Build combined list with checkmark logic (same as tagged)
      # Primary untagged
      if (( pu > 0 )); then
        for ((i=1; i<=pu; i++)); do
          local entry="${untagged_titles_array[primary_${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"
            local line="$movie_part"

            # Check if THIS SPECIFIC MOVIE was also untagged in secondary
            if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
              if [ "${untagged_in_secondary_array[${tag_name}_${movie_part}]:-}" = "true" ]; then
                line="${line} ✓"
              fi
            fi

            grouped_untagged_movies["$display_name"]+="${line}
"
          fi
        done
      fi

      # Secondary-only untagged (not already added via primary)
      if (( su > 0 )); then
        for ((i=1; i<=su; i++)); do
          local entry="${untagged_titles_array[secondary_${tag_name}_${i}]:-}"
          if [ -n "$entry" ]; then
            local movie_part="${entry%%|*}"

            # Only add if NOT already in list (would have been added via primary with ✓)
            if ! echo "${grouped_untagged_movies[$display_name]}" | grep -q "^${movie_part}"; then
              grouped_untagged_movies["$display_name"]+="${movie_part}
"
            fi
          fi
        done
      fi

      # Orphans (never have checkmark - only in secondary)
      for key in "${!untagged_titles_array[@]}"; do
        if [[ "$key" == orphan_${tag_name}_* ]]; then
          local entry="${untagged_titles_array[$key]}"
          local movie_part="${entry%%|*}"
          grouped_untagged_movies["$display_name"]+="${movie_part}
"
        fi
      done
    done

    # Send tagged movies with seamless continuation
    if [ "${grouped_tagged_movies[*]+isset}" ]; then
      if [ ${#grouped_tagged_movies[@]} -gt 0 ]; then
      log "${CYAN}Sending tagged movies (seamless flow)...${RESET}"

      # All tagged movies use GREEN color
      local group_color=5763719  # Green

      local first_tagged_embed=true

      for cfg in "${RELEASE_GROUPS[@]}"; do
        IFS=':' read -r search tag_name display_name mode <<< "$cfg"

        if [ -n "${grouped_tagged_movies[$display_name]:-}" ]; then
          local movie_list="${grouped_tagged_movies[$display_name]}"

          # Split into chunks of 50 movies if needed
          local line_count=$(echo "$movie_list" | wc -l)
          local chunk_size=50
          local chunks=$(( (line_count + chunk_size - 1) / chunk_size ))


          for ((chunk=0; chunk<chunks; chunk++)); do
            local start=$((chunk * chunk_size + 1))
            local end=$(( (chunk + 1) * chunk_size ))
            local chunk_list=$(echo "$movie_list" | sed -n "${start},${end}p")

            # First chunk of THIS group gets title, rest are blank
            local embed_title=""
            local content_prefix=""

            if (( chunk == 0 )); then
              embed_title="🎬 $display_name"
              if [ "$first_tagged_embed" = true ]; then
                content_prefix="**Tagged Movies:**"
                first_tagged_embed=false
              fi
            fi

            # Wrap content in code block
            local code_block_content="\`\`\`
${chunk_list}\`\`\`"

            # Send embed
            local payload=$(jq -n \
              --arg title "$embed_title" \
              --arg content "$code_block_content" \
              --arg prefix "$content_prefix" \
              --argjson color "$group_color" \
              '{content: $prefix, embeds: [{title: $title, description: $content, color: $color}]}')

            curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
              -H "Content-Type: application/json" \
              -d "$payload" > /dev/null

            log "${GREEN}✓ Sent $display_name chunk $((chunk+1))/$chunks${RESET}"
            sleep 0.2
          done
        fi
      done
      fi  # Close grouped_tagged_movies isset check
    fi

    # Send untagged movies with seamless continuation
    if [ "${grouped_untagged_movies[*]+isset}" ]; then
      if [ ${#grouped_untagged_movies[@]} -gt 0 ]; then
      log "${CYAN}Sending untagged movies (seamless flow)...${RESET}"

      # All untagged movies use PURPLE color
      local group_color=10181046  # Purple

      local first_untagged_embed=true

      for cfg in "${RELEASE_GROUPS[@]}"; do
        IFS=':' read -r search tag_name display_name mode <<< "$cfg"

        if [ -n "${grouped_untagged_movies[$display_name]:-}" ]; then
          local movie_list="${grouped_untagged_movies[$display_name]}"

          # Split into chunks of 50 movies if needed
          local line_count=$(echo "$movie_list" | wc -l)
          local chunk_size=50
          local chunks=$(( (line_count + chunk_size - 1) / chunk_size ))


          for ((chunk=0; chunk<chunks; chunk++)); do
            local start=$((chunk * chunk_size + 1))
            local end=$(( (chunk + 1) * chunk_size ))
            local chunk_list=$(echo "$movie_list" | sed -n "${start},${end}p")

            # First chunk of THIS group gets title, rest are blank
            local embed_title=""
            local content_prefix=""

            if (( chunk == 0 )); then
              embed_title="🎬 $display_name"
              if [ "$first_untagged_embed" = true ]; then
                content_prefix="**Untagged Movies:**"
                first_untagged_embed=false
              fi
            fi

            # Wrap content in code block
            local code_block_content="\`\`\`
${chunk_list}\`\`\`"

            # Send embed
            local payload=$(jq -n \
              --arg title "$embed_title" \
              --arg content "$code_block_content" \
              --arg prefix "$content_prefix" \
              --argjson color "$group_color" \
              '{content: $prefix, embeds: [{title: $title, description: $content, color: $color}]}')

            curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
              -H "Content-Type: application/json" \
              -d "$payload" > /dev/null

            log "${GREEN}✓ Sent $display_name chunk $((chunk+1))/$chunks${RESET}"
            sleep 0.2
          done
        fi
      done
      fi  # Close grouped_untagged_movies isset check
    fi

    log ""
    log "${GREEN}✓ Discord notifications sent${RESET}"
  fi

  ########################################
  # CLEANUP UNUSED TAGS
  ########################################

  if [ "$DISCOVER_ONLY" = true ]; then
    log ""
    log "${CYAN}Discovery-only mode — skipping tag cleanup${RESET}"
  elif [ "$CLEANUP_UNUSED_TAGS" = "true" ]; then
    log ""
    log "${CYAN}========================================${RESET}"
    log "${CYAN}CLEANUP: Checking for unused tags${RESET}"
    log "${CYAN}========================================${RESET}"

    for cfg in "${RELEASE_GROUPS[@]}"; do
      IFS=':' read -r search tag_name display_name mode <<< "$cfg"

      # Check primary
      local primary_tag_id="${primary_tag_ids[$tag_name]:-}"
      if [ -n "$primary_tag_id" ] && [ "$primary_tag_id" != "999999" ]; then
        # Count movies with this tag in primary
        local count
        count=$(curl -s "${PRIMARY_RADARR_URL}/api/v3/movie?apikey=${PRIMARY_RADARR_API_KEY}" | \
          jq --argjson tid "$primary_tag_id" '(. // []) | [.[] | select((.tags // []) | index($tid) != null)] | length')

        if [ "$count" = "0" ]; then
          log "${YELLOW}Tag '$tag_name' (ID: $primary_tag_id) has 0 movies in ${PRIMARY_RADARR_NAME}${RESET}"

          if [ "$DRY_RUN" = false ]; then
            curl -s -X DELETE "${PRIMARY_RADARR_URL}/api/v3/tag/${primary_tag_id}?apikey=${PRIMARY_RADARR_API_KEY}" >/dev/null
            log "${GREEN}✓ Deleted unused tag '$tag_name' from ${PRIMARY_RADARR_NAME}${RESET}"
          else
            log "${YELLOW}[DRY-RUN] Would delete tag '$tag_name' from ${PRIMARY_RADARR_NAME}${RESET}"
          fi
        else
          log "${GREEN}Tag '$tag_name' in use: $count movies in ${PRIMARY_RADARR_NAME}${RESET}"
        fi
      fi

      # Check secondary
      if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
        local secondary_tag_id="${secondary_tag_ids[$tag_name]:-}"
        if [ -n "$secondary_tag_id" ] && [ "$secondary_tag_id" != "999999" ]; then
          local count_sec
          count_sec=$(curl -s "${SECONDARY_RADARR_URL}/api/v3/movie?apikey=${SECONDARY_RADARR_API_KEY}" | \
            jq --argjson tid "$secondary_tag_id" '(. // []) | [.[] | select((.tags // []) | index($tid) != null)] | length')

          if [ "$count_sec" = "0" ]; then
            log "${YELLOW}Tag '$tag_name' (ID: $secondary_tag_id) has 0 movies in ${SECONDARY_RADARR_NAME}${RESET}"

            if [ "$DRY_RUN" = false ]; then
              curl -s -X DELETE "${SECONDARY_RADARR_URL}/api/v3/tag/${secondary_tag_id}?apikey=${SECONDARY_RADARR_API_KEY}" >/dev/null
              log "${GREEN}✓ Deleted unused tag '$tag_name' from ${SECONDARY_RADARR_NAME}${RESET}"
            else
              log "${YELLOW}[DRY-RUN] Would delete tag '$tag_name' from ${SECONDARY_RADARR_NAME}${RESET}"
            fi
          else
            log "${GREEN}Tag '$tag_name' in use: $count_sec movies in ${SECONDARY_RADARR_NAME}${RESET}"
          fi
        fi
      fi
    done

    log ""
  fi

  log ""
  log "${GREEN}========================================${RESET}"
  log "${GREEN}Script completed in ${duration_formatted}${RESET}"
  log "${GREEN}========================================${RESET}"
}

main "$@"
