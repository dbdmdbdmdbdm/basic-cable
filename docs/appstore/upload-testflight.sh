#!/bin/bash
# Upload both Basic Cable platforms to TestFlight.
# Prereq: the "Basic Cable" app record must exist in App Store Connect
# (bundle id com.dbdm.tunarrtv). IPAs are produced by:
#   xcodebuild archive + -exportArchive (see docs/appstore/metadata.md);
#   ready-made ones live in build/Export-tvOS and build/Export-iOS.
set -euo pipefail
cd "$(dirname "$0")/../.."

ISSUER=deebc4e9-60b8-48ca-b5cb-b55b43df0463

xcrun altool --upload-app --type appletvos \
  --file build/Export-tvOS/TunarrTV.ipa \
  --apiKey T9QCU42YW7 --apiIssuer "$ISSUER"

xcrun altool --upload-app --type ios \
  --file build/Export-iOS/TunarrTViOS.ipa \
  --apiKey T9QCU42YW7 --apiIssuer "$ISSUER"
