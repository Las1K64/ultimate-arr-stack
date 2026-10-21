# Maintenance Guide

Day-to-day operations, multi-compose commands, and verification procedures.

## Multi-Compose Quick Reference

This stack uses multiple compose files. Here are common commands for each scenario.

### Core Stack Only

```bash
# Start / recreate
docker compose -f docker-compose.arr-stack.yml up -d

# Stop without removing (Pi-hole stops too: LAN DNS is down until you start it again)
docker compose -f docker-compose.arr-stack.yml stop

# View logs
docker compose -f docker-compose.arr-stack.yml logs -f --tail=50

# Pull latest images
docker compose -f docker-compose.arr-stack.yml pull
```

### Core + Traefik (.lan domains)

```bash
# Start both
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml up -d

# Pull images for both
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml pull
```

### Core + Traefik + Cloudflared (remote access)

Cloudflared has its own project name (`cloudflared`), so give it its own command. Adding its file to the one above would make the *last* file's name win, and run the whole stack as project `cloudflared`.

```bash
# Start all three
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml up -d
docker compose -f docker-compose.cloudflared.yml up -d
```

### Utilities (independent)

```bash
# Start utilities
docker compose -f docker-compose.utilities.yml up -d

```

### Tailscale (independent)

```bash
# Start / update Tailscale (uses its own compose project name, so this won't disturb the arr-stack)
docker compose -f docker-compose.tailscale.yml up -d
docker compose -f docker-compose.tailscale.yml pull
```

### All Stacks

The three `arr-stack` files go together; Cloudflared and Tailscale are separate projects and get their own commands.

```bash
# Start everything
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.utilities.yml \
  up -d
docker compose -f docker-compose.cloudflared.yml up -d
docker compose -f docker-compose.tailscale.yml up -d

# Pull all images
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.utilities.yml \
  pull
docker compose -f docker-compose.cloudflared.yml pull
docker compose -f docker-compose.tailscale.yml pull
```

> **Never use `docker compose down`** on the arr-stack file — it removes the Pi-hole container and you lose DNS (and internet) before you can bring it back up. Use `stop` instead, or just `up -d` to recreate.

---

## VPN Verification

Verify the VPN is working and your real IP is not exposed:

```bash
# Quick check
./scripts/check-vpn.sh

# Manual check
docker exec gluetun wget -qO- https://ipinfo.io/ip     # Should show VPN IP
docker exec qbittorrent wget -qO- https://ipinfo.io/ip  # Should match Gluetun's IP
```

The `check-vpn.sh` script checks DNS, compares Gluetun's exit IP with the host's own egress (measured from Sonarr, which is off the VPN), and checks that each tunnelled service (qBittorrent, Prowlarr, SABnzbd, FlareSolverr) exits through Gluetun. It exits non-zero on a leak, a DNS failure, or a service it can't measure. You can add it to cron for periodic monitoring:

```bash
# Check every 5 minutes, log failures
*/5 * * * * $NAS_STACK_DIR/scripts/check-vpn.sh >> /var/log/vpn-check.log 2>&1
```

---

## Backups

Run periodic backups of service configs:

```bash
# Manual backup
./scripts/arr-backup.sh --tar

# Encrypted backup
./scripts/arr-backup.sh --tar --encrypt
```

See [Backup & Restore](BACKUP.md) for full details and [Restore Guide](RESTORE.md) for recovery procedures.

---

## Queue Cleanup

Torrents frequently stall (dead seeders, stuck metadata, failed imports). The cleanup script removes stuck items, blocklists them, and triggers fresh searches:

```bash
# Dry run — see what would be removed
./scripts/queue-cleanup.sh

# Actually remove stuck items
./scripts/queue-cleanup.sh --apply

# With verbose output
./scripts/queue-cleanup.sh --apply -v
```

### Automated (cron)

Add to NAS crontab (`crontab -e`):

```bash
# Thursday 2am — clean stuck downloads weekly
0 2 * * 4 $NAS_STACK_DIR/scripts/queue-cleanup.sh --apply >> $NAS_STACK_DIR/logs/queue-cleanup.log 2>&1
```

### What gets removed

- Downloads stalled with no connections (dead seeders)
- Torrents stuck downloading metadata (no peers)
- Failed imports (downloaded but can't import)
- Blocked imports (already imported, not an upgrade, missing episodes in pack)
- Import-pending items with warnings (executable files, quality not accepted)
- Items at 0% progress for more than 24 hours

Items with **any** download progress are never removed, even if slow.

**Left alone: downloads waiting for a manual import because Sonarr or Radarr matched them by ID.** An ID search lets the indexer say which show or film a release is, so Sonarr grabs releases whose names it can't recognise (a Netflix release of a Korean show under its romanised title, say). When one finishes, Sonarr won't import it on its own, by design, in case the indexer was wrong, and sends a "Needs manual import" notice. The file is usually fine, so the sweep doesn't blocklist it. It names each one in the weekly notice instead, as a `warning`, until you import it (Activity → Queue → the person icon). A grab made from Interactive Search imports normally.

Removed releases are blocklisted so the same broken release won't be grabbed again. A fresh search is triggered for each affected series/movie to find better-seeded alternatives.

---

## Stuck Requests

A request can sit undownloaded for weeks while every step reports success. Three naming authorities are involved and nothing checks that a request turned into monitored, findable episodes: Seerr follows TMDB, Sonarr follows TVDB, and release groups name files however they like. The case that prompted this check is in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#seerr-request-stuck-for-weeks-while-the-release-exists-three-naming-authorities). `scripts/check-stuck-requests.sh` reads Seerr's requests, asks Sonarr and Radarr what became of each one and Prowlarr whether the indexers have it, and posts one `info` notice to the Home Assistant panel (tag `stuck-requests`, so each day's notice replaces the last). It changes nothing in any app and posts nothing when nothing is stuck.

```bash
./scripts/check-stuck-requests.sh            # dry run: report, post nothing
./scripts/check-stuck-requests.sh --post     # post the notice if anything is stuck
./scripts/check-stuck-requests.sh --post -v  # also list the requests it judged fine
./scripts/check-stuck-requests.sh --test     # post a test notice, to prove the webhook
```

### What it reports

Each line names the title, who requested it, how long ago, and what to do:

- **Seerr never handed it over**, or marked the request *Failed* (the hand-off did not go through). Retry it from Seerr → Requests.
- **Sonarr monitored nothing.** Seerr asked for season numbers the TVDB record doesn't have (Seerr sent "season 10"; TVDB numbers that show's seasons 1964 … 2026), or every requested season is unmonitored. Re-request from the TVDB-linked entry, or monitor the season in Sonarr.
- **Aired, missing, never grabbed.** An episode aired `STUCK_DAYS` (default 3) or more days ago, has no file, and Sonarr's history holds no grab for it. A Prowlarr search for the show's title then says which it is: releases for the missing seasons under that title that Sonarr never took (if they are this show and not a same-named one, the episode numbering differs from TVDB's; grab one from Interactive Search), or nothing under that title at all (the release groups name it differently, as "70 Up" for *The Up Series*, or nobody carries it).
- **Radarr: never grabbed.** A monitored, available movie in Radarr for `MOVIE_STUCK_DAYS` (default 7) or more days with no file and no history, sorted by a Prowlarr search for its title. Only TV-style releases (`S01E01…`): a TV broadcast with a TMDB *movie* entry, which Radarr can never match; delete it and request the series. Film-style releases Radarr never took: open Interactive Search to see why it rejects them. Nothing under the title: no enabled indexer carries it. A film still in cinemas with no home release date yet, or whose home release is still to come, is waiting correctly and is not reported.
- **A monitored Sonarr series with no monitored season**, whether or not a request points at it (catches manual adds).

Thresholds come from the environment: `STUCK_DAYS=5 MOVIE_STUCK_DAYS=14 MAX_SEARCHES=20 ./scripts/check-stuck-requests.sh`. `MAX_SEARCHES` caps the Prowlarr searches per run, so a bad week doesn't spend an indexer's daily API allowance; without Prowlarr the "never grabbed" lines say so and leave the search to you. A film that isn't out yet, and an episode that was grabbed but failed to download, are left to Radarr, Sonarr and the [queue cleanup](#queue-cleanup).

### Automated (cron)

Daily is the point: a request that goes quiet shows up in the panel the day it passes the threshold, not five weeks later. On UGOS the admin user cannot write its own crontab, so install it the same way as the [audiobook mirror](#audiobooks-on-the-tv):

```bash
crontab -l > /tmp/cron.new
echo '30 8 * * * $NAS_STACK_DIR/scripts/check-stuck-requests.sh --post >> $NAS_STACK_DIR/logs/check-stuck-requests.log 2>&1' >> /tmp/cron.new
sudo crontab -u <user> /tmp/cron.new
```

Prove the webhook once with `--test` and look at the Home Assistant panel: HA answers 200 to any webhook id, so the script's "posted" line only proves the POST arrived. A notice stays in the panel after you fix the requests, until you dismiss it, because nothing is posted on a clean day.

---

## Executable Scan

Public torrent indexers sometimes serve a Windows executable padded to episode size and named after a real release group. qBittorrent rejects the usual extensions up front and Sonarr/Radarr refuse to import a release containing one — but a refused import leaves the payload in `/data/torrents`, inert on the NAS and one SMB browse away from a machine where it isn't. This reports anything already on disk:

```bash
./scripts/scan-executables.sh          # lists findings, exit 1 if any
./scripts/scan-executables.sh --quiet  # findings only, for cron
```

Weekly is plenty. Pair it with an Uptime Kuma push monitor the same way as the VPN check, or just log it:

```bash
0 4 * * 0 $NAS_STACK_DIR/scripts/scan-executables.sh --quiet >> $NAS_STACK_DIR/logs/scan-executables.log 2>&1
```

Anything it finds: verify, delete, then blocklist the release in Sonarr/Radarr (Activity → Queue → remove with **Blocklist** ticked) so the same grab isn't repeated. The e2e suite asserts the same steady state in `tests/e2e/media-hygiene.spec.ts`.

## Audiobooks on the TV

Jellyfin classifies a `.m4b` as an AudioBook, and the Android TV app cannot play AudioBook items — only the web client can. `scripts/audiobooks-tv-mirror.sh` hardlinks every `.m4b` in the audiobook folders (including the two `other` download lanes) as a `.m4a` under `/data/media/audiobooks-tv/`, where a *Music*-type Jellyfin library sees a plain audio track the TV plays. Same bytes, no extra space, originals untouched. It prunes a link whose source is gone.

```bash
./scripts/audiobooks-tv-mirror.sh --dry-run   # what it would link or prune
./scripts/audiobooks-tv-mirror.sh
```

On UGOS the admin user cannot write its own crontab (`crontab -` fails with `mkstemp: Permission denied`, and writing the spool file by hand is silently ignored — see [UTILITIES.md](UTILITIES.md#the-vpn-check-and-why-it-is-a-push-monitor)). Install it via root:

```bash
crontab -l > /tmp/cron.new
echo '*/15 * * * * $NAS_STACK_DIR/scripts/audiobooks-tv-mirror.sh >> $NAS_STACK_DIR/logs/audiobooks-tv-mirror.log 2>&1' >> /tmp/cron.new
sudo crontab -u <user> /tmp/cron.new
```

Trust it only once `logs/audiobooks-tv-mirror.log` shows a run.

The Jellyfin side is one library: Dashboard → Libraries → add a *Music* library named e.g. "Audiobooks (TV)" over `/data/media/audiobooks-tv` — see [APP-CONFIG.md § 4.1](APP-CONFIG.md#41-jellyfin-media-server). Chapter navigation exists only in the web's Books library; the TV gets resume.

## Health Checks

All services have Docker healthchecks. Check status:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Services showing `(unhealthy)` may need attention. Common causes:
- **Gluetun unhealthy**: VPN connection lost — check `docker logs gluetun`
- **qBittorrent/SABnzbd/Prowlarr unhealthy**: Often caused by Gluetun being down (they share its network). Sonarr/Radarr are on the bridge and not affected by a gluetun outage.
- **Pi-hole unhealthy**: DNS resolution failing — check upstream DNS config

---

## Updating Images

Check for available updates:

```bash
# New versions arrive as tag bumps in this repo (Renovate opens a PR for each):
# git pull, then pull and recreate what changed

# Manual check
docker compose -f docker-compose.arr-stack.yml pull
# Review what changed, then recreate
docker compose -f docker-compose.arr-stack.yml up -d
```

**Before bumping a service that owns a database** (Pi-hole's gravity/FTL config, the \*arrs' SQLite), back up its config volume first — a minor-version bump can migrate the DB irreversibly:

```bash
docker run --rm -v <project>_<service>-config:/src:ro -v "$PWD/backups":/bak \
  alpine tar czf /bak/<service>-config-backup-$(date +%Y%m%d).tgz -C /src .
# e.g. arr-stack_pihole-etc-pihole  →  backups/pihole-config-backup-YYYYMMDD.tgz
```

**Pi-hole and Cloudflared notes:** recreating Pi-hole briefly drops LAN DNS (~20-30s) — expected; verify `.lan` and external resolution after. Cloudflared runs as its **own compose project** (`-f docker-compose.cloudflared.yml`), so bump it with that file, not via the arr-stack project.

See [Upgrading Guide](UPGRADING.md) for version-specific upgrade notes.
