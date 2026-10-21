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
# side: the indexers have the title only as S10E01-style episodes.
#
# `docker` and `curl` are stubbed on PATH, and the script runs from a copy in a
# throwaway stack directory with no .env. The curl stub serves each API call
# from a fixture and logs every call, with its body, to $CURL_LOG. A Prowlarr
# search is served from prowlarr-<title-slug>.json, or an empty list. Dates in
# the fixtures are written relative to now, so the age thresholds are real.

setup() {
    load helpers/setup
    command -v python3 >/dev/null || skip "python3 not installed"
    unset HA_WEBHOOK_URL STUCK_DAYS MOVIE_STUCK_DAYS MAX_SEARCHES

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
    # carries (18), and a film the indexers have but Radarr never took (19).
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
dump("seerr-requests", {"pageInfo": {"pages": 1, "pageSize": 200, "results": 10, "page": 1}, "results": [
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
def movie(i, title, year, **kw):
    m = {"id": i, "title": title, "year": year, "monitored": True, "isAvailable": True,
         "hasFile": False, "added": ago(30)}
    m.update(kw); return m
# The 70 Up "movie": broadcast on 2026-09-15, a digital date, indexers have S10E01/E02.
dump("radarr-movie-200", movie(200, "Seventy Up", 2026, digitalRelease=ago(36)))
dump("radarr-history-200", [])
dump("radarr-movie-201", movie(201, "Not Yet", 2027, isAvailable=False))
# Still in cinemas, no home date: waiting is right.
dump("radarr-movie-202", movie(202, "Arthouse Film", 2026, inCinemas=ago(60), added=ago(40)))
dump("radarr-history-202", [])
# A 2003 film with no dates at all on TMDB and nothing on any indexer.
dump("radarr-movie-203", movie(203, "Old Obscure", 2003, added=ago(90)))
dump("radarr-history-203", [])
# Out at home, the indexers have film-shaped releases, Radarr never took one.
dump("radarr-movie-204", movie(204, "Grabbable", 2025, digitalRelease=ago(30), added=ago(25)))
dump("radarr-history-204", [])
def rel(title, indexer="NZBgeek"): return {"title": title, "indexer": indexer, "categories": []}
dump("prowlarr-seventy-up", [rel("Seventy.Up.S10E01.1080p.HDTV.H264-GRP"), rel("Seventy.Up.S10E02.1080p.HDTV.H264-GRP"),
                             rel("Seventy.Nine.Up.2019.1080p.WEB-DL")])   # not a prefix match
dump("prowlarr-grabbable", [rel("Grabbable.2025.1080p.WEB-DL.DDP5.1.H.264-GRP"), rel("Grabbable.2025.2160p.WEB-DL-GRP"),
                            rel("Ungrabbable.2025.1080p")])
# The second hit is a season Sonarr isn't missing (a same-named show's, say): not counted.
dump("prowlarr-phony", [rel("Phony.S01E01.720p.WEB.h264-GRP", "EZTV"), rel("Phony.S03E04.720p.WEB.h264-GRP", "EZTV")])
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
# A Prowlarr search is served by the query's slug, empty when no fixture has it.
search() {
  local q="${url#*query=}"; q="${q%%&*}"; q="${q//+/ }"
  q=$(printf '%b' "${q//%/\\x}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'); q="${q#-}"; q="${q%-}"
  [ -f "$FIX/prowlarr-$q.json" ] && cat "$FIX/prowlarr-$q.json" || echo '[]'
}
case "$method $url" in
  "GET http://localhost:5055/api/v1/request?take=200&skip=0&"*) serve seerr-requests ;;
  "GET http://localhost:5055/api/v1/request?take=200&skip=200&"*) serve seerr-requests-page2 ;;
  "GET http://localhost:5055/api/v1/movie/"*) serve "seerr-movie-${url##*/}" ;;
  "GET http://localhost:5055/api/v1/tv/"*) serve "seerr-tv-${url##*/}" ;;
  "GET http://localhost:8989/api/v3/series") serve sonarr-series ;;
  "GET http://localhost:8989/api/v3/episode?seriesId="*) serve "sonarr-episodes-${url##*=}" ;;
  "GET http://localhost:8989/api/v3/history/series?seriesId="*) serve "sonarr-history-${url##*=}" ;;
  "GET http://localhost:7878/api/v3/movie/"*) serve "radarr-movie-${url##*/}" ;;
  "GET http://localhost:7878/api/v3/history/movie?movieId="*) serve "radarr-history-${url##*=}" ;;
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

posts() {
    grep -c '^POST ' "$CURL_LOG" || true
}

@test "a dry run names each stuck request with a diagnosis, and posts nothing" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    # The 70 Up case: Seerr's season number isn't one TVDB uses.
    assert_output --partial "The Up Series (adam, requested 36 days ago)"
    assert_output --partial "Seerr asked for season(s) 10 but TVDB numbers this show's seasons 1964, 1970 … 2019, 2026"
    # Aired, missing, never grabbed; Prowlarr has it under the title, so numbering differs.
    assert_output --partial "Phony (kris, requested 20 days ago)"
    assert_output --partial "S01E01, S01E02 aired 15 days ago and Sonarr has never grabbed them: Prowlarr finds 1 release for season(s) 1 under this title that Sonarr never took (e.g. Phony.S01E01.720p.WEB.h264-GRP). If they are this show and not a same-named one"
    # Seerr's own FAILED state, titled from Seerr since Radarr never saw it.
    assert_output --partial "Failed Film (adam, requested 79 days ago)"
    assert_output --partial "Seerr marked this request FAILED: the hand-off to Radarr did not go through."
    refute_output --partial "VPN"
    # The sweep: monitored series with nothing monitored, no request behind it.
    assert_output --partial "Orphan (no Seerr request, added 12 days ago)"
    assert_output --partial "every season is unmonitored"
    assert_output --partial "Summary: 7 stuck requests (3 Radarr, 1 Seerr, 3 Sonarr)"
    # Left alone: unreleased film, grabbed episode, too-recent request, unmonitored series.
    refute_output --partial "Not Yet"
    refute_output --partial "Fine Show"
    refute_output --partial "Dropped"
    assert_output --partial "Notice: would post (dry run; use --post)"
    [ "$(posts)" -eq 0 ]
}

@test "Radarr: the indexers have the title only as episodes, so it is the TV-broadcast trap" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Seventy Up (2026) (adam, requested 30 days ago)"
    assert_output --regexp "In Radarr 30 days, home release 20[0-9]{2}-[0-9]{2}-[0-9]{2}, never grabbed: the indexers have it only as TV episodes \(e\.g\. Seventy\.Up\.S10E01\.1080p\.HDTV\.H264-GRP\): a TV broadcast with a TMDB movie entry, which Radarr can never match\. Delete it from Radarr and request the series instead\."
}

@test "Radarr: film-shaped releases Radarr never took point at Interactive Search" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Grabbable (2025) (adam, requested 25 days ago)"
    assert_output --partial "never grabbed: Prowlarr finds 2 releases under this title that Radarr never took (e.g. Grabbable.2025.1080p.WEB-DL.DDP5.1.H.264-GRP). Open Radarr → Interactive Search"
    # "Ungrabbable.2025" contains the title but doesn't start with it.
    refute_output --partial "finds 3 releases"
}

@test "Radarr: nothing under the title on any enabled indexer" {
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Old Obscure (2003) (adam, requested 90 days ago)"
    assert_output --partial "In Radarr 90 days, no home release date on TMDB, never grabbed: no enabled indexer has a release under this title. Wait, add an indexer that carries it, or decline the request."
}

@test "Radarr: a film still in cinemas with no home release date is waiting, not stuck" {
    run "$STACK/scripts/check-stuck-requests.sh" -v
    assert_success
    refute_output --partial "✗ Arthouse Film"
    assert_output --regexp "\[verbose\] Arthouse Film \(2026\): in cinemas 20[0-9]{2}-[0-9]{2}-[0-9]{2}, no home release date yet; waiting is right"
    # A Prowlarr search is spent only on the cases that need one.
    [ "$(grep -c '^GET http://localhost:9696/api/v1/search' "$CURL_LOG")" -eq 4 ]
    assert_output --partial "Prowlarr searches this run: 4 (cap 20)"
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

@test "without Prowlarr, the never-grabbed lines say they are unverified" {
    export STUB_CONTAINERS="gluetun seerr sonarr radarr"
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "WARNING: Could not read Prowlarr's API key"
    assert_output --partial "Seventy Up (2026)"
    assert_output --partial "never grabbed: Prowlarr could not be asked whether the indexers have it. If this is a TV broadcast with a TMDB movie entry, Radarr can never match it"
    assert_output --partial "Sonarr has never grabbed them: Prowlarr could not be asked"
    run grep -c '^GET http://localhost:9696' "$CURL_LOG"
    assert_output 0
}

@test "the per-run search cap is honoured" {
    MAX_SEARCHES=1 run "$STACK/scripts/check-stuck-requests.sh" -v
    assert_success
    [ "$(grep -c '^GET http://localhost:9696/api/v1/search' "$CURL_LOG")" -eq 1 ]
    assert_output --partial "Prowlarr could not be asked"
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
    [ "$(posts)" -eq 1 ]
    [ "$(notice level)" = info ]
    [ "$(notice tag)" = stuck-requests ]
    [ "$(notice title)" = "Stuck requests: 7 requests waiting" ]
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
    [ "$(posts)" -eq 0 ]
}

@test "--test posts a test notice even when nothing is stuck" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    printf '{"pageInfo": {"pages": 1}, "results": []}' > "$FIX/seerr-requests.json"
    run "$STACK/scripts/check-stuck-requests.sh" --test
    assert_success
    [ "$(posts)" -eq 1 ]
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

@test "Sonarr: nothing under the title on any indexer names the 70 Up renaming" {
    rm "$FIX/prowlarr-phony.json"
    run "$STACK/scripts/check-stuck-requests.sh"
    assert_success
    assert_output --partial "Sonarr has never grabbed them: no enabled indexer has a release under this title: they may name the show differently"
}

@test "--post without a webhook fails before any API call" {
    run "$STACK/scripts/check-stuck-requests.sh" --post
    assert_failure
    assert_output --partial "--post needs HA_WEBHOOK_URL"
    [ ! -s "$CURL_LOG" ]
}
