# Tagarr

A collection of bash scripts for automated movie tagging in [Radarr](https://radarr.video/).

Tag movies by release group with quality and audio filtering, sync tags across
dual Radarr instances, discover new release groups automatically, tag from
TMDb/Trakt lists, and recover missing release groups from grab history.

> **Warning:** These scripts modify Radarr metadata (tags, release groups) and
> can trigger file renames. Always run in dry-run mode first and review the
> output before using `--live`. The authors are not responsible for any data
> loss, incorrect tagging, or file renaming caused by misconfiguration or bugs.
> Use at your own risk.

---

## Scripts

| Script | Purpose | Trigger |
|--------|---------|---------|
| `tagarr.sh` | Batch tagger — scans all movies | Cron / manual |
| `tagarr_import.sh` | Event-driven tagger — processes one movie | Radarr Connect |
| `tagarr_recover.sh` | Release group recovery from grab history | Manual |
| `tagarr_list.sh` | Tag from TMDb/Trakt lists | Manual |
| `tagarr_remove.sh` | Bulk tag removal | Manual |
| `tagarr_rename.sh` | Bulk tag rename | Manual |

All scripts default to **dry-run mode** — no changes are made until you
explicitly use `--live`.

---

## Requirements

- **Radarr** v3+ (uses API v3)
- **bash** 4+
- **jq** (JSON processing)
- **curl** (API calls)
- **grep**, **sed**, **awk** (text processing)

---

## Installation

```bash
# Clone the repository
git clone https://github.com/prophetse7en/tagarr.git
cd tagarr

# Copy sample configs and fill in your values
cp tagarr.conf.sample tagarr.conf
cp tagarr_import.conf.sample tagarr_import.conf
# ... repeat for any other scripts you want to use

# Make scripts executable (should already be, but just in case)
chmod +x tagarr*.sh

# Edit your config with API keys, URLs, and release groups
nano tagarr.conf
```

---

## Quick Start

```bash
# 1. Configure your Radarr URL and API key in tagarr.conf

# 2. Dry-run — see what would be tagged (no changes)
./tagarr.sh --dry-run

# 3. Discovery — find release groups passing your filters
./tagarr.sh --discover

# 4. Review discovered groups in your config, uncomment to activate

# 5. Live run — apply tags
./tagarr.sh
```

---

## Configuration

Each script has its own `.conf` file. Copy the `.conf.sample` and fill in
your values. The sample files contain descriptions for every option.

### Radarr Connection

All configs require at minimum:

```bash
PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="your-api-key-here"
PRIMARY_RADARR_NAME="Radarr"
```

Find your API key in Radarr under Settings > General.

### Dual Instance Support

All scripts support a secondary Radarr instance. Tags are synced from
primary to secondary for movies that exist in both (matched by TMDb ID).

```bash
ENABLE_SYNC_TO_SECONDARY=true
SECONDARY_RADARR_URL="http://localhost:7979"
SECONDARY_RADARR_API_KEY="your-api-key-here"
SECONDARY_RADARR_NAME="Radarr 4K"
```

### Release Groups

Used by `tagarr.sh` and `tagarr_import.sh`. Each entry defines a release
group to tag:

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "btbn:btbn:BTBN:filtered"
    "sic:sic:SiC:simple"
)
```

| Field | Description |
|-------|-------------|
| `search_string` | Lowercase string matched against releaseGroup (word boundary) |
| `tag_name` | Tag label created in Radarr (lowercase, no spaces) |
| `display_name` | Human-readable name for logs and Discord |
| `mode` | `filtered` = require quality+audio match; `simple` = tag any match |

Commented entries (`#"group:..."`) are ignored for tagging but counted as
"known" by discovery, preventing re-discovery of groups already reviewed.

### Quality Filters

When `ENABLE_QUALITY_FILTER=true`, `filtered` mode groups only tag movies
whose filename contains one of the enabled quality sources:

| Toggle | Matches |
|--------|---------|
| `ENABLE_MA_WEBDL` | Movies Anywhere WEB-DL |
| `ENABLE_PLAY_WEBDL` | Google Play WEB-DL |

Supports both standard dot naming (`MA.WEBDL-2160p`) and bracket naming
(`[MA][WEBDL-2160p]`).

### Audio Filters

When `ENABLE_AUDIO_FILTER=true`, `filtered` mode groups only tag movies
whose filename contains one of the enabled lossless audio codecs:

| Toggle | Matches |
|--------|---------|
| `ENABLE_TRUEHD` | Dolby TrueHD (without Atmos) |
| `ENABLE_TRUEHD_ATMOS` | Dolby TrueHD Atmos |
| `ENABLE_DTS_X` | DTS:X |
| `ENABLE_DTS_HD_MA` | DTS-HD Master Audio |

Transcoded or upmixed audio is automatically rejected (`upmix`, `encode`,
`transcode`, etc.).

### Discord Notifications

All scripts support Discord webhook notifications with embeds:

```bash
DISCORD_ENABLED=true
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your-webhook-url"
```

### Logging

All scripts write to log files with automatic rotation at 2 MiB:

```bash
ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr.log"
```

---

## Script Details

### tagarr.sh — Batch Tagger

Scans all movies in Radarr and tags them by release group. Intended for
scheduled runs (cron, Cronicle, etc.) to catch up on any movies that
were missed by the event-driven tagger.

**Features:**
- Tag movies by release group with quality + audio filtering
- Lazy tag creation — tags only created when a movie actually matches
- Tag removal when movies no longer match criteria
- Sync tags to secondary Radarr instance
- Discovery — auto-detect unknown groups passing all filters
- Cleanup — remove tags with 0 movies at end of run
- Debug mode — detailed per-movie filter breakdown

**Flags:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Simulate all changes without modifying Radarr |
| `--tag NAME` | Only process specific tags (comma-separated) |
| `--discover` | Discovery-only mode — scan for new groups, no tagging |
| `--help` | Show usage information |

---

### tagarr_import.sh — Event-Driven Tagger

Radarr Connect handler that processes individual movies on import, upgrade,
or file delete. Uses the same release group + quality + audio filtering as
`tagarr.sh` but runs per-event instead of scanning all movies.

**Features:**
- Tags individual movies on Download / Upgrade / File Delete events
- Release group recovery from grab history (`ENABLE_RECOVER`) — fixes missing
  release groups inline before tagging, triggers rename, shows before/after
  filename in Discord
- Auto-tag discovery (`AUTO_TAG_DISCOVERED`) — new groups are added to config
  as active entries and the triggering movie is tagged immediately
- Syncs tags to secondary Radarr instance
- Discovery — unknown groups written to config (commented or active)
- Smart notifications — only sends Discord when tagged, discovered, or fixed
- File delete cleanup — removes all managed tags when a file is deleted

**Setup in Radarr:**
1. Settings > Connect > + > Custom Script
2. Path: point to `tagarr_import.sh`
3. Events: On Download, On Upgrade, On File Delete

**Note:** `tagarr_import.conf` is separate from `tagarr.conf`. Both configs
can have different release groups, webhooks, and filter settings.

---

### tagarr_recover.sh — Release Group Recovery

Some release groups (e.g., `126811`) include the group name in the indexer
release title but NOT in the actual filename inside the torrent. When Radarr
imports, it re-parses from the filename and loses the release group. The
grab history still has the correct data.

This script scans movies with missing release groups, verifies the correct
group from grab history, and patches it into Radarr's moviefile metadata.
The script does NOT rename files itself — it sends a `RenameFiles` command
to Radarr, which handles the actual rename according to your naming format.

This same recovery logic is also built into `tagarr_import.sh` so new
imports are fixed automatically before tagging proceeds.

**Safety chain:**

The script uses a 5-point safety chain to prevent incorrect fixes:

1. **Blanks only** — never overwrites an existing release group
2. **Filename check** — parses the actual filename for an existing release
   group. If one is found but Radarr has none, the movie is flagged for
   manual review instead of fixed
3. **Import-verified grab** — walks all history events and only uses grabs
   that were followed by a successful import. Skips failed downloads to
   prevent wrong group assignment
4. **Non-empty** — release group from history must have a value
5. **Title+year match** — grab sourceTitle must match the movie's title or year

**Flags:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview what would be fixed (default) |
| `--live` | Execute the fixes |
| `--instance TYPE` | `primary`, `secondary`, or `both` (default: both) |
| `--movie ID` | Process a single movie by Radarr movie ID |
| `--no-rename` | Skip file rename even in live mode |
| `--help` | Show usage information |

**Usage:**

```bash
# Preview all affected movies (default)
./tagarr_recover.sh

# Test on a single movie
./tagarr_recover.sh --movie 123

# Fix a single movie (live)
./tagarr_recover.sh --movie 123 --live

# Fix all affected movies
./tagarr_recover.sh --live

# Fix without renaming files
./tagarr_recover.sh --live --no-rename
```

---

### tagarr_list.sh — List-Based Tagger

Tags movies based on external lists from TMDb or Trakt. Matches list entries
against existing Radarr movies by TMDb ID. Optionally adds missing movies.

**Features:**
- Fetch movie lists from TMDb and Trakt APIs
- Tag existing Radarr movies that appear on configured lists
- Optionally add missing movies to Radarr (monitored or unmonitored)
- Sync tags to secondary Radarr instance
- Bulk API operations via `/movie/editor`

**Use cases:**
- Curated collections (Reference Audio, Reference Video)
- Awards lists (Oscar Winners, IMDb Top 250)
- Director/Actor filmographies
- Trakt community lists

**List configuration:**

```bash
LISTS=(
    "tmdb:LIST_ID:tag-name:Display Name"
    "trakt:user/list-slug:tag-name:Display Name"
)
```

| Field | Description |
|-------|-------------|
| `provider` | `tmdb` or `trakt` |
| `list_id` | TMDb numeric ID or Trakt `user/list-slug` |
| `tag_name` | Tag label created in Radarr (lowercase, no spaces) |
| `display_name` | Human-readable name for logs |

Requires `TMDB_API_KEY` and/or `TRAKT_CLIENT_ID` depending on which
providers you use.

**Flags:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview mode (default) |
| `--live` | Execute tagging and additions |

---

### tagarr_remove.sh — Bulk Tag Removal

Removes specified tags from all movies across one or two Radarr instances.
Optionally deletes the tag definitions from Radarr.

```bash
TAGS_TO_REMOVE=(
    "old-tag-name"
    "another-tag"
)
```

**Flags:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview mode (default) |
| `--live` | Execute removals |

---

### tagarr_rename.sh — Bulk Tag Rename

Renames tags by creating a new tag, migrating all movies, and removing the
old tag. Three-step process: create new, migrate, remove old.

```bash
TAG_RENAMES=(
    "old-name:new-name"
)
```

**Flags:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview mode (default) |
| `--live` | Execute renames |

---

## Discovery

When enabled in `tagarr.sh` or `tagarr_import.sh`, movies whose release
group is not in `RELEASE_GROUPS` (active or commented) are checked against
your quality + audio filters. Groups where both filters pass are written
to your config as commented entries:

```bash
    #"newgroup:newgroup:NewGroup:filtered"    # Discovered 2026-02-17: MA WEB-DL + TrueHD Atmos
```

**Manual review workflow (default):**
1. Enable discovery: `ENABLE_DISCOVERY=true`
2. Run `./tagarr.sh --discover` or wait for events via `tagarr_import.sh`
3. Review discovered groups in your config file
4. Uncomment groups you want to activate
5. Run `./tagarr.sh` to tag movies with the new groups

**Auto-tag workflow (`tagarr_import.sh` only):**
1. Set `AUTO_TAG_DISCOVERED=true` in `tagarr_import.conf`
2. Discovered groups are added as active entries (without `#`) and the
   triggering movie is tagged immediately — no manual step needed
3. All future imports with the same group are tagged automatically

Groups that appear in the config (active or commented) are never
re-discovered, so you can leave rejected groups commented as a record.

---

## Testing

`test_filters.sh` validates the quality and audio filter functions against
112 test filenames:
- 52 standard dot-separated naming patterns
- 52 bracket-style naming patterns
- 8 false positive checks

```bash
./test_filters.sh
```

---

## File Overview

| File | Description |
|------|-------------|
| `tagarr.sh` | Batch tagger (scheduled) |
| `tagarr_import.sh` | Event-driven tagger (Radarr Connect) |
| `tagarr_recover.sh` | Release group recovery from grab history |
| `tagarr_list.sh` | List-based tagger (TMDb/Trakt) |
| `tagarr_remove.sh` | Bulk tag removal |
| `tagarr_rename.sh` | Bulk tag rename |
| `tagarr.conf.sample` | Sample config for tagarr.sh |
| `tagarr_import.conf.sample` | Sample config for tagarr_import.sh |
| `tagarr_recover.conf.sample` | Sample config for tagarr_recover.sh |
| `tagarr_list.conf.sample` | Sample config for tagarr_list.sh |
| `tagarr_remove.conf.sample` | Sample config for tagarr_remove.sh |
| `tagarr_rename.conf.sample` | Sample config for tagarr_rename.sh |
| `test_filters.sh` | Filter validation (112 test cases) |
| `CHANGELOG.md` | Version history |
| `LICENSE` | MIT License |

---

## License

[MIT](LICENSE)
