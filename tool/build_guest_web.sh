#!/bin/sh
# Builds the guest menu web page (lib/guest_web_main.dart) into the POS gateway's public/t/, where GET /t/<code> serves it.
# The build is not committed (server/.gitignore). Run from anywhere: tool/build_guest_web.sh
# Extra arguments go to `flutter build web`, e.g. where the customer server is (specs/guest-experience-builder part 2, contract A):
#   tool/build_guest_web.sh --dart-define=CUSTOMER_API_BASE_URL=http://localhost:8099
# Without one the page finds it itself: http://localhost:8099 when it is opened on this machine, else its own host with /api.
# --dart-define=CUSTOMER_API_BASE_URL= (empty) keeps orders on the POS guest door, as before.
set -e
cd "$(dirname "$0")/.."
flutter build web -t lib/guest_web_main.dart --base-href /t/ --no-web-resources-cdn --pwa-strategy=none -o server/public/t "$@"
echo "built: server/public/t (open <gateway>/t/<table code> or <gateway>/<store link>)"
