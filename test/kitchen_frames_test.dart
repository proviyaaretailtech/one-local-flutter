// Exports the kitchen screens as phone frame PNGs (405 pt wide, 2x, real Inter and Lucide fonts), named like the founder's Figma exports in
// assets/figma_ref_h, for side-by-side review. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/kitchen_frames_test.dart   -> test/frames_h/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/inventory_api.dart' show Facts;
import 'package:vinii_pos/kitchen/add_station_screen.dart';
import 'package:vinii_pos/kitchen/kds_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_api.dart';
import 'package:vinii_pos/kitchen/kitchen_setup_screen.dart';
import 'package:vinii_pos/kitchen/kitchen_widgets.dart';
import 'package:vinii_pos/kitchen/station_detail_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  final fx = jsonDecode(File('test/fixtures/kitchen_server.json').readAsStringSync()) as Map<String, dynamic>;
  Map<String, dynamic> copy(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;
  http.Response ok(Object b) => http.Response(jsonEncode(b), 200, headers: {'content-type': 'application/json; charset=utf-8'});

  // The frames show Main Kitchen, Tandoor, Beverages, Desserts, one printer group "Hot kitchen" and no areas.
  final cfg = copy(fx['config'] as Map<String, dynamic>)
    ..['can'] = {'configure': true}
    ..['stations'] = [
      for (final (k, n) in [('main', 'Main Kitchen'), ('tandoor', 'Tandoor'), ('beverages', 'Beverages'), ('dessert', 'Desserts')]) {...copy((fx['config'] as Map)['stations'][0]), 'key': k, 'name': n, 'id': 'id-$k'},
    ];
  final queue = copy(fx['queue'] as Map<String, dynamic>)
    ..['stations'] = [for (final s in cfg['stations'] as List) {'key': s['key'], 'name': s['name']}];

  KitchenEnv env() => KitchenEnv(
        initials: 'NB',
        refreshEvery: null,
        api: KitchenApi(
          baseUrl: 'http://frames.local',
          accessToken: () => 'frames',
          client: MockClient((r) async {
            final p = r.url.path.split('/').last;
            if (p == 'kitchen_config') return ok(cfg);
            if (p == 'kitchen_station_view') return ok({...(cfg['stations'] as List)[0] as Map, 'can': {'configure': true}});
            if (p == 'kds_queue') return ok(queue);
            return http.Response('{}', 404);
          }),
        ),
      );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 900}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('frames_h/$file.png'));
  }

  testWidgets('Mobile POS · Kitchen Configuration', (t) => frame(t, 'Mobile POS · Kitchen Configuration', KitchenSetupScreen(env: env()), height: 880), skip: !on);
  testWidgets('Mobile POS · Add Kitchen Station', (t) => frame(t, 'Mobile POS · Add Kitchen Station', AddStationScreen(env: env(), config: Facts(cfg)), height: 880), skip: !on);
  testWidgets('Mobile POS · Main Kitchen station detail', (t) => frame(t, 'Mobile POS · Main Kitchen station detail', StationDetailScreen(env: env(), stationId: 'x'), height: 880), skip: !on);
  testWidgets('Mobile POS · Kitchen Display System', (t) => frame(t, 'Mobile POS · Kitchen Display System', KdsScreen(env: env()), height: 1900), skip: !on);
}
