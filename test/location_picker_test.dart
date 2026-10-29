import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/api/maps_api.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/ui/maps/location_picker.dart';
import 'package:vinii_pos/ui/maps/maps_setup.dart';

/// Google through the server, answered here.
class FakeMaps extends MapsApi {
  FakeMaps() : super(rpc: RpcClient(baseUrl: 'http://x', accessToken: () => null));
  final asked = <String>[];
  Object? failSearch;

  @override
  Future<List<MapsSuggestion>> search(String q, {double? lat, double? lng, String? session}) async {
    asked.add('search $q');
    if (failSearch != null) throw failSearch!;
    return const [MapsSuggestion('ChIJganjgolai01', 'Ganj Golai', 'Latur, Maharashtra, India')];
  }

  @override
  Future<MapsPlace> place(String placeId, {String? session}) async {
    asked.add('place $placeId');
    return const MapsPlace(lat: 18.3996, lng: 76.5842, line: 'Shop 4, Shivaji Road', locality: 'Ganj Golai', city: 'Latur', state: 'Maharashtra', pinCode: '413512');
  }
}

void main() {
  late List<MapsPick> picks;
  late FakeMaps maps;

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LocationPicker(lat: null, lng: null, api: maps, onPicked: picks.add, fallback: const Text('illustrative map')),
      ),
    ));
    await t.pump();
  }

  setUp(() {
    picks = [];
    maps = FakeMaps();
    // a live map needs a platform view: tests see the "could not load" note in its place, the search still works
    mapsKeyRefused.value = true;
  });
  tearDown(() {
    mapsEnabledOverride = null;
    mapsKeyRefused.value = false;
  });

  testWidgets('no map key: the screen keeps its illustrative map', (t) async {
    mapsEnabledOverride = false;
    await pump(t);
    expect(find.text('illustrative map'), findsOneWidget);
    expect(find.byKey(const ValueKey('maps-search')), findsNothing);
  });

  testWidgets('search, choose a result: the pin and the whole address are reported as a search pick', (t) async {
    mapsEnabledOverride = true;
    await pump(t);
    await t.enterText(find.byKey(const ValueKey('maps-search')), 'ga');
    await t.pump(const Duration(milliseconds: 400));
    expect(maps.asked, isEmpty, reason: 'under 3 letters nothing is searched');

    await t.enterText(find.byKey(const ValueKey('maps-search')), 'ganj golai');
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    expect(find.text('Latur, Maharashtra, India'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('maps-result-0')));
    await t.pump();
    await t.pump();
    expect(maps.asked, ['search ganj golai', 'place ChIJganjgolai01']);
    expect(picks, hasLength(1));
    expect((picks.single.lat, picks.single.lng, picks.single.searched), (18.3996, 76.5842, true));
    expect(picks.single.place?.pinCode, '413512');
    expect(find.byKey(const ValueKey('maps-result-0')), findsNothing, reason: 'the list closes after a pick');
  });

  testWidgets('search refused by the server: its sentence shows under the box', (t) async {
    mapsEnabledOverride = true;
    maps.failSearch = const PartnerApiException(503, 'Maps are not set up yet. Please type the address.');
    await pump(t);
    await t.enterText(find.byKey(const ValueKey('maps-search')), 'ganj golai');
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    expect(find.text('Maps are not set up yet. Please type the address.'), findsOneWidget);
    expect(picks, isEmpty);
  });
}
