# Privacy Policy — Basic Cable

**Basic Cable does not collect, store, or share any personal data.** There are no accounts, no analytics, no advertising, and no tracking of any kind.

What the app does with data, in full:

- **Playback** — the app talks directly to the Tunarr server URL you configure, over your own network. Nothing about your viewing is sent anywhere else.
- **Weather** — the app requests forecasts from the free [Open-Meteo](https://open-meteo.com) public API using the approximate coordinates you configure (or your device's location, only if you grant permission). Coordinates are sent solely to return a forecast and are not stored by the app. Open-Meteo's privacy policy: https://open-meteo.com/en/terms
- **Home Assistant (optional)** — if you configure a Home Assistant URL and token to show house sensor readings on the weather channel, the token is stored on your device and used only to read the sensor entities you list.
- **Settings** — server URL, location, and preferences are stored on-device (and in your personal iCloud/device backups as with any app). They are never transmitted to the developer.

The demo mode uses bundled sample video and the same Open-Meteo weather request described above.

Questions: open an issue at https://github.com/dbdmdbdmdbdm/basic-cable/issues
