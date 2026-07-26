# Running Tunarr for Basic Cable — field notes

Everything here was learned running Basic Cable against a real Tunarr 1.3.x
server (Docker on a 4-core Intel N100, VAAPI transcoding, media on a Plex
server over NFS) as the household's daily TV. None of it is required reading
to get started — but if a channel "doesn't work" and the app looks innocent,
the answer is probably on this page. The [README's server sizing
section](../README.md#server-sizing--troubleshooting) has the short version;
this is the long one.

## Stream mode must be `hls`

Every channel should use Tunarr's default **HLS** stream mode. The
alternative `hls_direct` mode looks tempting (remux instead of transcode)
but is broken for any client that isn't running on the Tunarr box itself:

- The playlist it emits contains a single giant segment pointing at
  **`http://localhost:<port>/stream.ts?...`** — `localhost` meaning *the
  client device*, so the Apple TV can never fetch it. The channel tunes,
  then plays nothing, forever.
- `hls_direct` also **ignores the channel's transcode config entirely**, so
  any per-channel resolution/bitrate settings silently do nothing.

The failure is quiet: Tunarr's API answers, the guide looks fine, only the
stream is dead. If exactly one channel never plays while its neighbors work,
check its `streamMode` first (channel settings in the Tunarr UI, or
`GET /api/channels`). Set it back to `hls` and re-tune with a **fresh
session** (force-quit the app, or restart the container) — Tunarr keeps an
in-progress session on whatever config it started with.

## Transcode configs: per-channel, and only fresh sessions see changes

Two things about Tunarr's transcode configs that are easy to burn an evening
on:

- **Changes only apply to new sessions.** Editing a transcode config (or
  assigning a different one to a channel) does nothing to a stream that's
  already running — re-tune from scratch or restart the container to see the
  effect. If you're testing a config change and "nothing happened," this is
  why.
- **Don't edit the shared default config to fix one channel.** Every channel
  points at a transcode config, and by default they all share one. Make a
  new config and assign it to the channel that needs it.

### High-framerate sources (50/60 fps broadcasts)

Tunarr's transcode config has **no output-framerate setting** — output
follows the source framerate. A 1080p50 sports broadcast therefore demands a
live 1080p50 encode, which is right at the limit of an N100-class iGPU: the
stream starts, then buffers endlessly. The available lever is resolution:
make a per-channel config at **1280×720** (with "normalize frame rate" on)
for channels built from 50/60 fps material. That's roughly a 2.3× cut in
encode load and plays smoothly where 1080p50 didn't.

## HDR: pre-transcode instead of live-tonemapping

As the README notes, HDR→SDR tonemapping is the most expensive thing Tunarr
does, and on VAAPI-only iGPUs the current release picks a broken pipeline
for it ([tunarr#1951](https://github.com/chrisbenincasa/tunarr/issues/1951)).
Even where tonemapping works, a live 4K HDR tonemap is the first thing to
fail under load. Untonemapped HDR is its own trap: the transcoded h264
keeps the bt2020/PQ color flags, which AVFoundation clients (Basic Cable,
Plex on Apple devices) refuse to play even though the stream looks fine in
a desktop browser.

The setup that actually works: **don't ask Tunarr to handle HDR at all.**
Keep a parallel "channel masters" library of pre-made **1080p SDR copies**
of the HDR movies your channels use, and point channel lineups at those
copies instead of the 4K HDR originals (the originals stay in the main
library for direct-play in Plex/Infuse/etc.). A batch ffmpeg job — hardware
tonemap (`tonemap_vaapi`) with a CPU `zscale`/hable fallback for files that
lack mastering-display metadata, where the hardware path errors out — runs
off-hours and produces ~2–3 GB per movie. Live channel tunes then transcode
easy 1080p SDR, and the whole class of "HDR channel wedges the server"
problems disappears.

## Channels are snapshots — library changes rot lineups

A Tunarr channel stores a **copy** of each program at the moment you added
it, not a live query. Two consequences:

- **New library items never auto-appear** on a channel. If you want a
  channel to track a growing collection (a label, a smart collection, a
  show), something external has to re-sync the lineup periodically —
  Tunarr's library scan (`POST /api/media-sources/{id}/libraries/{id}/scan`)
  picks up *new* items for manual adding, but doesn't touch existing
  channels.
- **Media-server churn silently kills slots.** When Plex re-indexes an item
  (metadata refresh on an unmatched item, a file replaced in place, a big
  download batch settling), the item's ratingKey or media-part ids change —
  and Tunarr's stored copy still points at the old ones. The library scan is
  **additive only**: it never reconciles deletions or refreshes media info
  on existing programs. Dead slots stay in the lineup looking healthy.

From the couch, rotted slots are the **"technical difficulties" slate**: the
channel is up, but at certain points in its schedule Tunarr's ffmpeg gets a
404 from the media server and plays its error image instead. Diagnose with
the container logs — `docker logs tunarr | grep "404 Not Found"` — and fix
by rebuilding the affected channel's lineup so it points at the current
library items. If a channel seems weirdly obsessed with one program, that's
the same disease: dead slots can't play, so the survivors repeat.

Two related gotchas: the error slate is not free — it's rendered by a
full realtime encode that runs as long as someone's tuned, so a rotted
channel left playing costs the same CPU as a real one. And error-image
sessions count toward the concurrent-transcode budget like everything else.

## Failure modes, from the server's side

The README describes what the app shows (**SERVER BUSY** vs **NO SIGNAL**);
here's what's usually happening on the box, in the order worth checking:

1. **ffmpeg pileup.** Check `uptime` and `pgrep -cx ffmpeg` *first*. If
   load is way above the core count and there are more ffmpegs than live
   viewers, this is it — channel-surfing leaves each abandoned tune's
   transcode running for a grace period, failed session starts leak theirs
   entirely ([tunarr#1950](https://github.com/chrisbenincasa/tunarr/issues/1950)),
   and error-slate encoders run indefinitely. New tunes then can't write
   their playlist before Tunarr's ready-timeout and fail in a retry loop
   while established streams keep playing. `docker restart tunarr` clears
   it; the [watchdog companion](../companion/tunarr-watchdog) prevents the
   slow-burn version by reaping viewerless ffmpegs automatically.
2. **Frozen served playlist.** Rarer and sneakier: everything looks healthy
   (ffmpeg alive and writing segments, API answering, session shows a live
   client) but the HLS playlist Tunarr *serves over HTTP* has stopped
   advancing, so the client buffers the same stale window forever. Diagnose
   by fetching `/stream/channels/{id}/hls/stream.m3u8` twice ~15 s apart —
   if the served playlist doesn't advance while the one on disk (in
   Tunarr's config dir under `streams/`) does, the in-memory session state
   is wedged. Only a container restart fixes it. No watchdog catches this
   one; the two-curl check is the test.
3. **Transient media-server errors masquerading as codec problems.** If the
   ffmpeg log shows an exotic filter error (`auto_scale_0`, hwaccel init
   failures), grep the *same* log for `503` or `Stream ends prematurely`
   first — an overloaded media server truncating its response makes the
   decoder chew garbage, and the last error line points at the wrong
   culprit. Re-run the logged ffmpeg command by hand; if it exits 0, the
   file is fine and it was a transient.

## Contain the blast radius

If Tunarr shares hardware with anything you care about (DNS, Home
Assistant, the hypervisor itself), **cap its CPU**. A pathological pileup —
a dozen ffmpegs stuck in I/O wait — can drive a shared host to load 80+ and
take down every co-tenant service. A Docker `cpus:` limit or an LXC
`cpulimit` one core below the host's count keeps a Tunarr meltdown a Tunarr
problem. For the same reason, run any watchdog with restart authority
*outside* the container/VM it watches, so it still works when the thing
it's watching is wedged.

Give the container headroom, too: transcoding plus library scans over NFS
is memory-hungry, and a 2 GB container that wedges under load often just
needs 4 GB.

## Behind a port-forward or proxy

Tunarr behind a TCP forwarder (socat, a reverse proxy, a NAT rule — e.g.
keeping an old address alive after moving the server) works fine with Basic
Cable — everything is plain HTTP and relative HLS URLs, as long as every
channel is in `hls` mode (`hls_direct`'s absolute `localhost` URLs are
exactly what breaks through a forwarder). One side effect worth knowing:
all clients reach Tunarr from the forwarder's IP, so `GET /api/sessions`
shows every viewer with the same address — session heartbeat freshness, not
IP, is the reliable liveness signal (the watchdog already counts it this
way).

## Keeping mixes cheap

The README covers [channel mixes](../README.md#channel-mixes); the server
note is just this: each *tuned* variant is a full transcode session, but
untuned variants cost nothing — so a 3-wide music mix costs one session
while you watch, plus a brief second one on each hop. On a small box,
resist the urge to pre-warm all variants around the clock; warm them only
while someone is actually watching the mix, if at all.
