# Changelog

## v2.9.0 — 2026-04-25

### Added (tagarr_import_sonarr.sh v1.1.0)

- **Grab rename for Sonarr.** Mirrors the Radarr feature in `tagarr_import.sh` — renames the qBit torrent on Sonarr's Grab event so that release-group and user-defined custom tokens (typically streaming-source flags like AMZN, NF, DSNP) survive into Sonarr's import-time CF scoring. Sonarr reads the qBit torrent display name (not the file on disk) when re-evaluating Custom Formats at import; without the rename, indexer-only tokens get lost between grab and import and the CF score drops, triggering Sonarr's upgrade loop where it re-grabs the same release. Real-world trigger from a user report: `Family Guy S13 1080p AMZN WEB-DL DD 5.1 H.264-CtrlHD` (1785) downloads as `Family.Guy.S13E01.The.Simpsons.Guy.1080p.WEB-DL.DD5.1.H.264-CtrlHD.mkv` (1710) — the AMZN flag is missing from the filename, the +75 CF score evaporates on import, Sonarr keeps re-grabbing.
- **AMZN and NF uncommented by default** in `tagarr_import_sonarr.conf.sample` — these two services dominate user reports of the scoring loop. All 17 other streaming services from TRaSH's `[Streaming Services] General` group are available as ready-to-uncomment entries.
- **`GRAB_RENAME_CUSTOM_TOKENS` for user-defined recovery patterns.** Each entry is `label:regex`. The script triggers a rename when the regex matches the indexer's release title but not the qBit torrent name. Bash extended regex (POSIX ERE — no lookahead/lookbehind), so the shipped streaming-service patterns are simplified from TRaSH's Perl-compatible originals. For streaming flags this is safe — a too-broad regex causes false negatives, not wrong renames, since the script only acts on grab-has-it-but-current-doesnt.
- **`QBIT_CLIENTS` config in Sonarr sample** — same syntax as Radarr (`name:url`), required when `ENABLE_GRAB_RENAME=true`.

### Carried over from v2.8.1 (now in both scripts)

- Strip indexer-appended suffixes after `-<RG>` before the qBit rename API call (handles `-126811 x ATM05`-class indexer cruft).
- Retry `qBit /torrents/info` lookup with `0,1,2,3,5,5s` backoff to handle the busy-qBit indexing race that produced ~1/5 "Torrent not found in qBit (yet?)" failures.

### Changed (tagarr_import_sonarr.conf.sample)

- **Config version bumped 1.0 → 1.1.** `tagarr_migrate.sh` adds the new `ENABLE_GRAB_RENAME`, `QBIT_CLIENTS`, and `GRAB_RENAME_CUSTOM_TOKENS` sections automatically on next migration run; existing `ENABLE_RECOVER`, `ENABLE_RENAME`, and Discord settings are preserved.

### Notes

- Grab rename for Sonarr is **untested** at release time — the Radarr equivalent has been running in production for months, but Sonarr-side feedback is requested. If you enable this and see anything unexpected, open an issue or drop a note in the Discord channel.

## v2.8.1 — 2026-04-24

### Fixed (tagarr_import.sh v1.6.1)

- **Indexer-appended suffixes no longer end up in the qBit torrent name.** The grab-rename call used `$GRAB_TITLE` (Radarr's raw `radarr_release_title`) verbatim as the new torrent name. Some indexers append a listing ID after the release group (e.g. `-126811 x ATM05`, or an occasional `.mkv` extension) that's valid metadata in the indexer's release table but shouldn't leak into qBit. Real-world trigger: a Garfield Movie grab renamed to `...Atmos-126811 x ATM05`. The rename now keeps the title up to and including `-<RG>` and drops anything that follows. No-op for the 81/88 historical grabs where `$GRAB_TITLE` already ends cleanly on the release group.

- **Retry on "Torrent not found in qBit" race.** Radarr fires the Grab event after qBit's `/torrents/add` returns `200`, but on busy qBit instances the torrent may not appear in `/torrents/info` for a second or two while qBit indexes the metadata. The script used to fail immediately with `not found in qBit (yet?) — skip`, silently losing the rename opportunity on ~1/5 of grabs per user reports. Now retries up to 6 times with `0, 1, 2, 3, 5, 5`-second backoff (total upper bound ~16s). First successful hit exits the loop — normal grabs see zero extra delay.

## v2.8.0 — 2026-04-23

### Changed (tagarr_import.sh v1.6.0) — behavioral

- **Grab-rename now covers the full TRaSH [Optional] Movie Versions CF group.** `GRAB_RENAME_IMAX` and `GRAB_RENAME_OPEN_MATTE` are replaced by a single `GRAB_RENAME_MOVIE_VERSION` toggle (default `true`). When enabled, the rename trigger fires whenever the grab title carries any of these title-only tokens but the qBit torrent name doesn't: Director's Cut, Theatrical, Extended, Unrated, Uncut, Remaster (also matches 4K Remaster / Remastered), Criterion, Masters of Cinema, Vinegar Syndrome, Hybrid, IMAX (also matches IMAX Enhanced), Open Matte. Regexes are simplified — one concept per match, not one-per-CF — so `\bimax\b` covers both IMAX variants and `\bremaster(ed)?\b` covers both Remaster variants. Discord label uses the concept name; Radarr still re-scores the renamed title against its full CF set on import so the exact variant is matched there. Real-world trigger: a Den of Thieves 2 grab with `Director's.Cut` in the release title but not in the torrent name — previous versions skipped rename ("no meaningful tokens to recover") and the Special Edition CF (+125) was lost on import. Behavioral change: users on previous versions with both IMAX and Open Matte set to `false` now get broader rename coverage by default; set `GRAB_RENAME_MOVIE_VERSION=false` to opt out entirely. `tagarr_migrate.sh` removes the two old vars on config version bump 1.5 → 1.6.

### Changed (tagarr_import.sh)

- **Audio-codec tokens removed from grab-rename trigger list.** Previously `ENABLE_GRAB_RENAME` forced a rename when the grab title carried TrueHD / Atmos / DTS-X / DTS-HD MA but the torrent name didn't. These are MediaInfo-derivable — Radarr reads the audio format directly from the file on import, so chasing them via rename was cosmetic only and violated the design principle that grab-rename should recover **only** tokens Radarr can't reconstruct from the file. Real-world trigger: a Mission: Impossible grab with `TrueHD5.1` (no separator) — the `\btruehd\b` word-boundary regex didn't match the concatenated form, rename fired unnecessarily, Discord notification spam. Audio filtering in `check_audio_match()` is unchanged — that path still scans the filename and tags correctly.

- **Discord grab-rename card cleaned up.** Previously two inline fields — "Quality Recovered" (source + IMAX/Open Matte) and "Audio Recovered" (TrueHD/Atmos/DTS-X/DTS-HD MA). After the audio-token removal the Audio field became dead, and the Quality field's `case` filter silently dropped every new Movie Version token added in this release (Director's Cut, Theatrical, Extended, Remaster, Criterion, ...) since they weren't on the allowlist. Both fields replaced by a single **"Tokens Recovered"** field that lists every non-group token that triggered the rename, so the notification always reflects the actual reason — whether that's `Director's Cut`, `IMAX`, `WEB-DL`, or multiple. "Release Group Recovered" remains its own field, so group vs. other-tokens are still distinguishable.

### Changed (tagarr_import.conf.sample)

- **Config version bumped 1.5 → 1.6.** Triggers one-time migration for existing users:
    - Adds `GRAB_RENAME_MOVIE_VERSION=true` to every config.
    - Keeps `GRAB_RENAME_IMAX` and `GRAB_RENAME_OPEN_MATTE` as commented-out backward-compat stubs — `tagarr_migrate.sh` preserves the user's value if set, so users whose config migrates to v1.6 before their script updates to v1.6.0 don't silently lose IMAX/Open Matte rename. The v1.6.0 script ignores those fields entirely; they exist purely as a bridge and will be removed in v1.7 once all deployments have caught up.
    - `CUSTOM_TOKENS` section reframed as an advanced escape hatch with realistic non-Movie-Version examples (`NORDIC`, `MULTi`, `iNTERNAL`). Previous examples (`Remaster`, `Criterion`) are now built-in and no longer need to be configured manually.

## v2.7.0 — 2026-04-18

### Added (tagarr.sh)

- **`--discover-clean` trigger.** Runs the same library scan as `--discover` but writes a clean report to `logs/tagarr_discovery_report.log` instead of modifying the config. The report includes a summary, per-movie detail table, and a ready-to-paste `RELEASE_GROUPS` array with filter-based comments and movie counts. Treats the config as empty — discovers everything matching your filters, including groups already configured. Config is never touched.

### Changed

- **Backups now go to `tagarr_backups/` folder** with date stamps instead of `.old` files in the main directory (tagarr_migrate.sh).
- **Connect event names** corrected in both import scripts to match Radarr/Sonarr UI.
- **Config sample bumped to v1.5** (tagarr_import.conf.sample) — distributes QBIT_CLIENTS docs, custom tokens cleanup, Qui proxy instructions.
- **Script descriptions** in tagarr_migrate.conf.sample corrected to match actual script purposes.

### Added (documentation)

- **Migration & Auto-Update Guide** (`docs/tagarr-migrate-guide.md`)
- **QBIT_CLIENTS Setup section** in Import Guide with step-by-step + Qui proxy
- **README** updated with migrate guide link

## v2.6.0 — 2026-04-17

### Fixed (tagarr_import.sh v1.5.8)

- **Single qBit users no longer need to match the download client name exactly.** When `QBIT_CLIENTS` has only one entry and the name doesn't match what Radarr reports, the script now uses that URL anyway (with an info log) instead of skipping with "not in QBIT_CLIENTS map". Users with multiple qBit instances still need names to match for correct routing. This was the root cause of a user-reported grab-rename failure — their Radarr client was named `qBittorrent` but the sample config defaulted to `qBit-movies`.

### Changed (tagarr_import.conf.sample)

- **Rewrote QBIT_CLIENTS documentation for clarity.** Now has step-by-step instructions ("1. Open Radarr, 2. Find the Name, 3. Use it here, 4. Put your URL"). Concrete example with realistic IP. Clear explanation of single vs multiple qBit behavior. Default example changed from `qBit-movies` to `qBittorrent` to match the most common Radarr setup.

### Changed (tagarr_migrate.conf.sample)

- **Complete rewrite of config documentation for accessibility.** Removed jargon ("mental model", "sort -V gate", `AUTOUPDATE_<SCRIPT>` placeholder notation). Replaced with plain-language sections: Quick start (4 steps), What about configs, Scripts in a different folder (with concrete example), Requirements. Config version stays at 1.2 — no structural change, only documentation.

## v2.5.5 — 2026-04-17

### Fixed (tagarr_migrate.sh)

- **Duplicated settings in `tagarr_migrate.conf` after v1.0 → v1.1 migration.** The regex that discovers commented-out variable placeholders in the sample (`^[[:space:]]*#?[[:space:]]*([A-Z_]+)=`) used `[[:space:]]*` (zero-or-more) between the `#` and the variable name. This matched documentation **examples** deep inside the sample (e.g. `#        AUTOUPDATE_TAGARR_IMPORT=true` with 8-space indent), treating them as real variable slots. Each example occurrence generated an extra copy of the user's active value in the migrated output. Tightened to `[[:space:]]?` (zero-or-one), so only first-column `#VAR=` and `# VAR=` forms match — not indented examples. Config version bumped to 1.2 to trigger a clean re-migration for users whose v1.1 files have duplicates.

## v2.5.4 — 2026-04-17

### Changed (tagarr_migrate.conf.sample)

- **Config version bumped 1.0 → 1.1** to distribute the expanded documentation that landed in v2.5.0 (four usage scenarios, the "one path per script" mental model, explicit DIR semantics, rollback instructions). Docs were added to the sample without bumping the version, so migrate correctly short-circuited at "already up to date" and never re-wrote the file — users who created their `tagarr_migrate.conf` before v2.5.0 had no way to see the new docs short of re-downloading the sample manually. Bump triggers one-time migration for existing users; the v2.5.1 commented-var logic preserves active `AUTOUPDATE_*=true` and `AUTOUPDATE_*_DIR` values through the rewrite. Previous config content is backed up to `tagarr_migrate.conf.old`.

## v2.5.3 — 2026-04-17

### Changed (tagarr_migrate.sh)

- **Per-config log lines for `already up to date` and download-failure cases.** v2.5.2 only logged configs that were actually migrated — a no-op run left users wondering whether each config had been scanned and evaluated, or silently skipped. Reports from the field confirmed the terseness was confusing: "migrate isn't updating tagarr_migrate.conf" when in fact it was checking it every run and correctly leaving it alone. Now every config in the scan list generates a log line: `config current:`, `config migrated:`, or `config FAILED:`. Each line includes the basename, version, and full path so users can trace exactly what was processed where. The `configs: N scanned across M dir(s)` summary is kept for at-a-glance totals. Script auto-update summary (`scripts: N updated, ...`) unchanged — its counts remain the primary signal for that side.

## v2.5.2 — 2026-04-16

### Added (tagarr_migrate.sh)

- **Logging to `logs/tagarr_migrate.log`** — event-based, minimal, audit-friendly. Writes timestamped entries for: migrate self-update, per-script auto-updates (success + failure with reason), script-update summary (counts of updated / current / failed), per-config migration (with version-from-to), per-run totals (`run start` / `configs: N scanned across M dir(s)` / `run complete`). Deliberately does NOT log per-script "already current" or per-config "already up to date" — a no-op run is 4 lines, a real-work run adds one line per actual change. Rotates at 2 MiB (one `.old` backup, matches the pattern used by `tagarr.sh` and `tagarr_import.sh`). Failure-tolerant: if the log dir isn't writable, log calls silently skip — never aborts the script. Makes cron-based migrate invocations auditable without requiring users to pipe stdout themselves.

## v2.5.1 — 2026-04-16

### Fixed (tagarr_migrate.sh)

- **Config migration now preserves uncommented settings when the sample has them commented out.** The scalar-variable discovery in the migration engine matched only uncommented lines (`^VAR=...`). Because `tagarr_migrate.conf.sample` keeps all its `AUTOUPDATE_*` slots commented by design (opt-in), a future Config-version bump of that sample would have silently reverted every user's active `AUTOUPDATE_*=true` flag back to commented default — scalar-discovery wouldn't have registered the var names, so the substitution pass would write the sample out verbatim. Latent bug — didn't trigger yet because the sample has stayed on `# Config version: 1.0`. Fixed by allowing the scalar-var discovery and substitution regexes to match commented-out placeholders (`^[[:space:]]*#?[[:space:]]*([A-Z_]+)=`). When the user has the var uncommented in their config, migrate writes it uncommented; when the user doesn't have it set, the sample's line (commented or not) is kept verbatim. Only counts as a "new setting added" in the summary when the sample's line is uncommented — commented opt-in slots aren't announced as new features each time a user runs migrate. No behavior change for configs whose samples are fully uncommented (tagarr, tagarr_import, tagarr_recover, etc.) — the optional `#?` matches zero `#` in those.

### Added (tagarr_migrate.sh)

- **Secondary sanity check on downloaded scripts.** In addition to the `^#!` shebang check, the auto-update download path now requires a `^SCRIPT_VERSION=` marker. Every script in `versions.json` ships with this line — absence means GitHub returned something unexpected (wrong branch, partial response, or worse). Protects against an auto-update writing a misconfigured file on top of a working one. Existing shebang check stays as the first line of defense.

### Changed (tagarr_migrate.sh)

- **`versions.json` fetch timeout raised from 5s to 10s.** More forgiving on slow connections. Script-download calls already use the default curl timeout, which is generous.

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
