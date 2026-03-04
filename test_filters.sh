#!/usr/bin/env bash
# Test script: validate check_quality_match() and check_audio_match()
# Tests BOTH standard (dot) naming and bracket naming schemes.
#
# Runs all test filenames and verifies expected results.

set -euo pipefail

# Load config for filter toggles
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Use tagarr_import.conf if available, otherwise set defaults
if [ -f "${SCRIPT_DIR}/tagarr_import.conf" ]; then
    source "${SCRIPT_DIR}/tagarr_import.conf"
else
    # Defaults matching standard config
    ENABLE_QUALITY_FILTER=true
    ENABLE_MA_WEBDL=true
    ENABLE_PLAY_WEBDL=true
    ENABLE_AUDIO_FILTER=true
    ENABLE_TRUEHD=true
    ENABLE_TRUEHD_ATMOS=true
    ENABLE_DTS_X=true
    ENABLE_DTS_HD_MA=true
fi

# === FILTER FUNCTIONS (from tagarr.sh / tagarr_import.sh v1.1.0) ===

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

    if echo "$f" | grep -Eqi '\b(upmix|encode|transcode|lossy|converted|re-?encode)\b'; then
        return 1
    fi

    if [ "$ENABLE_TRUEHD_ATMOS" = "true" ] || [ "$ENABLE_TRUEHD" = "true" ]; then
        if echo "$f" | grep -Eqi '\btruehd\b'; then
            if echo "$f" | grep -Eqi '\batmos\b'; then
                [ "$ENABLE_TRUEHD_ATMOS" = "true" ] && return 0
            else
                [ "$ENABLE_TRUEHD" = "true" ] && return 0
            fi
        fi
    fi

    if [ "$ENABLE_DTS_X" = "true" ]; then
        if echo "$f" | grep -Eqi '\bdts[._-]?x\b'; then
            return 0
        fi
    fi

    if [ "$ENABLE_DTS_HD_MA" = "true" ]; then
        if echo "$f" | grep -Eqi '\bdts[._ -]?hd[._ -]?ma\b'; then
            return 0
        fi
    fi

    return 1
}

# === TEST RUNNER ===

pass_count=0
fail_count=0

run_test() {
    local test_entry="$1"
    local expected="${test_entry%%|*}"
    local filename="${test_entry#*|}"

    q_pass=false
    a_pass=false
    check_quality_match "$filename" && q_pass=true
    check_audio_match "$filename" && a_pass=true

    if [ "$q_pass" = "true" ] && [ "$a_pass" = "true" ]; then
        actual="+"
    else
        actual="-"
    fi

    if [ "$expected" = "$actual" ]; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
        echo "  FAIL: expected=$expected actual=$actual q=$q_pass a=$a_pass"
        echo "        $filename"
    fi
}

########################################
# PART 1: STANDARD NAMING (dot-separated)
########################################

echo "========================================"
echo "PART 1: Standard Naming (52 tests)"
echo "========================================"

STANDARD_TESTS=(
    # Real files
    "-|Blue.Beetle.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.h265-FLUX.mkv"
    "+|Jumanji.1995.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv"
    "+|Batman.and.Robin.1997.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv"
    "+|Batman.1989.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv"
    "+|The.Mummy.1999.MA.WEBDL-2160p.DTS-X.7.1.HDR10.h265-FLUX.mkv"
    "+|Last.Christmas.2019.MA.WEBDL-2160p.DTS-HD.MA.7.1.HDR10.h265-FLUX.mkv"
    "-|Cash.Out.2024.AMZN.WEBDL-2160p.DTS-HD.MA.5.1.h265-126811.mkv"
    # TheFarm — MA
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    # TheFarm — Play
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.Play.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    # TheFarm — No source prefix (should fail quality)
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    # FLUX — MA
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-FLUX.mkv"
    # FLUX — Play
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.Play.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-FLUX.mkv"
    # FLUX — No source prefix (should fail quality)
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-FLUX.mkv"
    # 126811 — MA
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-126811.mkv"
    # Discovery groups (unknown, should pass filters)
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-rlsgrp_7.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-rlsgrp_1.mkv"
    "-|MOVIE.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-126811.mkv"
    # 126811 — Play
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.Play.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-126811.mkv"
    # 126811 — No source prefix (should fail quality)
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-126811.mkv"
)

for test_entry in "${STANDARD_TESTS[@]}"; do
    run_test "$test_entry"
done

std_pass=$pass_count
std_fail=$fail_count
std_total=${#STANDARD_TESTS[@]}
echo ""
echo "Standard: ${std_pass}/${std_total} passed, ${std_fail} failed"

########################################
# PART 2: BRACKET NAMING
########################################

echo ""
echo "========================================"
echo "PART 2: Bracket Naming (52 tests)"
echo "========================================"

# Reset counters for part 2
pass_count=0
fail_count=0

# Same test cases converted to bracket naming:
# Standard: Movie.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv
# Bracket:  Movie (2023) {tmdb-12345} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][h265]-FLUX.mkv

BRACKET_TESTS=(
    # Real files (bracket format)
    "-|Blue Beetle (2023) {tmdb-565770} - [MA][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][h265]-FLUX.mkv"
    "+|Jumanji (1995) {tmdb-8844} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][h265]-FLUX.mkv"
    "+|Batman and Robin (1997) {tmdb-415} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][h265]-FLUX.mkv"
    "+|Batman (1989) {tmdb-268} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][h265]-FLUX.mkv"
    "+|The Mummy (1999) {tmdb-564} - [MA][WEBDL-2160p][DTS-X 7.1][HDR10][h265]-FLUX.mkv"
    "+|Last Christmas (2019) {tmdb-548473} - [MA][WEBDL-2160p][DTS-HD MA 7.1][HDR10][h265]-FLUX.mkv"
    "-|Cash Out (2024) {tmdb-1011985} - [AMZN][WEBDL-2160p][DTS-HD MA 5.1][h265]-126811.mkv"
    # TheFarm — MA (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-TheFarm.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-TheFarm.mkv"
    # TheFarm — Play (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-TheFarm.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-TheFarm.mkv"
    # TheFarm — No source prefix (bracket, should fail quality)
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-TheFarm.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-TheFarm.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-TheFarm.mkv"
    # FLUX — MA (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-FLUX.mkv"
    # FLUX — Play (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-FLUX.mkv"
    # FLUX — No source prefix (bracket, should fail quality)
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-FLUX.mkv"
    # 126811 — MA (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-126811.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-126811.mkv"
    # Discovery groups (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-rlsgrp_7.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-rlsgrp_1.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [MA][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-126811.mkv"
    # 126811 — Play (bracket)
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-126811.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-126811.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-126811.mkv"
    "+|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-126811.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [Play][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-126811.mkv"
    # 126811 — No source prefix (bracket, should fail quality)
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-126811.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][DTS-X 7.1][DV HDR10][HEVC]-126811.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][TrueHD 7.1][DV HDR10][HEVC]-126811.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][DTS-HD MA 5.1][DV HDR10][HEVC]-126811.mkv"
    "-|MOVIE (2023) {tmdb-99999} - [WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10][HEVC]-126811.mkv"
)

for test_entry in "${BRACKET_TESTS[@]}"; do
    run_test "$test_entry"
done

brk_pass=$pass_count
brk_fail=$fail_count
brk_total=${#BRACKET_TESTS[@]}
echo ""
echo "Bracket: ${brk_pass}/${brk_total} passed, ${brk_fail} failed"

########################################
# PART 3: FALSE POSITIVE PROTECTION
########################################

echo ""
echo "========================================"
echo "PART 3: False Positive Protection (8 tests)"
echo "========================================"

pass_count=0
fail_count=0

# These should all FAIL quality — similar-looking sources that are NOT MA/Play
FALSE_POS_TESTS=(
    # IMAX should not match MA
    "-|MOVIE (2023) {tmdb-99999} - [IMAX][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE.2023.IMAX.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    # AMZN should not match
    "-|MOVIE (2023) {tmdb-99999} - [AMZN][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE.2023.AMZN.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    # NF (Netflix) should not match
    "-|MOVIE (2023) {tmdb-99999} - [NF][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE.2023.NF.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    # DSNP (Disney+) should not match
    "-|MOVIE (2023) {tmdb-99999} - [DSNP][WEBDL-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FLUX.mkv"
    "-|MOVIE.2023.DSNP.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
)

for test_entry in "${FALSE_POS_TESTS[@]}"; do
    run_test "$test_entry"
done

fp_pass=$pass_count
fp_fail=$fail_count
fp_total=${#FALSE_POS_TESTS[@]}
echo ""
echo "False positive: ${fp_pass}/${fp_total} passed, ${fp_fail} failed"

########################################
# SUMMARY
########################################

echo ""
echo "========================================"
echo "TOTAL RESULTS"
echo "========================================"

total_pass=$((std_pass + brk_pass + fp_pass))
total_fail=$((std_fail + brk_fail + fp_fail))
total_tests=$((std_total + brk_total + fp_total))

echo "Standard naming:        ${std_pass}/${std_total}"
echo "Bracket naming:         ${brk_pass}/${brk_total}"
echo "False positive protect: ${fp_pass}/${fp_total}"
echo "------------------------------------------"
echo "Total:                  ${total_pass}/${total_tests} passed, ${total_fail} failed"
echo "========================================"

if [ "$total_fail" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "${total_fail} TESTS FAILED"
    exit 1
fi
