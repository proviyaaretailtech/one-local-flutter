import 'dart:math';

import 'rpc_client.dart';

/// An address Google found: for a chosen search result, or at a map pin. Any part can be empty; the person checks and corrects it.
class MapsPlace {
  const MapsPlace({required this.lat, required this.lng, this.formatted = '', this.line = '', this.locality = '', this.city = '', this.state = '', this.pinCode = ''});

  factory MapsPlace.fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] as String? ?? '').trim();
    return MapsPlace(
      lat: (j['lat'] as num).toDouble(),
      lng: (j['lng'] as num).toDouble(),
      formatted: s('formatted'),
      line: s('line'),
      locality: s('locality'),
      city: s('city'),
      state: s('state'),
      pinCode: s('pin_code'),
    );
  }

  final double lat, lng;
  final String formatted, line, locality, city, state, pinCode;
}

/// One row of the address search.
class MapsSuggestion {
  const MapsSuggestion(this.placeId, this.title, this.subtitle);
  final String placeId, title, subtitle;
}

/// Address search and pin -> address through the POS server (maps_search, maps_place, maps_reverse). Google's key stays on the
/// server; this only sends what was typed or where the pin is. Nothing is saved: the screen fills its fields.
class MapsApi {
  MapsApi({RpcClient? rpc}) : _rpc = rpc ?? RpcClient();
  final RpcClient _rpc;

  /// A new Places session for one search (typing plus the chosen result count as one).
  static String newSession() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random.secure();
    return List.generate(24, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<List<MapsSuggestion>> search(String q, {double? lat, double? lng, String? session}) async {
    final r = await _rpc.callMap('maps_search', {'q': q, if (lat != null && lng != null) ...{'lat': lat, 'lng': lng}, 'session': ?session});
    return ((r['results'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .map((e) => MapsSuggestion(e['place_id'] as String, e['title'] as String? ?? '', e['subtitle'] as String? ?? ''))
        .toList();
  }

  Future<MapsPlace> place(String placeId, {String? session}) async =>
      MapsPlace.fromJson(await _rpc.callMap('maps_place', {'place_id': placeId, 'session': ?session}));

  Future<MapsPlace> reverse(double lat, double lng) async => MapsPlace.fromJson(await _rpc.callMap('maps_reverse', {'lat': lat, 'lng': lng}));
}
