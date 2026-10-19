#!/bin/sh
# Builds the guest menu web page (lib/guest_web_main.dart) into the POS gateway's public/t/, where GET /t/<code> serves it.
# The build is not committed (server/.gitignore). Run from anywhere: tool/build_guest_web.sh
set -e
cd "$(dirname "$0")/.."
flutter build web -t lib/guest_web_main.dart --base-href /t/ --no-web-resources-cdn --pwa-strategy=none -o server/public/t
echo "built: server/public/t (open <gateway>/t/<table code>)"
