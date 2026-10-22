#!/usr/bin/env bats
# Unit tests for scripts/check-stuck-requests.sh: the daily check that finds
# requests stuck between Seerr, Sonarr/Radarr and the indexers, and posts one
# panel-only notice to Home Assistant.
#
# The motivating case is modelled exactly: in September 2026 Seerr asked
# Sonarr for "season 10" of a show whose TVDB seasons are numbered by year
# (1964 … 2026), Sonarr monitored nothing, Seerr logged "accepted", and two
# aired episodes sat five weeks while the indexers had them all along. Its
# twin, a TMDB movie entry for the same broadcast, is modelled on the Radarr
# side: the indexers have the title only as S10E01-style episodes. So is the
# commonest cause, a release RSS missed that the app's own search would take.
#
# `docker` and `curl` are stubbed on PATH, and the script runs from a copy in a
# throwaway stack directory with no .env. The curl stub serves each API call
# from a fixture and logs every call, with its body, to $CURL_LOG. A release
# search is served from radarr-release-<movieId>.json or
# sonarr-release-<episodeId>.json, a Prowlarr search from
# prowlarr-<title-slug>.json, each an empty list when no fixture exists. Dates
# in the fixtures are written relative to now, so the age thresholds are real.

setup() {
    load helpers/setup
    command -v python3 >/dev/null || skip "python3 not installed"
    unset HA_WEBHOOK_URL STUCK_DAYS MOVIE_STUCK_DAYS MAX_SEARCHES
    export SEARCH_PAUSE=0

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts"
    cp "$REPO_ROOT/scripts/check-stuck-requests.sh" "$STACK/scripts/check-stuck-requests.sh"

    export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export HA_NOTICE="$BATS_TEST_TMPDIR/notice.json"
    export FIX="$BATS_TEST_TMPDIR/fixtures"
    export STUB_CONTAINERS="gluetun seerr sonarr radarr prowlarr"
    mkdir -p "$FIX"
    : > "$CURL_LOG"

    # Requests: the 70 Up mapping (10), aired episodes never grabbed (11), the
    # 70 Up "movie" (12), a movie not released yet (13), a FAILED hand-over
    # (14), one too recent to judge (15), one fine because its missing episode
    # was grabbed (16), a film still in cinemas (17), an old film no indexer
    # carries (18), a film RSS missed (19) and one Radarr rejects (20).
    python3 - "$FIX" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
fix = sys.argv[1]
now = datetime.now(timezone.utc)
def ago(days): return (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def dump(name, obj): json.dump(obj, open(f"{fix}/{name}.json", "w"))
adam, kris = {"displayName": "adam"}, {"displayName": "kris"}
def req(i, typ, days, media, seasons=(), status=2, by=adam):
    return {"id": i, "status": status, "type": typ, "createdAt": ago(days), "is4k": False,
            "media": media, "seasons": [{"seasonNumber": n} for n in seasons], "requestedBy": by}
def movie_media(tmdb, ext): return {"status": 3, "tmdbId": tmdb, "tvdbId": None, "externalServiceId": ext}
dump("seerr-requests", {"pageInfo": {"pages": 1, "pageSize": 200, "results": 11, "page": 1}, "results": [
    req(10, "tv", 36, {"status": 3, "tmdbId": 999, "tvdbId": 139751, "externalServiceId": 95}, [10]),
    req(11, "tv", 20, {"status": 3, "tmdbId": 888, "tvdbId": 5050, "externalServiceId": 50}, [1], by=kris),
    req(12, "movie", 30, movie_media(777, 200)),
    req(13, "movie", 30, movie_media(778, 201)),
    req(14, "movie", 79, {"status": 1, "tmdbId": 555, "tvdbId": None, "externalServiceId": None}, status=4),
    req(15, "tv", 1, {"status": 3, "tmdbId": 888, "tvdbId": 5050, "externalServiceId": 50}, [1]),
    req(16, "tv", 10, {"status": 3, "tmdbId": 666, "tvdbId": 6060, "externalServiceId": 60}, [1]),
    req(17, "movie", 40, movie_media(779, 202)),
    req(18, "movie", 90, movie_media(780, 203)),
    req(19, "movie", 25, movie_media(781, 204)),
    req(20, "movie", 50, movie_media(782, 205)),
]})
dump("seerr-requests-page2", {"pageInfo": {"pages": 2, "pageSize": 200, "results": 0, "page": 2}, "results": []})
dump("seerr-movie-555", {"id": 555, "title": "Failed Film"})
def season(n, mon): return {"seasonNumber": n, "monitored": mon}
dump("sonarr-series", [
    {"id": 95, "title": "The Up Series", "tvdbId": 139751, "monitored": True, "added": ago(40),
     "seasons": [season(0, False)] + [season(y, False) for y in (1964, 1970, 1977, 1984, 1991, 1998, 2005, 2012, 2019, 2026)]},
    {"id": 50, "title": "Phony", "tvdbId": 5050, "monitored": True, "added": ago(20), "seasons": [season(1, True)]},
    {"id": 60, "title": "Fine Show", "tvdbId": 6060, "monitored": True, "added": ago(10), "seasons": [season(1, True)]},
    {"id": 70, "title": "Orphan", "tvdbId": 7070, "monitored": True, "added": ago(12), "seasons": [season(1, False)]},
    {"id": 71, "title": "Dropped", "tvdbId": 7171, "monitored": False, "added": ago(300), "seasons": [season(1, False)]},
])
def ep(i, s, e, days, has, mon=True):
    return {"id": i, "seriesId": 50, "seasonNumber": s, "episodeNumber": e, "airDateUtc": ago(days),
            "hasFile": has, "monitored": mon}
dump("sonarr-episodes-50", [ep(501, 1, 1, 15, False), ep(502, 1, 2, 8, False), ep(503, 1, 3, -6, False)])
dump("sonarr-history-50", [])
dump("sonarr-episodes-60", [ep(601, 1, 1, 10, False)])
dump("sonarr-history-60", [{"episodeId": 601, "eventType": "grabbed", "date": ago(9), "sourceTitle": "Fine.Show.S01E01"}])
def found(title, approved=True, rejections=(), indexer="NZBgeek"):
    return {"title": title, "indexer": indexer, "approved": approved, "rejected": not approved,
            "rejections": list(rejections)}
# Phony: Sonarr's own search would take a release, so RSS simply missed it.
dump("sonarr-release-501", [found("Phony.S01E01.1080p.WEB.h264-GRP", indexer="EZTV")])
def movie(i, title, year, **kw):
    m = {"id": i, "title": title, "year": year, "monitored": True, "isAvailable": True,
         "hasFile": False, "added": ago(30)}
    m.update(kw); return m
# The 70 Up "movie": broadcast on 2026-09-15, a digital date, Radarr's search finds
# nothing, the indexers have the title only as S10E01/E02.
dump("radarr-movie-200", movie(200, "Seventy Up", 2026, digitalRelease=ago(36)))
dump("radarr-history-200", [])
dump("radarr-movie-201", movie(201, "Not Yet", 2027, isAvailable=False))
# Still in cinemas, no home date: waiting is right.
dump("radarr-movie-202", movie(202, "Arthouse Film", 2026, inCinemas=ago(60), added=ago(40)))
dump("radarr-history-202", [])
# A 2003 film with no dates at all on TMDB and nothing on any indexer.
dump("radarr-movie-203", movie(203, "Old Obscure", 2003, added=ago(90)))
dump("radarr-history-203", [])
# Out at home, Radarr's own search finds releases it would take: RSS missed it.
dump("radarr-movie-204", movie(204, "Grabbable", 2025, digitalRelease=ago(30), added=ago(25)))
dump("radarr-history-204", [])
dump("radarr-release-204", [found("Grabbable.2025.1080p.WEB-DL.DDP5.1.H.264-GRP"),
                            found("Grabbable.2025.2160p.WEB-DL-GRP")])
# Out at home, releases exist, Radarr rejects every one.
dump("radarr-movie-205", movie(205, "Rejected Film", 2024, digitalRelease=ago(200), added=ago(50)))
dump("radarr-history-205", [])
dump("radarr-release-205", [found("Rejected.Film.2024.480p.WEB", False, ["Quality 480p not wanted in profile"]),
                            found("Rejected.Film.2024.1080p.CAM", False, ["Quality 480p not wanted in profile", "Custom format score too low"])])
def rel(title, indexer="NZBgeek"): return {"title": title, "indexer": indexer, "categories": []}
dump("prowlarr-seventy-up", [rel("Seventy.Up.S10E01.1080p.HDTV.H264-GRP"), rel("Seventy.Up.S10E02.1080p.HDTV.H264-GRP"),
                             rel("Seventy.Nine.Up.2019.1080p.WEB-DL")])   # not a prefix match
# The second hit is a season Sonarr isn't missing (a same-named show's, say): not counted.
dump("prowlarr-phony", [rel("Phony.S01E01.720p.WEB.h264-GRP", "EZTV"), rel("Phony.S03E04.720p.WEB.h264-GRP", "EZTV")])
dump("prowlarr-indexers", [{"id": 3, "name": "EZTV"}, {"id": 7, "name": "NZBgeek"}])
# Prowlarr syncs the indexers into each app under its own naming; EZTV is TV-only.
dump("radarr-indexers", [{"name": "NZBgeek (Prowlarr)"}])
dump("sonarr-indexers", [{"name": "NZBgeek (Prowlarr)"}, {"name": "EZTV (Prowlarr)"}])
PY

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/docker" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "ps "*) tr ' ' '\n' <<< "$STUB_CONTAINERS" ;;
  "exec seerr") printf '{"main": {"apiKey": "seerr-key", "applicationTitle": "Seerr"}}\n' ;;
  exec\ *) printf '<Config>\n  <Port>8989</Port>\n  <ApiKey>key-%s</ApiKey>\n</Config>\n' "$2" ;;
  *) exit 1 ;;
esac
STUB
    cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
method=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d|--data-binary) data="$2"; shift 2 ;;
    -H|-m) shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
printf '%s %s %s\n' "$method" "$url" "$data" >> "$CURL_LOG"
serve() { [ -f "$FIX/$1.json" ] && cat "$FIX/$1.json" || exit 22; }
serve_or_empty() { [ -f "$FIX/$1.json" ] && cat "$FIX/$1.json" || echo '[]'; }
# A Prowlarr search is served by the query's slug, empty when no fixture has it.
search() {
  local q="${url#*query=}"; q="${q%%&*}"; q="${q//+/ }"
  q=$(printf '%b' "${q//%/\\x}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'); q="${q#-}"; q="${q%-}"
  serve_or_empty "prowlarr-$q"
}
case "$method $url" in
  "GET http://localhost:5055/api/v1/request?take=200&skip=0&"*) serve seerr-requests ;;
  "GET http://localhost:5055/api/v1/request?take=200&skip=200&"*) serve seerr-requests-page2 ;;
  "GET http://localhost:5055/api/v1/movie/"*) serve "seerr-movie-${url##*/}" ;;
  "GET http://localhost:5055/api/v1/tv/"*) serve "seerr-tv-${url##*/}" ;;
  "GET http://localhost:8989/api/v3/series") serve sonarr-series ;;
  "GET http://localhost:8989/api/v3/episode?seriesId="*) serve "sonarr-episodes-${url##*=}" ;;
  "GET http://localhost:8989/api/v3/history/series?seriesId="*) serve "sonarr-history-${url##*=}" ;;
  "GET http://localhost:8989/api/v3/episodefile?seriesId="*) serve_or_empty "sonarr-episodefile-${url##*=}" ;;
  "GET http://localhost:8989/api/v3/release?episodeId="*) serve_or_empty "sonarr-release-${url##*=}" ;;
  "GET http://localhost:8989/api/v3/indexer") serve sonarr-indexers ;;
  "GET http://localhost:7878/api/v3/indexer") serve radarr-indexers ;;
  "GET http://localhost:7878/api/v3/movie/"*) serve "radarr-movie-${url##*/}" ;;
  "GET http://localhost:7878/api/v3/history/movie?movieId="*) serve "radarr-history-${url##*=}" ;;
  "GET http://localhost:7878/api/v3/release?movieId="*) serve_or_empty "radarr-release-${url##*=}" ;;
  "POST http://localhost:8989/api/v3/command"|"POST http://localhost:7878/api/v3/command") echo '{"id": 1}' ;;
  "GET http://localhost:9696/api/v1/indexerstatus") serve_or_empty prowlarr-indexerstatus ;;
  "GET http://localhost:9696/api/v1/indexer") serve prowlarr-indexers ;;
  "GET http://localhost:9696/api/v1/search?query="*) search ;;
  "POST http://ha.test/"*) printf '%s' "$data" > "$HA_NOTICE" ;;
  *) exit 22 ;;
esac
STUB
    chmod +x "$STUB_BIN/docker" "$STUB_BIN/curl"
    export PATH="$STUB_BIN:$PATH"
}

# The value of one key in the notice the script posted to Home Assistant.
notice() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$HA_NOTICE" "$1"
}

ha_posts() {
    grep -c '^POST http://ha.test' "$CURL_LOG" || true
}

commands() {
    grep -c '^POST http://localhost:[0-9]*/api/v3/command' "$CURL_LOG" || true
}

indexer_searches() {
    grep -cE '^GET http://localhost:(7878/api/v3/release|8989/api/v3/release|9696/api/v1/search)' "$CURL_LOG" || true
}

# The October 2026 case, with its real numbers. The UK Queer as Folk (91) had
# eight season-1 files Sonarr imported on an untagged Queer.as.Folk.S01Exx
# name: the 2022 reboot's first episode (55:01) and the US run's episodes 2 to
# 8 (44 to 50 minutes), against TVDB's 32 to 36 for the UK episodes. The US
# series (89) sits beside it with a file that fits and three the check must
# leave alone: a two-episode file, one Sonarr has no media info for, and an
# episode TVDB gives no runtime.
add_queer_as_folk() {
    python3 - "$FIX" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
fix = sys.argv[1]
now = datetime.now(timezone.utc)
def ago(days): return (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
def dump(name, obj): json.dump(obj, open(f"{fix}/{name}.json", "w"))
def season(n, mon): return {"seasonNumber": n, "monitored": mon}
series = json.load(open(f"{fix}/sonarr-series.json"))
series += [
    {"id": 91, "title": "Queer as Folk", "tvdbId": 75625, "monitored": True, "added": ago(14),
     "seasons": [season(1, True), season(2, True)]},
    {"id": 89, "title": "Queer as Folk (US)", "tvdbId": 75001, "monitored": True, "added": ago(400),
     "seasons": [season(1, True), season(2, True)]},
]
dump("sonarr-series", series)
def ep(i, sid, s, e, runtime, file_id=None):
    return {"id": i, "seriesId": sid, "seasonNumber": s, "episodeNumber": e, "runtime": runtime,
            "airDateUtc": ago(9800), "hasFile": file_id is not None, "episodeFileId": file_id or 0,
            "monitored": True}
def efile(i, sid, s, scene, runtime, media=True):
    f = {"id": i, "seriesId": sid, "seasonNumber": s, "relativePath": f"Season {s:02d}/{scene}.mkv",
         "sceneName": scene, "dateAdded": ago(14), "size": 1}
    if media:
        f["mediaInfo"] = {"videoCodec": "x264", "runTime": runtime}
    return f
uk_tvdb = [32, 33, 35, 36, 33, 33, 32, 35]
uk_files = ["55:01", "44:10", "45:02", "50:15", "49:11", "48:57", "44:38", "48:39"]
uk_scene = ["Queer.As.Folk.S01E01.Babylon.1080p.PCOK.WEB-DL.DDP5.1.H.264-iVy"] + \
           [f"Queer.as.Folk.S01E0{n}.1080p.WEB.H264-DiMEPiECE" for n in range(2, 9)]
dump("sonarr-episodes-91",
     [ep(9100 + n, 91, 1, n, uk_tvdb[n - 1], 9100 + n) for n in range(1, 9)] +
     [ep(9201, 91, 2, 1, 47), ep(9202, 91, 2, 2, 44)])
dump("sonarr-episodefile-91",
     [efile(9100 + n, 91, 1, uk_scene[n - 1], uk_files[n - 1]) for n in range(1, 9)])
dump("sonarr-episodes-89", [
    ep(8901, 89, 1, 2, 44, 8901),
    ep(8902, 89, 2, 1, 44, 8902), ep(8903, 89, 2, 2, 44, 8902),   # one file, two episodes
    ep(8904, 89, 2, 3, 44, 8903),                                  # no media info
    ep(8905, 89, 2, 4, 0, 8904),                                   # TVDB gives no runtime
])
dump("sonarr-episodefile-89", [
    efile(8901, 89, 1, "Queer.as.Folk.US.S01E02.1080p.AMZN.WEB-DL.DDP2.0.x264-NTb", "44:38"),
    efile(8902, 89, 2, "Queer.as.Folk.US.S02E01-E02.1080p.AMZN.WEB-DL.DDP2.0.x264-NTb", "1:28:00"),
    efile(8903, 89, 2, "Queer.as.Folk.US.S02E03.1080p.AMZN.WEB-DL.DDP2.0.x264-NTb", None, media=False),
    efile(8904, 89, 2, "Queer.as.Folk.US.S02E04.1080p.AMZN.WEB-DL.DDP2.0.x264-NTb", "10:00"),
])
PY
}

@test "a dry run names each stuck request with a diagnosis, and changes nothing" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    # The 70 Up case: Seerr's season number isn't one TVDB uses.
    assert_output --partial "The Up Series (adam, requested 36 days ago)"
    assert_output --partial "Seerr asked for season(s) 10 but TVDB numbers this show's seasons 1964, 1970 … 2019, 2026"
    # Aired, missing, never grabbed, and Sonarr's own search would take a release: RSS missed it.
    assert_output --partial "Phony (kris, requested 20 days ago)"
    assert_output --partial "S01E01, S01E02 aired 15 days ago and Sonarr has never grabbed them: Sonarr's own search finds 1 release it would take (e.g. Phony.S01E01.1080p.WEB.h264-GRP on EZTV), so RSS missed them: nobody ever searched. Run with --apply to queue the search, or click Search in Sonarr."
    # Seerr's own FAILED state, titled from Seerr since Radarr never saw it.
    assert_output --partial "Failed Film (adam, requested 79 days ago)"
    assert_output --partial "Seerr marked this request FAILED: the hand-off to Radarr did not go through."
    refute_output --partial "VPN"
    # The sweep: monitored series with nothing monitored, no request behind it.
    assert_output --partial "Orphan (no Seerr request, added 12 days ago)"
    assert_output --partial "every season is unmonitored"
    assert_output --partial "Summary: 8 stuck requests (4 Radarr, 1 Seerr, 3 Sonarr)"
    # Left alone: unreleased film, grabbed episode, too-recent request, unmonitored series.
    refute_output --partial "Not Yet"
    refute_output --partial "Fine Show"
    refute_output --partial "Dropped"
    assert_output --partial "Notice: would post (dry run; use --post)"
    [ "$(ha_posts)" -eq 0 ]
    [ "$(commands)" -eq 0 ]
}

@test "--apply queues the searches RSS missed, and only those" {
    run "$STACK/scripts/check-stuck-requests.sh" --apply
    assert_success
    assert_output --partial "Searches: QUEUED for anything RSS missed (--apply)"
    assert_output --partial "so RSS missed it: nobody ever searched. A search has been queued now; if this is still here tomorrow, the download failed."
    assert_output --partial "A search for S01E01, S01E02 has been queued now"
    assert_output --partial "Searches queued: 2 (Sonarr: Phony, Radarr: Grabbable (2025))"
    grep -q '^POST http://localhost:7878/api/v3/command {"name": "MoviesSearch", "movieIds": \[204\]}$' "$CURL_LOG"
    grep -q '^POST http://localhost:8989/api/v3/command {"name": "EpisodeSearch", "episodeIds": \[501, 502\]}$' "$CURL_LOG"
    [ "$(commands)" -eq 2 ]
    # --apply alone notifies nobody.
    [ "$(ha_posts)" -eq 0 ]
}

@test "Radarr: a release it would take means RSS missed it" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Grabbable (2025) (adam, requested 25 days ago)"
    assert_output --regexp "In Radarr 25 days, home release 20[0-9]{2}-[0-9]{2}-[0-9]{2}, never grabbed: Radarr's own search finds 2 releases it would take \(e\.g\. Grabbable\.2025\.1080p\.WEB-DL\.DDP5\.1\.H\.264-GRP on NZBgeek\), so RSS missed it: nobody ever searched\. Run with --apply to queue the search, or click Search in Radarr\."
}

@test "Radarr: releases it rejects are reported with the reasons" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Rejected Film (2024) (adam, requested 50 days ago)"
    assert_output --partial "never grabbed: Radarr finds 2 releases and rejects them all (Quality 480p not wanted in profile; Custom format score too low). Fix the quality profile or custom formats, or decline the request."
}

@test "Radarr: nothing found, and the indexers have the title only as episodes: the TV-broadcast trap" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Seventy Up (2026) (adam, requested 30 days ago)"
    assert_output --regexp "In Radarr 30 days, home release 20[0-9]{2}-[0-9]{2}-[0-9]{2}, never grabbed: the indexers have it only as TV episodes \(e\.g\. Seventy\.Up\.S10E01\.1080p\.HDTV\.H264-GRP\): a TV broadcast with a TMDB movie entry, which Radarr can never match\. Delete it from Radarr and request the series instead\."
}

@test "Radarr: nothing found, nothing under the title on any enabled indexer" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Old Obscure (2003) (adam, requested 90 days ago)"
    assert_output --partial "In Radarr 90 days, no home release date on TMDB, never grabbed: no enabled indexer has a release under this title. Wait, add an indexer that carries it, or decline the request."
}

@test "a zero is not trusted while Prowlarr has an indexer in failure backoff" {
    python3 - "$FIX/prowlarr-indexerstatus.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
till = (datetime.now(timezone.utc) + timedelta(minutes=4)).strftime("%Y-%m-%dT%H:%M:%SZ")
past = (datetime.now(timezone.utc) - timedelta(minutes=4)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump([{"indexerId": 7, "disabledTill": till}, {"indexerId": 3, "disabledTill": past}], open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Old Obscure (2003)"
    assert_output --partial "never grabbed: Radarr's own search found nothing, but Prowlarr has NZBgeek in failure backoff, so that zero is not to be trusted. Try again later."
    refute_output --partial "EZTV in failure backoff"
    # The title probe is skipped: no Prowlarr search is spent on an untrustworthy zero.
    run grep -c '^GET http://localhost:9696/api/v1/search' "$CURL_LOG"
    assert_output 0
}

@test "a backed-off indexer the app doesn't use leaves its zero trusted, with a note" {
    python3 - "$FIX/prowlarr-indexerstatus.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
till = (datetime.now(timezone.utc) + timedelta(minutes=4)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump([{"indexerId": 3, "disabledTill": till}], open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    # EZTV is TV-only: Radarr's zero stands, the title probe runs, and the note says who didn't answer.
    assert_output --partial "Old Obscure (2003)"
    assert_output --partial "never grabbed: no enabled indexer has a release under this title. Wait, add an indexer that carries it, or decline the request. EZTV is in failure backoff, so re-check once it answers."
    assert_output --partial "Seventy Up (2026)"
    assert_output --partial "the indexers have it only as TV episodes"
    refute_output --partial "so that zero is not to be trusted"
}

@test "rejections about the match mean another title with the same name, not a profile problem" {
    python3 - "$FIX/sonarr-release-501.json" <<'PY'
import json, sys
json.dump([{"title": "Phony.US.S01E01.1080p", "indexer": "EZTV", "approved": False, "rejected": True,
            "rejections": ["Wrong series"]}] * 7, open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh" --apply
    assert_success
    assert_output --partial "Sonarr has never grabbed them: Sonarr finds 7 releases under this title and rejects them all (Wrong series): they belong to another title with the same name, so nothing it recognises as this one is on any enabled indexer. Wait, add an indexer that carries it, or decline the request."
    refute_output --partial "Sonarr finds 7 releases and rejects them all"
    run grep -c 'EpisodeSearch' "$CURL_LOG"
    assert_output 0
}

@test "Radarr: a film still in cinemas with no home release date is waiting, not stuck" {
    run "$STACK/scripts/check-stuck-requests.sh" -v
    assert_success
    refute_output --partial "✗ Arthouse Film"
    assert_output --regexp "\[verbose\] Arthouse Film \(2026\): in cinemas 20[0-9]{2}-[0-9]{2}-[0-9]{2}, no home release date yet; waiting is right"
    # Searches are spent only where needed: one release search per never-grabbed
    # item (5), plus a Prowlarr title probe for the two that found nothing.
    [ "$(indexer_searches)" -eq 7 ]
    assert_output --partial "Indexer searches this run: 7 (cap 20, 0s apart)"
}

@test "Radarr: a home release still to come is waiting, not stuck" {
    python3 - "$FIX/radarr-movie-204.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
m = json.load(open(sys.argv[1]))
m["digitalRelease"] = (datetime.now(timezone.utc) + timedelta(days=12)).strftime("%Y-%m-%dT00:00:00Z")
json.dump(m, open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh" -v
    assert_success
    refute_output --partial "✗ Grabbable"
    assert_output --partial "home release due"
}

@test "without Prowlarr, a zero cannot be sorted and the line says so" {
    export STUB_CONTAINERS="gluetun seerr sonarr radarr"
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "WARNING: Could not read Prowlarr's API key"
    # Radarr's and Sonarr's own searches still run.
    assert_output --partial "Grabbable (2025)"
    assert_output --partial "so RSS missed it"
    assert_output --partial "Old Obscure (2003)"
    assert_output --partial "never grabbed: Radarr's own search found nothing and Prowlarr could not be asked. If this is a TV broadcast with a TMDB movie entry, Radarr can never match it"
    run grep -c '^GET http://localhost:9696' "$CURL_LOG"
    assert_output 0
}

@test "the per-run search cap is honoured" {
    MAX_SEARCHES=1 run "$STACK/scripts/check-stuck-requests.sh" -v
    assert_success
    [ "$(indexer_searches)" -eq 1 ]
    assert_output --partial "Radarr's own search could not be run (over this run's search cap, or the indexers did not answer)"
}

@test "the sweep stays quiet about a series a request already explains" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    [ "$(grep -c '✗ The Up Series' <<< "$output")" -eq 1 ]
}

@test "--post sends one panel-only notice with a fixed tag" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    run "$STACK/scripts/check-stuck-requests.sh" --post
    assert_success
    assert_output --partial "Notice: posted to Home Assistant at"
    [ "$(ha_posts)" -eq 1 ]
    [ "$(notice level)" = info ]
    [ "$(notice tag)" = stuck-requests ]
    [ "$(notice title)" = "Stuck requests: 8 requests waiting" ]
    run notice message
    assert_output --partial "• The Up Series (Sonarr; adam, requested 36 days ago): Request monitored nothing in Sonarr"
    assert_output --partial "• Seventy Up (2026) (Radarr; adam, requested 30 days ago)"
    assert_output --partial "• Orphan (Sonarr; no Seerr request, added 12 days ago)"
}

@test "with nothing stuck, --post posts nothing" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    printf '{"pageInfo": {"pages": 1}, "results": []}' > "$FIX/seerr-requests.json"
    python3 - "$FIX/sonarr-series.json" <<'PY'
import json, sys
s = [x for x in json.load(open(sys.argv[1])) if x["id"] != 70 and x["id"] != 95]
json.dump(s, open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh" --post
    assert_success
    assert_output --partial "Summary: 0 stuck requests"
    assert_output --partial "Notice: nothing to post"
    [ "$(ha_posts)" -eq 0 ]
}

@test "--test posts a test notice even when nothing is stuck" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    printf '{"pageInfo": {"pages": 1}, "results": []}' > "$FIX/seerr-requests.json"
    run "$STACK/scripts/check-stuck-requests.sh" --test
    assert_success
    [ "$(ha_posts)" -eq 1 ]
    [ "$(notice title)" = "Stuck-request check: test" ]
    [ "$(notice level)" = info ]
    [ "$(notice tag)" = stuck-requests ]
}

@test "a second page of requests is fetched" {
    python3 - "$FIX/seerr-requests.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["pageInfo"]["pages"] = 2
json.dump(d, open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    grep -q '^GET http://localhost:5055/api/v1/request?take=200&skip=200&' "$CURL_LOG"
}

@test "the thresholds come from the environment" {
    STUCK_DAYS=40 MOVIE_STUCK_DAYS=40 run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Thresholds: TV 40 days, movies 40 days"
    refute_output --partial "Seerr asked for season(s) 10"
    refute_output --partial "Seventy Up"
    refute_output --partial "Phony"
    # Not age-gated: Seerr's FAILED state and the sweep, which now also
    # catches The Up Series since no request old enough explained it.
    assert_output --partial "Failed Film"
    assert_output --partial "Orphan (no Seerr request"
    assert_output --partial "The Up Series (no Seerr request"
}

@test "an old show's missing episodes are dated by year, not by a day count" {
    python3 - "$FIX/sonarr-episodes-50.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
eps = json.load(open(sys.argv[1]))
eps[0]["airDateUtc"] = (datetime.now(timezone.utc) - timedelta(days=9745)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(eps, open(sys.argv[1], "w"))
PY
    year=$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(days=9745)).year)')
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "S01E01, S01E02 aired in $year and Sonarr has never grabbed them"
    refute_output --partial "9745 days"
}

@test "Sonarr: nothing found, but Prowlarr has releases for the missing season under the title" {
    rm "$FIX/sonarr-release-501.json"
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Sonarr has never grabbed them: Sonarr's own search finds nothing, yet Prowlarr has 1 release for season(s) 1 under this title (e.g. Phony.S01E01.720p.WEB.h264-GRP). If they are this show and not a same-named one, the episode numbering differs from TVDB's"
}

@test "Sonarr: nothing found anywhere names the 70 Up renaming" {
    rm "$FIX/sonarr-release-501.json" "$FIX/prowlarr-phony.json"
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Sonarr has never grabbed them: no enabled indexer has a release under this title: they may name the show differently"
}

@test "Sonarr: releases it rejects are reported with the reasons" {
    python3 - "$FIX/sonarr-release-501.json" <<'PY'
import json, sys
json.dump([{"title": "Phony.S01E01.480p", "indexer": "EZTV", "approved": False, "rejected": True,
            "rejections": ["Quality 480p not wanted in profile"]}], open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh" --apply
    assert_success
    assert_output --partial "Sonarr has never grabbed them: Sonarr finds 1 release and rejects them all (Quality 480p not wanted in profile). Fix the quality profile or custom formats, or decline the request."
    run grep -c 'EpisodeSearch' "$CURL_LOG"
    assert_output 0
}

@test "Sonarr: a file far from TVDB's runtime, beside a same-named series, is the wrong show" {
    add_queer_as_folk
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Thresholds: TV 3 days, movies 7 days, file runtime 40% off TVDB's"
    assert_output --partial "Queer as Folk (3 wrong files, imported 14 days ago)"
    assert_output --partial "S01E01 runs 55:01 against TVDB's 32 min (Queer.As.Folk.S01E01.Babylon.1080p.PCOK.WEB-DL.DDP5.1.H.264-iVy); S01E05 runs 49:11 against TVDB's 33 min (Queer.as.Folk.S01E05.1080p.WEB.H264-DiMEPiECE); S01E06 runs 48:57 against TVDB's 33 min (Queer.as.Folk.S01E06.1080p.WEB.H264-DiMEPiECE). Queer as Folk (US) shares the title in Sonarr, so an untagged release of that show was filed here. Delete the files in Sonarr and search again, and check the season's other files: a smaller difference hides the same mistake."
    # The other five incident files are 29 to 39.6 percent long: under the
    # default, so the line stops at the three it can stand behind.
    refute_output --partial "S01E02 runs"
    refute_output --partial "S01E04 runs"
    refute_output --partial "S01E08 runs"
    # The US series has the sibling too, but its files fit or are not
    # comparable (two episodes in one file, no media info, no TVDB runtime).
    refute_output --partial "✗ Queer as Folk (US) ("
    refute_output --partial "1:28:00"
    assert_output --partial "Summary: 9 stuck requests (4 Radarr, 1 Seerr, 4 Sonarr)"
    assert_output --partial "• Queer as Folk (Sonarr; 3 wrong files, imported 14 days ago): S01E01 runs 55:01"
    [ "$(commands)" -eq 0 ]
    grep -q '^GET http://localhost:8989/api/v3/episodefile?seriesId=91 ' "$CURL_LOG"
}

@test "Sonarr: the same files with no same-named series are not reported, and -v says so" {
    add_queer_as_folk
    python3 - "$FIX/sonarr-series.json" <<'PY'
import json, sys
s = [x for x in json.load(open(sys.argv[1])) if x["id"] != 89]
json.dump(s, open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    refute_output --partial "wrong file"
    assert_output --partial "- none reported: 8 files in 1 series compared; 1 series (Queer as Folk) off by 40%+ with no same-named series in the library (-v lists them)"
    assert_output --partial "Summary: 8 stuck requests"
    run "$STACK/scripts/check-stuck-requests.sh" -v
    assert_success
    assert_output --partial "[verbose] Queer as Folk: 3 files 40%+ off TVDB's runtime (S01E01 runs 55:01 against TVDB's 32 min (Queer.As.Folk.S01E01.Babylon.1080p.PCOK.WEB-DL.DDP5.1.H.264-iVy)), but no other series shares the title, so not reported"
}

@test "Sonarr: RUNTIME_TOLERANCE widens the net; a clean library says so in one line" {
    add_queer_as_folk
    RUNTIME_TOLERANCE=30 run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Queer as Folk (7 wrong files, imported 14 days ago)"
    assert_output --partial "S01E01 runs 55:01 against TVDB's 32 min (Queer.As.Folk.S01E01.Babylon.1080p.PCOK.WEB-DL.DDP5.1.H.264-iVy); S01E02 runs 44:10 against TVDB's 33 min (Queer.as.Folk.S01E02.1080p.WEB.H264-DiMEPiECE); S01E04 runs 50:15 against TVDB's 36 min (Queer.as.Folk.S01E04.1080p.WEB.H264-DiMEPiECE); and 4 more. Queer as Folk (US) shares the title"
    # S01E03 at 45:02 against 35 min is 29 percent long: still under.
    refute_output --partial "S01E03 runs"
    # Without the UK files nothing is off, and the section says what it compared.
    rm "$FIX/sonarr-episodefile-91.json"
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "- none: 1 file in 1 series compared, all within 40% of TVDB's runtime"
}

@test "--post without a webhook fails before any API call" {
    run "$STACK/scripts/check-stuck-requests.sh" --post
    assert_failure
    assert_output --partial "--post needs HA_WEBHOOK_URL"
    [ ! -s "$CURL_LOG" ]
}
