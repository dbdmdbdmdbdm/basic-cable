# Verifying that the App Store app matches this source

Short version: **byte-for-byte verification of an iOS/tvOS App Store binary is
not possible — for any app.** Apple re-signs and FairPlay-encrypts every binary
it delivers, so nobody (including the developer) can produce or extract an IPA
that matches a published checksum. There is no F-Droid-style reproducible-build
path on the App Store.

What Basic Cable does instead is make the link between each store build and
this repository as auditable as the platform allows:

## 1. Every binary tells you its commit

Open **Settings → About** in the app. The version line looks like:

```
BASIC CABLE V1.0 (2) · A1B2C3D
```

`A1B2C3D` is the git commit the binary was built from, stamped into the app's
Info.plist at build time (see the `Stamp git commit` build phase in
[project.yml](project.yml)). Each App Store release corresponds to a tag here
(e.g. `v1.0-build2`) pointing at that exact commit.

## 2. Public CI builds the store binaries

Release builds are produced by the public
[Release workflow](.github/workflows/release.yml) on GitHub-hosted runners.
The workflow logs — hosted by GitHub, not by the developer — show which commit
was checked out, the build number that was stamped, and the upload to App
Store Connect. To audit a release, open the workflow run for its tag under the
repo's **Actions** tab.

(Build 1.0 (2) and earlier were built locally during initial submission; runs
from `v1.0-build3` onward are CI-built.)

## 3. Build it yourself

The strongest check is the one you run:

```bash
git clone https://github.com/dbdmdbdmdbdm/basic-cable && cd basic-cable
git checkout <tag>          # the tag matching the About-screen commit
brew install xcodegen
xcodegen generate
open TunarrTV.xcodeproj     # build & run on your own device with free signing
```

The app has no server component, no analytics SDK, and no third-party
dependencies — the ~2,700 lines of Swift in `TunarrTV/Sources` are the whole
app, small enough to read in an afternoon. Network calls exist in exactly two
files: `TunarrClient.swift` (your Tunarr server) and `WeatherService.swift`
(Open-Meteo, plus optional Home Assistant).

## What this does and doesn't prove

- ✅ The commit in About + the public CI log tie a store build number to exact
  public source, with GitHub as the witness.
- ✅ Anyone can build the same source and compare behavior, entitlements, and
  network traffic.
- ❌ No one can prove the delivered bytes are identical — that limitation is
  Apple's, and applies to every app on the App Store.
