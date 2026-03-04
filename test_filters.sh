#!/usr/bin/env bash
# Test script: validate check_quality_match() and check_audio_match()
# against the TAG-TEST-LIST from ORIGINAL_CRITERIA_TAG_AND_SYNC.md
#
# Runs all 52 test filenames and verifies expected results.

set -euo pipefail

# Load config for filter toggles
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/tagarr_import.conf"

# === FILTER FUNCTIONS (copied from tagarr_import.sh) ===

check_quality_match() {
    local f="$1"
    [ "$ENABLE_QUALITY_FILTER" != "true" ] && return 0

    if [ "$ENABLE_MA_WEBDL" = "true" ]; then
        if echo "$f" | grep -Eqi '\bma[._-]web([-.]?dl)?[._-]'; then
            return 0
        fi
    fi

    if [ "$ENABLE_PLAY_WEBDL" = "true" ]; then
        if echo "$f" | grep -Eqi '\bplay[._-]web([-.]?dl)?[._-]'; then
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
        if echo "$f" | grep -Eqi '\bdts[._-]?hd[._-]?ma\b'; then
            return 0
        fi
    fi

    return 1
}

# === TEST DATA ===
# Format: "expected_result|filename"
# expected: + = should pass both filters, - = should fail at least one
# Known groups: FLUX, TheFarm, 126811
# Unknown groups (discovery): rlsgrp_7, rlsgrp_1

declare -a TESTS=(
    # Lines 331-382 from ORIGINAL_CRITERIA_TAG_AND_SYNC.md
    "-|Blue.Beetle.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.h265-FLUX.mkv"
    "+|Jumanji.1995.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv"
    "+|Batman.and.Robin.1997.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv"
    "+|Batman.1989.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.h265-FLUX.mkv"
    "+|The.Mummy.1999.MA.WEBDL-2160p.DTS-X.7.1.HDR10.h265-FLUX.mkv"
    "+|Last.Christmas.2019.MA.WEBDL-2160p.DTS-HD.MA.7.1.HDR10.h265-FLUX.mkv"
    "-|Cash.Out.2024.AMZN.WEBDL-2160p.DTS-HD.MA.5.1.h265-126811.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.Play.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "-|MOVIE.2023.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-TheFarm.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.Play.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "-|MOVIE.2023.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-FLUX.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-rlsgrp_7.mkv"
    "+|MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-rlsgrp_1.mkv"
    "-|MOVIE.2023.MA.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-126811.mkv"
    "+|MOVIE.2023.Play.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.Play.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.Atmos.7.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-X.7.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-126811.mkv"
    "-|MOVIE.2023.WEBDL-2160p.EAC3.Atmos.5.1.DV.HDR10.HEVC-126811.mkv"
)

# === RUN TESTS ===

pass_count=0
fail_count=0
total=${#TESTS[@]}

echo "TAG-TEST-LIST Validation (${total} tests)"
echo "=========================================="
echo ""

for test_entry in "${TESTS[@]}"; do
    expected="${test_entry%%|*}"
    filename="${test_entry#*|}"

    # Run both filters
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
        status="PASS"
    else
        fail_count=$((fail_count + 1))
        status="FAIL"
        # Show detail on failures
        echo "FAIL: expected=$expected actual=$actual q=$q_pass a=$a_pass"
        echo "      $filename"
    fi
done

echo ""
echo "=========================================="
echo "Results: ${pass_count}/${total} passed, ${fail_count} failed"
echo "=========================================="

# === DISCOVERY TESTS ===
# rlsgrp_7 and rlsgrp_1 are unknown groups that pass filters → should DISCOVER
echo ""
echo "Discovery verification:"

# These two filenames have unknown groups but pass both filters
disc_files=(
    "MOVIE.2023.MA.WEBDL-2160p.TrueHD.7.1.DV.HDR10.HEVC-rlsgrp_7.mkv"
    "MOVIE.2023.MA.WEBDL-2160p.DTS-HD.MA.5.1.DV.HDR10.HEVC-rlsgrp_1.mkv"
)

# Load known groups from config (same logic as script)
declare -A test_known_groups
test_known_groups[_]=1; unset "test_known_groups[_]"
while IFS= read -r line; do
    if [[ "$line" =~ \"([^:\"]+):[^:\"]+:[^:\"]+:[^:\"]+\" ]]; then
        test_known_groups["${BASH_REMATCH[1],,}"]=1
    fi
done < "${SCRIPT_DIR}/tagarr_import.conf"

for df in "${disc_files[@]}"; do
    # Extract release group (after last -)
    rg="${df##*-}"
    rg="${rg%.mkv}"
    rg_lower="${rg,,}"

    known="no"
    [ -n "${test_known_groups[$rg_lower]:-}" ] && known="yes"

    q_pass=false
    a_pass=false
    check_quality_match "$df" && q_pass=true
    check_audio_match "$df" && a_pass=true

    if [ "$q_pass" = "true" ] && [ "$a_pass" = "true" ] && [ "$known" = "no" ]; then
        echo "  PASS: $rg → would DISCOVER (quality=$q_pass, audio=$a_pass, known=$known)"
    else
        echo "  FAIL: $rg → q=$q_pass a=$a_pass known=$known (expected: discoverable)"
        fail_count=$((fail_count + 1))
    fi
done

echo ""
if [ "$fail_count" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "${fail_count} TESTS FAILED"
    exit 1
fi
