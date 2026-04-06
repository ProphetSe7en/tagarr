# Tagarr Import Guide — Event-Driven Tagging and Recovery

Complete guide for the two Connect handler scripts:

- **`tagarr_import.sh`** — Radarr Connect (tagging + recovery + discovery)
- **`tagarr_import_sonarr.sh`** — Sonarr Connect (recovery only)

These scripts run automatically every time a movie or episode is imported. For the batch scanner, see [tagarr-guide.md](tagarr-guide.md). For the batch recovery tool, see [tagarr-recover-guide.md](tagarr-recover-guide.md).

---

## Prerequisites

- **Radarr v3+** and/or **Sonarr v3+** with API access enabled
- **bash 4+**, **jq**, and **curl** installed where the scripts run (inside the container or on the host)
- Scripts must be executable: `chmod +x tagarr_import.sh tagarr_import_sonarr.sh`

### Setup files

```bash
# For Radarr:
cp tagarr_import.conf.sample tagarr_import.conf
nano tagarr_import.conf

# For Sonarr:
cp tagarr_import_sonarr.conf.sample tagarr_import_sonarr.conf
nano tagarr_import_sonarr.conf
```

Each config must be in the same directory as its script, named without `.sample`.

---

## What Do These Scripts Do?

Both scripts are **Connect handlers** — Radarr and Sonarr have a feature called Connect (Settings > Connect) that lets you run external scripts automatically when certain events happen (like a movie being imported). These scripts are set up as Custom Scripts in Connect and run in the background on every import. They are not meant to be run manually.

### tagarr_import.sh (Radarr)

A full-featured event handler that does three things on every movie import:

1. **Tags** the movie by release group (same quality + audio filters as `tagarr.sh`)
2. **Recovers** the release group if it's missing (via download ID from grab history)
3. **Discovers** new release groups that pass your filters but aren't in your config

It also handles file deletion events by removing all managed tags from the movie.

### tagarr_import_sonarr.sh (Sonarr)

Recovers missing release groups the moment an episode is imported. When the release group is missing from the file, the script looks it up in grab history, patches it onto the episode, and renames the file so the group is permanently part of the filename. This ensures:

- **Custom Format scores stay correct** — CFs that match by release group keep scoring after import
- **No upgrade loops** — Sonarr won't re-grab the same release because the score dropped
- **The fix is permanent** — the group is in the filename, surviving rescans and restarts

No tagging, no discovery, no filters — the Sonarr script is focused entirely on making sure every episode has the correct release group.

---

## Why Use These Instead of the Batch Scripts?

The batch scripts (`tagarr.sh`, `tagarr_recover.sh`) scan your entire library. They're great for initial setup and scheduled catch-up runs. But they can't react in real-time.

The import scripts run **instantly** when a movie or episode is imported — before you even see it in Radarr/Sonarr. This means:

- Tags are applied immediately, not on the next scheduled run
- Missing release groups are fixed before Sonarr can start an upgrade loop
- New groups are discovered as they arrive, not hours later

**Best practice:** Use both. Start with the batch scripts to fix your backlog (`tagarr_recover.sh` → `tagarr.sh`), then set up the import scripts for real-time handling, and keep the batch scripts on a schedule as a safety net. See the [Overall Workflow section in tagarr-guide.md](tagarr-guide.md#overall-workflow--how-the-scripts-work-together) for the full recommended setup order.

---

## The Scoring Loop Problem (Sonarr)

This is the primary reason `tagarr_import_sonarr.sh` exists.

Some trackers name their releases differently from the files inside the torrent:
- **Indexer title:** `Show.S01E05.1080p.WEB-DL.TrueHD.Atmos-FLUX`
- **Actual file:** `Show.S01E05.1080p.WEB-DL.TrueHD.Atmos.mkv` (no `-FLUX`)

Sonarr grabs the release based on the indexer title and scores it with Custom Formats that match the group "FLUX". After import, Sonarr stores the actual filename — which has no group. The Custom Format score drops. Sonarr sees the file is now below the quality cutoff and grabs the same release again. Loop.

`tagarr_import_sonarr.sh` breaks this loop by recovering the release group from the grab event immediately on import. Sonarr then sees the correct group, the CF score stays, and no upgrade loop happens.

The same problem can occur in Radarr, and `tagarr_import.sh` handles it the same way — but Radarr's upgrade behavior is less aggressive, so the loop is less common.

---

## How Recovery Works (Both Scripts)

Both scripts use the same recovery method, which is simpler than `tagarr_recover.sh`:

1. The app provides a **download ID** in the Connect event variables
2. The script queries the item's history for **grab events**
3. It finds the grab with the **matching download ID** — this is the exact grab that produced this import
4. It extracts the **release group** from that grab
5. It patches the group onto the movie/episode file in the app's database
6. It triggers a **rename** so the recovered group is written into the actual filename on disk

The rename step is critical — it makes the fix **permanent**. Without rename, the group only exists in the database. Radarr/Sonarr reads the release group from the filename, so the next library rescan, app restart, or database rebuild would lose the fix. With rename, the group is part of the filename and survives anything.

This is a direct download ID match — no walking through history, no title/year verification, no safety chain. It's simpler and more reliable than the batch recovery because the download ID comes directly from the event, guaranteeing an exact match.

**What if recovery fails?** The script continues silently. A missing release group isn't fatal — the movie/episode is imported normally, just without the group. The batch recovery script (`tagarr_recover.sh`) can pick it up later.

---

## Use Cases

### Sonarr — keep release groups correct on every import

The Sonarr script has one job: make sure every episode has the correct release group after import. This matters because:

- Some trackers name their torrent `Show.S01E05.1080p.WEB-DL-FLUX` but the file inside is `Show.S01E05.1080p.WEB-DL.mkv` — no group. Sonarr stores the filename, so the group is lost.
- Custom Formats that score by release group stop working — the score drops to zero after import.
- Sonarr sees the lower score and grabs the same release again, creating an upgrade loop.

The script fixes this automatically on every import: looks up the grab in history, patches the group, and renames the file. The group is now permanently part of the filename — it survives rescans, restarts, and database rebuilds.

If your Sonarr naming format includes `{Release Group}` (check Sonarr > Settings > Media Management > Episode Naming), the rename puts the group into the filename. If it doesn't, the group is still patched in the database.

### Radarr — tag and recover on every import

The Radarr script does everything the Sonarr script does (recovery + rename), plus tagging and discovery. The examples below show the tagging patterns — each is configured in `RELEASE_GROUPS`.

Each entry uses four fields: `"search_string:tag_name:display_name:mode"`. The `mode` controls filtering: `filtered` means the release must pass quality and audio filters (MA/Play WEB-DL + lossless audio), `simple` means tag every match regardless of quality. See the [Configuration Reference](#release-groups) for full details.

#### Tag per group — know what arrived

Every import is checked against your configured groups. When a FLUX release is imported, it's tagged `flux` before you even see it in Radarr.

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "sic:sic:SiC:filtered"
    "thefarm:thefarm:TheFarm:filtered"
)
```

Over time, your library builds up tags automatically — you can filter by group, build collections, or see at a glance which imports met your quality bar.

#### Shared tag — flag every premium import

Instead of separate tags per group, every qualifying import gets the same tag. A new FLUX, SiC, or TheFarm release all arrive with the `premium` tag.

```bash
RELEASE_GROUPS=(
    "flux:premium:FLUX:filtered"
    "sic:premium:SiC:filtered"
    "thefarm:premium:TheFarm:filtered"
)
```

This simplifies quality profiles, custom formats, and automation rules — one tag to check instead of three. When you add a new group to the config, future imports from that group automatically get the same tag with no downstream changes needed.

#### Both — group-specific tag + shared tag

Every import gets two tags: one identifying the group, one for automation.

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "flux:premium:FLUX:filtered"
    "sic:sic:SiC:filtered"
    "sic:premium:SiC:filtered"
)
```

When a FLUX movie is imported, it gets both `flux` (so you know it's FLUX) and `premium` (for quality profiles and Maintainerr rules). The script processes each entry independently — the movie is matched twice and both tags are applied.

#### Remux cleanup — flag redundant imports across instances

With secondary sync enabled, every tag applied in your WEB-DL instance is automatically mirrored to your remux instance. When a premium WEB-DL is imported, the matching remux in the secondary instance is tagged — marking it as redundant.

```bash
ENABLE_SYNC_TO_SECONDARY=true
SECONDARY_RADARR_URL="http://localhost:7879"
SECONDARY_RADARR_API_KEY="..."
SECONDARY_RADARR_NAME="Radarr Remux"
```

This happens on every import, so your remux instance always has up-to-date tags showing which movies have a lossless WEB-DL equivalent. Automate the cleanup with [Maintainerr](https://github.com/jorenn92/Maintainerr) — you keep the smaller file with identical audio quality.

#### Discovery — catch new groups as they arrive

With discovery enabled, every import is checked: if the movie's release group passes your filters but isn't in your config, it's flagged immediately and written to the config file.

```bash
ENABLE_DISCOVERY=true
```

Unlike the batch script where you run discovery periodically, the import script catches new groups the moment they first appear in your library. With `AUTO_TAG_DISCOVERED=true`, the movie is tagged immediately in the same run — no second pass needed.

---

## Setup

### Radarr (tagarr_import.sh)

1. Copy the config: `cp tagarr_import.conf.sample tagarr_import.conf`
2. Edit `tagarr_import.conf` with your Radarr URL, API key, and release groups
3. In Radarr: **Settings > Connect > + > Custom Script**
   - Name: `Tagarr Import`
   - Path: full path to `tagarr_import.sh`
   - Events: **On File Import**, **On File Upgrade**, and **On Movie File Delete**
4. Click **Test** — you should see a test notification in the log (and Discord if enabled)

**Which events to enable and why:**

| Event | Enable | Purpose |
|-------|--------|---------|
| **On File Import** | Yes | Fires after Radarr finishes importing a new file. All file metadata (release group, quality, audio) is available. This triggers tagging, recovery, discovery, and secondary sync. |
| **On File Upgrade** | Yes | Fires after Radarr replaces a file with a better version. The new file is evaluated fresh — old tags that no longer match are removed, new tags are applied. |
| **On Movie File Delete** | Yes | Fires when you manually delete a file from Radarr. Removes all managed tags since the file they refer to no longer exists. The movie stays in Radarr without tags, ready to be re-grabbed. |
| **On Grab** | No | Fires when Radarr sends a release to the download client — **before the file exists**. No file metadata is available (no path, no release group, no quality info). The script cannot tag, recover, or filter anything at this point. |
| **On Movie File Delete For Upgrade** | No | Fires when the old file is deleted during an upgrade, right before the new file is imported. Enabling this would remove all tags and then immediately re-add them when On File Upgrade fires — unnecessary work. |

### Sonarr (tagarr_import_sonarr.sh)

1. Copy the config: `cp tagarr_import_sonarr.conf.sample tagarr_import_sonarr.conf`
2. Edit `tagarr_import_sonarr.conf` with your Sonarr URL and API key
3. In Sonarr: **Settings > Connect > + > Custom Script**
   - Name: `Tagarr Import Sonarr`
   - Path: full path to `tagarr_import_sonarr.sh`
   - Events: **On File Import** and **On Upgrade**
4. Click **Test** — you should see a test notification in the log (and Discord if enabled)

**Which events to enable and why:**

| Event | Enable | Purpose |
|-------|--------|---------|
| **On File Import** | Yes | Fires after Sonarr imports a new episode file. All per-file metadata is available: episode file ID, release group, quality, scene name. Works for both single episodes and season packs (fires once per episode). |
| **On Upgrade** | Yes | Fires after Sonarr replaces a file with a better version. Same per-file metadata as On File Import, with `sonarr_isupgrade=True` and `sonarr_deletedpaths` showing the old file. Required for both single episode upgrades and season pack upgrades. Without this, upgrades are silently ignored. |
| **On Import Complete** | No | Fires after all files from a download batch are imported. Uses plural variable names (`sonarr_episodefile_ids`, `sonarr_episodefile_releasegroups`) instead of the singular forms the script expects. Would cause the script to see an empty release group and trigger unnecessary recovery. |
| **On Grab** | No | Same as Radarr — fires before the file exists. No file metadata available. |

**Docker users:** These scripts run inside the Radarr/Sonarr container's filesystem. The script path in Connect must point to a location inside the container, not on the host. Mount the scripts directory as a read-only volume:

**docker run:**
```bash
-v /path/to/tagarr:/scripts:ro
```

**docker-compose.yml:**
```yaml
volumes:
  - /path/to/tagarr:/scripts:ro
```

Then set the Connect path to `/scripts/tagarr_import.sh` (Radarr) or `/scripts/tagarr_import_sonarr.sh` (Sonarr). The `:ro` flag means read-only — the scripts only need to read their config files. If you use discovery (which writes to the config file), remove `:ro` or use `:rw`.

**Unraid users:** Add the path mapping in the container's template under "Add another Path" — container path `/scripts`, host path pointing to your tagarr directory.

---

## Configuration Reference — Radarr (tagarr_import.conf)

### Primary Radarr

```bash
PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="your-api-key-here"
PRIMARY_RADARR_NAME="Radarr"
```

| Option | Description |
|--------|-------------|
| `PRIMARY_RADARR_URL` | URL to the Radarr instance this script runs in. If the script runs inside the Radarr container, use `http://localhost:7878`. If it runs on the host or another container, use the appropriate IP/hostname and port. |
| `PRIMARY_RADARR_API_KEY` | API key from Radarr > Settings > General > API Key. |
| `PRIMARY_RADARR_NAME` | Display name for logs and Discord. |

### Secondary Radarr (optional)

```bash
ENABLE_SYNC_TO_SECONDARY=false
SECONDARY_RADARR_URL="http://localhost:7979"
SECONDARY_RADARR_API_KEY="your-api-key-here"
SECONDARY_RADARR_NAME="Radarr 4K"
```

| Option | Description |
|--------|-------------|
| `ENABLE_SYNC_TO_SECONDARY` | When `true`, every tag add/remove in primary is mirrored to the secondary instance (matched by TMDb ID). If the movie doesn't exist in secondary, it's skipped silently. Set to `false` if you only have one Radarr instance. |
| `SECONDARY_RADARR_URL` | URL to your second Radarr instance. Must be reachable from wherever the script runs. |
| `SECONDARY_RADARR_API_KEY` | API key for the secondary instance. |
| `SECONDARY_RADARR_NAME` | Display name for the secondary instance. |

### Release Groups

```bash
RELEASE_GROUPS=(
    "flux:flux:FLUX:filtered"
    "sic:sic:SiC:filtered"
    #"hone:hone:HONE:filtered"             # Reviewed, decided not to tag
)
```

Each entry defines a release group to tag on import. The format is four fields separated by colons:

```
"search_string:tag_name:display_name:mode"
```

| Field | Description |
|-------|-------------|
| `search_string` | Text to match against the movie's release group. Case-insensitive, matched as a whole word — `sic` matches "SiC" but not "Jurassic" or "ClassiC". Checks: releaseGroup field, sceneName, then filename. |
| `tag_name` | The tag created in Radarr (lowercase, no spaces). Multiple entries can share the same tag_name to create a shared tag — see [Use Cases](#use-cases). |
| `display_name` | Human-readable name for logs and Discord (any casing). No effect on Radarr. |
| `mode` | `filtered` = must pass quality + audio filters below. `simple` = tag every release from this group. |

Commented entries (`#`) are not tagged but are counted as "known" by discovery — prevents re-discovering groups you've already reviewed.

**This config is separate from `tagarr.conf`.** Both are independent and can have different groups, filters, or webhooks. Most users keep them identical — when you add a group to one, add it to the other.

### Quality Filters

```bash
ENABLE_QUALITY_FILTER=true
ENABLE_MA_WEBDL=true
ENABLE_PLAY_WEBDL=true
```

Only applies to `filtered` mode groups. `simple` mode groups skip all filters.

| Option | Description |
|--------|-------------|
| `ENABLE_QUALITY_FILTER` | Master switch. When `true`, releases in `filtered` mode must come from one of the enabled WEB-DL sources below. When `false`, quality check is skipped (all releases pass). |
| `ENABLE_MA_WEBDL` | Match **Movies Anywhere** WEB-DLs. MA is a digital locker connected to major studios — MA WEB-DLs are sourced from the studio master and typically include lossless audio. Generally the highest quality WEB-DL source. |
| `ENABLE_PLAY_WEBDL` | Match **Google Play** WEB-DLs. Comparable quality to MA — often sourced from the same studio master. |

Other WEB-DL sources (AMZN, NF, DSNP, HMAX, etc.) are excluded because they typically compress audio to lossy formats. To tag releases from these sources, use `simple` mode or set `ENABLE_QUALITY_FILTER=false`.

### Audio Filters

```bash
ENABLE_AUDIO_FILTER=true
ENABLE_TRUEHD=true
ENABLE_TRUEHD_ATMOS=true
ENABLE_DTS_X=true
ENABLE_DTS_HD_MA=true
```

Only applies to `filtered` mode groups.

| Option | Description |
|--------|-------------|
| `ENABLE_AUDIO_FILTER` | Master switch. When `true`, releases in `filtered` mode must contain one of the enabled lossless codecs below. When `false`, audio check is skipped (all releases pass). |
| `ENABLE_TRUEHD` | Match **Dolby TrueHD** (without Atmos). Lossless, bit-for-bit studio master audio. |
| `ENABLE_TRUEHD_ATMOS` | Match **Dolby TrueHD Atmos**. Lossless + object-based spatial audio. Highest quality consumer audio. |
| `ENABLE_DTS_X` | Match **DTS:X**. DTS equivalent of Atmos — lossless + spatial audio. |
| `ENABLE_DTS_HD_MA` | Match **DTS-HD Master Audio**. Lossless surround, common in older BluRay releases. |

Releases with lossy audio (EAC3/DD+, AAC, AC3, base DTS) will not pass. Releases flagged as upmixed, transcoded, or re-encoded are automatically rejected even if they claim a lossless codec.

### Release Group Recovery

```bash
ENABLE_RECOVER=true
```

| Option | Description |
|--------|-------------|
| `ENABLE_RECOVER` | When `true`, the script attempts to recover missing release groups before tagging. If the imported movie has an empty or "Unknown" release group, the script looks up the grab event using the download ID from the Radarr Connect event. If a matching grab is found with a release group, it patches the group onto the movie file and triggers a rename. Recovery runs before tagging, so the recovered group is available for tag matching. Set to `false` to disable recovery and only perform tagging. |

**How this differs from tagarr_recover.sh:** The import script uses the download ID provided directly by the Radarr Connect event — a guaranteed exact match. The batch recovery script walks through history and uses a 5-point safety chain because it doesn't have a download ID from an event. The import method is simpler and more reliable for new imports.

### Discovery

```bash
ENABLE_DISCOVERY=true
```

| Option | Description |
|--------|-------------|
| `ENABLE_DISCOVERY` | When `true`, if the imported movie's release group is not in `RELEASE_GROUPS` (active or commented), the script checks it against your quality and audio filters. If both pass, the group is written to this config file as a commented entry. Discovery requires the movie to have a release group — if the group is empty (and recovery failed or is disabled), there is nothing to discover. |

**Concurrent write safety:** When multiple imports happen simultaneously, the config file write uses `flock` to prevent corruption. Only one instance of the script writes to the config at a time.

### Auto-Tag Discovered Groups

```bash
AUTO_TAG_DISCOVERED=false
```

| Option | Description |
|--------|-------------|
| `AUTO_TAG_DISCOVERED` | When `true`, discovered groups are added as **active entries** (without `#`) and the triggering movie is tagged **immediately** in the same run. Unlike `tagarr.sh` where auto-tag requires two runs (discover, then tag), the import script can tag in the same execution because it creates the tag and applies it right after discovery. When `false`, groups are added as commented entries for manual review. |

**This is the key behavioral difference from tagarr.sh:** In the batch script, discovery and tagging are separate passes — the config is read at startup, so newly discovered groups can't be tagged until the next run. In the import script, discovery happens mid-execution for a single movie, so the script can create and apply the tag immediately.

### Debug

```bash
ENABLE_DEBUG=false
```

| Option | Description |
|--------|-------------|
| `ENABLE_DEBUG` | When `true`, logs every filter decision: which groups matched, via which field (filename/scene/releaseGroup), quality and audio filter pass/fail, skip reasons, and discovery decisions. Enable this when a movie isn't being tagged and you want to understand why. Check the log file after the next import. |

### Discord Notifications

```bash
DISCORD_ENABLED=false
DISCORD_WEBHOOK_URL=""
```

| Option | Description |
|--------|-------------|
| `DISCORD_ENABLED` | Send per-movie notifications to Discord. **Smart behavior:** only sends when something happened — a tag was applied, a group was discovered, or a release group was recovered. Silent imports (no tag match, no discovery) produce no notification. |
| `DISCORD_WEBHOOK_URL` | Your Discord webhook URL. |

**Notification types:**

| Event | Color | Title | When |
|-------|-------|-------|------|
| Tagged | Orange | "Tagged — Movie (Year)" | Tag added or kept |
| Tagged + Discovered | Orange | "Tagged + Discovered — Movie (Year)" | New group found and auto-tagged |
| Discovered | Gold | "Discovered — Movie (Year)" | New group found, not auto-tagged |
| Release Group Fixed | Green | "Release Group Fixed — Movie (Year)" | Group recovered but no tag applied |
| Tagged + Fixed | Orange | "Tagged + Fixed — Movie (Year)" | Group recovered and then tagged |
| Test | Orange | "Tagarr Import vX.X.X — Test OK" | Connect test button clicked |

All notifications include a movie poster thumbnail (from Radarr/TMDb).

### Logging

```bash
ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr_import.log"
```

| Option | Description |
|--------|-------------|
| `ENABLE_LOGGING` | Write all output to the log file. Since the script runs automatically in the background, logging is the primary way to verify it's working. |
| `LOG_FILE` | Path to the log file. Rotated at 2 MiB (keeps one `.old` backup). The directory is created automatically. |

---

## Configuration Reference — Sonarr (tagarr_import_sonarr.conf)

The Sonarr config is much simpler — no tagging, no filters, no discovery, no secondary sync.

### Sonarr Instance

```bash
SONARR_URL="http://localhost:8989"
SONARR_API_KEY="your-api-key-here"
SONARR_NAME="Sonarr"
```

| Option | Description |
|--------|-------------|
| `SONARR_URL` | URL to your Sonarr instance. If the script runs inside the Sonarr container, use `http://localhost:8989`. If on the host or another container, use the appropriate address. |
| `SONARR_API_KEY` | API key from Sonarr > Settings > General > API Key. |
| `SONARR_NAME` | Display name for logs and Discord. |

### Rename

```bash
ENABLE_RENAME=true
```

| Option | Description |
|--------|-------------|
| `ENABLE_RENAME` | When `true`, triggers Sonarr's `RenameFiles` command after recovering a release group. This writes the group into the actual filename on disk, making the fix permanent — without rename, the group only exists in Sonarr's database and would be lost on the next rescan. **Requires `{Release Group}` in your Sonarr naming format** — check this in Sonarr > Settings > Media Management > Episode Naming. Set to `false` if you don't want file renames (e.g., to preserve cross-seed hardlinks). |

**Note:** The Radarr import script (`tagarr_import.sh`) always renames after recovery — there is no `ENABLE_RENAME` toggle. If you need to disable rename for Radarr, you would need to edit the script directly.

### Release Group Recovery

```bash
ENABLE_RECOVER=true
```

| Option | Description |
|--------|-------------|
| `ENABLE_RECOVER` | When `true`, the script attempts to recover missing release groups on every import. This is the core feature of the script — if you set this to `false`, the script effectively does nothing. The recovery uses the download ID from the Sonarr Connect event to find the exact grab, extract the release group, and patch it onto the episode file. |

### Discord Notifications

```bash
DISCORD_ENABLED=false
DISCORD_WEBHOOK_URL=""
```

| Option | Description |
|--------|-------------|
| `DISCORD_ENABLED` | Send per-episode notifications when a release group is recovered. Silent when the episode already has a group or when recovery fails/isn't needed. |
| `DISCORD_WEBHOOK_URL` | Your Discord webhook URL. |

**Notification:** Green embed with series title, episode number, recovered group, and series poster. Only sent when a recovery actually happened.

### Logging

```bash
ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr_import_sonarr.log"
```

| Option | Description |
|--------|-------------|
| `ENABLE_LOGGING` | Write all output to the log file. |
| `LOG_FILE` | Path to log file. Rotated at 2 MiB. |

---

## Events Handled

### Radarr (tagarr_import.sh)

| Event | What Happens |
|-------|-------------|
| **Test** | Verifies the script works, sends test notification to Discord if enabled, exits. |
| **File Import** | Full pipeline: recover missing group → tag by release group → discover new groups → sync to secondary → send Discord notification. Radarr internally calls this event `Download`. All file metadata is available: release group, quality, audio codec, file path, scene name. |
| **File Upgrade** | Same as File Import — the new file is evaluated fresh. Tags are applied based on the new file's release group and quality. Radarr sets `radarr_isupgrade=True` to distinguish from new imports. |
| **Movie File Delete** | Removes all managed tags (tags listed in `RELEASE_GROUPS`) from the movie. Does not touch other tags (renamed, upgradinatorr, etc.). Also syncs the removal to secondary if enabled. The movie remains in Radarr — only the file and its tags are gone. Radarr sets `radarr_moviefile_deletereason=Manual` for manual deletes. |

### Sonarr (tagarr_import_sonarr.sh)

| Event | What Happens |
|-------|-------------|
| **Test** | Verifies the script works, sends test notification to Discord if enabled, exits. |
| **File Import** | The script checks if the episode has a release group (from event env var → API → grab history recovery). If recovery was needed and successful, triggers a rename and sends Discord notification. Sonarr uses this same event for both new downloads and upgrades — when it's an upgrade, `sonarr_deletedpaths` contains the old file that was replaced. |
| All other events | Ignored — the script exits immediately. |

---

## Release Group Priority Chain

Both scripts resolve the release group through a priority chain before doing anything else:

### Radarr

1. **Radarr Connect env var** (`radarr_moviefile_releasegroup`) — Radarr passes this directly in the event. Most reliable for fresh imports.
2. **Radarr API** (`movieFile.releaseGroup`) — Fallback if the env var was empty. Reads the value from the Radarr database.
3. **Download ID recovery** — If both above are empty/Unknown, looks up the grab event by download ID and extracts the group.

### Sonarr

1. **Sonarr Connect env var** (`sonarr_episodefile_releasegroup`) — Same as Radarr.
2. **Sonarr API** (`episodefile.releaseGroup`) — Fallback read from API.
3. **Download ID recovery** — Same as Radarr. Looks up grab by download ID.

If all three sources come up empty, there is no release group available. The Radarr script continues with tagging (no group means no tag match — nothing happens). The Sonarr script exits with "nothing to recover."

---

## FAQ

### Can I use tagarr_import.sh with Sonarr or tagarr_import_sonarr.sh with Radarr?

No. Each script reads app-specific event variables (`radarr_*` vs `sonarr_*`) and uses app-specific API endpoints (`moviefile` vs `episodefile`). Using the wrong script will fail silently or produce errors.

### Do I need to keep tagarr_import.conf and tagarr.conf in sync?

Not technically — they're independent configs. But if they have different `RELEASE_GROUPS` or different filter settings, you'll get inconsistent tagging between the import handler and the batch scanner. Most users keep them identical. When you add a new group to one, add it to the other.

### What happens if Radarr/Sonarr imports multiple files simultaneously?

Each import triggers a separate script execution. For `tagarr_import.sh`, the `flock` mechanism prevents concurrent writes to the config file (relevant for discovery). Tag operations via the API are safe for concurrent access — Radarr/Sonarr handle that internally.

### Why doesn't the Sonarr script do tagging?

Sonarr's tagging system works differently from Radarr's. Tags in Sonarr are applied to series, not individual episodes. Tagging a series by the release group of one episode would be misleading — a series can have episodes from many different groups. The Sonarr script focuses on the one thing that matters per-episode: making sure the release group is correct for Custom Format scoring.

### The script runs but nothing happens — how do I debug?

1. Set `ENABLE_DEBUG=true` in the config
2. Wait for the next import
3. Check the log file (path from `LOG_FILE` in config)
4. The debug output shows every decision: which groups were checked, which fields matched, whether filters passed or failed

For Radarr, also check: Radarr > System > Events for any errors from the Connect script.

### Do these scripts slow down imports?

Minimally. Each script makes a few API calls (fetch movie/episode, check history, apply tags). Total execution is typically under 2 seconds. Radarr/Sonarr runs Connect scripts asynchronously after the import completes, so the import itself is never delayed.
