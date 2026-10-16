// Exports every built section H screen as a phone frame PNG (405 pt wide, 2x, real Inter and Lucide fonts), named like the founder's
// Figma exports in assets/figma_ref_h, for side-by-side review. Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/inventory_frames_test.dart   -> test/frames_h/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/inventory/adjustment_screen.dart';
import 'package:vinii_pos/inventory/audit_screen.dart';
import 'package:vinii_pos/inventory/forecast_screen.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/inventory/inventory_dashboard.dart';
import 'package:vinii_pos/inventory/movement_screen.dart';
import 'package:vinii_pos/inventory/receiving_screen.dart';
import 'package:vinii_pos/inventory/stock_detail_screen.dart';
import 'package:vinii_pos/inventory/stock_list_screen.dart';
import 'package:vinii_pos/inventory/transfer_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  final fx = jsonDecode(File('test/fixtures/inventory_server.json').readAsStringSync()) as Map<String, dynamic>;
  http.Response ok(Object b) => http.Response(jsonEncode(b), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  Map<String, dynamic> row(Map<String, dynamic> d) => {...d, 'totals': {'lines': 1, 'expected': 24, 'received': 24, 'rejected': 2}};

  InvEnv env(String docKey) => InvEnv(
        api: InventoryApi(
          baseUrl: 'http://frames.local',
          accessToken: () => 'frames',
          client: MockClient((r) async {
            final p = r.url.path.replaceFirst('/api/partner/inventory', '');
            if (p == '/options') return ok(fx['options']);
            if (p == '/dashboard') return ok(fx['dashboard']);
            if (p == '/stock') return ok(fx['stock_list']);
            if (p.startsWith('/stock/')) return ok(fx['stock_detail']);
            if (p == '/movements') return ok(fx['movements']);
            if (p.startsWith('/movements/')) return ok(fx['movement']);
            if (p == '/forecast') return ok(fx['forecast']);
            if (p == '/documents') return ok({'documents': [row(fx[docKey] as Map<String, dynamic>)]});
            if (p.startsWith('/documents/')) return ok(fx[docKey]);
            return http.Response('{}', 404);
          }),
        ),
      );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 1800}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: screen));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('frames_h/$file.png'));
  }

  testWidgets('Inventory Dashboard', (t) => frame(t, 'Inventory Dashboard', InventoryDashboard(env: env('receipt_draft')), height: 1180), skip: !on);
  testWidgets('Stock', (t) => frame(t, 'Stock', StockListScreen(env: env('receipt_draft')), height: 900), skip: !on);
  testWidgets('Stock Detail', (t) => frame(t, 'Stock Detail', StockDetailScreen(env: env('receipt_draft'), itemId: 'x'), height: 1180), skip: !on);
  testWidgets('Movement Detail', (t) => frame(t, 'Movement Detail', MovementScreen(env: env('receipt_draft'), movementId: 1), height: 1130), skip: !on);
  testWidgets('Receiving', (t) => frame(t, 'Receiving', ReceivingScreen(env: env('receipt_draft')), height: 1450), skip: !on);
  testWidgets('Adjustment', (t) => frame(t, 'Adjustment', AdjustmentScreen(env: env('adjustment_draft')), height: 1430), skip: !on);
  testWidgets('Transfer', (t) => frame(t, 'Transfer', TransferScreen(env: env('transfer_draft')), height: 1400), skip: !on);
  testWidgets('Stock Audit', (t) => frame(t, 'Stock Audit', AuditScreen(env: env('audit_counted')), height: 1300), skip: !on);
  testWidgets('Inventory Forecast', (t) => frame(t, 'Inventory Forecast', ForecastScreen(env: env('receipt_draft'), itemId: 'x'), height: 1320), skip: !on);
}
