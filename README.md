# Basic Cable

> ☕ Enjoying Basic Cable? [Buy me a coffee](https://buymeacoffee.com/dbdmdbdmdbdm).
>
> 🔍 Want to check that the App Store build matches this source? See [VERIFYING.md](VERIFYING.md).

**Basic Cable** is a native Apple TV + iPhone/iPad app for [Tunarr](https://tunarr.com) with a retro cable-guide interface. Browse your virtual channels in a classic EPG grid, see what's on now and next, and watch — all directly from your Tunarr server, with no Plex client or HDHomeRun emulation in the middle.

![TunarrTV guide](docs/screenshot.png)

## Features

- Turns on like a TV: launches straight into fullscreen playing your last-watched channel; press select or Menu for the guide
- Classic channel-guide grid: per-show cell shading (adjacent programs alternate three muted tones; episodes of a show match), per-channel accent stripes, channel logos, red now-line, green "on air" highlight with elapsed-time fill, monospaced retro styling
- Live video preview + program details (episode info, year, synopsis, progress bar with minutes remaining) that follow your focus through the guide
- Full-screen viewing with channel up/down zapping and a retro channel banner
- Guide paging in 30-minute steps, ~12 hours of schedule ahead
- Built-in **weather channel** (channel 999) with a retro "Local on the 8s" style display
- No account, no tracking, no dependencies — one small SwiftUI app talking to your own server

## Requirements

- **A running Tunarr server** (tested against Tunarr 1.3.x) reachable from your Apple TV over the network. Channels should use Tunarr's default **HLS** stream mode.
- **Apple TV** running tvOS 17 or later (or the tvOS Simulator), and/or an **iPhone/iPad** on iOS 17+ (target `TunarrTViOS` — same retro guide in a touch layout: tap a channel to tune, tap the tuned channel or the video preview for fullscreen, on-screen chevrons to zap).
- To build: a Mac with **Xcode 15+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

There is no App Store listing — you build and install it yourself with Xcode (see below).

## Connecting to Tunarr

There is no auto-discovery: on first launch the app asks for your Tunarr server's base URL — the same address you use for the Tunarr web UI, e.g. `http://192.168.1.100:8000`. Use the **TEST** button to verify the connection (it probes `/api/version`), then **SAVE**. The URL is stored on-device in `UserDefaults` and can be changed anytime via the SETTINGS button.

Everything the app does is three plain HTTP calls against that base URL:

| Purpose | Endpoint |
|---------|----------|
| Channel lineup | `GET /api/channels` |
| Guide/schedule data | `GET /api/guide/channels?dateFrom=...&dateTo=...` |
| Video streams | `GET /stream/channels/{channelId}.m3u8` — standard HLS, played natively by AVPlayer |

Notes:

- **Plain HTTP is fine.** The app enables an App Transport Security exception (`NSAllowsArbitraryLoads`) because most Tunarr servers run HTTP on a LAN. HTTPS URLs work too.
- **No authentication.** Tunarr currently has no auth, so the app sends none. Don't expose your Tunarr server to the internet; if you want out-of-home access, use a VPN (WireGuard/Tailscale).
- **Channel-change latency.** Tuning a channel takes roughly 10–15 seconds while Tunarr spins up the ffmpeg session server-side (a "TUNING" indicator shows during this). This is the same latency any Tunarr client has, including Plex.
- The app is read-only against Tunarr — it never modifies your server's channels or settings.

## The weather channel

![Weather channel](docs/weather.png)

The app adds a synthetic channel **999 WEATHER** to the guide (Tunarr doesn't know about it — it's rendered entirely client-side). Tuning it shows a retro weather display that cycles through current conditions and a 7-day forecast, refreshed every 15 minutes.

**Data sources:**

- **Forecast**: [Open-Meteo](https://open-meteo.com) — free, no API key required. It only needs coordinates, which come from one of:
  - your **Home Assistant** server's configured location (automatic when HA is set up below), or
  - a location entered in Settings — zip code, city name, or `lat, lon` (geocoded on-device via CLGeocoder), or
  - the Apple TV's own location via the "USE THIS APPLE TV'S LOCATION" button (one-time permission prompt; WiFi-based, city-level accuracy).
- **Home Assistant (optional)**: enter your HA URL and a [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile) in Settings, plus a comma-separated list of sensor entity IDs (e.g. `sensor.outdoor_temp, sensor.pool_temp`). Those readings appear on an extra "AROUND THE HOUSE" page of the weather channel. The token is stored on-device and only ever sent to the URL you configure.

Without any of this configured, the weather channel shows a "set location in settings" notice — the rest of the app is unaffected.

## Remote controls

**In the guide:**

- Swipe / arrows — move through guide cells; the info panel follows your focus
- Select on a cell — tune that channel
- `<` / `>` cells at row edges — page the guide window ±30 minutes
- CH UP / CH DN / FULL SCRN / SETTINGS buttons above the guide

**In fullscreen:**

- Swipe up/down — channel up/down (shows the channel banner)
- Play/Pause — pause and resume
- Select or Menu — back to the guide

## Building and installing

```bash
git clone <this repo> && cd tunarr-tv
xcodegen generate        # creates TunarrTV.xcodeproj (regenerate after adding source files)
```

**Run in the simulator:**

```bash
xcodebuild -project TunarrTV.xcodeproj -scheme TunarrTV \
  -sdk appletvsimulator -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot "Apple TV 4K (3rd generation) (at 1080p)"
xcrun simctl install booted <DerivedData path>/TunarrTV.app
xcrun simctl launch booted com.dbdm.tunarrtv
```

**Install on a real Apple TV:**

1. Open `TunarrTV.xcodeproj` in Xcode.
2. Target **TunarrTV** → Signing & Capabilities → select your Team (edit the bundle identifier in `project.yml` if you fork).
3. Pair the Apple TV: on the TV, Settings → Remotes and Devices → Remote App and Devices; in Xcode, Window → Devices and Simulators (both devices on the same network).
4. Choose the Apple TV as the run destination and press Run.

With a paid Apple Developer account the install is valid for about a year; with a free account it expires after 7 days and needs reinstalling.

## Project layout

- `project.yml` — XcodeGen spec (tvOS 17+, ATS exception for HTTP)
- `TunarrTV/Sources/`
  - `TunarrClient.swift` — the three Tunarr REST calls
  - `Models.swift` — channel/guide models, defensive JSON decoding
  - `AppState.swift` — tuning, guide-window paging, refresh timers, AVPlayer ownership
  - `GuideView.swift` — the EPG grid (focus-driven, 2-hour window, 30-minute paging)
  - `InfoPanelView.swift` — program details + control cluster
  - `PlayerViews.swift` — AVPlayerLayer wrapper + fullscreen player
  - `ContentView.swift`, `Theme.swift`, `SettingsView.swift`

## License

MIT — see [LICENSE](LICENSE).
