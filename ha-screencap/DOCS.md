# Basic Cable Screencap

Renders one or more Home Assistant dashboards in headless Chromium and
serves rolling PNG snapshots. Built for the Basic Cable app's **Home
Dashboard channels** — tvOS has no web engine, so this add-on runs the
browser and the app just shows the pixels.

## Setup

1. Create a **long-lived access token**: your HA profile → Security →
   Long-lived access tokens. Paste it into the `token` option.
2. List the dashboards to capture under `dash_paths` — the path part of
   the dashboard URL, e.g. `/lovelace/0` or `/dashboard-family/tv`.
3. Start the add-on, then check `http://<ha-host>:8090/latest.png`.

Each path is served in order: the first at `/latest.png` (also
`/latest/0.png`), the second at `/latest/1.png`, and so on.
`/healthz` reports the age of every capture.

In the Basic Cable app's settings, put those URLs in the Home Dashboard
channel field, comma-separated, optionally named:

```
http://<ha-host>:8090/latest.png, Kitchen=http://<ha-host>:8090/latest/1.png
```

> **Upgrading from 1.2.x**: the entity lists (dashboard paths/names,
> cameras, weather sensors, media players) changed from YAML lists to
> comma-separated text. If the add-on reports "invalid options" after
> updating, open Configuration and re-save those fields as
> comma-separated values.

## Options

| Option | Meaning |
|---|---|
| `token` | Long-lived access token used to log the browser into HA |
| `dash_paths` | List of dashboard paths to capture |
| `interval_seconds` | Idle time between capture rounds (per-dashboard refresh is this plus a few seconds of navigation per extra dashboard) |
| `width` / `height` | Capture resolution |
| `dark_mode` | Render with the dark color scheme |
| `reload_minutes` | Full page reload cadence (single-dashboard mode only) |
| `ha_url` | How the browser reaches HA — the default `http://homeassistant:8123` works on HA OS |

## Configuring the app from the add-on

Set `app_config_enabled: true` and the add-on serves `/appconfig` — the
Basic Cable app picks it up automatically (via the snapshot URL you
already configured) and these lists **override** whatever is typed in
the app's settings, so everything is managed here in HA.

**Prefer the Web UI for the entity lists**: the add-on's **Open Web UI**
button (or `http://<ha-host>:8090/config`) is a real entity picker —
searchable dropdowns for cameras (with grid-order reordering), weather
sensors, the weather forecast entity, and media players. It exists
because HA's add-on options page can only render these as text; saving
from it updates the options below and restarts the add-on. Dashboards,
capture settings, and ticker chips stay on the classic options page.

The same options in YAML form:

```yaml
app_config_enabled: true
dash_names:                    # names for dash_paths, in order — the app
  - Home                       # turns each captured dashboard into its own
  - Kitchen                    # channel automatically (996, then down)
cameras:                       # security channel — list order = grid order
  - camera.front_door
  - camera.backyard
weather_sensors:               # weather channel "around the house" page
  - sensor.outdoor_temp
weather_entity: weather.home   # forecast source replacing Open-Meteo (optional)
media_players:                 # ticker now-playing sources
  - media_player.living_room
ticker_scroll: false           # true = classic news crawl
ticker_entities:               # extra ticker items, optionally conditional
  - entity: cover.garage_door
    name: GARAGE               # defaults to the entity's friendly name
    show_when: open            # only show while the state matches (omit = always)
    color: red                 # red orange yellow green mint teal cyan blue purple pink white gray
    icon: exclamationmark.triangle.fill   # any SF Symbol name
    display: name_state        # name_state (default) | name | state
```

## Notes

- With several dashboards, one browser page cycles through them, so each
  refreshes roughly every `interval + 5s × dashboards`. Snappy enough
  for status dashboards; not meant for video.
- The header and sidebar are hidden automatically so the capture is just
  the dashboard. If an HA frontend update changes its internals, you may
  temporarily get them back in frame — update the add-on.
- Memory: Chromium typically uses 300–500 MB.
