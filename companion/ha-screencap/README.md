# ha-screencap

Companion service for Basic Cable's **Home Dashboard channel** (channel 998).

Apple TV has no web engine — there is no WebView on tvOS — so the app can't
render a Home Assistant dashboard itself. This tiny container runs headless
Chromium on your network instead: it signs into Home Assistant with a
long-lived access token, loads the dashboard you point it at, hides HA's
header and sidebar, and serves a fresh 1920×1080 PNG screenshot every few
seconds. The app just displays the latest snapshot.

## Run it

```bash
cp docker-compose.example.yml docker-compose.yml
echo "HA_TOKEN=<your long-lived access token>" > .env
# edit docker-compose.yml: set HA_URL and DASH_PATH
docker compose up -d --build
```

Check it's working: `http://<host>:8090/latest.png` should show your
dashboard, and `http://<host>:8090/healthz` reports snapshot age.

Then in Basic Cable's settings, set **SNAPSHOT URL** to
`http://<host>:8090/latest.png` — channel 998 appears in the guide.

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `HA_URL` | — | Home Assistant base URL |
| `HA_TOKEN` | — | Long-lived access token |
| `DASH_PATH` | `/lovelace/0` | Dashboard path from your browser's URL bar |
| `INTERVAL_SECONDS` | `10` | Seconds between screenshots (min 3) |
| `WIDTH`×`HEIGHT` | `1920`×`1080` | Render size |
| `DARK_MODE` | `true` | Render with dark color scheme |
| `RELOAD_MINUTES` | `60` | Full page reload cadence (leak hygiene) |

## Tips

- **Camera cards:** use `camera_view: auto` (stills) on the dashboard you
  capture, not `live` — at a 10-second snapshot cadence a live stream looks
  identical but burns CPU decoding video around the clock.
- The header/sidebar hiding reaches into HA's shadow DOM; if a Home
  Assistant update changes the frontend structure it degrades gracefully
  (you'll just see the header again until this script is updated).
- Sizing: ~400 MB image, idles at a few percent CPU for one dashboard at
  a 10s interval.
