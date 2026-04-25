# Tagarr Import Guide — Event-Driven Tagging and Recovery

Complete guide for the two Connect handler scripts:

- **`tagarr_import.sh`** — Radarr Connect (tagging + recovery + discovery + grab rename)
- **`tagarr_import_sonarr.sh`** — Sonarr Connect (recovery + grab rename)

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

Two things, both aimed at keeping Custom Format scores correct so Sonarr stops re-grabbing the same release over and over:

**1. Recovers missing release groups on import.** When an episode arrives with the release group missing from the filename, the script looks it up in grab history, patches it into the episode record, and renames the file so the group is permanently part of the filename.

**2. Renames the qBit torrent on grab to keep streaming-source flags (and the release group) visible.** This is the new piece in v1.1.0 — see the next section for what it solves and when to enable it.

No tagging, no discovery, no filters — the Sonarr script is focused on getting the right tokens into the right places so Sonarr doesn't re-grab the same release over and over.

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

## The Streaming-Source Loop (Sonarr) — fixed by Grab Rename

The release-group loop above is the most common cause of "Sonarr keeps re-grabbing the same episode." But there's a second variant that release-group recovery alone doesn't solve: the **streaming-source flag** going missing between the indexer's release name and the actual filename.

**Real-world example:**
- Indexer title: `Family Guy S13 1080p AMZN WEB-DL DD 5.1 H.264-CtrlHD` ← scores 1785
- Filename:      `Family.Guy.S13E01.The.Simpsons.Guy.1080p.WEB-DL.DD5.1.H.264-CtrlHD.mkv` ← scores 1710

The release group `CtrlHD` is in both, so release-group recovery wouldn't change anything. The 75-point difference comes from the **AMZN** flag — the indexer says it's an Amazon source (which the TRaSH "AMZN" Custom Format scores +75), but Amazon isn't part of the actual filename. On import, Sonarr re-evaluates Custom Formats against the filename, the AMZN CF doesn't fire, the score drops by 75, and Sonarr keeps trying to grab a higher-scoring release that doesn't exist.

`tagarr_import_sonarr.sh` v1.1.0 fixes this by **renaming the qBit torrent** — not the file on disk, just the display name qBit shows — so the indexer-only tokens are present when Sonarr reads the torrent name on import. The file inside the torrent is untouched; cross-seed hardlinks are safe.

What it can recover:
- **Release group** — automatic. If the qBit torrent name lacks `-<GROUP>`, it's appended.
- **Streaming source flags (AMZN, NF, DSNP, MAX, ATVP, ...)** — only the ones you list yourself in `GRAB_RENAME_CUSTOM_TOKENS`. The config sample ships ready-to-uncomment entries for all 19 streaming services in TRaSH's `[Streaming Services] General` group. Uncomment the ones whose CFs you actually use.
- **Anything else you score by release-title regex** — the `GRAB_RENAME_CUSTOM_TOKENS` list is your escape hatch for any TRaSH or custom CF where the file naming strips the trigger token.

Anything that comes from MediaInfo (resolution, codec, HDR/HDR10+/DV, audio format, channel count) is read by Sonarr directly from the file at import time, so renaming the torrent for those is pointless — leave them out.

The grab rename is **off by default**. Enable only after configuring `QBIT_CLIENTS` (see the Sonarr config reference below). It needs the qBit Web UI URL because that's how the rename is sent.

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
| **On Grab** | Optional | Fires when Radarr sends a release to the download client. Enables the **Grab Rename** feature (`ENABLE_GRAB_RENAME`) which renames the qBit display name to match the grab title, recovering missing title-only CF tokens (release group, MA/Play WEB-DL, and Optional Movie Versions like Director's Cut / IMAX / Remaster). Only renames when meaningful tokens differ — cosmetic differences are skipped. See the `GRAB_RENAME` section in the config file for details, including Prowlarr setup and scene handling. **[EXPERIMENTAL]** |
| **On Movie File Delete For Upgrade** | No | Fires when the old file is deleted during an upgrade, right before the new file is imported. Enabling this would remove all tags and then immediately re-add them when On File Upgrade fires — unnecessary work. |

### Sonarr (tagarr_import_sonarr.sh)

1. Copy the config: `cp tagarr_import_sonarr.conf.sample tagarr_import_sonarr.conf`
2. Edit `tagarr_import_sonarr.conf` with your Sonarr URL and API key
3. In Sonarr: **Settings > Connect > + > Custom Script**
   - Name: `Tagarr Import Sonarr`
   - Path: full path to `tagarr_import_sonarr.sh`
   - Events: **On Grab**, **On File Import**, **On Upgrade** (see table below for what each one does)
4. Click **Test** — you should see a test notification in the log (and Discord if enabled)

**Which events to enable and why:**

| Event | Enable | Purpose |
|-------|--------|---------|
| **On Grab** | Yes — required for grab rename | Fires the moment Sonarr sends a torrent to qBit, before the download finishes. The script renames the qBit torrent to recover release-group and any streaming-source flags you list in `GRAB_RENAME_CUSTOM_TOKENS`. Only does something when `ENABLE_GRAB_RENAME=true` in the config; safe to wire up even if you haven't enabled grab rename yet (script exits silently in that case). |
| **On File Import** | Yes | Fires after Sonarr imports a new episode file. All per-file metadata is available: episode file ID, release group, quality, scene name. Works for both single episodes and season packs (fires once per episode). |
| **On Upgrade** | Yes | Fires after Sonarr replaces a file with a better version. Same per-file metadata as On File Import, with `sonarr_isupgrade=True` and `sonarr_deletedpaths` showing the old file. Required for both single episode upgrades and season pack upgrades. Without this, upgrades are silently ignored. |
| **On Import Complete** | No | Fires after all files from a download batch are imported. Uses plural variable names (`sonarr_episodefile_ids`, `sonarr_episodefile_releasegroups`) instead of the singular forms the script expects. Would cause the script to see an empty release group and trigger unnecessary recovery. |

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

### Grab Rename [EXPERIMENTAL]

```bash
ENABLE_GRAB_RENAME=false
GRAB_RENAME_EXCLUDE_SCENE=false
GRAB_RENAME_MOVIE_VERSION=true
```

Renames the qBit display name to match the Radarr grab title when meaningful CF tokens differ between the torrent name and the grab title. This ensures Radarr's import parser sees the full release name with all Custom Format-relevant tokens, preventing download loops where stripped torrent names cause score drops.

**Requires:** "On Grab" must be enabled in the Radarr Connect handler events.

| Option | Description |
|--------|-------------|
| `ENABLE_GRAB_RENAME` | When `true`, the script renames the qBit display name on every grab where meaningful tokens differ. Only changes the display name (cosmetic) — never touches files or folders on disk. Radarr uses this name as `sceneName` for import scoring. Cosmetic-only differences (dots vs spaces, reordering) are skipped entirely. |
| `GRAB_RENAME_EXCLUDE_SCENE` | When `true`, scene releases are detected and skipped (no rename). Scene detection uses the same pattern as TRaSH Scene CF: resolution + `WEB` without `DL`, or known scene release groups. When `false` (default), scene releases are renamed like everything else. If the rename changes Scene CF matching (e.g. `WEB` → `WEB-DL`), Discord notification includes a ⚠️ Scene CF warning. |
| `GRAB_RENAME_MOVIE_VERSION` | When `true` (default), grab rename also triggers when the release title carries any Optional Movie Version token that's missing from the qBit torrent name: Director's Cut, Theatrical, Extended, Unrated, Uncut, Remaster (also covers 4K Remaster / Remastered), Criterion, Masters of Cinema, Vinegar Syndrome, Hybrid, IMAX (also covers IMAX Enhanced), Open Matte. Covers the full TRaSH `[Optional] Movie Versions` CF group. Set to `false` if you don't score any of these Custom Formats. |
| `QBIT_CLIENTS` | Tells the script how to reach your qBittorrent. Format: `"ClientName:http://host:port"`. The ClientName should match the name of the download client in Radarr (Settings > Download Clients > Name). **If you only have one qBit**, the name doesn't need to match exactly — the script uses the only URL it finds. **If you have multiple qBit instances**, the name must match so the script routes to the right one. See [QBIT_CLIENTS Setup](#qbit_clients-setup) below for step-by-step instructions. |

**Tokens detected:** Release group, MA WEB-DL, Play WEB-DL, WEB-DL, plus the full Optional Movie Versions group when `GRAB_RENAME_MOVIE_VERSION=true` (see above). Only these trigger a rename and Discord notification. **Audio codecs and other MediaInfo-derived tokens (HDR, DV, channels, resolution) are NOT chased here** — Radarr reads those directly from the file on import, so a cosmetic rename would be pointless. You can add your own tokens via `GRAB_RENAME_CUSTOM_TOKENS` in the config if you score a custom format outside this set.

**Prowlarr setup:** This feature works best when Prowlarr is set to use the **release name** from the indexer, not the actual filename. Many release groups (e.g. 126811) strip metadata from filenames — the torrent file might be named `Movie.2024.1080p.WEB.H264` while the indexer's release name is `Movie.2024.1080p.MA.WEB-DL.TrueHD.Atmos.H.265-126811`. Using the release name gives Radarr (and this script) the full metadata.

**Trade-off:** Some trackers rename scene `WEB` releases to `WEB-DL` in their release names. This means scene releases may appear as WEB-DL instead of WEB, which bypasses the Scene CF penalty (-10000). Use `GRAB_RENAME_EXCLUDE_SCENE=true` if you prefer accurate scene detection over consistent import scoring — but note this may cause download loops for scene releases where the tracker renamed WEB to WEB-DL.

**How it relates to Recovery:** Recovery (`ENABLE_RECOVER`) fixes missing release groups **after** import. Grab rename fixes metadata **before** import, preventing the score drop that causes download loops. For affected releases, grab rename makes recovery largely redundant — the metadata is correct from the start. Both can be enabled together safely.

### QBIT_CLIENTS Setup

How to fill in the `QBIT_CLIENTS` setting in your config:

1. Open **Radarr → Settings → Download Clients**
2. Find the **Name** of your qBit client (e.g. `qBittorrent`)
3. Note the **URL** of your qBit Web UI (e.g. `http://192.168.1.100:8080`)
4. Put both in the config, separated by a colon:

```bash
QBIT_CLIENTS=(
    "qBittorrent:http://192.168.1.100:8080"
)
```

If your client name has **spaces** (e.g. "qBit Movies"), keep the quotes:

```bash
QBIT_CLIENTS=(
    "qBit Movies:http://192.168.1.100:8080"
)
```

**Multiple qBit instances:** Add one line per client. Names must match so the script knows which qBit handled each grab.

```bash
QBIT_CLIENTS=(
    "qBit-movies:http://192.168.1.100:8080"
    "qBit-4k:http://192.168.1.100:8081"
)
```

**Note:** qBit must allow API access without login (subnet whitelist or bypass auth). The script does not support username/password authentication.

**Qui users:** If you use [Qui](https://github.com/iPromKnight/qui) to manage your qBit instances, use the Qui proxy URL instead of a direct qBit URL. Create a proxy API key in Qui (Settings → Client Proxy → Create Client API Key) and use:

```bash
QBIT_CLIENTS=(
    "qBittorrent:http://your-host:7476/proxy/YOUR_PROXY_KEY"
)
```

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
| `ENABLE_RECOVER` | When `true`, the script attempts to recover missing release groups on every import. This is one of the two core features of the script — if you set this to `false`, the import-time recovery is skipped. The recovery uses the download ID from the Sonarr Connect event to find the exact grab, extract the release group, and patch it onto the episode file. |

### Grab Rename

```bash
ENABLE_GRAB_RENAME=false
```

| Option | Description |
|--------|-------------|
| `ENABLE_GRAB_RENAME` | When `true`, the script renames the qBit torrent on Sonarr's Grab event so that release-group and any custom tokens you list in `GRAB_RENAME_CUSTOM_TOKENS` end up in the torrent display name. Sonarr reads that display name on import for Custom Format scoring — without this, indexer-only tokens (like AMZN/NF/DSNP source flags) get lost between grab and import, and CF scores drop. Off by default — enable only after you've set up `QBIT_CLIENTS` below. |

**What gets renamed:** Only the qBit torrent's display name (the title qBit shows in its UI and reports via API). The actual files inside the torrent are untouched, so cross-seed hardlinks remain intact.

**When to enable:** When you've seen Sonarr re-grab the same release multiple times despite the file already being there, **and** the grab title has tokens (like `AMZN`, `NF`) that aren't in the filename. Run the script for a few days with `ENABLE_GRAB_RENAME=false` first and watch the logs to confirm the issue is happening.

### QBIT_CLIENTS Setup

```bash
QBIT_CLIENTS=(
    "qBittorrent:http://localhost:8080"
)
```

Maps the **download client name from Sonarr** to the **qBit Web UI URL**. Required when `ENABLE_GRAB_RENAME=true`.

**How to fill this in:**

1. Open **Sonarr > Settings > Download Clients** and click on your qBit entry.
2. Find the **Name** field at the top of the dialog (e.g. `qBittorrent`, `qBit-tv`).
3. Use that exact name on the **left** side of the colon below.
4. Put the qBit Web UI URL (host:port) on the **right** side.

**Concrete example:** If Sonarr's download client is named `qBit-tv` and qBit's Web UI is at `192.168.1.10:8080`:

```bash
QBIT_CLIENTS=(
    "qBit-tv:http://192.168.1.10:8080"
)
```

**Single-client setup:** If you only have one qBit instance, the name doesn't have to match — the script falls back to the only entry with an info-log notice. Multi-client setups (e.g. one qBit for movies, another for TV) **must** have the names match exactly.

**Qui proxy users:** The URL format is `http://qui:7476/proxy/<your-32-char-client-id>`. Find your client ID in Qui's settings (it's the API path the dashboard uses internally).

### GRAB_RENAME_CUSTOM_TOKENS

```bash
GRAB_RENAME_CUSTOM_TOKENS=(
    # "AMZN:\\b(amzn|amazon(hd)?)\\b"
    # "NF:\\b(nf|netflix)\\b"
    # ...
)
```

Each line is `Label:regex`. The script triggers a rename if the regex matches in the indexer's release title but **not** in the qBit torrent name. The label is what shows up in the Discord notification; the regex is bash-extended (no lookaheads).

**The config sample ships AMZN and NF uncommented by default** — common starting points for the streaming-source case. They work out of the box once `ENABLE_GRAB_RENAME=true`.

**Other services available as ready-to-uncomment entries:** ATV, ATVP, CC, DCU, DSNP, HBO, HMAX, HULU, iT, PCOK, PMTP, ROKU, SHO, STAN, SYFY. Uncomment only the ones your scoring chain actually rewards (check Sonarr > Settings > Custom Formats — anything with a positive score is a candidate). The regex patterns are simplified from TRaSH's CF specifications — TRaSH uses Perl-compatible regex with lookahead/lookbehind (e.g. "MAX but not preceded by HBO") that bash `grep -E` does not support. For streaming flags the simplifications are usually safe (a too-broad regex causes false negatives, never wrong renames, since the script only renames when the token is in the indexer title but missing from the qBit torrent name).

**MAX and PLAY are intentionally NOT in the sample** — both words are too generic on their own without lookbehind/lookahead. Add a stricter variant if you need them, e.g. `"MAX:\\bmax[ ._-]web[ ._-]?(dl|rip)\\b"`.

**Adding your own:**

```bash
GRAB_RENAME_CUSTOM_TOKENS=(
    "AMZN:\\b(amzn|amazon(hd)?)\\b"
    "MyTracker:\\bMYTRK\\b"
)
```

The regex match is case-insensitive. Word boundaries (`\b`) recommended to avoid false positives — `\\bnf\\b` matches `NF` but not `Netflix.snff`.

**What NOT to put here:** anything Sonarr can read from the file directly — resolution, codec, HDR variants, audio format, channel count. Those CFs match against MediaInfo, not the release title, so renaming the torrent for them is pointless.

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
| **Grab** | Runs the grab rename pipeline: looks up the torrent in qBit (with retry — qBit may take a second or two to index a freshly added torrent), figures out which tokens are missing from the torrent name compared to the indexer's release title, and renames the torrent if anything's missing. Off-by-default — needs `ENABLE_GRAB_RENAME=true` and `QBIT_CLIENTS` configured. Files on disk are not touched. |
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
