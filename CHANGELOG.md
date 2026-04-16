# Changelog

## v2.5.0 — 2026-04-16

### Changed (tagarr_migrate.sh)

- **`AUTOUPDATE_<SCRIPT>_DIR` now drives config migration too.** Until v2.4.x, the per-script DIR override in `tagarr_migrate.conf` only told migrate where to find the `.sh` file for auto-update. Config migration still scanned only the directory `tagarr_migrate.sh` itself lives in. This was asymmetric — users who point a script to a custom directory (e.g. `/appdata/radarr/scripts/`) usually keep its matching `.conf` there too, and the old behavior ignored that config. Now, any `AUTOUPDATE_<SCRIPT>_DIR` that's set in `tagarr_migrate.conf` is ALSO scanned for `tagarr_*.conf` files during config migration, regardless of whether the corresponding `AUTOUPDATE_<SCRIPT>=true` flag is enabled. One path per script → migrate handles both the script and the config living there.

- **`./tagarr_migrate.sh` (no arguments) now defaults to "migrate everything found".** Previous behavior was to auto-detect a single config, or error out with "Multiple configs found, specify which" when two or more were present. Now a no-args invocation scans `SCRIPT_DIR` + every `AUTOUPDATE_<SCRIPT>_DIR` set in `tagarr_migrate.conf`, migrates every `tagarr_*.conf` file it finds, and optionally auto-updates any scripts flagged `AUTOUPDATE_<SCRIPT>=true`. `--all` is kept as a no-op alias for users who typed it out of habit. Single-config targeting (`./tagarr_migrate.sh tagarr_import.conf`) still works for narrow-focus runs.

### Added

- **Expanded `tagarr_migrate.conf.sample` documentation.** Inline comments now explain the "one path per script, two independent questions" model (where does it live / should it be auto-updated), list four concrete usage scenarios (same-dir + enable, custom-dir + enable, custom-dir without auto-update, fully untouched), and explicitly document that a set DIR drives both the script-update lookup AND the config-migration scan. File itself unchanged — existing configs work without modification.

## v2.4.2 — 2026-04-16

### Fixed (tagarr_migrate.sh)

- **Discovery notice now actually fires on the current upgrade wave.** The v2.4.1 notice was placed inside the self-update `if` block, meaning only the *local* version's code could print it — and older versions don't have that code. Result: users upgrading from v2.3.x or v2.4.0 to v2.4.1 never saw the tip, because v2.4.1's notice code only runs when v2.4.1+ does a future self-update. Moved the notice out of the self-update block into a standalone check that runs once per invocation, after the (silent-by-default) auto-update step. Now fires for *every* upgrade path on the first post-upgrade run, and stays silent on all subsequent runs once the user creates `tagarr_migrate.conf`. Still `--all`-recursion-guarded, so it shows once, not seven times.

## v2.4.1 — 2026-04-16

### Fixed (tagarr_migrate.sh)

- **Config migration no longer drops file permissions to 600.** The old write path was `mktemp` → `printf > tempfile` → `mv tempfile target`, which replaced the live config with the `mktemp` file's default 600 permissions (`rw-------`). Installs that relied on 666 or group-readable configs for Radarr/Sonarr process access could silently break after migration. Fixed by writing directly into the destination (`printf > "$OUTPUT_FILE"`), preserving inode, permissions, and ownership. Pre-existing bug, not introduced by v2.4.0 — surfaced while testing the v2.4.0 auto-update flow (which already uses the correct in-place overwrite pattern).

### Added (tagarr_migrate.sh)

- **Discovery notice for the opt-in script auto-update feature.** When `tagarr_migrate.sh` self-updates to a new version AND `tagarr_migrate.conf` does not exist, a short tip prints after the "Updating migration script…" line pointing at the sample config URL. Fires only on actual version bumps, so it doesn't nag on every invocation — users see it once or twice a year at most. Suppressed completely once `tagarr_migrate.conf` exists (opted-in or deliberately ignored by keeping a fully-commented copy). Without this, the v2.4.0 feature stayed effectively invisible — users discovered it only by reading CHANGELOG or Discord.

## v2.4.0 — 2026-04-16

### Added (tagarr_migrate.sh)

- **Opt-in script auto-update.** `tagarr_migrate.sh` can now check-and-update the tagarr scripts themselves (not just their `.conf` files) on every invocation. **Off by default — zero behavior change for existing users who don't configure it.** Enabled per script via a new `tagarr_migrate.conf` file.

  **First-time setup (one-off, manual):**
  ```bash
  # From your tagarr scripts directory:
  curl -O https://raw.githubusercontent.com/ProphetSe7en/tagarr/main/tagarr_migrate.conf.sample
  cp tagarr_migrate.conf.sample tagarr_migrate.conf
  # Edit tagarr_migrate.conf — uncomment AUTOUPDATE_<SCRIPT>=true for each
  # script you want auto-updated on every migrate run.
  ```

  Example contents after enabling for `tagarr_import.sh`:
  ```
  AUTOUPDATE_TAGARR_IMPORT=true
  AUTOUPDATE_TAGARR_IMPORT_DIR=""   # optional — blank = migrate script's dir
  ```

  When enabled for a script, the migrate flow reads the local `SCRIPT_VERSION`, fetches the current version from `versions.json` on GitHub, and only downloads a replacement if remote is strictly newer (same `sort -V` gate introduced in v2.3.7 — protects users running ahead of `main`).

  Old scripts are backed up as `<script>.old` before replacement. File permissions and ownership are preserved by overwriting the existing file in place (never `mv`-ing a fresh `mktemp` on top). Sanity check ensures the downloaded file begins with a shebang before replacement; download failures and missing scripts are reported without aborting the config migration.

  Requires `jq` and `curl`. Missing dependencies → auto-update is skipped with a warning; config migration continues normally. `tagarr_migrate.sh` itself uses its existing self-update mechanism and is intentionally NOT part of the auto-update list to avoid conflict.

  Summary printed after the check — counts for updated, skipped (with reason: already current / ahead of remote / not in versions.json / not found at path), and failed scripts.

- **`tagarr_migrate.conf` added to the supported config list.** Once the file exists locally, `tagarr_migrate.sh --all` picks it up alongside `tagarr.conf` / `tagarr_import.conf` etc., and future additions to the `AUTOUPDATE_*` surface (e.g. new scripts) can be migrated in like any other config — preserving your existing enabled/disabled choices and adding new slots commented out.

### Changed (tagarr_migrate.sh)

- **Auto-update step is guarded against `--all` recursion** via a new `TAGARR_MIGRATE_SKIP_AUTO_UPDATE=1` env var set on recursive subcalls. The script-update check runs once in the outer invocation, not per migrated config.

## v2.3.7 — 2026-04-16

### Fixed (update-check in all 7 scripts)

- **Spurious "Update available: v1.5.3 (current: v1.5.7)" log entries.** The update check compared `latest != SCRIPT_VERSION` — triggering on *any* mismatch, including when the local script was newer than what `versions.json` advertised. Real-world trigger: a user who pulled `tagarr_import.sh` v1.5.7 from `main` saw an "update available" notice pointing at v1.5.3 because `versions.json` in the repo had been left at 1.5.3 through v1.5.4–v1.5.7 pushes. Fixed the comparison in all seven scripts (`tagarr.sh`, `tagarr_import.sh`, `tagarr_import_sonarr.sh`, `tagarr_list.sh`, `tagarr_recover.sh`, `tagarr_remove.sh`, `tagarr_rename.sh`) to only alert when remote is strictly newer — semver-aware via `sort -V`. Works on GNU and BSD sort; falls back to silent-no-alert if `sort -V` is unavailable. Discord footer's "Update available" tag is gated on the same logic.

### Changed

- **`versions.json` now matches actual script versions.** `tagarr_import.sh` was recorded as `1.5.3` while the file on `main` was `1.5.7` — four sequential patch releases (v1.5.4–v1.5.7) never bumped the manifest. Sync restored. `/push` flow will now verify `versions.json` matches `SCRIPT_VERSION=` in every `*.sh` before pushing, so this drift can't recur silently.

## v2.3.6 — 2026-04-16

### Fixed (tagarr_migrate.sh)

- **BSD grep compatibility.** Version detection used `grep -oP` (Perl-compatible regex), which is GNU-only. Users on BSD grep — macOS default, some minimal Linux distros — hit `grep: invalid option -- P` during migration, and the version check fell through to `"unknown"`, defeating the "already up to date" shortcut. Replaced both occurrences with POSIX `sed`. Migration itself already worked on affected systems (the error was non-fatal), but the noise is gone and the version-skip path now fires correctly.

### Removed

- **`tagarr_import_migrate.sh`** — the legacy import-specific migrate script. Replaced by the universal `tagarr_migrate.sh` in v2.1.0 but never deleted. Dead code.

## v2.3.5 — 2026-04-16

### Removed (tagarr_import.sh v1.5.7)

- **Reverted `GRAB_RENAME_HDR10PLUS` flag** from v1.5.5/v1.5.6. The feature was based on a wrong diagnosis — verification against real grabs showed Radarr already handles HDR10+ correctly without our intervention. Delta between grab-time and import-time custom format score for HDR10+ releases was only 1 point (not the 100 we expected from a missing HDR10+ Boost CF), because Radarr matches the title-based CF against the filename inside the torrent (which has `HDR10Plus` intact) rather than against the qBit torrent name. Renaming the torrent provided no scoring benefit. Removed the flag to keep the config surface honest.
- **Documented the design principle** inline in both the script and the sample config: only title-only tokens that cannot be reconstructed from the file itself belong in the rename check. MediaInfo-derived attributes (HDR, HDR10+, DV, codec, audio channels, resolution) are read by Radarr directly from the file on import and never need preservation via torrent rename.

### Kept

- `GRAB_RENAME_CUSTOM_TOKENS` — still useful as an escape hatch for future title-only tokens users identify. Sample examples updated from MediaInfo-adjacent (Dolby Vision, HDR10) to title-only (Remux, PROPER).

## v2.3.4 — 2026-04-16

### Fixed (tagarr_import.sh v1.5.6)

- **HDR10+ rename regex didn't match `HDR10+` followed by whitespace.** The trailing `\b` word boundary fails when the preceding character (`+`) is non-word and the following character is also non-word (whitespace/dot) — `\b` requires a word/non-word transition. In practice, `HDR10+` followed by ` ` or `.` never triggered a rename, defeating the v1.5.5 feature. Fixed by dropping the trailing `\b` — the required `(plus|\+|p)` group is anchor enough. Verified against Terminator Genisys and Tenet grabs (both `HDR10+` → match) vs Solo, Guardians of the Galaxy, and Mike & Nick (all plain `HDR` → no match). HDR CF (base, +500) is still correctly triggered by Radarr separately via the `\b(HDR)\b` spec — no double-counting, no overlap.

## v2.3.3 — 2026-04-16

### Added (tagarr_import.sh v1.5.5)

- **HDR10+ rename token** — new `GRAB_RENAME_HDR10PLUS` config flag (default `false`). When enabled, the grab rename step triggers a rename if the release title has `HDR10+` / `HDR10Plus` / `HDR10P` but the qBit torrent name does not. Solves the case where Radarr's MediaInfo parser reads `Dolby Vision` first on DV/HDR10+ hybrid files and misses the HDR10+ flag, causing the TRaSH HDR10+ Boost CF (title-based) to not score the import. Renaming ensures the HDR10+ token is present in the filename Radarr uses for CF matching.
- **Custom user tokens** — new `GRAB_RENAME_CUSTOM_TOKENS` array config. Format per entry: `"Label:regex"`. Script triggers a rename when the grab title matches the regex but the torrent name doesn't — same semantics as the built-in flags (`GRAB_RENAME_IMAX`, `GRAB_RENAME_OPEN_MATTE`, `GRAB_RENAME_HDR10PLUS`). Bash-compatible regex (no lookaheads, no backreferences). Intended as an escape hatch for CF tokens users discover matter for their setup without waiting for a script update. Sample config includes commented examples for Dolby Vision, Remux, and HDR10.

### Changed

- **tagarr_import.conf.sample** — config version 1.3 → 1.4. New fields: `GRAB_RENAME_HDR10PLUS`, `GRAB_RENAME_CUSTOM_TOKENS`.

## v2.3.2 — 2026-04-16

### Fixed (tagarr_import.sh v1.5.4)

- **Discovery writes to config silently skipped inside the Radarr container.** Since v1.5.0 (2026-03-04), the auto-write path that appends newly-discovered release groups to `RELEASE_GROUPS` used `flock -w 10 200` to serialize concurrent writes. BusyBox `flock` — shipped in LinuxServer's Radarr image — does not support `-w` (timeout) and exits with `unrecognized option: w`. The subshell hit its error branch, the config write was skipped, and the outer grep-verification logged `Failed to write discovered group to config`. Every new release group detected since the regression was never persisted; in practice only APEX was hit on 2026-04-16 because the existing group set happened to be stable in the interim. Fix: switch to `flock -n 200` (non-blocking, BusyBox-compatible). Same semantic outcome — skip write if the lock is already held, next Grab retries — but it actually runs. Only `tagarr_import.sh` was affected; no other script uses `flock`.

## v2.3.1 — 2026-04-15

### Fixed (tagarr_import.sh v1.5.3)

- **Scene group detector spammed Radarr logs with grep errors on every Grab.** Pattern 2 of `_is_scene` used a regex beginning with `-` (the TRaSH Scene CF anchors release groups as `-CAKES|-GGEZ|...`). Both GNU grep and BusyBox grep parsed the leading `-` as a short option and failed with `invalid option -- '('` — BusyBox then dumped its full help text as stderr, which Radarr captured as Error-level log lines. On a typical install this produced ~54 Error lines per Grab event. Fix: pass `--` before the pattern to stop option parsing. Scene detection pattern 2 also now actually works — it was silently failing, meaning `GRAB_RENAME_EXCLUDE_SCENE` only ever triggered via pattern 1 (resolution + WEB naming).

## v2.3.0 — 2026-04-13

### Added (tagarr_import.sh v1.5.2)

- **Open Matte token tracking** — Grab rename now detects `Open Matte` in release titles. This TRaSH CF (+25 score) is title-based and lost when torrent names are stripped, causing score drops that block imports.
- **Configurable Movie Version tokens** — `GRAB_RENAME_IMAX` and `GRAB_RENAME_OPEN_MATTE` (both default `false`) let users toggle which Movie Version CFs trigger a rename. More tokens can be added as needed.
- **Qui proxy support** — Qui users can use their proxy URL in `QBIT_CLIENTS` instead of direct qBit URLs. No separate backend config needed.
- **Update check in all scripts** — All scripts check `versions.json` on GitHub at startup. Discord-enabled scripts show update notices in the footer; others log a message. 5s timeout, fail-safe.
- **Universal config migration** — `tagarr_migrate.sh` replaces `tagarr_import_migrate.sh`. Works with all 7 tagarr configs — detects type from filename, downloads matching sample from GitHub, `--all` flag to migrate everything at once. Self-updates from GitHub.
- **Config versioning** — All `.conf.sample` files now include `# Config version:` for tracking. Migration script skips if already current.

### Fixed

- **Release group false positive on cosmetic spacing** — The release group check now tolerates `- Group` (space after hyphen) and trailing parentheses, preventing unnecessary renames when the group is already present with slightly different formatting.

### Changed

- **Discord notification fields** — "Original Name" → "Torrent Name", "New Name" → "Restored to Release Name" for clearer intent.
- **IMAX/Open Matte default off** — Both default to `false` in sample config (opt-in, not opt-out).

## v2.2.0 — 2026-04-12

### Added (tagarr_import.sh v1.5.0) [EXPERIMENTAL]

- **Grab rename on all grabs** — `ENABLE_GRAB_RENAME` now renames ALL grabs (removed `GRAB_RENAME_GROUPS` whitelist). Only renames when meaningful CF tokens differ between torrent name and grab title — cosmetic differences (dots vs spaces, reordering) are skipped entirely.
- **Scene detection** — Detects scene releases using the same pattern as TRaSH Scene CF (WEB without DL + known scene groups). New `GRAB_RENAME_EXCLUDE_SCENE` option (default: false) to skip rename for scene releases.
- **Scene CF warning** — When a scene release is renamed and Scene CF no longer matches (e.g. WEB → WEB-DL), Discord notification includes a ⚠️ Scene CF warning field.
- **New diff tokens** — WEB-DL (catches WEB → WEB-DL, prevents Scene CF -10000 penalty) and IMAX/IMAX Enhanced.
- **Prowlarr guidance in config** — Explains the release name vs filename trade-off and its impact on scene detection.

### Changed

- **Notification wording** — "Fixed" → "Recovered" (rename doesn't guarantee import outcome).
- **No cosmetic renames** — Grabs where only dots/spaces/ordering differ are left untouched, preventing potential Radarr queue tracking issues.

## v2.1.1 — 2026-04-05

### Fixed

- **Shared tag_name double-counting** — When multiple release groups share the same `tag_name` (e.g., `flux:premium` + `sic:premium`), the summary, totals, and cleanup loops no longer process the same tag multiple times. Previously, shared tags would appear twice in the summary output and totals would be inflated in Discord notifications.

### Improved

- **Detailed how-to guides** — New standalone guides for each core script:
  - [Batch Tagger Guide](docs/tagarr-guide.md) — `tagarr.sh` with use cases, config reference, overall workflow
  - [Recovery Guide](docs/tagarr-recover-guide.md) — `tagarr_recover.sh` with safety chain details, Radarr/Sonarr differences
  - [Import Guide](docs/tagarr-import-guide.md) — `tagarr_import.sh` + `tagarr_import_sonarr.sh` with setup, use cases, Docker instructions
  - [Troubleshooting](docs/troubleshooting.md) — common issues across all scripts
- **Config sample descriptions** — All `.conf.sample` files rewritten with detailed explanations of every option
- **README restructured** — Short overview with links to guides, quick start follows recommended workflow
- **Shared tag documentation** — Use cases for shared tags (`flux:premium` + `sic:premium`), dual-tag pattern, and remux cleanup via secondary sync

## v2.1.0 — 2026-04-05

### Added

- **`AUTO_TAG_DISCOVERED` in `tagarr.sh`** — New config option (default: `false`)
  that writes discovered release groups as active entries instead of commented
  out. Groups are tagged automatically on the next scheduled run. Previously
  this option was only available in `tagarr_import.sh`.

## v2.0.0 — 2026-04-05

Sonarr support. **Sonarr functionality is new and needs further testing.**

### Added

- **Sonarr support in `tagarr_recover.sh`** — New `--app` flag supports
  `radarr`, `sonarr`, or `both` (default). Scans series → episodefiles for
  missing release groups using the same 5-point safety chain as Radarr.
  New `--series ID` flag for single-series mode.
- **`tagarr_import_sonarr.sh`** — New Sonarr Connect handler (On Download)
  that recovers missing release groups on import using exact download ID
  matching. Same approach as `tagarr_import.sh` v1.3.3 for Radarr. Includes
  Discord notification with series poster and episode label.
- **`tagarr_import_sonarr.conf.sample`** — Configuration for the Sonarr
  import script.

### Fixed

- **History walking matched wrong grab after upgrade** — When the newest
  import had no matching grab (pruned history) or the grab had no release
  group, the function fell through to older grabs that belonged to previous
  files. Now stops after the newest import — never falls through to old grabs.
  This fix applies to both Radarr and Sonarr in `tagarr_recover.sh`.

### Changed

- **`tagarr_recover.conf.sample`** — Now includes both Radarr and Sonarr
  instance configuration (primary + secondary for each).
- **Config backwards compatible** — Old configs with `ENABLE_SECONDARY`
  (without `_RADARR` suffix) still work.
- **Discord notifications** — Show app type (Radarr/Sonarr) and use correct
  terminology (movies vs episodes).
- **History parsing** — Handles both `releaseGroup` and `ReleaseGroup` key
  casing, and paginated history responses.

## v1.3.3 — 2026-03-11

Rewrite release group recovery to use exact download ID matching.

### Fixed

- **Recovery accuracy** — The old recover function walked Radarr history
  newest-to-oldest looking for an import→grab pair. During upgrades, the new
  import event isn't in history yet when Connect fires, causing recover to find
  the wrong grab from an older file (e.g., ZR instead of DRX).
- **New approach** — Uses `radarr_download_id` (available on every import event)
  to match the exact grab in history. No walking, no guessing.

### Changed

- **Priority chain** — `tagarr_import.sh` now resolves release groups in order:
  1. `radarr_moviefile_releasegroup` (direct from imported file)
  2. `movieFile.releaseGroup` (Radarr API)
  3. `downloadId` → grab history lookup (exact match)
- **Discovery requirement clarified** — Discovery only works when a release
  group is known. Movies with no recoverable group are silently skipped.

### Added

- **`tagarr_debug.sh`** — Debug script for inspecting Radarr Connect event
  variables. Logs all `radarr_*` environment variables to help troubleshoot
  import issues.

## v1.3.2 — 2026-03-10

Fix for upgrades applying the previous file's release group.

### Fixed

- **Upgrade release group bug** — During upgrades, the history-based recovery
  could pick up the OLD file's release group (e.g., BHDStudio) instead of the
  new one (e.g., GiLG). This happened because Radarr Connect fires before the
  new import event is written to history.
- **Fix:** Use `radarr_release_releasegroup` environment variable from Radarr
  Connect as the primary source for release group. This always contains the
  correct group for the current download. Also patches the moviefile via API
  so rename uses the correct group.
- History recovery remains as fallback for empty/Unknown groups (e.g., manual
  imports or standalone script runs).

## v1.3.1 — 2026-03-04

Renamed fixgrp to recover, code review fixes, branding.

### Changed

- `tagarr_fixgrp.sh` renamed to `tagarr_recover.sh` (consistent verb pattern)
- Discord footer branding: "by ProphetSe7en" on all notification scripts
- 5 medium code review findings fixed

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
