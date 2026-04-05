# Tagarr Guide — Batch Release Group Tagger for Radarr

Complete guide for `tagarr.sh` — what it does, how it works, and every configuration option explained.

For the other scripts in the toolset (import, recover, list, remove, rename), see [README.md](../README.md).

---

## What is Tagarr?

Tagarr scans your Radarr library and **tags movies based on which release group made the file**. A release group is the team that encoded or captured the release — names like FLUX, FraMeSToR, BHDStudio, SiC, etc. that appear at the end of filenames after a hyphen (e.g., `Movie.2024.1080p.WEB-DL-FLUX`).

Not all releases from a given group are equal. The same group might release:
- A premium **MA WEB-DL** with **TrueHD Atmos** audio (lossless, studio master)
- A basic **AMZN WEB-DL** with **EAC3** audio (lossy, compressed)

Tagarr lets you tag only the premium releases — the ones that pass your quality and audio filters — so your tags actually mean something.

---

## Prerequisites

- **Radarr v3+** with API access enabled (Settings > General > API Key)
- **bash 4+**, **jq**, and **curl** installed on the machine running the script
- The script must be executable: `chmod +x tagarr.sh`

### Setup

```bash
# Copy the sample config
cp tagarr.conf.sample tagarr.conf

# Edit with your Radarr URL, API key, and release groups
nano tagarr.conf
```

The config file must be in the same directory as the script and named `tagarr.conf` (without `.sample`). Every option is documented inside the sample file, and explained in detail in the [Configuration Reference](#configuration-reference) below.

---

## Why Tag by Release Group?

Tags in Radarr are metadata labels you can use for:

- **Quality profiles** — assign different quality cutoffs per tag (e.g., don't upgrade movies already tagged as premium)
- **Custom Formats** — score movies higher or lower based on tags
- **Filtering** — quickly find all movies from a specific group in Radarr's UI
- **Collections** — build Plex/Jellyfin collections from Radarr tags (via Kometa/DAPS)
- **Tracking** — see at a glance how many premium releases you have vs standard ones

Without Tagarr, you would need to manually check each movie's file details to know which release group it came from and whether it meets your quality standards.

---

## How It Works

When you run `tagarr.sh`, this is what happens step by step:

1. **Connect** — Verifies that Radarr (and optionally a secondary instance) is reachable
2. **Fetch** — Downloads the full movie list from Radarr's API (all movies with files)
3. **Resolve tags** — Looks up existing tags in Radarr, notes which ones need to be created
4. **Scan every movie** — For each movie with a file:
   - Reads the release group, scene name, and filename from Radarr
   - For each release group in your config: checks if the movie matches, applies quality and audio filters if configured, and decides whether to add, keep, or remove the tag
   - Optionally checks for release groups not in your config (discovery — see [Discovery](#discovery))
5. **Apply changes** — Batch-adds and batch-removes tags via Radarr's API
6. **Sync to secondary** — If enabled, mirrors all tag decisions to a second Radarr instance (matched by TMDb ID)
7. **Cleanup** — Optionally deletes tags that have 0 movies assigned
8. **Notify** — Sends summary, tagged/untagged lists, and discovery results to Discord

The entire scan is a single pass over all movies. Tags are applied in bulk at the end for efficiency.

---

## Use Cases

The examples below use config entries in this format — four fields separated by colons:

```
"search_string:tag_name:display_name:mode"
```

- **search_string** — text to match against the movie's release group (matched as a whole word, so `sic` matches "SiC" but not "Jurassic")
- **tag_name** — the tag created in Radarr (lowercase, no spaces)
- **display_name** — human-readable name for logs and Discord
- **mode** — `filtered` (must pass quality + audio filters) or `simple` (tag every match)

Each field is explained in full detail in the [Configuration Reference](#release-groups) below.

### 1. Tag per group — track what you have

The simplest setup. Each release group gets its own tag in Radarr. You can see at a glance which movies came from FLUX, which from SiC, etc.

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "sic:sic:SiC:filtered"
    "thefarm:thefarm:TheFarm:filtered"
)
```

This creates three tags in Radarr: `flux`, `sic`, `thefarm`. Use them to filter your library, build collections in Plex/Jellyfin (via Kometa/DAPS), or just keep track of where your releases came from.

### 2. Shared tag — one tag for all premium releases

Multiple groups can share the same `tag_name`. Instead of managing five separate tags downstream, you get one tag that means "this movie is premium quality."

```bash
RELEASE_GROUPS=(
    "flux:premium:FLUX:filtered"
    "sic:premium:SiC:filtered"
    "thefarm:premium:TheFarm:filtered"
    "126811:premium:126811:filtered"
    "xebec:premium:XEBEC:filtered"
)
```

All five groups produce the same `premium` tag in Radarr. This simplifies everything that uses tags:
- **Quality profiles** — one tag to check instead of five
- **Custom Formats** — one CF condition instead of five
- **Maintainerr rules** — one tag to match

When you discover a new group and add it to the config, it automatically gets the same `premium` tag — no need to update quality profiles, custom formats, or automation rules.

You can also **combine both approaches** — give each movie a group-specific tag AND a shared tag by duplicating the search string with different tag names:

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "flux:premium:FLUX:filtered"
    "sic:sic:SiC:filtered"
    "sic:premium:SiC:filtered"
)
```

A FLUX movie gets both the `flux` tag (for tracking which group it came from) and the `premium` tag (for quality profiles and automation). The script processes each entry independently — the same movie is matched twice and both tags are applied.

### 3. Remux cleanup — free space without losing quality

This is for setups with two Radarr instances — typically one for WEB-DL and one for remuxes (or 4K remuxes). The problem: remuxes are large (40-80 GB each), and many of them have the same lossless audio track as a much smaller MA/Play WEB-DL (10-20 GB).

With secondary sync enabled, Tagarr mirrors tags to both instances. When a movie is tagged in your WEB-DL instance, the same tag appears in your remux instance — telling you "this movie exists as a premium WEB-DL with lossless audio, so the remux is redundant."

```bash
# In tagarr.conf:
ENABLE_SYNC_TO_SECONDARY=true
SECONDARY_RADARR_URL="http://localhost:7979"    # Remux instance
SECONDARY_RADARR_API_KEY="..."
SECONDARY_RADARR_NAME="Radarr Remux"

RELEASE_GROUPS=(
    "flux:lossless-webdl:FLUX:filtered"
    "sic:lossless-webdl:SiC:filtered"
    "thefarm:lossless-webdl:TheFarm:filtered"
)
```

Now in your remux instance, movies with the `lossless-webdl` tag can safely be cleaned up — you already have a lossless audio version in a smaller file. Automate this with [Maintainerr](https://github.com/jorenn92/Maintainerr): create a rule that targets movies with this tag and adds them to a cleanup collection.

The savings add up quickly. If you have 100 remuxes that also exist as premium WEB-DLs, that's potentially 3-6 TB of storage freed — without losing audio quality.

### 4. Discovery — find new premium groups

Enable discovery and Tagarr will check every movie whose release group is not in your config. If the release passes both your quality and audio filters, the group is flagged as "discovered" and written to your config for review.

This is how you find groups you didn't know about. You set your quality bar (MA/Play WEB-DL + lossless audio), and Tagarr tells you which groups consistently meet it.

```bash
ENABLE_DISCOVERY=true
```

Discovery works in both `tagarr.sh` (batch scan) and `tagarr_import.sh` (per-import). New groups appear as commented entries in your config — uncomment the ones you want to tag.

---

## Configuration Reference

Every option in `tagarr.conf` explained in detail.

### Primary Radarr

```bash
PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="your-api-key-here"
PRIMARY_RADARR_NAME="Radarr"
```

| Option | Description |
|--------|-------------|
| `PRIMARY_RADARR_URL` | Full URL to your Radarr instance, including port. No trailing slash. If Radarr runs on the same machine, use `http://localhost:7878`. If on a different machine or behind a reverse proxy, use the appropriate URL. |
| `PRIMARY_RADARR_API_KEY` | Your Radarr API key. Find it in Radarr under Settings > General > API Key. This is a 32-character hex string. |
| `PRIMARY_RADARR_NAME` | A display name for this instance, used in logs and Discord notifications. Can be anything — "Radarr", "Radarr HD", "Movies", etc. |

### Secondary Radarr (optional)

```bash
ENABLE_SYNC_TO_SECONDARY=false
SECONDARY_RADARR_URL="http://localhost:7979"
SECONDARY_RADARR_API_KEY="your-api-key-here"
SECONDARY_RADARR_NAME="Radarr 4K"
```

| Option | Description |
|--------|-------------|
| `ENABLE_SYNC_TO_SECONDARY` | Set to `true` to mirror tags to a second Radarr instance. When enabled, every tag add/remove in primary is also applied to the secondary instance — but only for movies that exist in both (matched by TMDb ID). If a movie is tagged in primary but doesn't exist in secondary, it's logged as "not found" but nothing breaks. Set to `false` if you only have one Radarr instance. |
| `SECONDARY_RADARR_URL` | Same as primary — full URL to your second Radarr instance. |
| `SECONDARY_RADARR_API_KEY` | API key for the secondary instance. |
| `SECONDARY_RADARR_NAME` | Display name for logs and Discord. |

**How sync works:** Tagarr fetches all movies from both instances at startup and builds a TMDb ID lookup table. When it decides a movie should have a tag in primary, it checks if the same TMDb ID exists in secondary and applies the same tag there. Orphaned tags (movie has the tag in secondary but shouldn't according to primary) are cleaned up automatically during a secondary scan pass.

### Release Groups

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "sic:sic:SiC:filtered"
    "sparks:sparks:SPARKS:simple"
    #"hone:hone:HONE:filtered"             # Reviewed, decided not to tag
)
```

This is the core of the configuration. Each line defines one release group to tag. The format is four fields separated by colons:

```
"search_string:tag_name:display_name:mode"
```

| Field | Description |
|-------|-------------|
| `search_string` | The text to search for in the movie's release group field. Case-insensitive. Matched using **word boundaries** — this means `sic` will match the release group "SiC" but will NOT match "Jurassic" or "ClassiC". The search checks three fields in priority order: releaseGroup (Radarr's parsed group), sceneName, then relativePath (filename). |
| `tag_name` | The tag label that will be created in Radarr. Must be lowercase with no spaces — Radarr normalizes tag names to lowercase anyway. This is what appears in Radarr's tag list and what you reference in quality profiles, custom formats, etc. |
| `display_name` | Human-readable name shown in terminal output, logs, and Discord notifications. Can use any casing — "FLUX", "SiC", "FraMeSToR", etc. Has no effect on Radarr. |
| `mode` | How strictly to filter releases. Two options: `filtered` or `simple` (see below). |

**Mode: `filtered`**

The release must pass **both** your quality filter AND your audio filter to be tagged. This is the strict mode — it ensures only premium releases get the tag. Use this when a group releases both premium and standard quality content, and you only want to track the premium ones.

Example: FLUX releases both MA WEB-DL with TrueHD Atmos (premium) and AMZN WEB-DL with EAC3 (standard). With `filtered` mode, only the MA WEB-DL + TrueHD Atmos releases get the `flux` tag.

**Mode: `simple`**

Every release from this group gets tagged regardless of quality or audio. No filters are applied. Use this when you trust all releases from a group, or when the group doesn't release WEB-DL content (e.g., remux groups, BluRay encode groups).

Example: FraMeSToR only releases remuxes with lossless audio. There's no need to filter — everything they release is premium by definition.

**Commented entries**

Lines starting with `#` inside the `RELEASE_GROUPS` array are ignored for tagging but still counted as "known" by the discovery feature. This means if you've reviewed a group and decided not to tag it, commenting it out prevents discovery from suggesting it again. Use this as a record of groups you've evaluated and rejected.

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"         # Active — will be tagged
    #"hone:hone:HONE:filtered"          # Reviewed, decided not to tag — won't be re-discovered
)
```

### Quality Filters

```bash
ENABLE_QUALITY_FILTER=true
ENABLE_MA_WEBDL=true
ENABLE_PLAY_WEBDL=true
```

These filters only apply to release groups in `filtered` mode. Groups in `simple` mode skip all filters.

| Option | Description |
|--------|-------------|
| `ENABLE_QUALITY_FILTER` | Master switch for quality filtering. When `true`, releases in `filtered` mode must come from one of the enabled WEB-DL sources below. When `false`, the quality check is skipped entirely (all releases pass). |
| `ENABLE_MA_WEBDL` | Match releases from **Movies Anywhere** (MA). Movies Anywhere is a digital locker service connected to major studios (Disney, Sony, Universal, Warner Bros, Lionsgate). MA WEB-DLs are sourced directly from the studio master and typically include lossless audio tracks (TrueHD Atmos, DTS-HD MA). This is generally considered the highest quality WEB-DL source. Matches patterns like: `MA.WEB-DL`, `MA-WEBDL`, `[MA][WEBDL]`, etc. |
| `ENABLE_PLAY_WEBDL` | Match releases from **Google Play**. Google Play WEB-DLs are similar to MA — often sourced from the same studio master. Some releases are available on Play but not MA (or vice versa). The quality is comparable. Matches patterns like: `Play.WEB-DL`, `PLAY-WEBDL`, `[Play][WEBDL]`, etc. |

**Why MA and Play specifically?**

Not all WEB-DLs are created equal. Amazon (AMZN), Netflix (NF), Apple TV+ (APTV), and other streaming services typically compress audio to lossy formats (EAC3/DD+, AAC). MA and Play are the primary sources that preserve the original lossless audio from the studio master. This is why Tagarr specifically filters for these two sources when combined with lossless audio codecs — it identifies the true premium releases.

**What about other sources?**

Releases from AMZN, NF, DSNP (Disney+), HMAX (HBO Max), etc., are intentionally excluded from the quality filter. These services compress their audio and sometimes video too. If you want to tag releases from these sources regardless, use `simple` mode for the release group, or set `ENABLE_QUALITY_FILTER=false` to disable quality filtering entirely.

**How matching works**

The quality check looks at the combined metadata from all available fields (relativePath, sceneName, releaseGroup). It uses word boundary matching to prevent false positives — "MA" won't match inside "IMAX" or "AMZN", and "Play" won't match inside "DisplayName".

### Audio Filters

```bash
ENABLE_AUDIO_FILTER=true
ENABLE_TRUEHD=true
ENABLE_TRUEHD_ATMOS=true
ENABLE_DTS_X=true
ENABLE_DTS_HD_MA=true
```

These filters only apply to release groups in `filtered` mode.

| Option | Description |
|--------|-------------|
| `ENABLE_AUDIO_FILTER` | Master switch for audio filtering. When `true`, releases in `filtered` mode must contain one of the enabled lossless audio codecs below. When `false`, the audio check is skipped entirely (all releases pass). |
| `ENABLE_TRUEHD` | Match releases with **Dolby TrueHD** audio (without Atmos). TrueHD is a lossless codec — a bit-for-bit copy of the studio master audio. Delivers reference-quality surround sound (typically 7.1 channels). |
| `ENABLE_TRUEHD_ATMOS` | Match releases with **Dolby TrueHD Atmos** audio. Atmos adds object-based spatial audio on top of the TrueHD lossless base. This is the highest quality consumer audio format for movies. Requires both "TrueHD" and "Atmos" to appear in the filename. |
| `ENABLE_DTS_X` | Match releases with **DTS:X** audio. DTS:X is the DTS equivalent of Atmos — object-based spatial audio built on top of a DTS-HD MA lossless core. Less common than Atmos but equally premium. |
| `ENABLE_DTS_HD_MA` | Match releases with **DTS-HD Master Audio**. DTS-HD MA is a lossless surround codec, similar to TrueHD but using the DTS format. Common in older BluRay releases. Matches various filename patterns: `DTS-HD.MA`, `DTS-HD MA`, `DTS.HD.MA`, etc. |

**Automatic rejection**

Before checking for lossless codecs, the audio filter automatically rejects releases with known lossy or processed audio indicators: `upmix`, `encode`, `transcode`, `lossy`, `converted`, `re-encode`. This prevents a release labeled as "TrueHD" but also tagged as "upmixed" from passing the filter.

**Common lossy codecs that will NOT pass the filter:**
- EAC3 / DD+ (Dolby Digital Plus) — lossy, used by most streaming services
- AAC — lossy, common in lower quality web rips
- AC3 / DD (Dolby Digital) — lossy, older standard
- DTS (base DTS without HD MA) — lossy core codec

**How TrueHD and TrueHD Atmos are distinguished:**

The filter is precise about this. If a filename contains "TrueHD" and "Atmos", it's treated as TrueHD Atmos and only passes if `ENABLE_TRUEHD_ATMOS=true`. If it contains "TrueHD" without "Atmos", it's treated as plain TrueHD and only passes if `ENABLE_TRUEHD=true`. This means you can enable one without the other.

### Discovery

```bash
ENABLE_DISCOVERY=true
DISCOVERY_LOG_FILE="${SCRIPT_DIR}/discovery.log"
```

| Option | Description |
|--------|-------------|
| `ENABLE_DISCOVERY` | When `true`, Tagarr looks for release groups that are NOT in your `RELEASE_GROUPS` config (neither active nor commented) but whose releases pass both your quality and audio filters. These "discovered" groups are logged and written to your config file as commented entries for you to review. This is how you find new premium groups you didn't know about. |
| `DISCOVERY_LOG_FILE` | Path to the discovery log file. `${SCRIPT_DIR}` is automatically set to the directory where the script lives — you don't need to define it. Each run appends a timestamped section with all discovered groups and their movies. Rotated automatically at 2 MiB (keeps one `.old` backup). |

**How discovery works:**

After checking all configured release groups for a movie, if the movie's release group is not in the config at all (not even commented), Tagarr runs the quality and audio filters on it. If both pass, the group is "discovered" — meaning this is a group you haven't configured yet that produces releases meeting your premium standards.

Discovered groups are written to your `tagarr.conf` as commented entries inside the `RELEASE_GROUPS` array:

```bash
    #"newgroup:newgroup:NewGroup:filtered"    # Discovered 2026-04-05: MA WEB-DL + TrueHD Atmos
```

**Your workflow:**
1. Run Tagarr (scheduled or manual)
2. Check the discovery section in the output or Discord notification
3. Open your config file and review the new commented entries
4. Uncomment the groups you want to tag, delete the ones you don't
5. Run Tagarr again — the newly activated groups will now be tagged

Groups that remain commented are remembered and won't be re-discovered in future runs.

### Auto-Tag Discovered Groups

```bash
AUTO_TAG_DISCOVERED=false
```

| Option | Description |
|--------|-------------|
| `AUTO_TAG_DISCOVERED` | When `true`, discovered groups are added as **active entries** (without `#`) instead of commented entries. **Two runs are needed to tag:** the first run discovers the group and writes it to the config, but can't tag movies from it because the config was already loaded at startup. The second run reads the updated config and tags the movies. When `false` (default), groups are added as commented entries for manual review — you uncomment the ones you want, then run again to tag. |

**When to use this:** Only if you trust your filters completely and don't want to manually review each new group. The quality + audio filters act as your gatekeepers — any group whose releases pass both filters will be auto-activated.

**When NOT to use this:** If you want to review groups before tagging. Some groups you might recognize as low-quality despite having occasional premium releases. Manual review gives you control.

### Debug

```bash
ENABLE_DEBUG=false
```

| Option | Description |
|--------|-------------|
| `ENABLE_DEBUG` | When `true`, prints a detailed breakdown at the end of the run for every movie that was tagged or untagged. For each movie, shows: file path, scene name, release group, which field matched, quality filter result (pass/fail with detected source), and audio filter result (pass/fail with detected codec). Extremely verbose — only enable when troubleshooting why a specific movie was or wasn't tagged. |

### Discord Notifications

```bash
DISCORD_ENABLED=false
DISCORD_WEBHOOK_URL=""
```

| Option | Description |
|--------|-------------|
| `DISCORD_ENABLED` | Set to `true` to send notifications to Discord after each run. Sends: a summary embed (tagged/untagged counts per instance), tagged movie list (green embeds grouped by release group), untagged movie list (purple embeds), and discovery results (gold embed). Long lists are automatically split into chunks to stay under Discord's 2000-character limit. |
| `DISCORD_WEBHOOK_URL` | Your Discord webhook URL. Create one in Discord: Server Settings > Integrations > Webhooks > New Webhook. Copy the URL. |

**What the notifications contain:**

| Notification | Color | Content |
|-------------|-------|---------|
| Summary | Orange | Total tagged/untagged per instance, runtime, dry-run status |
| Tagged movies | Green | Movie titles grouped by release group. Checkmark (✓) means also tagged in secondary. |
| Untagged movies | Purple | Movies where tags were removed, with reason (wrong group, failed quality, failed audio) |
| Discoveries | Gold | New groups found, movie count per group |

### Logging

```bash
ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr.log"
PROGRESS_INTERVAL=50
```

| Option | Description |
|--------|-------------|
| `ENABLE_LOGGING` | When `true`, all terminal output is also written to the log file with timestamps. When `false`, output only goes to the terminal. |
| `LOG_FILE` | Path to the log file. `${SCRIPT_DIR}` is automatically set to the script's directory. The `logs/` subdirectory is created automatically if it doesn't exist. The log is rotated when it exceeds 2 MiB — the current file is renamed to `.old` and a new one starts. Only one backup is kept. |
| `PROGRESS_INTERVAL` | How often to print a progress line during the scan. A value of `50` means "print progress every 50 movies processed." Set higher (100, 200) for large libraries to reduce log noise. Set to `1` for maximum verbosity (one line per movie). Only affects the progress counter — individual tag actions are always logged. |

### Tag Cleanup

```bash
CLEANUP_UNUSED_TAGS=false
```

| Option | Description |
|--------|-------------|
| `CLEANUP_UNUSED_TAGS` | When `true`, Tagarr checks each tag in your `RELEASE_GROUPS` at the end of the run and deletes any that have 0 movies assigned. This cleans up empty tags that might be left over from groups that no longer have qualifying releases. **Only affects tags defined in your config** — other Radarr tags (from quality profiles, custom formats, etc.) are never touched. Skipped in discovery-only mode. |

---

## Command Line Options

```bash
./tagarr.sh [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Simulate the entire run without making any changes to Radarr. Shows exactly what would be tagged, untagged, created, and deleted. Always start with this when testing a new config. |
| `--discover` | Run discovery only — scan for new release groups without tagging or modifying any tags. Implies `--dry-run` for the tagging part, but still writes discovered groups to the config file and sends Discord notifications. |
| `--tag NAME` | Only process specific release groups by their `tag_name` field (comma-separated). Example: `--tag flux,sic` processes only entries where tag_name is `flux` or `sic`. All other groups are skipped. Useful for testing a single group's behavior. |
| `--help` | Show usage information and exit. |

### Recommended workflow

1. **First time:** `./tagarr.sh --dry-run` — review the full output
2. **Verify filters:** `./tagarr.sh --dry-run --tag flux` — check one group in detail
3. **Enable debug if needed:** Set `ENABLE_DEBUG=true` in config, run with `--dry-run`
4. **Apply:** `./tagarr.sh` — tags are applied for real
5. **Schedule:** Set up a cron job or Cronicle task to run periodically (e.g., daily) as a catch-up for movies that the event-driven import tagger may have missed

---

## Typical Setup

### Single Radarr instance, filtered tagging

The most common setup. You have one Radarr instance and want to tag premium releases.

```bash
# tagarr.conf

PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="abc123..."
PRIMARY_RADARR_NAME="Radarr"

ENABLE_SYNC_TO_SECONDARY=false

RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "sic:sic:SiC:filtered"
    "thefarm:thefarm:TheFarm:filtered"
    "126811:126811:126811:filtered"
    "xebec:xebec:XEBEC:filtered"
    "framesto:framesto:FraMeSToR:simple"    # Remux group — always premium
    "bhdstudio:bhdstudio:BHDStudio:simple"  # Encode group — trusted quality
)

ENABLE_QUALITY_FILTER=true
ENABLE_MA_WEBDL=true
ENABLE_PLAY_WEBDL=true

ENABLE_AUDIO_FILTER=true
ENABLE_TRUEHD=true
ENABLE_TRUEHD_ATMOS=true
ENABLE_DTS_X=true
ENABLE_DTS_HD_MA=true

ENABLE_DISCOVERY=true
DISCOVERY_LOG_FILE="${SCRIPT_DIR}/discovery.log"
AUTO_TAG_DISCOVERED=false

ENABLE_DEBUG=false

DISCORD_ENABLED=true
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."

ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr.log"
PROGRESS_INTERVAL=50

CLEANUP_UNUSED_TAGS=false
```

### Dual Radarr instances (HD + 4K)

```bash
PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="abc123..."
PRIMARY_RADARR_NAME="Radarr HD"

ENABLE_SYNC_TO_SECONDARY=true
SECONDARY_RADARR_URL="http://localhost:7979"
SECONDARY_RADARR_API_KEY="def456..."
SECONDARY_RADARR_NAME="Radarr 4K"
```

Tags are applied to both instances. If a movie exists in both HD and 4K Radarr and qualifies for a tag, it gets tagged in both. If a movie is only in one instance, it's only tagged there.

---

## Overall Workflow — How the Scripts Work Together

Tagarr has three main scripts that each serve a different purpose. Here's the recommended order for getting everything set up and running:

### Step 1: Fix your backlog (one-time)

Before tagging, make sure your library has correct release groups. Tagarr can only tag movies where Radarr knows the release group — if the release group field is empty, there's nothing to match against.

Many movies in your library may have empty release groups. This happens when the file inside a torrent doesn't include the group name in the filename, even though the indexer/tracker listing did. For example, the indexer title might be `Movie.2024.MA.WEB-DL.TrueHD.Atmos-FLUX` but the actual file is `Movie.2024.MA.WEB-DL.TrueHD.Atmos.mkv` — no `-FLUX`. Radarr stores the filename, so the group is lost.

`tagarr_recover.sh` fixes this by looking up the original grab event in Radarr/Sonarr's history and patching the release group back onto the file. It also renames the file so the group is permanently part of the filename — surviving rescans, restarts, and database rebuilds.

```bash
# Preview what needs fixing
./tagarr_recover.sh --dry-run

# Fix everything
./tagarr_recover.sh --live
```

See [tagarr-recover-guide.md](tagarr-recover-guide.md) for full details on how recovery works and all configuration options.

### Step 2: Tag your backlog (one-time)

Now that release groups are correct, tag the entire library:

```bash
# Preview what would be tagged
./tagarr.sh --dry-run

# Tag everything
./tagarr.sh
```

### Step 3: Set up real-time import handling (permanent)

Set up the Connect handlers so new downloads are handled automatically:

- **Radarr:** `tagarr_import.sh` as a Custom Script — tags movies, recovers missing groups, and discovers new groups on every import. See [tagarr-import-guide.md](tagarr-import-guide.md).
- **Sonarr:** `tagarr_import_sonarr.sh` as a Custom Script — recovers missing release groups and renames episode files on every import. This prevents the upgrade loop where Sonarr keeps re-grabbing the same release because the Custom Format score drops when the group is missing. See [tagarr-import-guide.md](tagarr-import-guide.md).

### Step 4: Schedule batch scripts as a safety net (permanent)

The import scripts handle real-time events, but they can miss things — Radarr/Sonarr restarts, Connect timeouts, script errors. Run the batch scripts on a schedule to catch anything that slipped through:

```bash
# Daily or weekly via cron/Cronicle:
./tagarr_recover.sh --live    # Fix any new missing groups
./tagarr.sh                   # Re-tag anything the import script missed
```

Also run `tagarr.sh` manually after changing your config (new groups, different filters) — it re-evaluates the entire library against the current config.

---

## FAQ

### Do I need to run tagarr.sh AND tagarr_import.sh?

**Yes, for the best coverage.** `tagarr_import.sh` tags movies instantly on import (event-driven via Radarr Connect), but it only handles one movie at a time and only triggers on new downloads/upgrades/deletes. `tagarr.sh` is the batch scanner — it catches anything the import script missed and can retag your entire library when you change your config. Run `tagarr.sh` on a schedule (e.g., daily) as a safety net.

### What happens if I change my filters after initial setup?

Run `tagarr.sh` again. It re-evaluates every movie against the current config. Movies that no longer pass the filters will have their tags removed. Movies that now pass (because you relaxed filters) will be tagged. The script is fully idempotent — you can run it as many times as you want.

### Will this interfere with other Radarr tags?

No. Tagarr only manages tags that are listed in your `RELEASE_GROUPS` config. It never touches, reads, or deletes tags created by quality profiles, custom formats, or other tools. Even the cleanup feature (`CLEANUP_UNUSED_TAGS`) only deletes tags from your config that have 0 movies.

### How long does a full scan take?

Depends on your library size. The script makes one API call to fetch all movies, then processes them in memory. For a library of ~5,000 movies, expect 2-5 minutes. The bottleneck is the per-movie jq parsing, not API calls. Tag changes are batched into bulk API calls (one per release group).

### What if a release group name conflicts with a common word?

The word boundary matching prevents most false positives. `sic` won't match "Jurassic" or "Classic". However, very short names (2-3 characters) in unusual positions might still cause edge cases. If you're unsure, run with `--dry-run --tag yourgroup` and check the results. The `ENABLE_DEBUG=true` option shows exactly which field and position matched.

### Can I use this with Sonarr?

`tagarr.sh` is Radarr-only (movies). For Sonarr, use `tagarr_import_sonarr.sh` (Connect handler for release group recovery) and `tagarr_recover.sh --app sonarr` (batch release group recovery). Sonarr does not currently have a batch tagging equivalent of `tagarr.sh`.
