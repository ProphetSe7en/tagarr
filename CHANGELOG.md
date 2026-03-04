# Changelog

## v1.3.0 — 2026-03-03

Release group recovery from grab history.

### Added

- **`tagarr_recover.sh`** — Standalone backlog scanner that recovers missing
  release groups from Radarr grab history. Fixes movies where the indexer had
  the correct group (e.g., `126811`) but the actual filename did not include it.
  Dry-run by default, `--live` to execute. Supports `--instance` and `--no-rename`.
- **`tagarr_recover.conf`** — Configuration for the recover script.
- **`tagarr_import.sh` inline recovery** — New `fix_release_group_from_history()`
  function runs before the existing tag logic. When a movie arrives with an empty
  release group, it checks grab history and patches the moviefile before tagging
  proceeds. Prevents new movies from falling through.
- **5-point safety chain** — Both scripts verify: (1) blanks only — never
  overwrites existing release groups, (2) filename check — if a group exists
  in the filename but Radarr has none, the movie is flagged for manual review,
  (3) import-verified grab — walks all history events and only uses grabs
  confirmed by a successful import, (4) non-empty result, (5) title+year match.
- **Flagged movies** — Movies where the filename contains a release group but
  Radarr has none are reported separately for manual review instead of being
  auto-fixed.
- **`--movie ID` flag** — Process a single movie by Radarr ID for testing.
- **Rename trigger** — After patching releaseGroup, triggers Radarr's
  `RenameFiles` command so the file on disk reflects the corrected group.

### Changed

- `tagarr_import.sh` — Bumped to v1.3.0.
- **No-RlsGroup category** — Verified grabs with genuinely empty release groups
  are reported as "No-RlsGroup" (matching Radarr UI terminology) instead of
  being counted as failures.
- **Auto-tag discovered groups** (`tagarr_import.sh`) — New `AUTO_TAG_DISCOVERED`
  config option. When enabled, discovered groups are added as active entries
  and the triggering movie is tagged immediately. No manual review step needed.
- **Concurrent write protection** (`tagarr_import.sh`) — Config file writes
  during discovery use `flock` to prevent corruption when multiple import
  events fire simultaneously.

## v1.2.0 — 2026-02-27

Lazy tag creation and new command-line flags.

### Added

- **`--help` flag** — Shows usage information and exits.
- **`--discover` flag** — Discovery-only mode. Scans for unknown release groups
  without tagging or modifying anything. Implies `--dry-run` and forces
  `ENABLE_DISCOVERY=true` for the run.
- **Config documentation** — Available command-line flags documented in
  `tagarr.conf` header for reference.

### Changed

- **Lazy tag creation** — Tags defined in `RELEASE_GROUPS` are no longer
  pre-created at startup. The resolve phase now only looks up existing tag IDs.
  Tags are created lazily during the apply phase, only when there are movies
  that need the tag. This prevents unused tags from flickering in and out of
  Radarr on every run when `CLEANUP_UNUSED_TAGS=true`, and prevents tag
  accumulation when set to `false`.

## v1.1.0 — 2026-02-26

Compatibility and robustness release. Fixes issues reported by users with
bracket-style Radarr naming and certain Radarr database states.

### Fixed

- **Bracket naming support** — Quality filter regex (`MA WEBDL`, `Play WEBDL`)
  now matches bracket-separated naming (`[MA][WEBDL-2160p]`) in addition to
  standard dot naming (`MA.WEBDL-2160p`). Affects `tagarr.sh` and
  `tagarr_import.sh`.
- **DTS-HD MA audio detection** — Audio filter now matches space-separated
  format (`DTS-HD MA 5.1`) used in bracket naming, not just dot/hyphen
  separators.
- **jq null-safety** — All `.tags` field access guarded with `(.tags // [])`
  fallback. Prevents `null and array cannot have their containment checked`
  crash on movies where Radarr returns `.tags: null` instead of an empty array.
- **API response null-safety** — All API array iterations guarded with
  `(. // []) | .[]` fallback. Prevents `Cannot iterate over null` crash when
  Radarr `/movie` or `/tag` endpoints return null.

### Changed

- `tagarr.sh` — 9 jq null-safety fixes, 6 regex fixes
- `tagarr_import.sh` — 14 jq null-safety fixes, 6 regex fixes
- `test_filters.sh` — Expanded to 112 tests (52 standard + 52 bracket + 8 false positive)

## v1.0.0 — 2026-02-18

Initial release of the Tagarr toolset.

- `tagarr.sh` — Batch tagger (scheduled via Cronicle)
- `tagarr_import.sh` — Event-driven tagger (Radarr Connect)
- `tagarr_remove.sh` — Bulk tag removal (manual, dry-run default)
- `tagarr_rename.sh` — Bulk tag rename (manual, dry-run default)
- `tagarr_list.sh` — TMDb/Trakt list-based tagger (manual, dry-run default)
