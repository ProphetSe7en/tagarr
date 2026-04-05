# Tagarr

Automated movie tagging for [Radarr](https://radarr.video/) based on release groups, with release group recovery for both Radarr and [Sonarr](https://sonarr.tv/).

## What Does This Do?

When you download movies through Radarr, each release comes from a **release group** (like FLUX, BHD, FraMeSToR, etc.). Some groups consistently deliver premium quality — lossless audio (TrueHD Atmos, DTS:X), high-bitrate encodes, or WEB-DLs from premium sources like Movies Anywhere.

Tagarr automatically **tags movies in Radarr** based on which release group made the file, with optional quality and audio filtering so only premium releases get tagged. It also **recovers missing release groups** in both Radarr and Sonarr by looking up the original grab in history.

> **Warning:** These scripts modify Radarr/Sonarr metadata (tags, release groups) and
> can trigger file renames. Always run in dry-run mode first and review the
> output before using `--live`. Use at your own risk.

---

## Guides

| Guide | Script(s) | What It Covers |
|-------|-----------|---------------|
| **[Batch Tagger](docs/tagarr-guide.md)** | `tagarr.sh` | Library scanning, quality/audio filters, discovery, dual instance sync. **Start here.** |
| **[Recovery](docs/tagarr-recover-guide.md)** | `tagarr_recover.sh` | Batch release group recovery, 5-point safety chain, Radarr + Sonarr. |
| **[Import Handlers](docs/tagarr-import-guide.md)** | `tagarr_import.sh`, `tagarr_import_sonarr.sh` | Real-time Connect handlers for tagging (Radarr) and recovery (Sonarr). |
| **[Troubleshooting](docs/troubleshooting.md)** | All | Common issues, screenshots, debug instructions, reporting. |

**New to Tagarr?** Start with the [Batch Tagger Guide](docs/tagarr-guide.md) — it explains the core concepts and includes the [recommended workflow](docs/tagarr-guide.md#overall-workflow--how-the-scripts-work-together) for setting up all scripts.

---

## Quick Start

```bash
git clone https://github.com/prophetse7en/tagarr.git
cd tagarr && chmod +x tagarr*.sh
```

**Requirements:** Radarr v3+ and/or Sonarr v3+, bash 4+, jq, curl

```bash
# 1. Configure
cp tagarr.conf.sample tagarr.conf && nano tagarr.conf

# 2. Fix missing release groups in your backlog
./tagarr_recover.sh --live

# 3. Tag your library
./tagarr.sh

# 4. Set up Connect handlers for real-time (see Import Guide)
# 5. Schedule tagarr.sh + tagarr_recover.sh as a safety net
```

---

## Scripts

### Core Scripts

| Script | App | Purpose | Run As |
|--------|-----|---------|--------|
| `tagarr.sh` | Radarr | Scan all movies, tag by release group with filters | Schedule or manual |
| `tagarr_recover.sh` | Both | Fix missing release groups from grab history | Schedule or manual |
| `tagarr_import.sh` | Radarr | Tag + recover + discover on every import | [Radarr Connect](docs/tagarr-import-guide.md#setup) |
| `tagarr_import_sonarr.sh` | Sonarr | Recover missing release groups on every import | [Sonarr Connect](docs/tagarr-import-guide.md#setup) |

### Utility Scripts

**`tagarr_list.sh`** — Tags movies from TMDb or Trakt lists. Useful for curated collections like "Reference Audio", "Oscar Winners", or director filmographies. Define lists in `tagarr_list.conf` with format `"source:list_id:tag_name:display_name"`. Runs on a schedule or manually.

**`tagarr_remove.sh`** — Bulk-removes one or more tags from all movies in one or both Radarr instances. Useful when you want to clean up old tags or start fresh. Dry-run by default.

**`tagarr_rename.sh`** — Renames a tag (old name → new name) and migrates all movies to the new tag. Useful when you want to change a tag's name without re-running the full tagger. Dry-run by default.

> All scripts default to **dry-run mode** — no changes until you pass `--live`.

---

## Support

- **Discord:** [`#prophetse7en-apps`](https://discordapp.com/channels/492590071455940612/1486391669384417300) on the [TRaSH Guides Discord](https://trash-guides.info/discord) (under Community Apps)
- **GitHub:** [prophetse7en/tagarr/issues](https://github.com/prophetse7en/tagarr/issues)

## License

[MIT](LICENSE)
