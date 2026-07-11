# App Store metadata — Basic Cable 1.0

## App record
- **Name:** Basic Cable
- **Subtitle** (≤30 chars): `Retro TV guide for Tunarr`
- **Bundle ID:** com.dbdm.tunarrtv (registered: TNRZT432KQ)
- **SKU:** com.dbdm.tunarrtv
- **Primary language:** English (U.S.)
- **Primary category:** Entertainment · **Secondary:** Utilities
- **Price:** Free
- **Age rating:** 4+ (answer "No" to everything)
- **Copyright:** © 2026 Dylan McDermott

## URLs
- **Support URL:** https://github.com/dbdmdbdmdbdm/basic-cable
- **Marketing URL (optional):** https://github.com/dbdmdbdmdbdm/basic-cable
- **Privacy Policy URL:** https://github.com/dbdmdbdmdbdm/basic-cable/blob/main/PRIVACY.md

## App Privacy
**Data Not Collected** (select "No" on the collection question — no data types).

## Promotional text (≤170 chars)
> Flip through your own channels like it's 1989. Now with a built-in demo lineup — no server required to try it.

## Description
```
Basic Cable turns your Tunarr server into a nostalgia machine: a retro
cable-style program guide, instant channel surfing, and a classic
"local forecast" weather channel.

Point it at the Tunarr server you already run on your home network and
flip through your channels the way TV used to work — no wall of
posters, no autoplay, just a grid, a clock, and whatever's on.

FEATURES
• Classic scrolling program guide with time slots, channel numbers,
  and now-playing progress
• One-press channel surfing, just like the old box
• Fullscreen live playback with a retro channel banner
• Built-in weather channel: current conditions, 7-day forecast, and
  optional readings from your Home Assistant sensors
• Remembers your last channel and turns on right where you left off
• Works entirely on your local network — your media never leaves home
• Free and open source (MIT), no accounts, no tracking, no ads

REQUIREMENTS
Basic Cable is a client for Tunarr, a free self-hosted service that
builds live TV channels from your own media library. A Tunarr server
on your network is required for live playback — or tap TRY THE DEMO
to explore the app with a sample lineup, no server needed.

Weather data by Open-Meteo.com (CC BY 4.0).
```

## Keywords (≤100 chars)
`tunarr,live tv,epg,guide,retro,cable,channels,iptv,plex,jellyfin,weather,self-hosted`
(85 chars)

## App Review notes
```
Basic Cable is a client for the reviewer-less case: it plays live TV
from a Tunarr server the user runs on their own home network
(https://tunarr.com), so there is no public server to test against.

To review without a server: on the first-run "CONNECT TO TUNARR"
screen, select TRY THE DEMO. This loads a clearly-labeled sample
channel lineup (yellow DEMO badge) with bundled test-pattern video and
a fully working guide. Channel 999 (Weather) shows live Open-Meteo
weather data. EXIT DEMO in Settings returns to setup.

No account or sign-in exists anywhere in the app. No data is
collected.
```

## Screenshots (docs/appstore/screenshots/)
- **tvOS (1920×1080):** 01-guide, 02-fullscreen, 03-weather-current, 04-weather-forecast
- **iOS 6.9" (1320×2868, iPhone 17 Pro Max sim):** 01-guide, 02-weather, 03-fullscreen
- Regenerate any shot: install a Debug build on a clean simulator and launch with
  `xcrun simctl launch <udid> com.dbdm.tunarrtv --demo [--tune <number>] [--fullscreen]`,
  then `xcrun simctl io <udid> screenshot out.png`.

## Export compliance
`ITSAppUsesNonExemptEncryption = false` is set in both Info.plists — no export
compliance questions at submission.
