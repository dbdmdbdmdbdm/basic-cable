# Scoping: A Google TV app for Basic Cable

> Status: planning document. This scopes a **native Google TV / Android TV**
> build of Basic Cable at **full feature parity** with the existing Apple TV +
> iPhone/iPad app. Nothing here is committed yet — it's the map before the trip.

## TL;DR

- **"Google TV" = Android TV OS.** A native app is an **Android app in Kotlin**
  built with **Jetpack Compose for TV** and **AndroidX Media3 (ExoPlayer)**.
- This is a **ground-up rewrite, not a port** — no Swift/SwiftUI/AVFoundation
  code carries over. But the current codebase is cleanly factored, so it serves
  as a precise behavioral **spec**: the hard product decisions (guide windowing,
  the surf guard, session cleanup, synthetic-channel numbering, the retro look)
  are all already made.
- The existing iOS app already **casts *to* Google TV**, so "watch on the TV"
  is partly solved today. This project is about a first-class **on-device D-pad
  experience**, plus (per the parity goal) an Android phone/tablet build that can
  itself **cast out** to a Chromecast — mirroring the universal iOS target.
- Rough effort for one experienced Compose-for-TV developer: **usable MVP in
  ~1–2 weeks, full parity in ~4–8 weeks.** The dominant risk is the EPG grid's
  D-pad focus behavior.

## Why it's a rewrite

Basic Cable today is ~7,100 lines of Swift/SwiftUI across two Xcode targets
(`TunarrTV` for tvOS 17+, `TunarrTViOS` universal for iOS 17+), generated with
XcodeGen. Every UI, media, and networking primitive it uses is Apple-only:
SwiftUI, AVPlayer/AVPlayerLayer, `URLSession`, `Network.framework` (Bonjour +
TLS sockets for casting), `CLGeocoder`/CoreLocation. None of this runs on
Android, and there is no transpile path.

What *does* transfer is the design. The logic is concentrated and readable:

- `TunarrClient.swift` — the entire Tunarr integration is 3–4 REST calls.
- `Models.swift` — channel/guide models with defensive JSON decoding.
- `AppState.swift` (1,697 lines) — tuning, guide-window paging, refresh timers,
  the surf guard, session snapshots, synthetic-channel assembly. This file *is*
  the spec for the Android ViewModel layer.

## Target platform & stack

| Concern | Choice | Rationale |
|---|---|---|
| Language | **Kotlin** | Native Android standard |
| UI | **Jetpack Compose for TV** (`androidx.tv:tv-material`, `tv-foundation`) | Modern equivalent to SwiftUI; official Google TV path. (Leanback is the older XML alternative — avoid.) |
| Video | **AndroidX Media3 / ExoPlayer** | First-class HLS, hardware decode, trivial fullscreen |
| Networking | **Ktor** or **OkHttp** + **kotlinx-serialization** | Mirrors `TunarrClient` |
| Images | **Coil** | HA dashboard PNGs, Immich photos, channel logos |
| Persistence | **DataStore** (Preferences) | Replaces iOS `UserDefaults`/`NSUbiquitousKeyValueStore` |
| Async | **Coroutines + Flow** | Replaces Swift `async/await` + `@Published` |
| Location | Fused Location + `Geocoder` | Replaces CoreLocation/`CLGeocoder` |
| Casting (phone build) | **Google Cast SDK** (`CastContext`, `MediaRouteButton`) — see note | Replaces the hand-rolled CASTV2 socket |
| Build | **Gradle** (Android Studio) | Replaces XcodeGen/Xcode |

Minimum SDK: target **Android TV API 30+** (Android 11) to cover the Google TV
install base comfortably; the phone build can go a bit lower.

## Feature-by-feature port map

Synthetic channel numbering to preserve (from `AppState`): **999 weather**,
**998 home / HA dashboard** (extras count **down from 996**), **997 photos**,
**951 security cameras**.

| Feature (current) | Android approach | Effort | Risk / notes |
|---|---|---|---|
| Tunarr REST client (`/api/channels`, `/api/guide/channels`, `/stream/.../{id}.m3u8`, `/api/version`, `/api/sessions`) | Ktor/OkHttp + serialization | **Trivial** | Small, well-defined surface |
| Channel/guide models, defensive decoding | Kotlin data classes | **Trivial** | |
| `AppState` orchestration (tuning, paging, timers, surf guard, session cleanup) | ViewModel(s) + Flow + coroutines | **Moderate** | Behavior is fully specified; re-express, don't re-invent |
| HLS playback (AVPlayer) | Media3 ExoPlayer | **Easy** | Often *easier* than iOS |
| Fullscreen + channel up/down zapping + retro banner | Compose + Media3 UI, D-pad up/down | **Moderate** | "Turns on like a TV" auto-launch into last channel |
| **EPG guide grid** (`GuideView` — cell shading, per-channel accent stripes, now-line, on-air fill, 30-min paging, focus-follows-info) | Compose for TV `TvLazyColumn`/`TvLazyRow` + focus | **High — the centerpiece** | D-pad focus engine differs materially from tvOS; getting "focus drives the info panel + live preview" smooth is the main time sink |
| Live preview + program details panel | Compose + a second Media3 player | **Moderate** | Preview player lifecycle on focus change |
| Settings (`SettingsView`, 786 lines: Tunarr, HA, Immich, weather, cameras, TEST buttons) | Compose forms + DataStore | **Moderate** | Lots of fields + live validation probes |
| Weather channel 999 (Open-Meteo, HA sensors, "Local on the 8s" render) | Same HTTP; custom Compose `Canvas` drawing | **Moderate** | Pure data + bespoke rendering |
| HA dashboard channels 998/996… (screencap PNGs) | Coil polling `latest.png` | **Easy** | **Server-side `ha-screencap` companion is unchanged** — reuse as-is |
| Photos channel 997 (Immich favorites, crossfade, Ken Burns, portrait pairs) | Coil + Compose animation | **Moderate** | Ken Burns/crossfade choreography |
| Security cameras 951 (every HA camera, HLS via HA websocket, CCTV wall) | Multiple Media3 players + OkHttp WebSocket (`camera/stream`) | **Moderate–High** | Many concurrent decoders strain TV SoCs — cap tiles / stagger joins |
| Retro theme, bundled OFL fonts, TV static | Compose theme; fonts drop in; static via shader/`Canvas`/`RenderEffect` | **Easy–Moderate** | Same font files (OFL) reusable |
| Demo / no-Tunarr mode (self-generated test clips) | Bundle equivalent clips as raw resources | **Easy** | |
| **Cast *out* to Chromecast** (phone build) | Google Cast SDK **or** port CASTV2 (see below) | **Moderate** | Only relevant to the phone/tablet build, not the TV app |

## Casting (parity goal: keep it)

On the **TV app itself**, casting-out is irrelevant — the device *is* the
playback endpoint. Casting matters for the **Android phone/tablet build**, which
mirrors the universal iOS app.

Two options:

1. **Google Cast SDK (recommended for the phone build).** Add
   `com.google.android.gms:play-services-cast-framework`, drop in a
   `MediaRouteButton`, register the default media receiver, and hand ExoPlayer's
   HLS URL to the Cast session. Far less code than iOS needed, officially
   supported, and it's the idiomatic Android path. Cost: a Google Play Services
   dependency (fine for a phone app; the current app's "no third-party deps"
   ethos was a tvOS-era constraint).
2. **Port the dependency-free CASTV2 implementation.** The iOS
   `CastProtocol.swift` / `CastController.swift` hand-encode the CASTV2 protobuf
   over a TLS socket and discover devices via Bonjour. This ports to Kotlin with
   `NsdManager` (discovery) + a TLS `Socket` + the same length-prefixed protobuf
   frames. Keeps zero third-party deps, at the cost of re-implementing and
   maintaining wire-format code. Choose this only if avoiding Play Services is a
   hard requirement.

**Recommendation:** Cast SDK for the phone build; skip casting entirely on the
TV build.

## What's *easier* than on Apple

- **Distribution.** No 7-day free-cert expiry, no annual re-sign. Sign a release
  APK once and **sideload it indefinitely** (adb, or a "Downloader"-style app on
  the device). No Play Store account required — and there's no store listing
  today anyway. A Play Store listing is optional and additive.
- **HLS + LAN cleartext.** Media3 plays HLS natively; the tvOS
  `NSAllowsLocalNetworking` ATS exception becomes a `network_security_config.xml`
  entry permitting cleartext to private/LAN addresses.
- **CI.** `./gradlew assembleRelease` on GitHub Actions is straightforward;
  attach the APK as a release artifact.

## Effort estimate (one experienced Android/Compose-for-TV dev)

| Milestone | Estimate |
|---|---|
| Project scaffold, Tunarr client, models, DataStore settings shell | ~2–3 days |
| Media3 playback + fullscreen + zapping + banner + auto-launch | ~2–4 days |
| **EPG guide grid with D-pad focus + info panel + live preview** | ~1–2 weeks |
| Settings screens + TEST/validation probes | ~3–5 days |
| Weather channel 999 | ~2–3 days |
| HA dashboard channels (Coil polling) | ~1–2 days |
| Photos / Immich channel | ~3–4 days |
| Cameras wall (multi-player + HA websocket) | ~4–6 days |
| Retro polish (fonts, static, cell shading, theming) | ~3–5 days |
| Phone build + Cast SDK | ~3–5 days |
| **Usable MVP** (Tunarr guide + playback + settings + weather) | **~1–2 weeks** |
| **Full parity** | **~4–8 weeks** |

The single biggest risk and time-sink is the **guide grid focus behavior** in
Compose for TV — matching "focus drives the info panel and the live video
preview" against a D-pad remote. Everything else is well-trodden Android work.

## Recommended phasing

1. **MVP:** scaffold → Tunarr client → guide grid → playback/fullscreen →
   settings. A watchable channel-surfing experience.
2. **Built-in channels:** weather (999), then HA dashboards (998/996…).
3. **Media channels:** photos (997), cameras (951).
4. **Polish:** retro theming, fonts, static, auto-launch-into-last-channel.
5. **Phone build + casting.**

## Alternatives considered

- **Compose for TV (native Kotlin) — chosen.** Best remote UX and performance;
  the platform-blessed path for Google TV.
- **Flutter / React Native for TV.** Cross-platform, but TV D-pad focus handling
  is notoriously fiddly, and since we're porting *from Swift* there's no code to
  share anyway — little upside, real ecosystem risk.
- **Kotlin Multiplatform.** Valuable when sharing logic between two Kotlin apps;
  irrelevant here because the source is Swift, so there's no shared module to
  reuse.

## Open questions before implementation

- **Minimum Android TV API level** — 30 (Android 11) is a safe default; confirm
  against the oldest Google TV hardware to support.
- **Play Services acceptable?** Drives the Cast SDK vs. hand-rolled-CASTV2
  decision for the phone build.
- **Cameras concurrency cap** — how many simultaneous HLS tiles to allow before
  degrading gracefully on lower-end TV SoCs.
- **Repo layout** — separate Gradle project in this repo (e.g. `android/`)
  vs. a sibling repository.
