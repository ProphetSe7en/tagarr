# Tagarr Migration & Auto-Update Guide

Complete guide for `tagarr_migrate.sh` — the tool that keeps your tagarr scripts and configs up to date.

For the main tagger, see [tagarr-guide.md](tagarr-guide.md). For the import handlers, see [tagarr-import-guide.md](tagarr-import-guide.md).

---

## Prerequisites

- **bash 4+**, **curl**, and **jq** installed where the script runs
- Script must be executable: `chmod +x tagarr_migrate.sh`

---

## What Does This Script Do?

`tagarr_migrate.sh` does two things:

### 1. Config Migration (always on)

When a new version of tagarr adds settings to a config file (like `tagarr_import.conf`), your existing config doesn't have those new settings. Instead of manually comparing your config against the latest sample, the migration script does it for you:

- Downloads the latest `.conf.sample` from GitHub
- Adds any new settings with safe defaults
- Keeps all your existing values exactly as they were
- Backs up your original config to `tagarr_backups/` with a date stamp

You don't need to configure anything for this — it runs automatically.

### 2. Script Auto-Update (opt-in)

If enabled, the script can also update your tagarr `.sh` files to the latest version from GitHub. This is **off by default** — you enable it per script by creating a `tagarr_migrate.conf` file.

When enabled for a script:
- Checks the script's version against `versions.json` on GitHub
- Only updates if a newer version exists (never downgrades)
- Backs up the old script to `tagarr_backups/` with a date stamp before replacing
- Preserves file permissions and ownership

---

## Quick Start

### Config migration only (no setup needed)

```bash
# Run from the directory where your tagarr scripts live
./tagarr_migrate.sh
```

That's it. The script finds all tagarr `.conf` files in the directory and migrates any that are behind the latest sample version.

### Enable script auto-update

```bash
# 1. Download the sample config
curl -O https://raw.githubusercontent.com/ProphetSe7en/tagarr/main/tagarr_migrate.conf.sample

# 2. Copy it to create your config
cp tagarr_migrate.conf.sample tagarr_migrate.conf

# 3. Edit tagarr_migrate.conf — remove the # in front of
#    any script you want auto-updated

# 4. Run
./tagarr_migrate.sh
```

---

## How to Set Up Auto-Update

Open `tagarr_migrate.conf` in a text editor. You'll see a list of all tagarr scripts, each with two lines:

```bash
# tagarr_import.sh — Radarr import tagger (runs on every movie import)
#AUTOUPDATE_TAGARR_IMPORT=true
#AUTOUPDATE_TAGARR_IMPORT_DIR=""
```

**To enable auto-update for a script:** Remove the `#` in front of `AUTOUPDATE_<SCRIPT>=true`:

```bash
AUTOUPDATE_TAGARR_IMPORT=true
```

**That's all you need for scripts in the same folder as `tagarr_migrate.sh`.**

### Scripts in a Different Folder

If a script lives somewhere else (for example, Radarr Connect scripts often live in the Radarr appdata folder), set the `_DIR` line to point there:

```bash
AUTOUPDATE_TAGARR_IMPORT=true
AUTOUPDATE_TAGARR_IMPORT_DIR="/mnt/user/appdata/radarr/scripts"
```

When you set a `_DIR` path, the script does two things in that folder:
1. Updates the `.sh` script (if auto-update is enabled for it)
2. Migrates any tagarr `.conf` files found there

This means your config file in that folder (like `tagarr_import.conf`) gets migrated too — you don't need to run migrate separately against it.

### Example — Typical Setup

Scripts in two places: main folder for cron scripts, Radarr appdata for the Connect handler.

```bash
# Main folder (same as tagarr_migrate.sh)
AUTOUPDATE_TAGARR=true
AUTOUPDATE_TAGARR_LIST=true
AUTOUPDATE_TAGARR_RECOVER=true
AUTOUPDATE_TAGARR_REMOVE=true
AUTOUPDATE_TAGARR_RENAME=true

# Radarr Connect handler (different folder)
AUTOUPDATE_TAGARR_IMPORT=true
AUTOUPDATE_TAGARR_IMPORT_DIR="/mnt/user/appdata/radarr/scripts"

# Sonarr Connect handler (different folder)
AUTOUPDATE_TAGARR_IMPORT_SONARR=true
AUTOUPDATE_TAGARR_IMPORT_SONARR_DIR="/mnt/user/appdata/sonarr/scripts"
```

Running `./tagarr_migrate.sh` with this config:
- Updates 7 scripts across 3 folders
- Migrates all tagarr `.conf` files found in those 3 folders
- Logs everything to `logs/tagarr_migrate.log`

---

## Running on a Schedule

You can schedule `tagarr_migrate.sh` to run automatically (e.g. weekly via cron). This way your scripts and configs stay up to date without manual intervention.

```bash
# Example cron — every Sunday at 4 AM
0 4 * * 0 /path/to/tagarr_migrate.sh >> /dev/null 2>&1
```

Every run is logged to `logs/tagarr_migrate.log` with timestamps, so you can verify what happened:

```
2026-04-20 04:00:15 run start
2026-04-20 04:00:17 scripts: 0 updated, 7 current/skipped, 0 failed
2026-04-20 04:00:19 config current: tagarr_import.conf (v1.5) — /appdata/radarr/scripts/tagarr_import.conf
2026-04-20 04:00:19 configs: 8 scanned across 3 dir(s)
2026-04-20 04:00:19 run complete
```

When a script is actually updated:

```
2026-04-27 04:00:16 script updated: tagarr_import.sh v1.5.8 -> v1.5.9 in /appdata/radarr/scripts
```

---

## Self-Update

`tagarr_migrate.sh` updates itself automatically on every run. Before doing anything else, it checks GitHub for a newer version of itself. If one exists, it downloads and re-runs. You don't need to update the migration script manually.

To skip this (e.g. for offline testing): `./tagarr_migrate.sh --no-update`

---

## Rolling Back

Every update creates a dated backup in a `tagarr_backups/` folder next to the file it replaced:

```
tagarr_backups/
  tagarr_import.sh.2026-04-17
  tagarr_import.sh.2026-04-20
  tagarr_import.conf.2026-04-17
  tagarr_import.conf.2026-04-20
```

To undo an update, copy the backup back:

```bash
cp tagarr_backups/tagarr_import.sh.2026-04-17 tagarr_import.sh
```

All backups are kept — you can go back to any previous version by date.

---

## Configuration Reference

### tagarr_migrate.conf

| Setting | Description |
|---------|-------------|
| `AUTOUPDATE_TAGARR=true` | Enable auto-update for `tagarr.sh` (batch tagger) |
| `AUTOUPDATE_TAGARR_IMPORT=true` | Enable auto-update for `tagarr_import.sh` (Radarr Connect) |
| `AUTOUPDATE_TAGARR_IMPORT_SONARR=true` | Enable auto-update for `tagarr_import_sonarr.sh` (Sonarr Connect) |
| `AUTOUPDATE_TAGARR_LIST=true` | Enable auto-update for `tagarr_list.sh` (list tagger) |
| `AUTOUPDATE_TAGARR_RECOVER=true` | Enable auto-update for `tagarr_recover.sh` (batch recovery) |
| `AUTOUPDATE_TAGARR_REMOVE=true` | Enable auto-update for `tagarr_remove.sh` (tag removal) |
| `AUTOUPDATE_TAGARR_RENAME=true` | Enable auto-update for `tagarr_rename.sh` (tag renaming) |

Each script also has a `_DIR` setting for scripts in a different folder:

| Setting | Description |
|---------|-------------|
| `AUTOUPDATE_<SCRIPT>_DIR="/path"` | Where this script (and its config) lives. Leave blank or remove to use the same folder as `tagarr_migrate.sh`. |

### Command Line

| Command | What It Does |
|---------|-------------|
| `./tagarr_migrate.sh` | Update scripts + migrate all configs found |
| `./tagarr_migrate.sh tagarr_import.conf` | Migrate just that one config (+ update scripts) |
| `./tagarr_migrate.sh --no-update` | Skip self-update of the migrate script |
| `./tagarr_migrate.sh --help` | Show help |

---

## FAQ

### Do I need tagarr_migrate.conf to use config migration?

No. Config migration works without it — the script always scans the folder it's in for tagarr `.conf` files and migrates any that are behind. `tagarr_migrate.conf` is only needed if you want script auto-update or if your scripts live in a different folder.

### Will auto-update break my configs?

No. Auto-update only replaces `.sh` script files. Your `.conf` files are never touched by auto-update — they're handled separately by config migration, which preserves all your values.

### What if I have scripts in multiple folders?

Set the `_DIR` line for each script that lives elsewhere. The script scans every folder you point it at — you don't need to run migrate multiple times.

### Can I update scripts without migrating configs?

Not separately — both happen in the same run. But config migration is safe: if your config is already up to date, it's skipped with "Nothing to do." No unnecessary writes.

### What if the download fails?

The script checks two things before replacing a file:
1. The download must start with a `#!` (shebang) — proves it's a script, not an error page
2. The download must contain `SCRIPT_VERSION=` — proves it's a tagarr script

If either check fails, the update is skipped and the failure is logged. Your existing script stays untouched.

### What if I want to stop auto-updating a script?

Add a `#` back in front of the line in `tagarr_migrate.conf`:

```bash
#AUTOUPDATE_TAGARR_IMPORT=true
```

Or delete `tagarr_migrate.conf` entirely to disable all auto-updates.
