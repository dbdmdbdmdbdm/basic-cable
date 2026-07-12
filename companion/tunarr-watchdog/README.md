# tunarr-watchdog

Optional server-side companion for keeping a Tunarr box healthy on modest
hardware. **You don't need this to use Basic Cable** — it exists because
Tunarr (as of 1.3.8) has two bugs that bite hardest on the small
Intel-N100-class boxes people actually run it on:

- **ffmpeg leaks on failed session starts**
  ([tunarr#1950](https://github.com/chrisbenincasa/tunarr/issues/1950)):
  a tune that fails under load leaves its ffmpeg running for hours. Orphans
  accumulate, saturate the CPU, and then every *new* tune fails while
  already-playing streams continue — from the couch it looks like "some
  channels work, some don't, makes no sense." Basic Cable shows **SERVER
  BUSY** when it detects this state; this watchdog fixes it server-side.
- **HDR tonemap pipeline never engages on VAAPI-only iGPUs**
  ([tunarr#1951](https://github.com/chrisbenincasa/tunarr/issues/1951)):
  unrelated to this script, but the reason HDR channels are the first to
  pile up — they're the heaviest transcodes.

Once those are fixed upstream, delete this directory with joy.

## What it does

Run `tunarr-watchdog.sh` from cron every ~3 minutes on the machine that runs
the Tunarr Docker container. Each pass it:

1. **Logs a status line** to `/var/log/tunarr-status.log` — load, ffmpeg
   count vs. sessions vs. live viewers, and a per-channel ffmpeg map with
   channel names. Cheap history for "what was happening at 9pm?"
2. **Logs per-channel stream failures** to
   `/var/log/tunarr-channel-failures.log` (scraped from the container logs,
   resolved to channel names) — answers "which channels are failing?"
3. **Reaps zombies**: any ffmpeg writing a channel stream that has had no
   live viewer for 5+ minutes gets killed (set `ZOMBIE_KILL=0` to report
   only). A viewer only counts as live if its session heartbeat is fresh —
   stale session records don't shield a zombie. Channels with a live viewer
   are never touched.
4. **Alerts on sustained pileup** and, as a last resort, restarts the
   container — only when the pileup is heavy *and* the API has stopped
   answering.

`tunarr-diag.sh` is the matching one-shot snapshot for interactive
debugging: ffmpeg→channel map with ages, who's watching what, a zombie
check with ready-made kill commands, and recent errors.

## Install

```bash
sudo cp tunarr-watchdog.sh tunarr-diag.sh /opt/
sudo chmod +x /opt/tunarr-watchdog.sh /opt/tunarr-diag.sh
echo '*/3 * * * * root /opt/tunarr-watchdog.sh >/dev/null 2>&1' | sudo tee /etc/cron.d/tunarr-watchdog
```

Requirements: `bash`, `curl`, `python3`, and the `docker` CLI, running on
the host that can see the Tunarr container's processes (same machine, or a
privileged container/LXC).

## Configuration

Environment variables, or put them in `/etc/tunarr-watchdog.conf`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `TUNARR_URL` | `http://localhost:8000` | Tunarr base URL (as seen from this machine) |
| `TUNARR_CONTAINER` | `tunarr` | Docker container name |
| `ZOMBIE_KILL` | `1` | `0` = detect + alert only, never kill |
| `ZOMBIE_AGE` | `300` | seconds an ffmpeg must be viewerless before it's a zombie |
| `FF_ALERT` / `LOAD_ALERT` | `5` / `16` | pileup alert thresholds (tune to your core count) |
| `FF_RESTART` | `7` | auto-restart needs more ffmpeg than this AND a dead API |
| `NOTIFY_CMD` | *(unset)* | command invoked as `cmd "<title>" "<message>"` for alerts |

Notification examples:

```bash
# ntfy.sh
NOTIFY_CMD='/opt/notify-ntfy.sh'   # curl -d "$2" -H "Title: $1" https://ntfy.sh/yourtopic

# Home Assistant (script that forwards to your notify service)
NOTIFY_CMD='/opt/notify-ha.sh'     # curl -X POST -H "Authorization: Bearer $TOKEN" ... 
```

Unset, alerts still land in `/var/log/tunarr-watchdog.log`.

## Reading the logs

```
tunarr-status.log:
2026-07-12 05:05:41 load=3.02,10.66 ffmpeg=2 sessions=2 viewers=1 [ch9 Best Picture Winners:1] [ch121 Jeopardy!:1]

tunarr-channel-failures.log:
2026-07-12 04:57:12 STREAM-FAIL ch80 Best of 1980s (80779740-...)
2026-07-12 05:03:41 ZOMBIE-KILLED ch121 Jeopardy! (pid 16491, 17504s);
```

The zombie signature, if you're checking by hand: `pgrep -cx ffmpeg` much
larger than the channel count in `GET /api/sessions`.
