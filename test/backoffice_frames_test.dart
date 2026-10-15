// Exports the two section J screens as phone frame PNGs (390 pt wide, 2x, real Inter and Lucide fonts), named like the founder's Figma
// exports in assets/figma_ref_j, for side-by-side review. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/backoffice_frames_test.dart   -> test/frames_j/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/backoffice/backoffice_api.dart';
import 'package:vinii_pos/backoffice/low_stock_screen.dart';
import 'package:vinii_pos/backoffice/purchase_suggestions_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'backoffice_fixtures.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

final _api = BackofficeApi(
  baseUrl: 'http://frames.local',
  accessToken: () => 'frames',
  client: MockClient((r) async => http.Response(jsonEncode(r.url.path.endsWith('/low-stock') ? lowStockJson() : suggestionsJson()), 200,
      headers: {'content-type': 'application/json; charset=utf-8'})),
);

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  setUpAll(() async {
    if (!on) return;
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {Future<void> Function()? then}) async {
    t.view.physicalSize = const Size(780, 2270);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen));
    await t.pumpAndSettle();
    if (then != null) await then();
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('frames_j/$file.png'));
  }

  testWidgets('Low Stock', (t) => frame(t, 'OneLocal · Low Stock', LowStockScreen(api: _api)), skip: !on);
  testWidgets('Purchase Suggestions', (t) => frame(t, 'OneLocal · Purchase Suggestions', PurchaseSuggestionsScreen(api: _api), then: () async {
        await t.tap(find.bySemanticsLabel('Include Paneer'));
      }), skip: !on);
}
