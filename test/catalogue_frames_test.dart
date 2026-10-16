// Exports the built section G screens as phone frame PNGs (405 pt wide, 2x, real Inter and Lucide fonts) for side-by-side review
// with assets/figma_ref_g. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/catalogue_frames_test.dart   -> test/frames_g/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/catalogue_screen.dart';
import 'package:vinii_pos/catalogue/grn_screens.dart';
import 'package:vinii_pos/catalogue/item_form_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'catalogue_fixtures.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

CatalogueApi _api() => CatalogueApi(
      baseUrl: 'http://frames.local',
      accessToken: () => 'frames',
      client: MockClient((r) async {
        final p = r.url.path;
        final Object body = p.endsWith('/matching') ? matchingView() : p.contains('/grn/') ? grnView() : p.endsWith('/catalogue/i1') ? sixItems.first : catalogueList(sixItems);
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  setUpAll(() async {
    if (!on) return;
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 1355, Future<void> Function()? then}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(const SizedBox()); // a fresh Navigator for every frame (no sheet left open by the previous one)
    await t.pumpWidget(RepaintBoundary(key: const ValueKey('frame'), child: MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen)));
    await t.pumpAndSettle();
    if (then != null) await then();
    await expectLater(find.byKey(const ValueKey('frame')), matchesGoldenFile('frames_g/$file.png'));
  }

  testWidgets('frames', (t) async {
    await frame(t, 'catalogue_list', CatalogueScreen(api: _api()), height: 1500);
    await frame(t, 'catalogue_grid', CatalogueScreen(api: _api()), height: 1500, then: () async {
      await t.tap(find.text('Grid'));
      await t.pumpAndSettle();
    });
    await frame(t, 'action_sheet', CatalogueScreen(api: _api()), height: 1000, then: () async {
      await t.tap(find.byTooltip('Actions for Coca-Cola 500ml'));
      await t.pumpAndSettle();
    });
    await frame(t, 'about_this_product', CatalogueScreen(api: _api()), height: 1000, then: () async {
      await t.tap(find.text('Coca-Cola 500ml'));
      await t.pumpAndSettle();
    });
    await frame(t, 'detail_drawer', CatalogueScreen(api: _api()), height: 1000, then: () async {
      await t.tap(find.text('Coca-Cola 500ml'));
      await t.pumpAndSettle();
      await t.tap(find.text('View product details'));
      await t.pumpAndSettle();
    });
    await frame(t, 'add_item', CatalogueScreen(api: _api()), height: 900, then: () async {
      await t.tap(find.text('+ Add Items'));
      await t.pumpAndSettle();
    });
    await frame(t, 'quick_add', CatalogueScreen(api: _api()), height: 900, then: () async {
      await t.tap(find.text('+ Add Items'));
      await t.pumpAndSettle();
      await t.tap(find.text('Quick Add'));
      await t.pumpAndSettle();
    });
    await frame(t, 'scan_qr', CatalogueScreen(api: _api()), height: 900, then: () async {
      await t.tap(find.byTooltip('Scan a code'));
      await t.pumpAndSettle();
    });
    await frame(t, 'item_creation', ItemFormScreen(api: _api()), height: 2700);
    await frame(t, 'grn_dashboard', GrnDashboardScreen(receiptId: 'r1', api: _api()), height: 1900);
    await frame(t, 'grn_matching', GrnMatchingScreen(receiptId: 'r1', api: _api()), height: 1100);
  }, skip: !on);
}
