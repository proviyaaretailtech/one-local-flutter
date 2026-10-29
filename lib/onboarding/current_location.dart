import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../auth/partner_api.dart';

/// Where the phone is, and the address there as the phone's own geocoder reads it (founder, 29 Oct 2026: detect the shop's location
/// instead of typing it all). Any part can be empty; the person checks and corrects it.
typedef FoundAddress = ({double lat, double lng, String line, String area, String city, String state, String pin});

/// Finds the phone's location and its address. Throws [PartnerApiException] with a sentence to show when location is off or refused.
/// Tests replace it.
Future<FoundAddress> Function() locateBusiness = _locate;

Future<FoundAddress> _locate() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const PartnerApiException(0, 'Turn on location on your phone, then try again.');
  }
  const refused = PartnerApiException(0, 'Allow location for OneLocal to find your address, or type it below.');
  final Position pos;
  try {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw refused;
    pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
  } on PermissionDeniedException {
    throw refused; // a browser that blocks location says so here, not through the permission check
  } on LocationServiceDisabledException {
    throw const PartnerApiException(0, 'Turn on location on your phone, then try again.');
  }
  var line = '', area = '', city = '', state = '', pin = '';
  if (!kIsWeb) {
    // the browser has no geocoder: there only the pin is found
    try {
      final m = (await Geocoding().placemarkFromCoordinates(pos.latitude, pos.longitude)).firstOrNull;
      if (m != null) {
        String v(String? s) => (s ?? '').trim();
        line = {v(m.name), [v(m.subThoroughfare), v(m.thoroughfare)].where((s) => s.isNotEmpty).join(' ')}
            .where((s) => s.isNotEmpty && s != v(m.postalCode))
            .join(', ');
        area = v(m.subLocality).isNotEmpty ? v(m.subLocality) : v(m.locality);
        city = v(m.locality).isNotEmpty ? v(m.locality) : v(m.subAdministrativeArea);
        state = v(m.administrativeArea);
        pin = v(m.postalCode).replaceAll(RegExp(r'\D'), '');
      }
    } catch (_) {
      // no address for this spot: the pin is still kept
    }
  }
  return (lat: pos.latitude, lng: pos.longitude, line: line, area: area, city: city, state: state, pin: pin);
}
