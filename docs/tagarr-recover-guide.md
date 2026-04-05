# Tagarr Recover Guide — Release Group Recovery for Radarr and Sonarr

Complete guide for `tagarr_recover.sh` — what it does, how it works, and every configuration option explained.

For the batch tagger (`tagarr.sh`), see [tagarr-guide.md](tagarr-guide.md). For the full toolset overview, see [README.md](../README.md).

---

## Prerequisites

- **Radarr v3+** and/or **Sonarr v3+** with API access enabled (Settings > General > API Key)
- **bash 4+**, **jq**, and **curl** installed on the machine running the script
- The script must be executable: `chmod +x tagarr_recover.sh`

### Setup

```bash
# Copy the sample config
cp tagarr_recover.conf.sample tagarr_recover.conf

# Edit with your Radarr/Sonarr URLs and API keys
nano tagarr_recover.conf
```

The config file must be in the same directory as the script and named `tagarr_recover.conf` (without `.sample`).

---

## What is Tagarr Recover?

Tagarr Recover fixes movies and episodes where Radarr or Sonarr shows **no release group** even though one existed when the file was downloaded.

This happens because of a mismatch between the **indexer title** (what your tracker/indexer listed) and the **actual filename** inside the torrent. The indexer title might be `Movie.2024.MA.WEB-DL.TrueHD.Atmos-FLUX`, but the actual file inside the torrent is just `Movie.2024.MA.WEB-DL.TrueHD.Atmos.mkv` — no `-FLUX` at the end. Radarr stores the filename, not the indexer title, so the release group is lost.

Tagarr Recover looks up the original **grab event** in Radarr/Sonarr's history, extracts the release group from it, and patches it back onto the movie or episode file.

---

## Why Does This Matter?

A missing release group breaks anything that depends on it:

- **Custom Format scoring** — CFs that match by release group (e.g., "prefer FLUX releases") can't score what they can't see
- **Tagarr tagging** — `tagarr.sh` matches by release group — no group means no tag
- **File renaming** — If your naming format includes `{Release Group}`, the filename shows nothing or "Unknown" instead of the actual group
- **Upgrade loops** — Sonarr/Radarr may keep downloading the same release because the CF score drops after import (group disappears, score drops, app thinks it can upgrade)

This is especially common with certain release groups (like 126811 — a well-known WEB-DL group) where the tracker includes the group name in the release title but the actual files inside the torrent don't.

---

## How It Works

When you run `tagarr_recover.sh`, this is what happens:

1. **Connect** — Verifies that Radarr/Sonarr is reachable
2. **Fetch** — Downloads all movies or series from the API
3. **Filter** — Finds items where `releaseGroup` is empty, null, or "Unknown"
4. **For each affected item**, runs the **5-point safety chain**:

### The 5-Point Safety Chain

Every item goes through five checks before any fix is applied. If any check fails, the item is skipped.

| Check | What It Does | Why |
|-------|-------------|-----|
| **1. Blanks only** | Only processes items where releaseGroup is empty. Never overwrites an existing group. | Prevents corrupting a group that Radarr/Sonarr already parsed correctly. |
| **2. Filename check** | Extracts text after the last `-` in the filename and checks if it looks like a release group. If the filename already contains a group that the app didn't parse, the item is **flagged** instead of auto-fixed. | Catches cases where the group IS in the filename but the app failed to parse it (e.g., unusual formatting). These need manual review — auto-fixing from history could set a different group than what's actually in the file. |
| **3. Import-verified grab** | Finds the **newest import event** in the item's history, then finds the **grab event** that produced that import (matched by download ID). Only uses grabs that were actually successfully imported. | Prevents recovering from a failed download, a rejected grab, or an old grab that belongs to a previous version of the file. |
| **4. Non-empty group** | The grab event must actually contain a release group value. | Some grabs have no group (the indexer itself didn't include one). Nothing to recover. |
| **5. Title+year match** | The grab's source title must match the movie/series title and year. | Final sanity check — confirms the grab event is for the correct item. Prevents cross-contamination when history contains events for different versions. |

After the safety chain passes:

6. **Fix** — Patches the release group onto the movie/episode file in Radarr/Sonarr's database
7. **Rename** (optional but recommended) — Triggers Radarr/Sonarr's RenameFiles command so the recovered group is written into the actual filename on disk. This makes the fix **permanent** — Radarr/Sonarr reads the release group from the filename, so without rename the group only exists in the database and will be lost on the next library rescan, app restart, or any other event that re-parses the filename.
8. **Notify** — Sends results to Discord

### The History Walk-Back

The core of the recovery logic is the **import-verified grab lookup**. It works like this:

1. Fetch the item's complete history (all events, sorted newest first)
2. Find the **newest import event** — this is the event that created the current file
3. Get that import's `downloadId`
4. Search for a **grab event** with the same `downloadId` — this is the grab that initiated the download that was imported
5. If found: extract the release group from the grab
6. If not found (grab pruned from history): fall back to title+year matching

This two-step approach (find import first, then its grab) is critical. Without it, the script could match an old grab from a previous download that has a completely different release group. The walk-back logic was rewritten in v2.0.0 to fix exactly this bug.

---

## Radarr vs Sonarr

The script works with both apps but the data structure differs:

| | Radarr | Sonarr |
|---|--------|--------|
| **Unit** | Movie | Episode file |
| **History** | Per movie (`/history/movie?movieId=X`) | Per series (`/history/series?seriesId=X`), filtered by episode ID |
| **Fix** | PUT `/moviefile/{id}` | PUT `/episodefile/{id}` |
| **Rename** | `RenameFiles` with `movieId` | `RenameFiles` with `seriesId` |
| **Filtering** | `--movie ID` for single movie | `--series ID` for single series |

When processing Sonarr, the script fetches all series, then for each series fetches its episode files and filters to those with missing release groups. History is fetched once per series (not per episode) and then filtered by episode ID for efficiency.

---

## When to Use This

### Fixing your existing library (first-time setup)

You've just installed Tagarr and want to tag your library, but many movies have empty release groups. Tagarr can't tag what it can't see. Run recover first to patch the missing groups, then run `tagarr.sh` to tag everything.

```bash
# See how many movies/episodes are affected (dry-run is the default — no changes are made)
./tagarr_recover.sh

# Fix them all (--live applies the changes)
./tagarr_recover.sh --live
```

This is the most common use case — a one-time cleanup of your backlog before setting up the import handlers for real-time processing.

### Stopping Sonarr upgrade loops

Sonarr keeps re-downloading the same episode because Custom Format scores drop after import. This happens when the release group is in the indexer title but not in the filename — the CF score is high during grab but drops to zero after import. Recover fixes the group, the CF score holds, and the loop stops.

```bash
# Fix all Sonarr episodes with missing groups
./tagarr_recover.sh --app sonarr --live
```

After this, set up `tagarr_import_sonarr.sh` as a Connect handler to prevent new loops from starting. See [tagarr-import-guide.md](tagarr-import-guide.md).

### Making Custom Formats work correctly

You've set up Custom Formats that score by release group (e.g., +1000 for FLUX), but the scores aren't applying. Check your movies — if the release group field is empty in Radarr, the CF has nothing to match. Recover patches the groups back, and the CF scores apply.

### Getting release groups into filenames

Your naming format includes `{Release Group}` but many files show "Unknown" or nothing where the group should be. Recover patches the group and triggers a rename — the group appears in the filename permanently.

```bash
# Fix groups and rename files
./tagarr_recover.sh --live

# Fix groups but don't rename (if you have cross-seed hardlinks etc.)
./tagarr_recover.sh --live --no-rename
```

### Only processing one instance (dual setups)

If you have two Radarr instances (e.g., HD + 4K), you can target just one:

```bash
# Only process secondary Radarr instance
./tagarr_recover.sh --app radarr --instance secondary --live

# Only process primary Sonarr instance
./tagarr_recover.sh --app sonarr --instance primary --live
```

### Debugging a specific movie or series

A movie should have been fixed but wasn't. Use debug mode to see exactly what the script found in history and why it skipped the item.

```bash
# Radarr — movie ID from the URL (/movie/6913)
./tagarr_recover.sh --movie 6913 --debug

# Sonarr — series ID from the URL (/series/5)
./tagarr_recover.sh --app sonarr --series 5 --debug
```

Include this output when reporting issues — without it, diagnosing the problem is very difficult.

### Running on a schedule as a safety net

The import scripts (`tagarr_import.sh`, `tagarr_import_sonarr.sh`) handle new downloads in real-time, but they can miss events — app restarts, Connect timeouts, script errors. Schedule recover as a catch-all:

```bash
# Daily or weekly via cron/Cronicle:
./tagarr_recover.sh --live
```

The script is idempotent — items already fixed (release group no longer empty) are skipped automatically. Safe to run as often as you want.

---

## Configuration Reference

Every option in `tagarr_recover.conf` explained in detail.

### Default App

```bash
DEFAULT_APP="both"
```

| Option | Description |
|--------|-------------|
| `DEFAULT_APP` | Which application to process when `--app` is not specified on the command line. Options: `radarr` (movies only), `sonarr` (series only), `both` (process Radarr first, then Sonarr). Can always be overridden with `--app` on the command line. If you only have Radarr, set this to `radarr` to skip the Sonarr connection attempt. |

### Primary Radarr

```bash
PRIMARY_RADARR_URL="http://localhost:7878"
PRIMARY_RADARR_API_KEY="your-api-key-here"
PRIMARY_RADARR_NAME="Radarr"
```

| Option | Description |
|--------|-------------|
| `PRIMARY_RADARR_URL` | Full URL to your Radarr instance, including port. No trailing slash. |
| `PRIMARY_RADARR_API_KEY` | API key from Radarr > Settings > General > API Key. |
| `PRIMARY_RADARR_NAME` | Display name used in logs and Discord notifications. Can be anything. |

### Secondary Radarr (optional)

```bash
ENABLE_SECONDARY_RADARR=false
SECONDARY_RADARR_URL="http://localhost:7979"
SECONDARY_RADARR_API_KEY="your-api-key-here"
SECONDARY_RADARR_NAME="Radarr 4K"
```

| Option | Description |
|--------|-------------|
| `ENABLE_SECONDARY_RADARR` | Set to `true` if you have a second Radarr instance (e.g., 4K). When enabled, the script processes both instances independently — each instance's movies are scanned and fixed using that instance's own history. Unlike `tagarr.sh` which mirrors tags from primary to secondary, recover processes each instance on its own because history and file metadata are per-instance. Set to `false` if you only have one Radarr instance. |
| `SECONDARY_RADARR_URL` | Full URL to your second Radarr instance. |
| `SECONDARY_RADARR_API_KEY` | API key for the secondary instance. |
| `SECONDARY_RADARR_NAME` | Display name for the secondary instance. |

### Primary Sonarr

```bash
PRIMARY_SONARR_URL="http://localhost:8989"
PRIMARY_SONARR_API_KEY="your-api-key-here"
PRIMARY_SONARR_NAME="Sonarr"
```

| Option | Description |
|--------|-------------|
| `PRIMARY_SONARR_URL` | Full URL to your Sonarr instance, including port. No trailing slash. |
| `PRIMARY_SONARR_API_KEY` | API key from Sonarr > Settings > General > API Key. |
| `PRIMARY_SONARR_NAME` | Display name for logs and Discord. |

### Secondary Sonarr (optional)

```bash
ENABLE_SECONDARY_SONARR=false
SECONDARY_SONARR_URL="http://localhost:8990"
SECONDARY_SONARR_API_KEY="your-api-key-here"
SECONDARY_SONARR_NAME="Sonarr 4K"
```

| Option | Description |
|--------|-------------|
| `ENABLE_SECONDARY_SONARR` | Same as `ENABLE_SECONDARY_RADARR` but for Sonarr. Set to `true` if you have two Sonarr instances. Each is processed independently. |
| `SECONDARY_SONARR_URL` | Full URL to your second Sonarr instance. |
| `SECONDARY_SONARR_API_KEY` | API key for the secondary Sonarr instance. |
| `SECONDARY_SONARR_NAME` | Display name for the secondary Sonarr instance. |

### Rename

```bash
ENABLE_RENAME=true
```

| Option | Description |
|--------|-------------|
| `ENABLE_RENAME` | When `true`, Tagarr Recover triggers Radarr/Sonarr's `RenameFiles` command after fixing each item's release group. This renames the actual file on disk to include the recovered group — but **only if your naming format includes `{Release Group}`**. If your naming format doesn't include the group token, enabling this does nothing harmful but wastes an API call. Set to `false` if you don't want file renames, or use `--no-rename` on the command line to override. |

**Why rename matters:** Without rename, the recovered release group only exists in Radarr/Sonarr's database — not in the filename on disk. The fix works immediately, but the next time the app re-reads the file (library rescan, database rebuild, app update), it parses the filename again and finds no group. The fix is lost. Rename writes the group into the filename, making the recovery permanent.

**Trade-off:** Renaming changes the filename on disk. If other tools reference the exact filename (cross-seed hardlinks, external media players with bookmarks), a rename could break those references. In most setups, rename is the right choice — the permanent fix outweighs the risk.

### Dry-Run

```bash
ENABLE_DRY_RUN=true
```

| Option | Description |
|--------|-------------|
| `ENABLE_DRY_RUN` | The default run mode. When `true`, the script shows what would be fixed but makes no changes to Radarr/Sonarr. Override with `--live` on the command line to execute fixes. It is strongly recommended to leave this as `true` and explicitly pass `--live` when you want to apply changes — this prevents accidental modifications if the script is run without arguments. |

### Discord Notifications

```bash
DISCORD_ENABLED=false
DISCORD_WEBHOOK_URL=""
```

| Option | Description |
|--------|-------------|
| `DISCORD_ENABLED` | Set to `true` to send results to Discord after each run. Sends a summary embed (mode, counts, runtime) plus separate lists for fixed items (green), flagged items (amber), and skipped items (grey). |
| `DISCORD_WEBHOOK_URL` | Your Discord webhook URL. Create one in Discord: Server Settings > Integrations > Webhooks > New Webhook. |

**Discord notification categories:**

| Category | Color | Meaning |
|----------|-------|---------|
| **Fixed** | Green | Items where the release group was successfully recovered (or would be in dry-run) |
| **Flagged** | Amber | Items where the filename contains a release group but the app didn't parse it. Needs manual review — the group in the filename might differ from the grab history |
| **Skipped** | Grey | Items that couldn't be fixed: no history, no verified grab, no group in history, or verification failed |

### Logging

```bash
ENABLE_LOGGING=true
LOG_FILE="${SCRIPT_DIR}/logs/tagarr_recover.log"
```

| Option | Description |
|--------|-------------|
| `ENABLE_LOGGING` | When `true`, all terminal output is also written to the log file with timestamps. ANSI color codes are stripped from the log file for clean text. |
| `LOG_FILE` | Path to the log file. The directory is created automatically. Rotated at 2 MiB (keeps one `.old` backup). |

---

## Command Line Options

```bash
./tagarr_recover.sh [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `--app TYPE` | Which application to process: `radarr`, `sonarr`, or `both`. Overrides `DEFAULT_APP` in config. |
| `--dry-run` | Preview what would be fixed, no changes made. This is the default. |
| `--live` | Execute the fixes. Patches release groups and optionally renames files. |
| `--instance TYPE` | Which instance to process: `primary`, `secondary`, or `both`. Default: `both`. |
| `--movie ID` | Process a single movie by Radarr movie ID. Automatically sets `--app radarr`. The ID is Radarr's internal ID (visible in the URL: `/movie/6913`), not TMDb ID. |
| `--series ID` | Process a single series by Sonarr series ID. Automatically sets `--app sonarr`. The ID is Sonarr's internal ID (visible in the URL: `/series/5`). |
| `--no-rename` | Skip the file rename step even in live mode. Useful if you want to fix the metadata but not touch filenames. |
| `--debug` | Dump full data for each affected item: file metadata from the API, complete history (all events with dates, source titles, download IDs, release groups), and the exact decision the script made. Essential for troubleshooting. |
| `--help` | Show usage and examples. |

---

## Understanding the Output

### Status Categories

Each affected item gets one of these outcomes:

| Status | What It Means |
|--------|--------------|
| **Fixed** | Release group recovered from grab history and patched (or would be, in dry-run). In live mode, the file is also renamed if `ENABLE_RENAME=true`. |
| **Flagged** | The filename already contains what looks like a release group (text after the last `-`), but Radarr/Sonarr didn't parse it. This usually means the group is there but in an unusual format. Flagged items are NOT auto-fixed — they need manual review because the group in the filename might differ from the group in grab history. |
| **No-RlsGroup** | A verified grab was found (the download ID matched an import), but the grab itself has no release group. The indexer didn't include a group in the release name. Nothing to recover. |
| **No History** | The item has no history events at all. This happens with manually imported files or when Radarr/Sonarr's history has been cleared. No grab to recover from. |
| **Failed Verify** | History exists but no grab could be verified. Either the grab was pruned (history auto-cleanup removed it), the download ID didn't match any import, or the title+year fallback didn't match. |

### What "Flagged" Means in Practice

When a movie is flagged, it means:
- The file on disk is `Movie.2024.MA.WEB-DL.TrueHD.Atmos-FLUX.mkv`
- Radarr's release group field is empty
- The script found "FLUX" after the last `-` in the filename

This is unusual — Radarr should have parsed `-FLUX` from the filename. Possible causes:
- Radarr bug or edge case in filename parsing
- The file was renamed manually after import
- An unusual filename structure confused the parser

These items are not auto-fixed because the group in grab history might be different from what's in the filename (e.g., if the file was replaced by a different release). Manual review is needed.

---

## FAQ

### Is this safe to run on a schedule?

Yes. The script is idempotent — it only processes items with empty release groups. Items already fixed are skipped. Dry-run is the default, so even if someone runs it without `--live`, nothing happens.

### Will this fix the Sonarr upgrade loop?

Yes, this is one of the main use cases. When Sonarr grabs a release where the indexer title has a group but the file doesn't, Custom Format scores drop after import. Sonarr sees a lower score and grabs again, creating a loop. Fixing the release group restores the CF score and stops the cycle.

### What if the grab history is wrong?

The safety chain (especially the download ID matching) makes this very unlikely. The script matches the **exact grab** that produced the **current import** — not just any grab in history. If you're worried, run with `--dry-run` first and review the output.

### Can I run this alongside tagarr_import.sh?

Yes, they complement each other. `tagarr_import.sh` (Radarr) and `tagarr_import_sonarr.sh` (Sonarr) fix groups on import in real-time using the download ID from the event — simpler and more reliable for new imports. `tagarr_recover.sh` is the batch scanner for your existing library — it catches everything that was imported before the Connect scripts were set up, or where the Connect script wasn't triggered.

### Why does it process both Radarr and Sonarr by default?

Because missing release groups can occur in both apps, and fixing them is independent — each app uses its own history. If you only have one app, set `DEFAULT_APP` in the config to skip the connection attempt for the other.
