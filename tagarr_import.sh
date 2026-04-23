#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Tagarr Import — Event-Driven Radarr Tagger with Discovery
# Version: 1.6.0
#
# Radarr Connect handler that tags individual movies on import, upgrade, or
# file delete events. Tags are based on release group, quality source
# (MA/Play WEB-DL), and lossless audio codec (TrueHD, TrueHD Atmos, DTS-X,
# DTS-HD MA). Optionally syncs tags to a secondary Radarr instance.
#
# Features:
#   TAGGING    — Match movies by release group + quality + audio filters
#   SYNC       — Mirror tags to a secondary Radarr instance (optional)
#   DISCOVERY  — Auto-detect new release groups that pass all filters but
#                aren't in the config yet. Writes them as commented entries
#                for manual review and activation. (optional)
#   CLEANUP    — Remove managed tags when movie file is deleted
#   DEBUG      — Log every filter decision per event (optional)
#   SMART      — Only send Discord notifications when something happens
#                (tagged or discovered). Silent otherwise.
#
# Setup:
#   Radarr > Settings > Connect > Custom Script
#   Path: /scripts/tagarr_import.sh
#   Events: On Grab, On File Import, On File Upgrade, On Movie File Delete
#
# Based on auto_tag_import.sh v3.4.1. Configuration: tagarr_import.conf
#
# Author: prophetSe7en
#
# WARNING: Runs automatically on every import/upgrade/delete event.
# Test with a single movie before enabling as a Radarr Connect handler.
# -----------------------------------------------------------------------------

SCRIPT_VERSION="1.6.0"

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

# Constructed API URLs
PRIMARY_RADARR_API_URL="${PRIMARY_RADARR_URL}/api/v3"
SECONDARY_RADARR_API_URL="${SECONDARY_RADARR_URL}/api/v3"

########################################
# DISCOVERY SETUP
########################################

# Build set of ALL known release groups from config (active + commented)
declare -A known_release_groups
known_release_groups[_]=1; unset "known_release_groups[_]"
while IFS= read -r line; do
    if [[ "$line" =~ \"([^:\"]+):[^:\"]+:[^:\"]+:[^:\"]+\" ]]; then
        known_release_groups["${BASH_REMATCH[1],,}"]=1
    fi
done < "$CONFIG_FILE"

########################################
# EVENT VARIABLES FROM RADARR
########################################

EVENT_TYPE="${radarr_eventtype:-Test}"
MOVIE_ID="${radarr_movie_id:-0}"
MOVIE_FILE_RELATIVE="${radarr_moviefile_relativepath:-}"
MOVIE_FILE_SCENE="${radarr_moviefile_scenename:-}"
RELEASE_GROUP_FROM_FILE="${radarr_moviefile_releasegroup:-}"
DOWNLOAD_ID_FROM_EVENT="${radarr_download_id:-}"

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
# UPDATE CHECK — non-blocking, fail-safe
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

# Discord footer — includes update notice when available
DISCORD_FOOTER="Tagarr Import v${SCRIPT_VERSION} by ProphetSe7en"
[ -n "$UPDATE_AVAILABLE" ] && DISCORD_FOOTER="${DISCORD_FOOTER} • Update available (v${UPDATE_AVAILABLE})"

################################################################################
# HANDLE RADARR GRAB EVENT — qBit torrent rename to match Radarr grab title
#
# Fires when Radarr sends a release to the download client. Renames the qBit
# display name to match radarr_release_title so Radarr's import parser sees
# the full release name (with all CF-relevant tokens) and scores correctly.
# This prevents download loops where stripped torrent names cause score drops.
#
# Discord notification is only sent when meaningful tokens were recovered
# (release group, WEB-DL, IMAX, MA, TrueHD, etc.). Plain cosmetic renames
# (dots vs spaces, DD+ vs DD plus) are silent.
#
# Idempotent — skips when qBit name already equals grab title.
# Never modifies files or folders on disk.
################################################################################

if [ "$EVENT_TYPE" = "Grab" ]; then
    log "INFO" "============================================"
    log "INFO" "Tagarr Import v${SCRIPT_VERSION}"
    log "INFO" "Event: Grab"
    log "INFO" "============================================"

    # Feature toggle (default off — must be explicitly enabled in config)
    if [ "${ENABLE_GRAB_RENAME:-false}" != "true" ]; then
        log "INFO" "ENABLE_GRAB_RENAME is not true — skipping"
        exit 0
    fi

    GRAB_RG="${radarr_release_releasegroup:-}"
    GRAB_TITLE="${radarr_release_title:-}"
    GRAB_HASH="${radarr_download_id:-}"
    GRAB_CLIENT="${radarr_download_client:-}"

    if [ -z "$GRAB_RG" ] || [ -z "$GRAB_TITLE" ] || [ -z "$GRAB_HASH" ] || [ -z "$GRAB_CLIENT" ]; then
        log "WARN" "Missing required env vars (rg='$GRAB_RG' title='$GRAB_TITLE' hash='$GRAB_HASH' client='$GRAB_CLIENT') — skip"
        exit 0
    fi

    log "INFO" "Movie:   ${radarr_movie_title:-?} (${radarr_movie_year:-?})"
    log "INFO" "Release: $GRAB_TITLE"
    log "INFO" "Group:   $GRAB_RG"
    log "INFO" "Client:  $GRAB_CLIENT"
    log "INFO" "Hash:    $GRAB_HASH"

    # Map download client name to qBit URL (case-insensitive match)
    # Supports direct qBit URLs or Qui proxy URLs
    hash_lower="${GRAB_HASH,,}"

    if [ "${#QBIT_CLIENTS[@]}" -eq 0 ]; then
        log "WARN" "QBIT_CLIENTS is empty or unset — skip"
        exit 0
    fi

    qbit_url=""
    grab_client_lower="${GRAB_CLIENT,,}"
    for entry in "${QBIT_CLIENTS[@]}"; do
        client_name="${entry%%:*}"
        client_url="${entry#*:}"
        if [ "${client_name,,}" = "$grab_client_lower" ]; then
            qbit_url="$client_url"
            break
        fi
    done

    if [ -z "$qbit_url" ]; then
        if [ "${#QBIT_CLIENTS[@]}" -eq 1 ]; then
            qbit_url="${QBIT_CLIENTS[0]#*:}"
            log "INFO" "Client '$GRAB_CLIENT' not in QBIT_CLIENTS but only one entry configured — using ${qbit_url}"
        else
            log "WARN" "Download client '$GRAB_CLIENT' not in QBIT_CLIENTS map (${#QBIT_CLIENTS[@]} entries) — skip"
            exit 0
        fi
    fi

    log "INFO" "qBit URL: $qbit_url"

    # Fetch current torrent info from qBit (case-insensitive hash)
    qbit_info=$(curl -sS --max-time 10 "${qbit_url}/api/v2/torrents/info?hashes=${hash_lower}" 2>/dev/null)

    if [ -z "$qbit_info" ] || [ "$qbit_info" = "[]" ]; then
        log "WARN" "Torrent $hash_lower not found in qBit (yet?) — skip"
        exit 0
    fi

    current_name=$(echo "$qbit_info" | jq -r '.[0].name // ""' 2>/dev/null)
    if [ -z "$current_name" ]; then
        log "WARN" "Could not parse qBit torrent name — skip"
        exit 0
    fi

    log "INFO" "Current torrent name: $current_name"

    # Idempotent: if name is already exactly the grab title, skip
    if [ "$current_name" = "$GRAB_TITLE" ]; then
        log "INFO" "Torrent name already equals grab title — no rename needed"
        exit 0
    fi

    # Scene detection — uses the same logic as TRaSH Scene CF:
    # 1) Resolution + WEB (not followed by DL) = scene naming pattern
    # 2) Known scene release groups from TRaSH Scene CF
    # Source: docs/json/radarr/cf/scene.json in TRaSH-Guides repo
    _is_scene() {
        local name="$1"
        # Pattern 1: has resolution + WEB without DL (scene naming)
        if echo "$name" | grep -Eqi '\b[0-9]{3,4}p\b' && \
           echo "$name" | grep -Eqi '(^|[_. ])WEB([_. ]|$)' && \
           ! echo "$name" | grep -Eqi 'WEB[-.]?DL'; then
            return 0
        fi
        # Pattern 2: known scene groups (from TRaSH Scene CF)
        # NOTE: `--` is required — the pattern starts with `-` which grep
        # otherwise parses as a short option, printing "invalid option -- '('"
        # and silently failing the match.
        if echo "$name" | grep -Eqi -- '-(CAKES|GGEZ|GGWP|GLHF|GOSSIP|NAISU|KOGI|PECULATE|SLOT|EDITH|ETHEL|ELEANOR|B2B|SPAMnEGGS|FTP|DiRT|SYNCOPY|BAE|SuccessfulCrab|NHTFS|SURCODE|B0MBARDIERS|D3US|BROTHERHOOD|W4K|STRiKES)\b'; then
            return 0
        fi
        return 1
    }

    is_scene_before=false
    is_scene_after=false
    _is_scene "$current_name" && is_scene_before=true
    _is_scene "$GRAB_TITLE" && is_scene_after=true

    if [ "$is_scene_before" = "true" ]; then
        log "INFO" "Scene release detected (original torrent name matches Scene CF pattern)"
        if [ "${GRAB_RENAME_EXCLUDE_SCENE:-false}" = "true" ]; then
            log "INFO" "GRAB_RENAME_EXCLUDE_SCENE is true — skipping rename for scene release"
            exit 0
        fi
    fi

    # Track whether rename changes Scene CF matching (scene before but not after)
    scene_cf_changed=false
    if [ "$is_scene_before" = "true" ] && [ "$is_scene_after" = "false" ]; then
        scene_cf_changed=true
        log "INFO" "Rename will change Scene CF matching: scene → non-scene"
    fi

    # Compute diff: which tokens are present in grab title but absent in qBit name.
    # Used for both log output and Discord notification.
    # Helper: returns true if grab has the pattern but qBit name does not.
    _added() {
        local regex="$1"
        ! echo "$current_name" | grep -Eqi "$regex" && \
          echo "$GRAB_TITLE"  | grep -Eqi "$regex"
    }

    diff_tokens=()

    # Release group suffix — flexible match: -GROUP, - GROUP, -GROUP), etc.
    # Escape group name for regex (groups are typically alphanumeric, but be safe)
    _grab_rg_esc=$(printf '%s' "$GRAB_RG" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    if ! echo "$current_name" | grep -Eqi "[-][ ]?${_grab_rg_esc}([^a-zA-Z0-9]|$)"; then
        diff_tokens+=("-${GRAB_RG} (release group)")
    fi

    # Token detection — check which title-only tokens are in the grab title
    # but missing from the qBit torrent name. Only these trigger Discord
    # notification and justify the rename.
    #
    # Design principle: only tokens that Radarr CANNOT reconstruct from
    # the file itself belong here. MediaInfo-derived CFs (HDR10/HDR10+/
    # DV/HLG, audio codecs/channels, resolution, video codec) are handled
    # by Radarr's own file analysis — renaming the torrent to preserve
    # those tokens is pointless because Radarr reads the file directly.
    # Only title-only tokens (release group stripped to digits, source
    # flavor like MA/Play WEB-DL, Movie Version tokens like Director's
    # Cut / IMAX / Remaster) are worth chasing via rename. Source
    # patterns mirror check_quality_match below (~lines 525-560). Audio
    # patterns are intentionally NOT mirrored — check_audio_match still
    # scans the filename for TrueHD/Atmos/DTS-X/DTS-HD MA, but forcing
    # a rename to recover those tokens would be cosmetic only.
    ma_or_play_added=false
    _added '\bma(\]?\s*\[?|[._-])web([-.]?dl)?'   && { diff_tokens+=("MA WEB-DL"); ma_or_play_added=true; }
    _added '\bplay(\]?\s*\[?|[._-])web([-.]?dl)?' && { diff_tokens+=("Play WEB-DL"); ma_or_play_added=true; }
    # Standalone WEB-DL only when MA/Play didn't already cover it
    [ "$ma_or_play_added" = "false" ] && _added '\bweb[-.]?dl\b' && diff_tokens+=("WEB-DL")

    # Optional Movie Versions — TRaSH CF group `f4f1474b963b24cf983455743aa9906c`.
    # All title-only tokens that Radarr can't reconstruct from MediaInfo.
    # One regex per "concept": `imax` matches both IMAX and IMAX Enhanced,
    # `remaster(ed)?` matches Remaster / Remastered / 4K Remaster, etc.
    # We lose the exact CF name in the Discord label but keep the rename
    # trigger correct — Radarr re-scores the renamed title anyway.
    [ "${GRAB_RENAME_MOVIE_VERSION:-true}" = "true" ] && {
        _added "\bdirector('?s)?[._ -]?cut\b"            && diff_tokens+=("Director's Cut")
        _added '\btheatrical\b'                          && diff_tokens+=("Theatrical")
        _added '\bextended\b'                            && diff_tokens+=("Extended")
        _added '\bunrated\b'                             && diff_tokens+=("Unrated")
        _added '\buncut\b'                               && diff_tokens+=("Uncut")
        _added '\bremaster(ed)?\b'                       && diff_tokens+=("Remaster")
        _added '\bcriterion\b'                           && diff_tokens+=("Criterion")
        _added '\b(masters[._ -]?of[._ -]?cinema|moc)\b' && diff_tokens+=("Masters of Cinema")
        _added '\bvinegar[._ -]?syndrome\b'              && diff_tokens+=("Vinegar Syndrome")
        _added '\bhybrid\b'                              && diff_tokens+=("Hybrid")
        _added '\bimax\b'                                && diff_tokens+=("IMAX")
        _added '\bopen[ ._-]?matte\b'                    && diff_tokens+=("Open Matte")
    }

    # User-defined tokens — format per entry: "label:regex". Bash regex,
    # no lookaheads. Same semantics as the built-ins above: added to
    # diff_tokens when grab title matches but torrent name doesn't.
    for _cf_entry in "${GRAB_RENAME_CUSTOM_TOKENS[@]}"; do
        _cf_label="${_cf_entry%%:*}"
        _cf_regex="${_cf_entry#*:}"
        [ -z "$_cf_label" ] || [ -z "$_cf_regex" ] && continue
        _added "$_cf_regex" && diff_tokens+=("$_cf_label")
    done

    # Build comma-space-separated summary string for the "Tokens added" field
    if [ "${#diff_tokens[@]}" -gt 0 ]; then
        printf -v diff_summary '%s, ' "${diff_tokens[@]}"
        diff_summary="${diff_summary%, }"
        log "INFO" "Tokens added by rename: $diff_summary"
    else
        # No meaningful tokens to recover — skip rename entirely.
        # Cosmetic differences (dots vs spaces, reordering) don't affect
        # Radarr's import scoring and renaming can interfere with queue tracking.
        log "INFO" "No meaningful tokens to recover — skipping rename (cosmetic only)"
        exit 0
    fi

    # Build natural-language description for Discord (separate from token list)
    group_recovered=false
    other_tokens=()
    for t in "${diff_tokens[@]}"; do
        if [[ "$t" == *"(release group)"* ]]; then
            group_recovered=true
        else
            other_tokens+=("$t")
        fi
    done

    if [ "${#other_tokens[@]}" -gt 0 ]; then
        printf -v others_str '**%s**, ' "${other_tokens[@]}"
        others_str="${others_str%, }"
    else
        others_str=""
    fi

    if [ "$group_recovered" = "true" ] && [ -n "$others_str" ]; then
        summary_text="Recovered release group **${GRAB_RG}** and added ${others_str}"
    elif [ "$group_recovered" = "true" ]; then
        summary_text="Recovered release group **${GRAB_RG}**"
    elif [ -n "$others_str" ]; then
        summary_text="Added ${others_str}"
    else
        summary_text="Cosmetic rename — no scoring impact tracked"
    fi

    # Execute rename
    log "INFO" "Renaming qBit torrent to: $GRAB_TITLE"
    rename_response=$(curl -sS --max-time 10 -w "\nHTTP_CODE:%{http_code}" \
        -X POST "${qbit_url}/api/v2/torrents/rename" \
        --data-urlencode "hash=${hash_lower}" \
        --data-urlencode "name=${GRAB_TITLE}" 2>/dev/null)

    rename_http=$(echo "$rename_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

    if [ "$rename_http" = "200" ]; then
        log "INFO" "Rename successful (HTTP 200)"
    else
        log "WARN" "Rename failed (HTTP $rename_http)"
        exit 0
    fi

    # Discord notification — only when meaningful tokens were recovered or
    # Scene CF matching was changed by the rename. Plain cosmetic renames are silent.
    if [ "${DISCORD_ENABLED:-false}" = "true" ] && [ -n "${DISCORD_WEBHOOK_URL:-}" ] && \
       { [ "${#diff_tokens[@]}" -gt 0 ] || [ "$scene_cf_changed" = "true" ]; }; then
        # Fetch movie details for poster (Grab handler exits before main flow runs)
        grab_poster_url=""
        grab_movie_id="${radarr_movie_id:-}"
        if [ -n "$grab_movie_id" ] && [ -n "${PRIMARY_RADARR_API_URL:-}" ] && [ -n "${PRIMARY_RADARR_API_KEY:-}" ]; then
            grab_movie_json=$(curl -sS --max-time 5 "${PRIMARY_RADARR_API_URL}/movie/${grab_movie_id}?apikey=${PRIMARY_RADARR_API_KEY}" 2>/dev/null)
            if [ -n "$grab_movie_json" ] && [ "$grab_movie_json" != "null" ]; then
                grab_poster_url=$(echo "$grab_movie_json" | jq -r '.remotePoster // ""' 2>/dev/null)
                if [ -z "$grab_poster_url" ] || [ "$grab_poster_url" = "null" ]; then
                    grab_poster_url=$(echo "$grab_movie_json" | jq -r '.images[]? | select(.coverType == "poster") | .remoteUrl // .url // empty' 2>/dev/null | head -1)
                fi
            fi
        fi
        [ "$grab_poster_url" = "null" ] && grab_poster_url=""

        # All non-group tokens go in one "Tokens Recovered" field.
        # Source tokens (MA/Play WEB-DL), Movie Version tokens (Director's
        # Cut / IMAX / Remaster / ...), and user-defined custom tokens
        # share the same field — the CF-type distinction matters to Radarr's
        # scoring, not to the human reading the Discord card.
        tokens_recovered=""
        if [ "${#other_tokens[@]}" -gt 0 ]; then
            printf -v tokens_recovered '%s, ' "${other_tokens[@]}"
            tokens_recovered="${tokens_recovered%, }"
        fi

        notif_title="Renamed - ${radarr_movie_title:-Unknown} (${radarr_movie_year:-?})"

        # Always orange — matches Radarr's existing Tagged notifications
        notif_color=16753920  # Orange (0xFFA500)

        # Build fields dynamically — only include what was actually recovered
        fields_json='[]'

        fields_json=$(echo "$fields_json" | jq \
            --arg val "$GRAB_CLIENT" \
            '. += [{ name: "Renamed in", value: $val, inline: false }]')

        if [ "$group_recovered" = "true" ]; then
            fields_json=$(echo "$fields_json" | jq \
                --arg val "$GRAB_RG" \
                '. += [{ name: "Release Group Recovered", value: $val, inline: true }]')
        fi

        if [ -n "$tokens_recovered" ]; then
            fields_json=$(echo "$fields_json" | jq \
                --arg val "$tokens_recovered" \
                '. += [{ name: "Tokens Recovered", value: $val, inline: true }]')
        fi

        if [ "$scene_cf_changed" = "true" ]; then
            fields_json=$(echo "$fields_json" | jq \
                '. += [{ name: "⚠️ Scene CF", value: "No longer matches after rename", inline: true }]')
        fi

        fields_json=$(echo "$fields_json" | jq \
            --arg event "Grab" \
            --arg old "$current_name" \
            --arg new "$GRAB_TITLE" \
            '. += [
                { name: "Event", value: $event, inline: true },
                { name: "Torrent Name", value: $old, inline: false },
                { name: "Restored to Release Name", value: $new, inline: false }
            ]')

        payload=$(jq -n \
            --arg title "$notif_title" \
            --argjson color "$notif_color" \
            --arg poster_url "$grab_poster_url" \
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
        response=$(curl -sS -w "\nHTTP_CODE:%{http_code}" --max-time 10 \
            -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        http_code=$(echo "$response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)
        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
            log "INFO" "Discord notification sent successfully"
        else
            log "WARN" "Discord notification failed (HTTP $http_code)"
        fi
    fi

    log "INFO" "Grab handler complete"
    exit 0
fi

################################################################################
# HANDLE RADARR TEST EVENT (early exit — no API calls needed)
################################################################################

if [ "$EVENT_TYPE" = "Test" ]; then
    log "INFO" "============================================"
    log "INFO" "Tagarr Import v${SCRIPT_VERSION}"
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
                    title: "Tagarr Import v'"${SCRIPT_VERSION}"' — Test OK",
                    color: $color,
                    fields: [
                        { name: "Status", value: "Connection successful", inline: true },
                        { name: "Discovery", value: "'"${ENABLE_DISCOVERY:-false}"'", inline: true }
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
# HANDLE MOVIE FILE DELETE EVENT
################################################################################

if [ "$EVENT_TYPE" = "MovieFileDelete" ] || [ "$EVENT_TYPE" = "MovieFileDeleteForUpgrade" ]; then
    log "INFO" "============================================"
    log "INFO" "Tagarr Import v${SCRIPT_VERSION}"
    log "INFO" "Event: $EVENT_TYPE"
    log "INFO" "============================================"

    log "INFO" "Movie file deleted - removing all managed tags"

    # Get movie details
    movie_json=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")

    if [ -z "$movie_json" ]; then
        log "ERROR" "Failed to fetch movie details from Radarr"
        exit 1
    fi

    MOVIE_TITLE=$(echo "$movie_json" | jq -r '.title')
    MOVIE_YEAR=$(echo "$movie_json" | jq -r '.year')
    MOVIE_TMDB_ID=$(echo "$movie_json" | jq -r '.tmdbId')
    MOVIE_CURRENT_TAGS=$(echo "$movie_json" | jq -r '(.tags // [])')

    log "INFO" "Movie: $MOVIE_TITLE ($MOVIE_YEAR)"

    # Get all managed tag IDs
    declare -a managed_tag_ids=()

    for tag_config in "${RELEASE_GROUPS[@]}"; do
        TAG_NAME=$(echo "$tag_config" | cut -d: -f2)

        # Get tag ID in primary
        primary_tag_id=$(curl -s "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" | \
            jq -r "(.// []) | .[] | select(.label == \"${TAG_NAME}\") | .id")

        if [ -n "$primary_tag_id" ]; then
            managed_tag_ids+=("$primary_tag_id")
        fi
    done

    # Check if movie has any managed tags
    has_managed_tags=false
    for tag_id in "${managed_tag_ids[@]}"; do
        if echo "$MOVIE_CURRENT_TAGS" | jq -e "(. // []) | contains([${tag_id}])" > /dev/null 2>&1; then
            has_managed_tags=true
            break
        fi
    done

    if [ "$has_managed_tags" = "false" ]; then
        log "INFO" "Movie has no managed tags - nothing to remove"
    else
        log "INFO" "Removing managed tags from movie..."

        # Get fresh movie object
        movie_full=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")
        current_tags=$(echo "$movie_full" | jq -r '(.tags // [])')

        # Remove all managed tags
        for tag_id in "${managed_tag_ids[@]}"; do
            current_tags=$(echo "$current_tags" | jq "(. // []) | del(.[] | select(. == ${tag_id}))")
        done

        # Update movie
        updated_movie=$(echo "$movie_full" | jq ".tags = ${current_tags}")

        curl -s -X PUT "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$updated_movie" > /dev/null

        log "INFO" "Tags removed from primary Radarr"

        # Sync to secondary if enabled
        if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
            log "INFO" "Syncing tag removal to $SECONDARY_RADARR_NAME..."

            # Find movie in secondary
            secondary_movie=$(curl -s "${SECONDARY_RADARR_API_URL}/movie?apikey=${SECONDARY_RADARR_API_KEY}" | \
                jq -c "(. // []) | .[] | select(.tmdbId == ${MOVIE_TMDB_ID})")

            if [ -n "$secondary_movie" ]; then
                secondary_movie_id=$(echo "$secondary_movie" | jq -r '.id')
                secondary_current_tags=$(echo "$secondary_movie" | jq -r '(.tags // [])')

                log "INFO" "Found movie in $SECONDARY_RADARR_NAME (ID: $secondary_movie_id)"

                # Get managed tag IDs in secondary
                for tag_config in "${RELEASE_GROUPS[@]}"; do
                    TAG_NAME=$(echo "$tag_config" | cut -d: -f2)

                    secondary_tag_id=$(curl -s "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" | \
                        jq -r "(. // []) | .[] | select(.label == \"${TAG_NAME}\") | .id")

                    if [ -n "$secondary_tag_id" ]; then
                        secondary_current_tags=$(echo "$secondary_current_tags" | jq "del(.[] | select(. == ${secondary_tag_id}))")
                    fi
                done

                # Update secondary movie
                secondary_movie_full=$(curl -s "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}")
                updated_secondary=$(echo "$secondary_movie_full" | jq ".tags = ${secondary_current_tags}")

                curl -s -X PUT "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "$updated_secondary" > /dev/null

                log "INFO" "Tags removed from $SECONDARY_RADARR_NAME"
            else
                log "INFO" "Movie not found in $SECONDARY_RADARR_NAME"
            fi
        fi
    fi

    log "INFO" "============================================"
    log "INFO" "File delete cleanup completed"
    log "INFO" "============================================"

    exit 0
fi

################################################################################
# QUALITY/AUDIO FILTER FUNCTIONS
################################################################################

# Check if filename matches quality filters
# EXACT COPY FROM tagarr.sh v1.0.0
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

# Check if filename matches audio filters
# EXACT COPY FROM tagarr.sh v1.0.0
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

################################################################################
# RELEASE GROUP RECOVERY VIA DOWNLOAD ID
################################################################################

# Result variable — set by fix_release_group_from_history() on success.
# Using a global avoids the log-via-tee stdout contamination that would
# occur if we returned the value via echo inside a $() capture.
_RECOVER_RESULT=""

fix_release_group_from_history() {
    local movie_id="$1"
    local movie_title="$2"
    local movie_year="$3"
    local current_rg="$4"
    local moviefile_id="$5"
    local download_id="$6"

    _RECOVER_RESULT=""

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

    # Query history for this movie
    local history_json
    history_json=$(curl -s -f "${PRIMARY_RADARR_API_URL}/history/movie?movieId=${movie_id}&apikey=${PRIMARY_RADARR_API_KEY}") || history_json=""

    if [ -z "$history_json" ] || [ "$history_json" = "null" ] || [ "$history_json" = "[]" ] || \
       ! echo "$history_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
        log "INFO" "No history found for movie"
        return 1
    fi

    # Find grab with matching downloadId — exact match, no walking/guessing
    local grab_rg
    grab_rg=$(echo "$history_json" | jq -r --arg dlid "$download_id" '
        [.[] | select(.eventType == "grabbed" and .downloadId == $dlid)] |
        .[0].data.releaseGroup // ""
    ') || grab_rg=""

    if [ -z "$grab_rg" ]; then
        log "INFO" "No grab found with downloadId $download_id"
        return 1
    fi

    log "INFO" "Found releaseGroup '$grab_rg' from grab with downloadId $download_id"

    if [ -z "$moviefile_id" ] || [ "$moviefile_id" = "null" ]; then
        log "WARN" "Cannot determine movieFile ID — skipping fix"
        return 1
    fi

    # Fetch full moviefile object for PUT
    local moviefile_json
    moviefile_json=$(curl -s -f "${PRIMARY_RADARR_API_URL}/moviefile/${moviefile_id}?apikey=${PRIMARY_RADARR_API_KEY}") || moviefile_json=""

    if [ -z "$moviefile_json" ] || [ "$moviefile_json" = "null" ]; then
        log "WARN" "Failed to fetch moviefile object — skipping fix"
        return 1
    fi

    # Patch releaseGroup and PUT
    local updated_moviefile
    updated_moviefile=$(echo "$moviefile_json" | jq --arg rg "$grab_rg" '.releaseGroup = $rg')

    local put_response put_http_code
    put_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
        "${PRIMARY_RADARR_API_URL}/moviefile/${moviefile_id}?apikey=${PRIMARY_RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$updated_moviefile")
    put_http_code=$(echo "$put_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

    if [ "$put_http_code" != "200" ] && [ "$put_http_code" != "202" ]; then
        log "WARN" "Failed to update moviefile releaseGroup (HTTP $put_http_code)"
        return 1
    fi

    log "INFO" "Fixed releaseGroup: '$grab_rg' applied to moviefile $moviefile_id"

    # Trigger rename so the file reflects the corrected releaseGroup
    local rename_response rename_http_code
    rename_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        "${PRIMARY_RADARR_API_URL}/command?apikey=${PRIMARY_RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"RenameFiles\",\"movieId\":${movie_id},\"files\":[${moviefile_id}]}")
    rename_http_code=$(echo "$rename_response" | grep "HTTP_CODE:" | tail -1 | cut -d: -f2)

    if [ "$rename_http_code" = "200" ] || [ "$rename_http_code" = "201" ]; then
        log "INFO" "Rename command triggered for movie $movie_id"
    else
        log "WARN" "Rename command failed (HTTP $rename_http_code) — file may need manual rename"
    fi

    _RECOVER_RESULT="$grab_rg"
    return 0
}

################################################################################
# MAIN SCRIPT
################################################################################

log "INFO" "============================================"
log "INFO" "Tagarr Import v${SCRIPT_VERSION}"
log "INFO" "Event: $EVENT_TYPE"
log "INFO" "============================================"

# Get movie details from primary Radarr
log "INFO" "Fetching movie details (ID: $MOVIE_ID)..."
movie_json=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")

if [ -z "$movie_json" ]; then
    log "ERROR" "Failed to fetch movie details from Radarr"
    exit 1
fi

MOVIE_TITLE=$(echo "$movie_json" | jq -r '.title')
MOVIE_YEAR=$(echo "$movie_json" | jq -r '.year')
MOVIE_TMDB_ID=$(echo "$movie_json" | jq -r '.tmdbId')
MOVIE_CURRENT_TAGS=$(echo "$movie_json" | jq -r '(.tags // [])')

# Get poster URL (try multiple sources)
MOVIE_POSTER_URL=""
# Try remotePoster first
remote_poster=$(echo "$movie_json" | jq -r '.remotePoster // ""')
if [ -n "$remote_poster" ] && [ "$remote_poster" != "null" ] && [ "$remote_poster" != "" ]; then
    MOVIE_POSTER_URL="$remote_poster"
    log "INFO" "Poster URL from remotePoster: $MOVIE_POSTER_URL"
else
    # Try images array for poster
    poster_from_images=$(echo "$movie_json" | jq -r '.images[] | select(.coverType == "poster") | .remoteUrl // .url // "" | select(length > 0)' | head -1)
    if [ -n "$poster_from_images" ] && [ "$poster_from_images" != "null" ]; then
        MOVIE_POSTER_URL="$poster_from_images"
        log "INFO" "Poster URL from images array: $MOVIE_POSTER_URL"
    fi
fi

# Fallback to TMDb poster if still empty
if [ -z "$MOVIE_POSTER_URL" ] || [ "$MOVIE_POSTER_URL" = "null" ]; then
    if [ -n "$MOVIE_TMDB_ID" ] && [ "$MOVIE_TMDB_ID" != "null" ] && [ "$MOVIE_TMDB_ID" != "0" ]; then
        MOVIE_POSTER_URL="https://image.tmdb.org/t/p/w500/placeholder.jpg"
        log "INFO" "Using TMDb placeholder poster"
    else
        log "WARN" "No poster URL available"
    fi
fi

# Get file details
MOVIE_FILE_QUALITY=$(echo "$movie_json" | jq -r '.movieFile.quality.quality.name // "Unknown"')
MOVIE_FILE_SIZE_BYTES=$(echo "$movie_json" | jq -r '.movieFile.size // 0')
MOVIE_FILE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $MOVIE_FILE_SIZE_BYTES/1073741824}")
MOVIE_RELEASE_GROUP=$(echo "$movie_json" | jq -r '.movieFile.releaseGroup // "Unknown"')

log "INFO" "Movie: $MOVIE_TITLE ($MOVIE_YEAR)"
log "INFO" "File: $MOVIE_FILE_RELATIVE"

if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
    log "DEBUG" "Release group: $MOVIE_RELEASE_GROUP"
    log "DEBUG" "Quality: $MOVIE_FILE_QUALITY"
    log "DEBUG" "Size: ${MOVIE_FILE_SIZE_GB} GiB"
    log "DEBUG" "Scene: ${MOVIE_FILE_SCENE:-none}"
fi

# Get file info for matching — priority: file env var > API > downloadId recovery
RELEASE_GROUP_FIELD=$(echo "$movie_json" | jq -r '.movieFile.releaseGroup // ""')

# --- Release group from Radarr file env var (most reliable on import/upgrade) ---
if [ -n "$RELEASE_GROUP_FROM_FILE" ] && [ "$RELEASE_GROUP_FROM_FILE" != "null" ]; then
    if [ -z "$RELEASE_GROUP_FIELD" ] || [ "$RELEASE_GROUP_FIELD" = "Unknown" ] || [ "$RELEASE_GROUP_FIELD" = "null" ]; then
        log "INFO" "Using release group from file env var: '$RELEASE_GROUP_FROM_FILE' (API had: '${RELEASE_GROUP_FIELD:-empty}')"
        RELEASE_GROUP_FIELD="$RELEASE_GROUP_FROM_FILE"
        MOVIE_RELEASE_GROUP="$RELEASE_GROUP_FROM_FILE"
    fi
fi

# --- Release group recovery via downloadId (fallback for empty/Unknown) ---
if [ "${ENABLE_RECOVER:-true}" = "true" ] && \
   { [ -z "$RELEASE_GROUP_FIELD" ] || [ "$RELEASE_GROUP_FIELD" = "Unknown" ] || [ "$RELEASE_GROUP_FIELD" = "null" ]; }; then
    _moviefile_id=$(echo "$movie_json" | jq -r '.movieFile.id // ""')
    if fix_release_group_from_history "$MOVIE_ID" "$MOVIE_TITLE" "$MOVIE_YEAR" "$RELEASE_GROUP_FIELD" "$_moviefile_id" "$DOWNLOAD_ID_FROM_EVENT"; then
        RELEASE_GROUP_FIELD="$_RECOVER_RESULT"
        MOVIE_RELEASE_GROUP="$_RECOVER_RESULT"
        RECOVER_GROUP="$_RECOVER_RESULT"
        log "INFO" "Proceeding with recovered releaseGroup: $_RECOVER_RESULT"
    fi
fi
# --- End release group recovery ---

# Combine all sources for searching
COMBINED_NAME="${MOVIE_FILE_RELATIVE} ${MOVIE_FILE_SCENE}"
COMBINED_LOWER=$(echo "$COMBINED_NAME" | tr '[:upper:]' '[:lower:]')
RELEASE_GROUP_LOWER=$(echo "$RELEASE_GROUP_FIELD" | tr '[:upper:]' '[:lower:]')

log "INFO" "Checking release group matches..."

# Arrays to track what should happen
declare -a tags_to_add=()
declare -a tags_to_remove=()
declare -a tags_to_keep=()

# Check each release group
for tag_config in "${RELEASE_GROUPS[@]}"; do
    SEARCH_STRING=$(echo "$tag_config" | cut -d: -f1)
    TAG_NAME=$(echo "$tag_config" | cut -d: -f2)
    DISPLAY_NAME=$(echo "$tag_config" | cut -d: -f3)
    TAG_MODE=$(echo "$tag_config" | cut -d: -f4)

    # Defaults
    [ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$TAG_NAME"
    [ -z "$TAG_MODE" ] && TAG_MODE="simple"

    search_lower=$(echo "$SEARCH_STRING" | tr '[:upper:]' '[:lower:]')

    # Check if release group matches (3 places)
    match_found=false
    match_location=""

    if echo "$COMBINED_LOWER" | grep -q "$search_lower"; then
        match_found=true
        match_location="filename/scene"
    elif [ -n "$RELEASE_GROUP_LOWER" ] && echo "$RELEASE_GROUP_LOWER" | grep -q "$search_lower"; then
        match_found=true
        match_location="release group field"
    fi

    # Get or create tag in primary
    primary_tag_id=$(curl -s "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" | \
        jq -r "(. // []) | .[] | select(.label == \"${TAG_NAME}\") | .id")

    if [ -z "$primary_tag_id" ]; then
        log "INFO" "Creating tag '$TAG_NAME' in $PRIMARY_RADARR_NAME..."
        new_tag=$(curl -s -X POST "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"label\": \"${TAG_NAME}\"}")
        primary_tag_id=$(echo "$new_tag" | jq -r '.id')
        log "INFO" "Created tag with ID: $primary_tag_id"
    fi

    # Check if movie currently has this tag
    movie_has_tag=$(echo "$MOVIE_CURRENT_TAGS" | jq "(. // []) | contains([${primary_tag_id}])")

    # Determine if movie SHOULD have this tag
    should_have_tag=false
    reason=""

    if [ "$match_found" = "true" ]; then
        if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            log "DEBUG" "Group match: $DISPLAY_NAME via $match_location"
        fi

        if [ "$TAG_MODE" = "simple" ]; then
            should_have_tag=true
            reason="$DISPLAY_NAME (simple mode)"
        elif [ "$TAG_MODE" = "filtered" ]; then
            # Check filters
            quality_ok=false
            audio_ok=false

            if check_quality_match "$MOVIE_FILE_RELATIVE"; then
                quality_ok=true
            fi

            if check_audio_match "$MOVIE_FILE_RELATIVE"; then
                audio_ok=true
            fi

            if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
                log "DEBUG" "  Quality filter: $quality_ok | Audio filter: $audio_ok"
            fi

            if [ "$quality_ok" = "true" ] && [ "$audio_ok" = "true" ]; then
                should_have_tag=true
                reason="$DISPLAY_NAME (passed filters)"
            else
                if [ "$quality_ok" = "false" ]; then
                    reason="$DISPLAY_NAME (failed quality filter)"
                elif [ "$audio_ok" = "false" ]; then
                    reason="$DISPLAY_NAME (failed audio filter)"
                fi
            fi
        fi
    fi

    # Decide action: add, keep, or remove
    if [ "$should_have_tag" = "true" ]; then
        if [ "$movie_has_tag" = "true" ]; then
            log "INFO" "Keeping tag: $reason"
            tags_to_keep+=("$TAG_NAME:$primary_tag_id:$DISPLAY_NAME")
        else
            log "INFO" "Adding tag: $reason"
            tags_to_add+=("$TAG_NAME:$primary_tag_id:$DISPLAY_NAME")
        fi
    else
        if [ "$movie_has_tag" = "true" ]; then
            log "INFO" "Removing tag: $reason"
            tags_to_remove+=("$TAG_NAME:$primary_tag_id:$DISPLAY_NAME")
        elif [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            if [ "$match_found" = "true" ]; then
                log "DEBUG" "Skipped: $reason"
            else
                log "DEBUG" "No match for $DISPLAY_NAME"
            fi
        fi
    fi
done

################################################################################
# DISCOVERY CHECK
################################################################################

discovered=false
discovered_group=""
discovered_quality=""
discovered_audio=""

if [ "${ENABLE_DISCOVERY:-false}" = "true" ] && [ -n "$RELEASE_GROUP_FIELD" ] && [ "$RELEASE_GROUP_FIELD" != "Unknown" ]; then
    rg_lower="${RELEASE_GROUP_FIELD,,}"

    # Skip if already known (active or commented in config)
    if [ -z "${known_release_groups[$rg_lower]:-}" ]; then
        if [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            log "DEBUG" "Discovery: unknown group '$RELEASE_GROUP_FIELD' — checking filters"
        fi
        # Run quality + audio filters on the filename
        if check_quality_match "$MOVIE_FILE_RELATIVE" && check_audio_match "$MOVIE_FILE_RELATIVE"; then
            discovered=true
            discovered_group="$RELEASE_GROUP_FIELD"

            # Detect quality detail
            if echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bma(\]?\s*\[?|[._-])web'; then
                discovered_quality="MA WEB-DL"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bplay(\]?\s*\[?|[._-])web'; then
                discovered_quality="Play WEB-DL"
            else
                discovered_quality="Unknown WEB-DL"
            fi

            # Detect audio detail
            if echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\btruehd\b.*\batmos\b|\batmos\b.*\btruehd\b'; then
                discovered_audio="TrueHD Atmos"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bdts[._-]?x\b'; then
                discovered_audio="DTS-X"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\btruehd\b'; then
                discovered_audio="TrueHD"
            elif echo "$MOVIE_FILE_RELATIVE" | grep -Eqi '\bdts[._ -]?hd[._ -]?ma\b'; then
                discovered_audio="DTS-HD.MA"
            else
                discovered_audio="Lossless audio"
            fi

            log "INFO" "DISCOVERED: $discovered_group ($discovered_quality + $discovered_audio)"

            # Write entry to config file (commented or active based on AUTO_TAG_DISCOVERED)
            today=$(date '+%Y-%m-%d')
            rg_key="${rg_lower}"
            if [ "${AUTO_TAG_DISCOVERED:-false}" = "true" ]; then
                insert_line="    \"${rg_key}:${rg_key}:${discovered_group}:filtered\"              # Discovered ${today}: ${discovered_quality} + ${discovered_audio}"
            else
                insert_line="    #\"${rg_key}:${rg_key}:${discovered_group}:filtered\"              # Discovered ${today}: ${discovered_quality} + ${discovered_audio}"
            fi

            # Find the closing ) of RELEASE_GROUPS array (locked to prevent concurrent write corruption).
            # Use -n (non-blocking) — BusyBox flock inside the Radarr container
            # does not support -w (timeout). If the lock is held, skip this
            # discovery write; the next Grab with the same group will retry.
            (
                flock -n 200 || { echo "LOCK_FAIL"; exit 1; }

                rg_start_line=$(grep -n 'RELEASE_GROUPS=(' "$CONFIG_FILE" | head -n1 | cut -d: -f1)

                if [ -n "$rg_start_line" ]; then
                    rg_close_line=$(tail -n +"$rg_start_line" "$CONFIG_FILE" | grep -n '^)' | head -n1 | cut -d: -f1)

                    if [ -n "$rg_close_line" ]; then
                        rg_close_line=$(( rg_start_line + rg_close_line - 1 ))
                        tmp_file="${CONFIG_FILE}.tmp"
                        {
                            head -n $(( rg_close_line - 1 )) "$CONFIG_FILE"
                            echo "$insert_line"
                            tail -n +"$rg_close_line" "$CONFIG_FILE"
                        } > "$tmp_file"
                        mv "$tmp_file" "$CONFIG_FILE"
                    fi
                fi
            ) 200>"${CONFIG_FILE}.lock"

            if grep -q "$rg_key" "$CONFIG_FILE" 2>/dev/null; then
                log "INFO" "Written discovered group to config: $discovered_group"

                # Auto-tag: immediately tag the current movie with the discovered group
                if [ "${AUTO_TAG_DISCOVERED:-false}" = "true" ]; then
                    log "INFO" "Auto-tagging: creating and applying tag '$rg_key'"
                    auto_tag_id=$(curl -s "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" | \
                        jq -r "(. // []) | .[] | select(.label == \"${rg_key}\") | .id")
                    if [ -z "$auto_tag_id" ]; then
                        auto_tag_id=$(curl -s -X POST "${PRIMARY_RADARR_API_URL}/tag?apikey=${PRIMARY_RADARR_API_KEY}" \
                            -H "Content-Type: application/json" \
                            -d "{\"label\": \"${rg_key}\"}" | jq -r '.id')
                    fi
                    if [ -n "$auto_tag_id" ] && [ "$auto_tag_id" != "null" ]; then
                        tags_to_add+=("${rg_key}:${auto_tag_id}:${discovered_group}")
                        log "INFO" "Auto-tag queued: $discovered_group (ID: $auto_tag_id)"
                    else
                        log "WARN" "Auto-tag failed: could not create tag '$rg_key'"
                    fi
                fi
            else
                log "WARN" "Failed to write discovered group to config"
            fi
        elif [ "${ENABLE_DEBUG:-false}" = "true" ]; then
            log "DEBUG" "Discovery: '$RELEASE_GROUP_FIELD' failed filters — not discovered"
        fi
    elif [ "${ENABLE_DEBUG:-false}" = "true" ]; then
        log "DEBUG" "Discovery: '$RELEASE_GROUP_FIELD' already known — skipped"
    fi
fi

################################################################################
# APPLY TAG CHANGES IN PRIMARY
################################################################################

if [ ${#tags_to_add[@]} -gt 0 ]; then
    log "INFO" "Applying ${#tags_to_add[@]} new tags to movie..."

    # Get fresh movie object
    movie_full=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")
    current_tags=$(echo "$movie_full" | jq -r '(.tags // [])')

    for tag_info in "${tags_to_add[@]}"; do
        tag_id=$(echo "$tag_info" | cut -d: -f2)
        current_tags=$(echo "$current_tags" | jq "(. // []) + [${tag_id}] | unique")
    done

    # Update movie with new tags
    updated_movie=$(echo "$movie_full" | jq ".tags = ${current_tags}")

    curl -s -X PUT "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$updated_movie" > /dev/null

    log "INFO" "Tags added successfully"
fi

if [ ${#tags_to_remove[@]} -gt 0 ]; then
    log "INFO" "Removing ${#tags_to_remove[@]} outdated tags from movie..."

    # Get fresh movie object
    movie_full=$(curl -s "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}")
    current_tags=$(echo "$movie_full" | jq -r '(.tags // [])')

    for tag_info in "${tags_to_remove[@]}"; do
        tag_id=$(echo "$tag_info" | cut -d: -f2)
        current_tags=$(echo "$current_tags" | jq "(. // []) | del(.[] | select(. == ${tag_id}))")
    done

    # Update movie with cleaned tags
    updated_movie=$(echo "$movie_full" | jq ".tags = ${current_tags}")

    curl -s -X PUT "${PRIMARY_RADARR_API_URL}/movie/${MOVIE_ID}?apikey=${PRIMARY_RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$updated_movie" > /dev/null

    log "INFO" "Tags removed successfully"
fi

################################################################################
# SYNC TO SECONDARY
################################################################################

SECONDARY_STATUS="disabled"
if [ "$ENABLE_SYNC_TO_SECONDARY" = "true" ]; then
    log "INFO" "Syncing tags to $SECONDARY_RADARR_NAME..."

    # Find movie in secondary by TMDb ID
    secondary_movie=$(curl -s "${SECONDARY_RADARR_API_URL}/movie?apikey=${SECONDARY_RADARR_API_KEY}" | \
        jq -c "(. // []) | .[] | select(.tmdbId == ${MOVIE_TMDB_ID})")

    if [ -n "$secondary_movie" ]; then
        secondary_movie_id=$(echo "$secondary_movie" | jq -r '.id')
        secondary_current_tags=$(echo "$secondary_movie" | jq -r '(.tags // [])')

        log "INFO" "Found movie in $SECONDARY_RADARR_NAME (ID: $secondary_movie_id)"

        # Process each tag for secondary
        for tag_info in "${tags_to_add[@]}"; do
            tag_name=$(echo "$tag_info" | cut -d: -f1)

            # Get or create tag in secondary
            secondary_tag_id=$(curl -s "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" | \
                jq -r "(. // []) | .[] | select(.label == \"${tag_name}\") | .id")

            if [ -z "$secondary_tag_id" ]; then
                new_tag=$(curl -s -X POST "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" \
                    -H "Content-Type: application/json" \
                    -d "{\"label\": \"${tag_name}\"}")
                secondary_tag_id=$(echo "$new_tag" | jq -r '.id')
            fi

            secondary_current_tags=$(echo "$secondary_current_tags" | jq "(. // []) + [${secondary_tag_id}] | unique")
        done

        # Remove tags in secondary
        for tag_info in "${tags_to_remove[@]}"; do
            tag_name=$(echo "$tag_info" | cut -d: -f1)

            secondary_tag_id=$(curl -s "${SECONDARY_RADARR_API_URL}/tag?apikey=${SECONDARY_RADARR_API_KEY}" | \
                jq -r "(. // []) | .[] | select(.label == \"${tag_name}\") | .id")

            if [ -n "$secondary_tag_id" ]; then
                secondary_current_tags=$(echo "$secondary_current_tags" | jq "(. // []) | del(.[] | select(. == ${secondary_tag_id}))")
            fi
        done

        # Update secondary movie
        secondary_movie_full=$(curl -s "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}")
        updated_secondary=$(echo "$secondary_movie_full" | jq ".tags = ${secondary_current_tags}")

        curl -s -X PUT "${SECONDARY_RADARR_API_URL}/movie/${secondary_movie_id}?apikey=${SECONDARY_RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$updated_secondary" > /dev/null

        log "INFO" "Tags synced to $SECONDARY_RADARR_NAME"
        SECONDARY_STATUS="synced"
    else
        log "INFO" "Movie not found in $SECONDARY_RADARR_NAME"
        SECONDARY_STATUS="not_found"
    fi
fi

################################################################################
# BUILD SUMMARY
################################################################################

tags_added_list=""
tags_removed_list=""
tags_kept_list=""

for tag_info in "${tags_to_add[@]}"; do
    display=$(echo "$tag_info" | cut -d: -f3)
    tags_added_list="${tags_added_list}${display}, "
done
tags_added_list=${tags_added_list%, }

for tag_info in "${tags_to_remove[@]}"; do
    display=$(echo "$tag_info" | cut -d: -f3)
    tags_removed_list="${tags_removed_list}${display}, "
done
tags_removed_list=${tags_removed_list%, }

for tag_info in "${tags_to_keep[@]}"; do
    display=$(echo "$tag_info" | cut -d: -f3)
    tags_kept_list="${tags_kept_list}${display}, "
done
tags_kept_list=${tags_kept_list%, }

# Final summary
log "INFO" "============================================"
log "INFO" "Summary:"
[ -n "$tags_added_list" ] && log "INFO" "  Added: $tags_added_list"
[ -n "$tags_kept_list" ] && log "INFO" "  Kept: $tags_kept_list"
[ -n "$tags_removed_list" ] && log "INFO" "  Removed: $tags_removed_list"
[ -z "$tags_added_list" ] && [ -z "$tags_kept_list" ] && [ -z "$tags_removed_list" ] && log "INFO" "  No tags applied"
[ "$discovered" = "true" ] && log "INFO" "  Discovered: $discovered_group ($discovered_quality + $discovered_audio)"
log "INFO" "  Secondary: $SECONDARY_STATUS"
log "INFO" "============================================"

################################################################################
# DISCORD NOTIFICATION (smart — only when something happened)
################################################################################

tagged=$( [ ${#tags_to_add[@]} -gt 0 ] || [ ${#tags_to_keep[@]} -gt 0 ] && echo true || echo false )
recover_done=$( [ -n "${RECOVER_GROUP:-}" ] && echo true || echo false )

if [ "${DISCORD_ENABLED:-false}" = "true" ] && { [ "$tagged" = "true" ] || [ "$discovered" = "true" ] || [ "$recover_done" = "true" ]; }; then
    log "INFO" "Sending Discord notification..."

    # Determine title and color
    if [ "$tagged" = "true" ] && [ "$discovered" = "true" ]; then
        notif_title="Tagged + Discovered - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16753920  # Orange (0xFFA500)
    elif [ "$tagged" = "true" ] && [ "$recover_done" = "true" ]; then
        notif_title="Tagged + Fixed - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16753920  # Orange (0xFFA500)
    elif [ "$discovered" = "true" ]; then
        notif_title="Discovered - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16766720  # Gold (0xFFD700)
    elif [ "$recover_done" = "true" ]; then
        notif_title="Release Group Fixed - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=3066993   # Green (0x2ECC71)
    else
        notif_title="Tagged - ${MOVIE_TITLE} (${MOVIE_YEAR})"
        notif_color=16753920  # Orange (0xFFA500)
    fi

    # Build fields array dynamically — only include relevant fields
    fields_json='[]'

    # Tag fields — only when tagged
    if [ "$tagged" = "true" ]; then
        tag_summary=""
        [ -n "$tags_added_list" ] && tag_summary="${tags_added_list}"
        if [ -n "$tags_kept_list" ]; then
            [ -n "$tag_summary" ] && tag_summary="${tag_summary}, ${tags_kept_list}" || tag_summary="${tags_kept_list}"
        fi

        instance_value="${PRIMARY_RADARR_NAME}"
        [ "$SECONDARY_STATUS" = "synced" ] && instance_value="${PRIMARY_RADARR_NAME} + ${SECONDARY_RADARR_NAME}"

        fields_json=$(echo "$fields_json" | jq \
            --arg instance "$instance_value" \
            --arg tags "$tag_summary" \
            '. += [
                { name: "Tagged in", value: $instance, inline: false },
                { name: "Tags Applied", value: $tags, inline: true }
            ]')
    fi

    # Recovery field — only when release group was recovered
    if [ "$recover_done" = "true" ]; then
        fields_json=$(echo "$fields_json" | jq \
            --arg recovered "$RECOVER_GROUP" \
            '. += [{ name: "Release Group Recovered", value: $recovered, inline: true }]')
    fi

    # Discovery field
    if [ "$discovered" = "true" ]; then
        discovery_value="${discovered_group} — added to config"
        fields_json=$(echo "$fields_json" | jq \
            --arg disc_value "$discovery_value" \
            '. += [{ name: "Discovered Group", value: $disc_value, inline: false }]')
    fi

    # Filename from Radarr env var (pre-rename — rename executes after script exits)
    notif_filename="$MOVIE_FILE_RELATIVE"

    # Event + filename — always present
    fields_json=$(echo "$fields_json" | jq \
        --arg event_type "$EVENT_TYPE" \
        --arg filename "$notif_filename" \
        '. += [
            { name: "Event", value: $event_type, inline: true },
            { name: "Filename", value: $filename, inline: false }
        ]')

    # Build Discord embed payload
    payload=$(jq -n \
        --arg title "$notif_title" \
        --argjson color "$notif_color" \
        --arg poster_url "$MOVIE_POSTER_URL" \
        --argjson fields "$fields_json" \
        --arg footer_text "$DISCORD_FOOTER" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: {
                    text: $footer_text
                },
                timestamp: $timestamp,
                thumbnail: {
                    url: $poster_url
                }
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
    log "INFO" "Nothing to report - skipping Discord notification"
fi

log "INFO" "Script completed successfully"
exit 0
