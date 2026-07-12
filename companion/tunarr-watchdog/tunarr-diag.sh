#!/bin/bash
# tunarr-diag — one-shot health snapshot of a Tunarr server, with channel names.
# Usage: TUNARR_URL=http://localhost:8000 ./tunarr-diag.sh

[ -f /etc/tunarr-watchdog.conf ] && . /etc/tunarr-watchdog.conf
API=${TUNARR_URL:-http://localhost:8000}
CHAN_CACHE=/var/lib/tunarr-watchdog/channels.tsv

chan_name() {
  awk -F'\t' -v k="$1" '$1==k || $2==k {print "ch"$2" "$3; f=1; exit} END{if(!f) print "ch? "k}' "$CHAN_CACHE" 2>/dev/null
}

echo "=== TUNARR DIAG $(date '+%Y-%m-%d %H:%M:%S') ==="
echo
echo "-- system --"
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)   (4-core N100: >12 = trouble)"
free -m | awk 'NR<=2'
echo
API_CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$API/api/version")
echo "-- tunarr api: HTTP $API_CODE --"
echo
echo "-- ffmpeg processes ($(pgrep -cx ffmpeg)) --"
ps -o pid=,etimes=,args= -C ffmpeg 2>/dev/null | awk '{
  id="(non-stream: re-encode etc)"; if (match($0,/stream_[a-f0-9-]+/)) id=substr($0,RSTART+7,36);
  printf "%s %s %s\n", $1, $2, id }' | while read pid et id; do
    name=""; [ "${#id}" = "36" ] && name=$(chan_name "$id")
    printf "  pid %-8s age %5ss  %s %s\n" "$pid" "$et" "$name" "$id"
done
echo
echo "-- sessions (who is watching what) --"
curl -s -m 5 "$API/api/sessions" | python3 -c '
import json,sys
try: s=json.load(sys.stdin)
except Exception: print("  (sessions API unparseable)"); sys.exit(0)
if not s: print("  (none)")
names={}
try:
    for line in open("/var/lib/tunarr-watchdog/channels.tsv"):
        p=line.rstrip("\n").split("\t")
        if len(p)>=3: names[p[0]]="ch"+p[1]+" "+p[2]
except Exception: pass
for cid,lst in s.items():
    for sess in lst:
        conns=sess.get("connections",[])
        if isinstance(conns,dict): conns=list(conns.values())
        agents=", ".join(c.get("userAgent","?")[:40] for c in conns) or "no viewers"
        print(f"  {names.get(cid,cid)}  state={sess.get('state')}  conns={sess.get('numConnections')}  [{agents}]")'
echo
echo "-- ZOMBIE check (ffmpeg with no connected viewer, >5 min old) --"
ACTIVE=$(curl -s -m 5 "$API/api/sessions" | python3 -c '
import json,sys
try: s=json.load(sys.stdin)
except Exception: sys.exit(0)
print(" ".join(cid for cid,lst in s.items() if sum(x.get("numConnections",0) for x in lst)>0))')
FOUND=0
while read pid et id; do
  [ -z "$pid" ] && continue
  [ "${#id}" != "36" ] && continue
  [ "$et" -lt 300 ] && continue
  if ! echo " $ACTIVE " | grep -q " $id "; then
    echo "  ZOMBIE: pid $pid (${et}s) $(chan_name "$id") — kill with: pkill -9 -f stream_$id"
    FOUND=1
  fi
done < <(ps -o pid=,etimes=,args= -C ffmpeg 2>/dev/null | awk '{
  id="none"; if (match($0,/stream_[a-f0-9-]+/)) id=substr($0,RSTART+7,36); print $1, $2, id }')
[ "$FOUND" = "0" ] && echo "  none"
echo
echo "-- stream errors in tunarr log (last 30 min) --"
docker logs "${TUNARR_CONTAINER:-tunarr}" --since 30m 2>&1 | grep -aE 'Error starting stream|No master playlist|Stream not ready|still running after SIGTERM|error decoding' | tail -12 | cut -c1-160
echo
echo "-- recent channel failures (watchdog scrape) --"
tail -12 /var/log/tunarr-channel-failures.log 2>/dev/null || echo "  (no failures logged yet)"
echo
echo "-- watchdog status (last 5 passes) --"
tail -5 /var/log/tunarr-status.log 2>/dev/null || echo "  (no status yet)"
