#!/bin/bash
set -euo pipefail
#
# Find media requests stuck between Seerr, Sonarr/Radarr and the indexers
#
# A request can sit undownloaded for weeks while every step reports success.
# Three naming authorities are involved and nothing checks that a request
# turned into monitored, findable episodes: Seerr follows TMDB, Sonarr follows
# TVDB, and the release groups name files however they like. In September 2026
# two requests for a two-part ITV documentary sat five weeks while both parts
# were on the indexers at 1080p the whole time: a TMDB *movie* entry for a TV
# broadcast kept Radarr looking for a film that doesn't exist, and a duplicate
# TMDB TV entry made Seerr ask Sonarr for "season 10" of a show whose TVDB
# seasons are named by year (1964 … 2026), so Sonarr monitored nothing and
# Seerr logged "accepted". This check finds that class of silence and posts one
# notice a day to the Home Assistant panel.
#
# Usage:
#   ./scripts/check-stuck-requests.sh           # dry run (default): report, post nothing
#   ./scripts/check-stuck-requests.sh --post    # also post the notice to Home Assistant
#   ./scripts/check-stuck-requests.sh --post -v # with the requests it judged fine
#   ./scripts/check-stuck-requests.sh --test    # post a test notice, whatever it finds
#
#   STUCK_DAYS=3 MOVIE_STUCK_DAYS=7 ./scripts/check-stuck-requests.sh   # thresholds
#
# Cron (daily, 08:30):
#   30 8 * * * $NAS_STACK_DIR/scripts/check-stuck-requests.sh --post >> $NAS_STACK_DIR/logs/check-stuck-requests.log 2>&1
#
# Prerequisites:
#   - Seerr, Sonarr and Radarr running, with their ports published on localhost
#   - python3 and curl available
#   - HA_WEBHOOK_URL in .env (see docs/HOME-ASSISTANT.md) for --post
#
# What it reports, each with the title, who asked, how long ago, and what to do:
#   - Seerr approved a request but never handed it to Sonarr/Radarr, or marked
#     it FAILED (the hand-over failed, typically during a VPN blip).
#   - Sonarr monitored nothing for a TV request: Seerr asked for season numbers
#     that don't exist in the TVDB record, or every requested season is
#     unmonitored.
#   - Episodes aired at least STUCK_DAYS ago, still missing, and Sonarr has
#     never grabbed them: the indexers probably name the show differently.
#   - A Radarr movie that is available, in Radarr for MOVIE_STUCK_DAYS or more,
#     with no file and nothing ever grabbed: often a TV broadcast with a TMDB
#     movie entry, which Radarr can never match.
#   - Any monitored Sonarr series with no monitored season, request or not.
#
# One notice, level "info" (panel only), tag "stuck-requests" so each day's
# notice replaces the last. Nothing is posted when nothing is stuck. The check
# changes nothing in any app.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It only reads from the apps' APIs;
#     --post sends one HTTP POST to your own Home Assistant.
#

# Derive stack directory from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"

# Cron hands the script no environment and nothing else loads .env, so read
# the webhook from it here, the way queue-cleanup.sh does.
if [ -z "${HA_WEBHOOK_URL:-}" ] && [ -f "$NAS_STACK_DIR/.env" ]; then
  HA_WEBHOOK_URL=$(sed -n 's/^HA_WEBHOOK_URL=//p' "$NAS_STACK_DIR/.env" | tail -n 1 | tr -d "\"'")
fi
LOG_FILE="$NAS_STACK_DIR/logs/check-stuck-requests.log"
MAX_LOG_LINES=2000
STUCK_DAYS="${STUCK_DAYS:-3}"
MOVIE_STUCK_DAYS="${MOVIE_STUCK_DAYS:-7}"

# --- Parse arguments ---
POST=false
TEST=false
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --post|--apply) POST=true ;;
    --test) TEST=true; POST=true ;;
    --verbose|-v) VERBOSE=true ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

log() { echo "[check-stuck-requests] $1"; }

echo ""
echo "========================================"
echo "Stuck Request Check — $(date '+%Y-%m-%d %H:%M:%S')"
if $TEST; then
  echo "Mode: TEST (a test notice goes to Home Assistant whatever is found)"
elif $POST; then
  echo "Mode: POSTING (a notice goes to Home Assistant if anything is stuck)"
else
  echo "Mode: DRY RUN (use --post to notify Home Assistant)"
fi
echo "Thresholds: TV ${STUCK_DAYS} days, movies ${MOVIE_STUCK_DAYS} days"
echo "========================================"

if $POST && [[ -z "${HA_WEBHOOK_URL:-}" ]]; then
  log "ERROR: --post needs HA_WEBHOOK_URL, in the environment or in $NAS_STACK_DIR/.env"
  exit 1
fi

# --- Discover API keys from running containers (never printed) ---
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

get_arr_api_key() {
  local container="$1"
  container_running "$container" || return 1
  # sed rather than grep -P, which BSD grep lacks, so the tests run on macOS.
  docker exec "$container" cat /config/config.xml 2>/dev/null \
    | sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' || return 1
}

get_seerr_api_key() {
  container_running seerr || return 1
  docker exec seerr cat /app/config/settings.json 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["main"]["apiKey"])' 2>/dev/null \
    || return 1
}

SEERR_KEY=$(get_seerr_api_key) || true
SONARR_KEY=$(get_arr_api_key sonarr) || true
RADARR_KEY=$(get_arr_api_key radarr) || true

if [[ -z "$SEERR_KEY" ]]; then
  log "ERROR: Could not read Seerr's API key. Is the seerr container running?"
  exit 1
fi
if [[ -z "$SONARR_KEY" ]] && [[ -z "$RADARR_KEY" ]]; then
  log "ERROR: Could not read Sonarr's or Radarr's API key. Are the containers running?"
  exit 1
fi

# The python below writes the Home Assistant notice here, since only it knows
# what the run found. An empty file means nothing to post.
NOTICE_FILE=$(mktemp)
trap 'rm -f "$NOTICE_FILE"' EXIT

# --- Main check (python3 for JSON processing) ---
python3 - "$VERBOSE" "$TEST" "$SEERR_KEY" "$SONARR_KEY" "$RADARR_KEY" \
  "$NOTICE_FILE" "$NAS_STACK_DIR" "$STUCK_DAYS" "$MOVIE_STUCK_DAYS" << 'PYEOF'
import json, subprocess, sys
from datetime import datetime, timezone

VERBOSE = sys.argv[1] == "true"
TEST = sys.argv[2] == "true"
SEERR_KEY, SONARR_KEY, RADARR_KEY = sys.argv[3:6]
NOTICE_FILE = sys.argv[6]
NAS_STACK_DIR = sys.argv[7]
STUCK_DAYS = int(sys.argv[8])
MOVIE_STUCK_DAYS = int(sys.argv[9])

SEERR = ("http://localhost:5055", SEERR_KEY)
SONARR = ("http://localhost:8989", SONARR_KEY)
RADARR = ("http://localhost:7878", RADARR_KEY)

NOW = datetime.now(timezone.utc)

# Seerr's enums (server/constants/media.ts). Request: 2 approved, 4 failed.
# Media: 3 processing, 4 partially available, 5 available.
REQ_APPROVED, REQ_FAILED = 2, 4
MEDIA_AVAILABLE = 5

def verbose(msg):
    if VERBOSE:
        print(f"  [verbose] {msg}")

def api_get(base, path):
    """GET JSON with the app's API key in a header, so it never lands in a
    log line. None on any failure (HTTP >= 400 included)."""
    url, key = base[0] + path, base[1]
    result = subprocess.run(
        ["curl", "-s", "-f", "-m", "30", "-H", f"X-Api-Key: {key}", url],
        capture_output=True, text=True, timeout=40)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None

def parse_date(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None

def days_since(s):
    d = parse_date(s)
    return None if d is None else int((NOW - d).total_seconds() // 86400)

def plural(n, word):
    return f"{n} {word}" if n == 1 else f"{n} {word}s"

def ago(days, verb="requested"):
    return f"{verb} {plural(days, 'day')} ago" if days is not None else f"{verb} on an unknown date"

def season_list(numbers):
    """1964, 1970 … 2019, 2026 for a long run of seasons, the plain list for a short one."""
    nums = sorted(numbers)
    if len(nums) > 6:
        return f"{nums[0]}, {nums[1]} … {nums[-2]}, {nums[-1]}"
    return ", ".join(str(n) for n in nums)

def requester(req):
    u = req.get("requestedBy") or {}
    return (u.get("displayName") or u.get("username") or u.get("jellyfinUsername")
            or u.get("plexUsername") or u.get("email") or "unknown")

def service_id(req):
    media = req.get("media") or {}
    return media.get("externalServiceId4k") if req.get("is4k") else media.get("externalServiceId")

findings = []   # dicts: app, title, who, when, diagnosis
seen = set()    # one line per (problem, thing), however many requests point at it

def add_finding(app, title, who, when, diagnosis, key):
    if key in seen:
        return
    seen.add(key)
    findings.append({"app": app, "title": title, "who": who, "when": when,
                     "diagnosis": diagnosis})
    print(f"  ✗ {title} ({who}, {when})")
    print(f"    {diagnosis}")

# ---------------------------------------------------------------- Seerr ---
print("\n--- Seerr ---")
requests_all = []
page_size = 200
skip = 0
while True:
    data = api_get(SEERR, f"/api/v1/request?take={page_size}&skip={skip}&filter=all")
    if data is None:
        print("  ✗ Failed to fetch Seerr's requests")
        sys.exit(1)
    results = data.get("results", [])
    requests_all.extend(results)
    pages = (data.get("pageInfo") or {}).get("pages", 1)
    skip += page_size
    if skip >= pages * page_size or not results:
        break

approved = [r for r in requests_all if r.get("status") == REQ_APPROVED
            and (r.get("media") or {}).get("status", 0) < MEDIA_AVAILABLE]
failed = [r for r in requests_all if r.get("status") == REQ_FAILED]
print(f"  {len(requests_all)} requests: {len(approved)} approved and not yet available, "
      f"{len(failed)} marked failed")

def seerr_title(req):
    """The request result carries IDs, not names, so ask Seerr for the name
    only when Sonarr/Radarr can't supply it."""
    media = req.get("media") or {}
    kind = "tv" if req.get("type") == "tv" else "movie"
    d = api_get(SEERR, f"/api/v1/{kind}/{media.get('tmdbId')}")
    if d:
        return d.get("name") or d.get("title") or f"TMDB {media.get('tmdbId')}"
    return f"TMDB {media.get('tmdbId')}"

for req in failed:
    app = "Sonarr" if req.get("type") == "tv" else "Radarr"
    add_finding("Seerr", seerr_title(req), requester(req), ago(days_since(req.get("createdAt"))),
                f"Seerr marked this request FAILED: it could not hand it to {app} "
                f"(often a VPN blip at the time). Open Seerr → Requests and retry it, "
                f"or decline it.", key=("Seerr-failed", req.get("id")))

# Approved requests old enough to judge. A TV request whose media is already
# partly available is still checked for aired-but-never-grabbed episodes: a
# season that nothing ever grabs looks exactly like one that hasn't aired.
tv_candidates, movie_candidates = [], []
for req in approved:
    age = days_since(req.get("createdAt"))
    if age is None or age < STUCK_DAYS:
        continue
    app = "Sonarr" if req.get("type") == "tv" else "Radarr"
    if service_id(req) is None:
        add_finding("Seerr", seerr_title(req), requester(req), ago(age),
                    f"Approved but never handed to {app}: Seerr holds no {app} id for it. "
                    f"Retry the request from Seerr → Requests, or add it in {app} by hand.",
                    key=("Seerr-unsent", req.get("id")))
    elif req.get("type") == "tv":
        tv_candidates.append(req)
    else:
        movie_candidates.append(req)

# --------------------------------------------------------------- Sonarr ---
if SONARR_KEY:
    print("\n--- Sonarr ---")
    series_all = api_get(SONARR, "/api/v3/series")
    if series_all is None:
        print(f"  ✗ Failed to fetch Sonarr's series; {len(tv_candidates)} TV request(s) not checked")
        series_all = []
        tv_candidates = []
    series_by_id = {s["id"]: s for s in series_all}
    series_by_tvdb = {s.get("tvdbId"): s for s in series_all if s.get("tvdbId")}
    flagged_series = set()   # series already reported, so the sweep stays quiet about them
    sonarr_before = len(findings)

    for req in tv_candidates:
        media = req["media"]
        who, when = requester(req), ago(days_since(req.get("createdAt")))
        series = series_by_id.get(service_id(req)) or series_by_tvdb.get(media.get("tvdbId"))
        if series is None:
            add_finding("Sonarr", seerr_title(req), who, when,
                        f"Seerr says Sonarr has this (id {service_id(req)}) but Sonarr has no "
                        f"such series: it was removed, or never added. Re-request it, or add "
                        f"it in Sonarr by hand.",
                        key=("Sonarr-missing", service_id(req)))
            continue
        title = series.get("title", "?")
        requested = sorted({s.get("seasonNumber") for s in req.get("seasons", [])
                            if s.get("seasonNumber") is not None})
        have = {s["seasonNumber"] for s in series.get("seasons", [])}
        real_seasons = [n for n in have if n != 0]

        # 1. Seerr asked for seasons the TVDB record doesn't have (70 Up: Seerr
        #    sent season 10, Sonarr had 1964 … 2026).
        absent = [n for n in requested if n not in have]
        if absent:
            flagged_series.add(series["id"])
            add_finding("Sonarr", title, who, when,
                        f"Request monitored nothing in Sonarr: Seerr asked for season(s) "
                        f"{season_list(absent)} but TVDB numbers this show's seasons "
                        f"{season_list(real_seasons) or 'none'}. Re-request from the "
                        f"TVDB-linked entry, or monitor the season in Sonarr by hand.",
                        key=("Sonarr-absent", series["id"], tuple(absent)))
            continue

        episodes = api_get(SONARR, f"/api/v3/episode?seriesId={series['id']}") or []
        scope = [e for e in episodes if not requested or e.get("seasonNumber") in requested]
        monitored = [e for e in scope if e.get("monitored")]

        # 2. The seasons exist but nothing in them is monitored.
        if not monitored:
            flagged_series.add(series["id"])
            what = f"season(s) {season_list(requested)}" if requested else "this series"
            add_finding("Sonarr", title, who, when,
                        f"Request monitored nothing in Sonarr: {what} exists but every "
                        f"episode is unmonitored, so Sonarr will never search. Monitor "
                        f"the season in Sonarr, or decline the request in Seerr.",
                        key=("Sonarr-unmonitored", series["id"], tuple(requested)))
            continue

        # 3. Aired, still missing, and Sonarr has never grabbed anything for it.
        aired_missing = []
        for e in monitored:
            if e.get("hasFile"):
                continue
            aired = days_since(e.get("airDateUtc"))
            if aired is not None and aired >= STUCK_DAYS:
                aired_missing.append((aired, e))
        if not aired_missing:
            verbose(f"{title}: nothing aired and missing for {STUCK_DAYS}+ days")
            continue
        history = api_get(SONARR, f"/api/v3/history/series?seriesId={series['id']}") or []
        grabbed = {h.get("episodeId") for h in history if h.get("eventType") == "grabbed"}
        never = sorted(((a, e) for a, e in aired_missing if e.get("id") not in grabbed),
                       key=lambda t: -t[0])
        if not never:
            verbose(f"{title}: {len(aired_missing)} missing episode(s), each grabbed at least "
                    f"once (a download problem, not a naming one)")
            continue
        oldest = never[0][0]
        codes = [f"S{e.get('seasonNumber', 0):02d}E{e.get('episodeNumber', 0):02d}" for _, e in never]
        shown = ", ".join(codes[:4]) + (f" and {len(codes) - 4} more" if len(codes) > 4 else "")
        add_finding("Sonarr", title, who, when,
                    f"{shown} aired {plural(oldest, 'day')} ago and Sonarr has never grabbed "
                    f"{'it' if len(never) == 1 else 'them'}: the indexers may name this show "
                    f"differently. Check a Prowlarr search for the title; push the release to "
                    f"Sonarr under a title it can parse, or add a scene mapping.",
                    key=("Sonarr-never", series["id"], tuple(codes)))

    if len(findings) == sonarr_before:
        print("  - nothing stuck" if tv_candidates else "  - no TV requests old enough to check")

    # Cheap sweep: a monitored series whose seasons are all unmonitored can
    # never download anything. Catches manual adds no Seerr request points at.
    print("\n--- Sonarr: monitored series with no monitored season ---")
    swept = 0
    for s in series_all:
        if not s.get("monitored") or not s.get("seasons") or s["id"] in flagged_series:
            continue
        if any(se.get("monitored") for se in s["seasons"]):
            continue
        swept += 1
        add_finding("Sonarr", s.get("title", "?"), "no Seerr request",
                    ago(days_since(s.get("added")), "added"),
                    f"Monitored in Sonarr but every season is unmonitored, so nothing will "
                    f"ever be searched. Monitor a season, or unmonitor the series.",
                    key=("Sonarr-sweep", s["id"]))
    if swept == 0:
        print("  - none")
elif tv_candidates:
    print("\n--- Sonarr ---")
    print(f"  ✗ No Sonarr API key; {len(tv_candidates)} TV request(s) not checked")

# --------------------------------------------------------------- Radarr ---
if RADARR_KEY:
    print("\n--- Radarr ---")
    radarr_before = len(findings)
    for req in movie_candidates:
        who, when = requester(req), ago(days_since(req.get("createdAt")))
        movie = api_get(RADARR, f"/api/v3/movie/{service_id(req)}")
        if movie is None:
            add_finding("Radarr", seerr_title(req), who, when,
                        f"Seerr says Radarr has this (id {service_id(req)}) but Radarr has no "
                        f"such movie: it was removed, or never added. Re-request it, or add it "
                        f"in Radarr by hand.",
                        key=("Radarr-missing", service_id(req)))
            continue
        title = movie.get("title", "?")
        if movie.get("year"):
            title = f"{title} ({movie['year']})"
        if movie.get("hasFile"):
            verbose(f"{title}: has a file; Seerr just hasn't noticed yet")
            continue
        if not movie.get("monitored"):
            add_finding("Radarr", title, who, when,
                        f"Approved in Seerr but unmonitored in Radarr, so Radarr will never "
                        f"search for it. Monitor it in Radarr, or decline the request.",
                        key=("Radarr-unmonitored", movie["id"]))
            continue
        if not movie.get("isAvailable"):
            verbose(f"{title}: not released yet (Radarr isAvailable false); waiting")
            continue
        in_radarr = days_since(movie.get("added"))
        if in_radarr is None or in_radarr < MOVIE_STUCK_DAYS:
            verbose(f"{title}: available but in Radarr only {in_radarr} day(s)")
            continue
        history = api_get(RADARR, f"/api/v3/history/movie?movieId={movie['id']}") or []
        if any(h.get("eventType") == "grabbed" for h in history):
            verbose(f"{title}: grabbed at least once (a download problem, not a naming one)")
            continue
        add_finding("Radarr", title, who, when,
                    f"Available, in Radarr {plural(in_radarr, 'day')}, never grabbed. If this "
                    f"is a TV broadcast with a TMDB movie entry, Radarr can never match it: "
                    f"delete it from Radarr and request the series instead. Otherwise check "
                    f"a Prowlarr search for the title.",
                    key=("Radarr-never", movie["id"]))
    if len(findings) == radarr_before:
        print("  - nothing stuck")
elif movie_candidates:
    print("\n--- Radarr ---")
    print(f"  ✗ No Radarr API key; {len(movie_candidates)} movie request(s) not checked")

# -------------------------------------------------------------- Summary ---
print(f"\n{'=' * 40}")
by_app = {}
for f in findings:
    by_app[f["app"]] = by_app.get(f["app"], 0) + 1
detail = ", ".join(f"{n} {app}" for app, n in sorted(by_app.items()))
print(f"Summary: {plural(len(findings), 'stuck request')}" + (f" ({detail})" if detail else ""))

def notice_for(findings):
    """One notice for the panel: a line per request, title first, then what
    is wrong and what to do. Capped so a bad week still reads."""
    lines = []
    for f in findings[:8]:
        lines.append(f"• {f['title']} ({f['app']}; {f['who']}, {f['when']}): {f['diagnosis']}")
    if len(findings) > 8:
        lines.append(f"…and {len(findings) - 8} more in {NAS_STACK_DIR}/logs/check-stuck-requests.log")
    return {
        "title": f"Stuck requests: {plural(len(findings), 'request')} waiting",
        "message": "\n".join(lines),
        "level": "info",
        "tag": "stuck-requests",
    }

if TEST:
    notice = {
        "title": "Stuck-request check: test",
        "message": (f"The daily stuck-request check can reach Home Assistant. Nothing to do. "
                    f"(This run found {plural(len(findings), 'stuck request')}.)"),
        "level": "info",
        "tag": "stuck-requests",
    }
elif findings:
    notice = notice_for(findings)
else:
    notice = None

if notice is not None:
    with open(NOTICE_FILE, "w") as fh:
        json.dump(notice, fh, ensure_ascii=False)
PYEOF

# --- Home Assistant notice ---
if [[ ! -s "$NOTICE_FILE" ]]; then
  echo "Notice: nothing to post"
elif $POST; then
  if curl -s -m 10 -f -X POST "$HA_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      --data-binary "@$NOTICE_FILE" > /dev/null; then
    # HA answers 200 to any webhook id, so this proves the POST reached HA,
    # not that the automation rendered it. Check the panel.
    echo "Notice: posted to Home Assistant at $(date '+%Y-%m-%d %H:%M:%S %Z') (check the panel)"
  else
    echo "Notice: POST to Home Assistant FAILED"
    exit 1
  fi
else
  echo "Notice: would post (dry run; use --post):"
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print("  " + d["title"]); print("  " + d["message"].replace("\n", "\n  "))' "$NOTICE_FILE"
fi

# --- Trim log file ---
if [[ -f "$LOG_FILE" ]]; then
  LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$LINES" -gt "$MAX_LOG_LINES" ]]; then
    TMPLOG=$(mktemp)
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TMPLOG" && mv "$TMPLOG" "$LOG_FILE"
  fi
fi
