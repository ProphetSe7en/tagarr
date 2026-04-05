# Troubleshooting

Common issues with Tagarr and how to diagnose them. Covers all scripts — tagging, recovery, and import handlers.

---

## Tagging Issues

### "My movie wasn't tagged"

Work through this in order — each step eliminates a possible cause:

**1. Is the release group in your config?**

Check `RELEASE_GROUPS` in your `.conf` file. The group must be listed and uncommented. If it starts with `#`, it's known but not active — uncomment it.

Note: `tagarr.sh` and `tagarr_import.sh` use **separate config files** (`tagarr.conf` and `tagarr_import.conf`). A group can exist in one but not the other. Check the config for the script that should have tagged the movie.

**2. Is the mode `filtered` and the release failing filters?**

In `filtered` mode, the release must pass **both** quality and audio filters. Common reasons for failure:
- Source is AMZN, NF, DSNP, or other non-MA/Play WEB-DL → fails quality filter
- Audio is EAC3, AAC, AC3, or base DTS → fails audio filter
- Audio says "TrueHD" but also contains "upmix" or "transcode" → auto-rejected

Quick test: temporarily change the group to `:simple` mode, run `tagarr.sh --dry-run --tag yourgroup`, and see if it tags. If it does, the issue is your filters, not the group match.

**3. Does Radarr have a release group for this movie?**

Go to the movie in Radarr → click the file → check the **Release Group** field. If it's empty, Tagarr has nothing to match against. See [Release Group Issues](#release-group-issues) below.

**4. Did the import script actually run?**

Check two places:
- Radarr > System > Events — look for errors from the Custom Script
- The log file (path in your `LOG_FILE` config setting)

If neither shows the import event, the Connect handler may not be set up correctly. Verify: Radarr > Settings > Connect — the script should be listed with the correct path and events enabled.

**5. Is word boundary matching preventing the match?**

`tagarr.sh` uses word boundary matching to prevent false positives (e.g., "sic" won't match "Jurassic"). This can occasionally prevent a legitimate match if the release group appears in an unusual position in the filename. Run with `ENABLE_DEBUG=true` and `--dry-run` to see exactly what the script matched and where.

### "A movie was tagged but shouldn't have been"

The movie matched a release group and passed the filters. Run with `ENABLE_DEBUG=true` to see which field matched (`releaseGroup`, `sceneName`, or `relativePath`) and which quality/audio was detected. Common causes:
- The `search_string` is too broad (matches inside other words despite word boundaries)
- The mode is `simple` when it should be `filtered`
- The quality/audio detection matched something unexpected in the filename

### "Tags disappear after running tagarr.sh"

`tagarr.sh` re-evaluates every movie on each run. If a movie had a tag but no longer passes the filters (e.g., you tightened your audio filter), the tag is removed. This is by design — the script keeps tags in sync with the current config. Check what changed in your config or filters since the tag was applied.

---

## Release Group Issues

### "The release group is empty in Radarr"

Radarr determines the release group by parsing the filename — it looks for a `-` separator before the group name at the end. If the release group field is empty, one of these is the cause:

**The filename uses a dot separator instead of a hyphen.** Radarr expects `Movie.2024.WEB-DL-GROUP.mkv` but the file has `Movie.2024.WEB-DL.GROUP.mkv`. Radarr won't parse `.GROUP` as a release group. This is an indexer/release naming issue.

**The indexer title had the group, but the actual file inside the torrent didn't.** The indexer listing shows `Movie.2024.WEB-DL-GROUP` but the file is `Movie.2024.WEB-DL.mkv` (no group at all). Radarr imports based on the actual file, so the group is lost. This is exactly what recovery is designed to fix.

**The movie was manually imported.** No grab event exists in history, so there's nothing to recover from.

### Recovery scenarios at a glance

| Scenario | Grab title | Filename on disk | Recovery? |
|----------|-----------|-----------------|-----------|
| Normal release | `Movie.2024-GROUP` | `Movie.2024-GROUP.mkv` | Not needed — Radarr parses it |
| Missing from file | `Movie.2024-GROUP` | `Movie.2024.mkv` | Yes — recovery patches from grab |
| Dot separator | `Movie.2024.GROUP` | `Movie.2024.GROUP.mkv` | No — neither Radarr nor indexer used `-` |
| No group anywhere | `Movie.2024.1080p` | `Movie.2024.1080p.mkv` | No — nothing to recover |
| Manual import | *(no grab event)* | `Movie.2024-GROUP.mkv` | No grab history — but Radarr parses `-GROUP` from filename |

---

## Recovery Issues

### "Recovery ran but didn't fix my movie"

Recovery has different safety checks depending on which script you're using:

**`tagarr_import.sh` / `tagarr_import_sonarr.sh`** (Connect handlers) use download ID matching — the simplest and most reliable method. Recovery fails when:
- The release group was already set (recovery only fixes blanks)
- No download ID was available in the event
- No grab event with that download ID exists in history
- The grab event itself has no release group

**`tagarr_recover.sh`** (batch scanner) uses a 5-point safety chain. Recovery can be skipped for additional reasons:
- **Flagged:** The filename already contains what looks like a release group, but the app didn't parse it. These need manual review.
- **No history:** The item has no history events at all (manual import, cleared history)
- **Failed verify:** History exists but no grab could be verified — grab was pruned, download ID didn't match, or title/year fallback didn't match
- **No-RlsGroup:** A verified grab was found, but the grab itself has no release group (the indexer didn't include one)

### "Recovery fixed the wrong release group"

This is very unlikely with the import scripts (direct download ID match). With `tagarr_recover.sh`, the history walk-back logic finds the newest import event and its matching grab — it never falls through to older grabs from previous files.

If you believe the wrong group was applied, run with `--debug`:

```bash
./tagarr_recover.sh --movie <RADARR_MOVIE_ID> --debug --dry-run
```

This dumps: the current file metadata, complete history (all events with dates, source titles, download IDs), and the exact decision the script made. Include this output when reporting issues.

> **Note:** `--movie` uses Radarr's internal movie ID (visible in the URL: `/movie/6913`), not TMDb ID. For Sonarr, use `--series` with the series ID.

### "The Sonarr upgrade loop won't stop"

The scoring loop happens when: Sonarr grabs a release → the file has no release group → CF scores drop → Sonarr grabs again. `tagarr_import_sonarr.sh` breaks this by recovering the group on import. If the loop continues:

1. Check that the Connect handler is set up: Sonarr > Settings > Connect
2. Check the log file for errors
3. Verify `ENABLE_RECOVER=true` in your config
4. Check if the grab event actually has a release group: Sonarr > Series > History tab — does the grab event show a group in its source title?

If the grab has no group either, recovery can't help — the indexer itself didn't include one.

---

## Discord Issues

### "I'm not getting Discord notifications"

1. Check `DISCORD_ENABLED=true` in your config
2. Verify `DISCORD_WEBHOOK_URL` is set and correct
3. The import scripts use **smart notifications** — they only send when something happens (tag applied, group recovered, group discovered). If nothing happened, no notification is sent. Check the log file to see if the script ran and what it decided.
4. Test the webhook: click "Test" on the Connect handler in Radarr/Sonarr — you should get a test notification.

### "Discord notifications are truncated"

Lists longer than ~1800 characters are automatically split into multiple messages. If a message is still cut off, it may be a Discord API issue. Check the log file for "failed" or error HTTP codes.

---

## General

### "The script fails with 'Config not found'"

Each script looks for its config file in the same directory as the script itself, named `<script_name>.conf`. For example, `tagarr.sh` expects `tagarr.conf` in the same folder. Make sure you copied the `.conf.sample` and renamed it (remove `.sample`).

### "Permission denied"

Make sure the script is executable: `chmod +x tagarr*.sh`. If running inside Docker, ensure the scripts directory is mounted and the user inside the container has read+execute access.

### "jq: command not found"

Install jq — it's required by all scripts. On most systems: `apt install jq` (Debian/Ubuntu), `apk add jq` (Alpine), or `yum install jq` (CentOS/RHEL).
