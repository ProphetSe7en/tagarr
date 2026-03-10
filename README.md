# Tagarr

Automated movie tagging for [Radarr](https://radarr.video/) based on release groups.

## What Does This Do?

When you download movies through Radarr, each release comes from a **release group** (like FLUX, BHD, FraMeSToR, etc.). Some groups consistently deliver premium quality — lossless audio (TrueHD Atmos, DTS:X), high-bitrate encodes, or WEB-DLs from premium sources like Movies Anywhere.

Tagarr automatically **tags movies in Radarr** based on which release group made the file. This lets you:

- **Build smart collections** — filter your library by release group quality
- **Track what you have** — see at a glance which movies came from premium groups
- **Filter with quality gates** — only tag releases that meet your audio/video standards
- **Discover new groups** — automatically find groups you haven't seen before that pass your filters
- **Sync across instances** — mirror tags between HD and 4K Radarr

### Example

You configure Tagarr with the release group FLUX in `filtered` mode. Tagarr scans your library and finds:

| Movie | Release Group | Source | Audio | Result |
|-------|--------------|--------|-------|--------|
| Inception.2010.MA.WEB-DL.TrueHD.Atmos-FLUX | FLUX | MA WEB-DL | TrueHD Atmos | Tagged `flux` |
| Dune.2021.AMZN.WEB-DL.AAC-FLUX | FLUX | Amazon WEB-DL | AAC | **Not tagged** (fails audio filter) |
| Oppenheimer.2023.BluRay.Remux.TrueHD.Atmos-FraMeSToR | FraMeSToR | BluRay | TrueHD Atmos | **Not tagged** (different group) |

The `flux` tag appears in Radarr and you can use it in filters, collections, or custom formats.

> **Warning:** These scripts modify Radarr metadata (tags, release groups) and
> can trigger file renames. Always run in dry-run mode first and review the
> output before using `--live`. The authors are not responsible for any data
> loss, incorrect tagging, or file renaming caused by misconfiguration or bugs.
> Use at your own risk.

---

## Getting Started

### 1. Install

```bash
git clone https://github.com/prophetse7en/tagarr.git
cd tagarr
chmod +x tagarr*.sh
```

**Requirements:** Radarr v3+, bash 4+, jq, curl

### 2. Configure

```bash
cp tagarr.conf.sample tagarr.conf
nano tagarr.conf
```

Fill in three things:

```bash
# Your Radarr URL and API key (Settings > General in Radarr)
PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="your-api-key-here"

# Release groups you want to tag
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"       # Only tag if quality+audio filters pass
    "sparks:sparks:SPARKS:simple"   # Tag all releases from this group
)
```

Each release group entry has 4 fields separated by `:` — `search_string:tag_name:display_name:mode`

| Mode | Behavior |
|------|----------|
| `filtered` | Only tags if the release also passes your quality and audio filters (MA/Play WEB-DL + lossless audio) |
| `simple` | Tags every release from this group regardless of quality |

### 3. Test with Dry-Run

```bash
# See what would be tagged — no changes are made
./tagarr.sh --dry-run
```

Review the output. If it looks right:

```bash
# Apply the tags
./tagarr.sh
```

### 4. Set Up Automatic Tagging (Optional)

For new downloads to be tagged automatically, set up `tagarr_import.sh` as a Radarr Connect script:

1. Copy config: `cp tagarr_import.conf.sample tagarr_import.conf` and fill in your values
2. In Radarr: Settings > Connect > + > **Custom Script**
3. Path: full path to `tagarr_import.sh`
4. Events: **On Download**, **On Upgrade**, **On File Delete**

Now every new import is tagged instantly. Run `tagarr.sh` on a schedule (cron, Cronicle, etc.) as a catch-up for anything missed.

---

## Scripts

| Script | What It Does | When to Use |
|--------|-------------|-------------|
| `tagarr.sh` | Scans all movies, tags by release group | Schedule daily/weekly or run manually |
| `tagarr_import.sh` | Tags one movie on import/upgrade/delete | Radarr Connect (automatic) |
| `tagarr_recover.sh` | Fixes missing release groups from grab history | When Radarr lost the release group on import |
| `tagarr_list.sh` | Tags movies from TMDb/Trakt lists | Curated collections (awards, directors, etc.) |
| `tagarr_remove.sh` | Removes tags from all movies | Cleanup old/unwanted tags |
| `tagarr_rename.sh` | Renames tags (old→new, migrates movies) | Rename a tag without losing assignments |

All scripts default to **dry-run mode** — no changes are made until you pass `--live`.

---

## Configuration Reference

Each script has its own `.conf` file. Copy the `.conf.sample` and edit it — every option is documented inside the sample file.

### Dual Instance Support

If you run two Radarr instances (e.g., HD + 4K), tags are automatically synced from primary to secondary for movies that exist in both (matched by TMDb ID):

```bash
ENABLE_SYNC_TO_SECONDARY=true
SECONDARY_RADARR_URL="http://localhost:7979"
SECONDARY_RADARR_API_KEY="your-api-key-here"
SECONDARY_RADARR_NAME="Radarr 4K"
```

### Release Group Format

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"       # search_string:tag_name:display_name:mode
    "btbn:btbn:BTBN:filtered"
    "sic:sic:SiC:simple"
    #"rejected:rejected:Rejected:filtered"   # Commented = known but not tagged
)
```

- **search_string** — matched against Radarr's releaseGroup field (case-insensitive, word boundary)
- **tag_name** — the tag created in Radarr (lowercase, no spaces)
- **display_name** — shown in logs and Discord notifications
- **mode** — `filtered` (must pass quality + audio filters) or `simple` (tag everything from this group)

Commented entries are tracked so discovery won't re-suggest groups you've already reviewed.

### Quality and Audio Filters

These only apply to `filtered` mode groups. Enable the sources and codecs you consider premium:

```bash
# Quality sources (WEB-DL origin)
ENABLE_QUALITY_FILTER=true
ENABLE_MA_WEBDL=true       # Movies Anywhere
ENABLE_PLAY_WEBDL=true     # Google Play

# Lossless audio codecs
ENABLE_AUDIO_FILTER=true
ENABLE_TRUEHD_ATMOS=true   # Dolby TrueHD Atmos
ENABLE_TRUEHD=true         # Dolby TrueHD (without Atmos)
ENABLE_DTS_X=true          # DTS:X
ENABLE_DTS_HD_MA=true      # DTS-HD Master Audio
```

Transcoded or upmixed audio is automatically rejected.

### Discord and Logging

```bash
DISCORD_ENABLED=true
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your-webhook-url"

ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr.log"   # Auto-rotated at 2 MiB
```

---

## Script Details

### tagarr.sh — Batch Tagger

Scans your entire library and tags movies by release group. Run on a schedule as a catch-up for anything the event-driven tagger missed.

```bash
./tagarr.sh --dry-run          # Preview changes (safe)
./tagarr.sh                    # Apply tags
./tagarr.sh --discover         # Only scan for new groups, no tagging
./tagarr.sh --tag flux,sic     # Only process specific groups
```

### tagarr_import.sh — Event-Driven Tagger

Runs automatically via Radarr Connect on every download, upgrade, or file delete. Tags the movie instantly using the same filters as `tagarr.sh`.

**Setup:** Radarr > Settings > Connect > Custom Script > path to `tagarr_import.sh` > Events: On Download, On Upgrade, On File Delete

Extra features beyond `tagarr.sh`:
- **Release group recovery** — fixes missing groups from grab history before tagging
- **Auto-tag discovery** — optionally adds new groups as active (no manual review needed)
- **File delete cleanup** — removes all managed tags when a movie file is deleted

Uses its own config file (`tagarr_import.conf`), separate from `tagarr.conf`.

### tagarr_recover.sh — Release Group Recovery

Fixes movies where Radarr lost the release group during import. This happens when the group name is in the indexer title but not in the actual filename inside the torrent.

The script checks grab history, verifies the correct group through a 5-point safety chain (blank-only, filename cross-check, import-verified grab, non-empty, title+year match), and patches it back.

```bash
./tagarr_recover.sh                    # Preview all (dry-run)
./tagarr_recover.sh --movie 123        # Preview one movie
./tagarr_recover.sh --movie 123 --live # Fix one movie
./tagarr_recover.sh --live             # Fix all
```

### tagarr_list.sh — List-Based Tagger

Tags movies from TMDb or Trakt lists. Useful for curated collections (Reference Audio, Oscar Winners, director filmographies, etc.).

```bash
# In tagarr_list.conf:
LISTS=(
    "tmdb:12345:ref-audio:Reference Audio"
    "trakt:user/list-slug:oscar-winners:Oscar Winners"
)
```

### tagarr_remove.sh / tagarr_rename.sh — Tag Management

Bulk remove or rename tags across one or both instances. Both default to dry-run.

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
