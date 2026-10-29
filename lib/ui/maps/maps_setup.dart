import 'package:flutter/foundation.dart';

import 'maps_setup_io.dart' if (dart.library.js_interop) 'maps_setup_web.dart' as platform;

/// The Google Maps key that shows the map in the app (Maps SDK for Android / iOS, Maps JavaScript API on the web), from
/// --dart-define GOOGLE_MAPS_KEY (names only in code; the value lives in the git-ignored .env.local). Android reads it at build time
/// (android/app/build.gradle.kts puts it in the manifest); iOS and the web get it here. Address search and pin -> address never use
/// it: they go through the POS server, which has its own key.
const kGoogleMapsKey = String.fromEnvironment('GOOGLE_MAPS_KEY');

/// Tests (and screens without a key) see the old illustrative map instead of a live one.
@visibleForTesting
bool? mapsEnabledOverride;

/// Whether a live map can be shown at all.
bool get mapsEnabled => mapsEnabledOverride ?? kGoogleMapsKey.isNotEmpty;

/// True when Google refused the key on this page (web only: the key does not allow this address or the Maps JavaScript API).
final ValueNotifier<bool> mapsKeyRefused = ValueNotifier(false);

Future<bool>? _ready;

/// Gets the map ready once: loads Google's script on the web, hands the key to the Maps SDK on iOS. False when it cannot load.
Future<bool> prepareMaps() => _ready ??= mapsEnabled ? platform.prepare(kGoogleMapsKey, () => mapsKeyRefused.value = true) : Future.value(false);
