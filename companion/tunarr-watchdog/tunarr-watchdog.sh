#!/bin/bash
# tunarr-watchdog — keeps a Tunarr server healthy on modest hardware.
#
# Tunarr (as of 1.3.8) leaks ffmpeg processes when a session fails to start
# (https://github.com/chrisbenincasa/tunarr/issues/1950). Orphaned transcodes
# accumulate, saturate the CPU, and then every NEW tune fails while
# established streams keep playing — which looks like "random channels are
# broken" from the couch. This script detects and reaps them.
#
# Run from cron every few minutes (see README.md). Every pass it:
#   1. Appends a status line to $STATUS_LOG (load, ffmpeg count, sessions,
#      per-channel ffmpeg map with channel names).
#   2. Scrapes the Tunarr container logs for stream errors since the last
#      pass -> $FAIL_LOG, resolved to channel names ("which channel is
#      failing and when").
#   3. Detects ZOMBIES: an ffmpeg writing a channel stream that has had no
#      connected viewer for ZOMBIE_AGE seconds. Kills them (ZOMBIE_KILL=1)
#      or just reports. Never touches a channel with a live viewer.
#   4. Alerts on sustained pileup (ffmpeg count / load thresholds) and
#      auto-restarts the container if the pileup is heavy AND the API has
#      stopped answering.
#
# Config: environment variables, or /etc/tunarr-watchdog.conf (sourced).
# Requires: bash, curl, python3, docker CLI access to the Tunarr container.

[ -f /etc/tunarr-watchdog.conf ] && . /etc/tunarr-watchdog.conf

TUNARR_URL=${TUNARR_URL:-http://localhost:8000}
TUNARR_CONTAINER=${TUNARR_CONTAINER:-tunarr}
LOG=${LOG:-/var/log/tunarr-watchdog.log}
STATUS_LOG=${STATUS_LOG:-/var/log/tunarr-status.log}
FAIL_LOG=${FAIL_LOG:-/var/log/tunarr-channel-failures.log}
STATE_DIR=${STATE_DIR:-/var/lib/tunarr-watchdog}

FF_ALERT=${FF_ALERT:-5}            # ffmpeg count above this = breach
LOAD_ALERT=${LOAD_ALERT:-16}       # 5-min load above this = breach
FF_RESTART=${FF_RESTART:-7}        # auto-restart needs > this AND a dead API
ALERT_COOLDOWN=${ALERT_COOLDOWN:-1800}
RESTART_COOLDOWN=${RESTART_COOLDOWN:-1800}
ZOMBIE_AGE=${ZOMBIE_AGE:-300}      # ffmpeg older than this w/o viewer = zombie
ZOMBIE_KILL=${ZOMBIE_KILL:-1}      # 0 = report only

# NOTIFY_CMD is invoked as: $NOTIFY_CMD "<title>" "<message>" — point it at
# anything (ntfy, Pushover, Home Assistant, a Discord webhook wrapper...).
# Unset = log only. Examples in README.md.
NOTIFY_CMD=${NOTIFY_CMD:-}

mkdir -p "$STATE_DIR"
exec 9>/run/tunarr-watchdog.lock
flock -n 9 || exit 0

ts() { date '+%Y-%m-%d %H:%M:%S'; }
logit() { echo "$(ts) $*" >> "$LOG"; }

notify() { # $1=title $2=message
  logit "ALERT: $1 — $2"
  [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$1" "$2" >> "$LOG" 2>&1
}

# ---- channel name cache (id \t number \t name), refreshed hourly ----
CHAN_CACHE=$STATE_DIR/channels.tsv
if [ ! -s "$CHAN_CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$CHAN_CACHE" 2>/dev/null || echo 0) )) -gt 3600 ]; then
  curl -s -m 10 "$TUNARR_URL/api/channels" | python3 -c '
import json,sys
try: chans=json.load(sys.stdin)
except Exception: sys.exit(1)
for c in chans: print(c["id"], c["number"], c["name"], sep="\t")
' > "$CHAN_CACHE.tmp" 2>/dev/null && [ -s "$CHAN_CACHE.tmp" ] && mv "$CHAN_CACHE.tmp" "$CHAN_CACHE"
  rm -f "$CHAN_CACHE.tmp"
fi
chan_name() { # $1 = channel uuid OR channel number -> "ch<num> <name>"
  awk -F'\t' -v k="$1" '$1==k || $2==k {print "ch"$2" "$3; f=1; exit} END{if(!f) print "ch? "k}' "$CHAN_CACHE" 2>/dev/null
}

# ---- gather ffmpeg map: "pid etimes chanid" ----
FF_MAP=$(ps -o pid=,etimes=,args= -C ffmpeg 2>/dev/null | awk '{
  id="none"; if (match($0,/stream_[a-f0-9-]+/)) id=substr($0,RSTART+7,36);
  print $1, $2, id }')
FF_COUNT=$(pgrep -cx ffmpeg)
LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)

# ---- sessions: which channels have a LIVE viewer ----
# A connection only counts if its heartbeat is <120s old — Tunarr's session
# records can go stale (backgrounded clients, proxy remnants) and a stale
# connection must not shield a zombie.
SESSIONS_JSON=$(curl -s -m 5 "$TUNARR_URL/api/sessions")
SESS_PARSE=$(echo "$SESSIONS_JSON" | python3 -c '
import json,sys,time
try: s=json.load(sys.stdin)
except Exception: print("PARSE_FAIL"); sys.exit(0)
now_ms=time.time()*1000
def live(sess):
    conns=sess.get("connections",[])
    if isinstance(conns,dict): conns=list(conns.values())
    return any(now_ms - c.get("lastHeartbeat",0) < 120000 for c in conns)
active=[cid for cid,lst in s.items() if any(live(x) for x in lst)]
print(str(len(s))+" "+str(len(active))+" "+" ".join(active))')
if [ "$SESS_PARSE" = "PARSE_FAIL" ] || [ -z "$SESS_PARSE" ]; then
  SESS_OK=0; SESS_COUNT="?"; ACTIVE_CHANS=""
else
  SESS_OK=1
  SESS_COUNT=$(echo "$SESS_PARSE" | cut -d' ' -f1)
  ACTIVE_CHANS=$(echo "$SESS_PARSE" | cut -d' ' -f3-)
fi

# ---- status line (every pass) ----
CHAN_SUMMARY=""
if [ -n "$FF_MAP" ]; then
  CHAN_SUMMARY=$(echo "$FF_MAP" | awk '{print $3}' | sort | uniq -c | while read n id; do
    [ "$id" = "none" ] && { echo -n "[non-stream:$n] "; continue; }
    echo -n "[$(chan_name "$id"):$n] "
  done)
fi
echo "$(ts) load=$LOAD1,$LOAD5 ffmpeg=$FF_COUNT sessions=$SESS_COUNT viewers=$(echo $ACTIVE_CHANS | wc -w) $CHAN_SUMMARY" >> "$STATUS_LOG"

# ---- per-channel failure scrape (container logs since last pass) ----
MARKER_FILE=$STATE_DIR/logscrape_since
SINCE=$(cat "$MARKER_FILE" 2>/dev/null || date -Is -d '10 minutes ago')
date -Is > "$MARKER_FILE"
docker logs "$TUNARR_CONTAINER" --since "$SINCE" 2>&1 | \
  grep -aE 'Error starting stream|No master playlist|Stream not ready|still running after SIGTERM|error decoding' | \
  grep -aoE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}|channel-[0-9]+-transcode' | \
  sed 's/channel-\([0-9]*\)-transcode/\1/' | sort -u | while read cid; do
    name=$(chan_name "$cid")
    # drop unresolvable 36-char uuids — those are session ids, not channels
    case "$name" in "ch? "*) [ "${#cid}" = "36" ] && continue ;; esac
    echo "$(ts) STREAM-FAIL $name ($cid)" >> "$FAIL_LOG"
done

# ---- zombie detection + auto-kill (only when sessions API parsed OK) ----
if [ "$SESS_OK" = "1" ] && [ -n "$FF_MAP" ]; then
  ZOMBIE_PIDS=""; ZOMBIE_DESC=""; DUP_DESC=""
  while read pid et chan; do
    [ -z "$pid" ] && continue
    [ "$chan" = "none" ] && continue            # unrelated ffmpeg on the box
    [ "$et" -lt "$ZOMBIE_AGE" ] && continue     # still spinning up / viewer just left
    if ! echo " $ACTIVE_CHANS " | grep -q " $chan "; then
      ZOMBIE_PIDS="$ZOMBIE_PIDS $pid"
      ZOMBIE_DESC="$ZOMBIE_DESC$(chan_name "$chan") (pid $pid, ${et}s); "
    fi
  done <<< "$FF_MAP"

  # duplicate writers on an ACTIVE channel (report-only — killing risks the live viewer)
  DUPS=$(echo "$FF_MAP" | awk '$3!="none"{print $3}' | sort | uniq -c | awk '$1>1{print $2}')
  for d in $DUPS; do
    if echo " $ACTIVE_CHANS " | grep -q " $d "; then
      DUP_DESC="$DUP_DESC$(chan_name "$d") x$(echo "$FF_MAP" | grep -c " $d\$"); "
    fi
  done

  if [ -n "$ZOMBIE_PIDS" ]; then
    if [ "$ZOMBIE_KILL" = "1" ]; then
      logit "ZOMBIE-KILL: $ZOMBIE_DESC-> kill -9$ZOMBIE_PIDS"
      kill -9 $ZOMBIE_PIDS 2>>"$LOG"
      echo "$(ts) ZOMBIE-KILLED $ZOMBIE_DESC" >> "$FAIL_LOG"
      notify "Tunarr zombies killed" "Killed orphan ffmpeg with no viewer: $ZOMBIE_DESC(load5 $LOAD5, ffmpeg was $FF_COUNT)"
    else
      logit "ZOMBIE-DETECTED (kill disabled): $ZOMBIE_DESC"
      notify "Tunarr zombie ffmpeg" "Orphan ffmpeg with no viewer: $ZOMBIE_DESC(auto-kill disabled)"
    fi
  fi
  if [ -n "$DUP_DESC" ]; then
    logit "DUPLICATE-WRITERS on active channel: $DUP_DESC"
    now=$(date +%s)
    last_dup=$(cat "$STATE_DIR/last_dup_alert" 2>/dev/null || echo 0)
    if [ $((now - last_dup)) -ge "$ALERT_COOLDOWN" ]; then
      echo "$now" > "$STATE_DIR/last_dup_alert"
      notify "Tunarr duplicate writers" "Multiple ffmpeg writing one ACTIVE channel (corruption risk): $DUP_DESC- not auto-killed (live viewer)."
    fi
  fi
fi

# ---- sustained-pileup breach / last-resort restart ----
breach=0
if [ "$FF_COUNT" -gt "$FF_ALERT" ] || awk -v l="$LOAD5" -v t="$LOAD_ALERT" 'BEGIN{exit !(l>t)}'; then
  breach=1
fi

prev=$(cat "$STATE_DIR/breaches" 2>/dev/null || echo 0)
if [ "$breach" -eq 1 ]; then
  count=$((prev + 1))
else
  count=0
  [ "$prev" -ge 2 ] && logit "recovered: ffmpeg=$FF_COUNT load5=$LOAD5"
fi
echo "$count" > "$STATE_DIR/breaches"
[ "$breach" -eq 0 ] && exit 0

HEALTH=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$TUNARR_URL/api/version")
logit "breach #$count: ffmpeg=$FF_COUNT load5=$LOAD5 api=$HEALTH"
[ "$count" -lt 2 ] && exit 0

now=$(date +%s)
last_alert=$(cat "$STATE_DIR/last_alert" 2>/dev/null || echo 0)
last_restart=$(cat "$STATE_DIR/last_restart" 2>/dev/null || echo 0)

if [ "$FF_COUNT" -gt "$FF_RESTART" ] && [ "$HEALTH" != "200" ]; then
  if [ $((now - last_restart)) -ge "$RESTART_COOLDOWN" ]; then
    logit "AUTO-RESTART: ffmpeg=$FF_COUNT (> $FF_RESTART) and API probe failed ($HEALTH) — docker restart $TUNARR_CONTAINER"
    docker restart "$TUNARR_CONTAINER" >> "$LOG" 2>&1
    echo "$now" > "$STATE_DIR/last_restart"
    echo "$now" > "$STATE_DIR/last_alert"
    echo 0 > "$STATE_DIR/breaches"
    notify "Tunarr auto-restarted" "$FF_COUNT ffmpeg sessions, load5 $LOAD5, API probe failed ($HEALTH). Ran docker restart $TUNARR_CONTAINER."
  else
    logit "restart wanted but in cooldown ($((now - last_restart))s since last)"
  fi
  exit 0
fi

if [ $((now - last_alert)) -ge "$ALERT_COOLDOWN" ]; then
  api_note="API OK"
  [ "$HEALTH" != "200" ] && api_note="API probe FAILING ($HEALTH)"
  echo "$now" > "$STATE_DIR/last_alert"
  notify "Tunarr ffmpeg pileup" "$FF_COUNT ffmpeg sessions, load5 $LOAD5, $api_note (2+ checks). Suggest: docker restart $TUNARR_CONTAINER"
else
  logit "alert suppressed (cooldown, $((now - last_alert))s since last)"
fi
