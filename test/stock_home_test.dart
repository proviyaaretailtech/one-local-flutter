import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/api/rpc_client.dart';
import 'package:vinii_pos/catalogue/catalogue_api.dart';
import 'package:vinii_pos/catalogue/item_parts.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/side_nav.dart';
import 'package:vinii_pos/inventory/inv_env.dart';
import 'package:vinii_pos/inventory/inventory_api.dart';
import 'package:vinii_pos/inventory/inventory_widgets.dart' show InvChips;
import 'package:vinii_pos/stock/alerts_screen.dart';
import 'package:vinii_pos/stock/stock_env.dart';
import 'package:vinii_pos/stock/stock_home.dart';
import 'package:vinii_pos/stock/product_page.dart';
import 'package:vinii_pos/ui/theme.dart';

/// Answers captured from the real local database (the same fixtures the stock API tests use).
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/inventory_server.json').readAsStringSync()) as Map<String, dynamic>;
http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;

final _catalogue = [
  {'id': 'm1', 'inventory_item_id': 'i1', 'name': 'Coca-Cola 500ml', 'sku': 'CC500', 'status': 'active', 'available': true, 'version': 1, 'stock_known': true, 'stock_qty': 10, 'cost_minor': 3000, 'price_minor': 4000, 'mrp_minor': 4500},
  {'id': 'm2', 'inventory_item_id': 'i2', 'name': 'Tata Salt', 'sku': 'TS1', 'status': 'active', 'available': true, 'version': 1, 'stock_known': true, 'stock_qty': 5, 'cost_minor': null, 'price_minor': 2800},
];

class Fake {
  Fake({this.record = false});
  final bool record; // true: env.open is recorded instead of navigating / switching tabs
  final requests = <http.Request>[];
  final opened = <String>[];
  late final client = MockClient((r) async {
    requests.add(r);
    return switch (fnOf(r)) {
      'inv_options' => ok(fx['options']),
      'inv_dashboard' => ok(fx['dashboard']),
      'inv_stock_list' => ok(fx['stock_list']),
      'inv_stock_detail' => ok(fx['stock_detail']),
      'inv_forecast' => ok(fx['forecast']),
      'inv_movement_list' => ok(fx['movements']),
      'inv_document_list' => ok(fx['documents_receipt']),
      'cat_item_list' => ok({'items': _catalogue, 'total': _catalogue.length, 'page': 1, 'counts': {}, 'categories': []}),
      'sf_products' => ok({'items': []}),
      _ => http.Response('{"detail":"not found"}', 404),
    };
  });
  late final env = StockEnv(
    inv: InvEnv(api: InventoryApi(baseUrl: 'http://inv.test', accessToken: () => 't', client: client)),
    catalogue: CatalogueApi(baseUrl: 'http://inv.test', accessToken: () => 't', client: client),
    rpc: RpcClient(baseUrl: 'http://inv.test', accessToken: () => 't', client: client),
    open: record ? (context, page, {itemId}) async => opened.add(itemId == null ? page : '$page:$itemId') : null,
    onOpenReceiving: (_) => opened.add('receiving'),
  );
  Map<String, dynamic> argsOf(String fn) => jsonDecode(requests.lastWhere((r) => fnOf(r) == fn).body) as Map<String, dynamic>;
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// A 390-point phone with the real fonts, so an overflow here is a real one.
Future<void> phone(WidgetTester t, Widget screen, {double height = 3200}) async {
  t.view.physicalSize = Size(780, height);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });
  tearDown(HomeNav.reset);

  group('Stock page', () {
    testWidgets('opens Stock Management with no tab strip; its jobs are small buttons', (t) async {
      final f = Fake();
      await phone(t, StockHomeScreen(env: f.env));
      expect(find.text('Stock Management'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && '${(w.key! as ValueKey<String>).value}'.startsWith('stock-tab-')), findsNothing);
      for (final b in ['Alerts', 'Adjust', 'Transfer', 'History', 'Count']) {
        expect(find.text(b), findsOneWidget, reason: b);
      }
    });

    testWidgets('in Item, the Stock part shows the part switcher, the number strip and the stock buttons', (t) async {
      final f = Fake(record: true);
      await phone(t, ItemParts(current: 'stock', select: (_) {}, child: StockHomeScreen(env: f.env)));
      expect(find.byKey(const ValueKey('item-part-purchase')), findsOneWidget);
      for (final s in ['Stock value', 'Low', 'Out', 'Expiring', 'Damaged']) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      for (final tool in ['alerts', 'adjust', 'transfer', 'movements', 'count']) {
        await t.tap(find.byKey(ValueKey('stock-tool-$tool')));
      }
      await t.tap(find.byKey(const ValueKey('stock-number-low')));
      expect(f.opened, ['alerts', 'adjust', 'transfer', 'movements', 'count', 'alerts']);
    });

    testWidgets('each stock page opens on top with a back arrow, from its button elsewhere', (t) async {
      final f = Fake();
      const titles = {
        StockPage.movements: 'Stock movements', StockPage.adjust: 'Adjust stock', StockPage.count: 'Count stock',
        StockPage.transfer: 'Transfer stock', StockPage.low: 'Low stock', StockPage.reorder: 'Reorder', StockPage.alerts: 'Alerts',
      };
      for (final MapEntry(key: page, value: title) in titles.entries) {
        await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => f.env.open(c, page), child: const Text('go')))), height: 5000);
        await t.tap(find.text('go'));
        await t.pumpAndSettle();
        expect(find.text(title), findsWidgets, reason: page);
        expect(find.byTooltip('Back'), findsOneWidget, reason: page);
        await t.tap(find.byTooltip('Back'));
        await t.pumpAndSettle();
        expect(find.text('go'), findsOneWidget, reason: page);
      }
    });

    testWidgets('Update stock fits a 390-point phone in both sections: no sideways table, nothing overflows', (t) async {
      final f = Fake();
      await phone(t, StockHomeScreen(env: f.env));
      expect(find.text('Coca-Cola 500ml'), findsOneWidget);
      expect(find.text('₹40'), findsOneWidget);
      expect(find.text('Cost ₹30'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal && w.child is! Row && w.child is! InvChips), findsNothing); // chip lines may scroll
      await t.tap(find.byKey(const ValueKey('section-availability')));
      await t.pumpAndSettle();
      expect(find.byType(Switch), findsNWidgets(4)); // Store and App for both products
      for (final it in _catalogue) {
        final row = t.getRect(find.byKey(ValueKey('switch-row-${it['id']}')));
        expect(row.width, lessThanOrEqualTo(390));
      }
    });

    testWidgets('Grid in both sections: two cards per row with the photo on top; tapping a card edits it; switches in Store & app', (t) async {
      final f = Fake();
      await phone(t, StockHomeScreen(env: f.env));
      await t.tap(find.byKey(const ValueKey('view-grid')));
      await t.pumpAndSettle();
      final a = t.getRect(find.byKey(const ValueKey('stock-card-m1'))), b = t.getRect(find.byKey(const ValueKey('stock-card-m2')));
      expect(a.top, b.top); // side by side
      expect(b.left, greaterThan(a.right));
      expect(find.descendant(of: find.byKey(const ValueKey('stock-card-m1')), matching: find.byType(AspectRatio)), findsOneWidget); // the photo
      expect(find.descendant(of: find.byKey(const ValueKey('stock-card-m1')), matching: find.text('₹40')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('stock-card-m1')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sheet-price')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sheet-done')));
      await t.pumpAndSettle();
      // the same grid in Store & app, with the two switches on each card
      await t.tap(find.byKey(const ValueKey('section-availability')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('switch-card-m1')), findsOneWidget);
      expect(t.widget<Switch>(find.byKey(const ValueKey('grid-shop-m1'))).value, isTrue);
      await t.tap(find.byKey(const ValueKey('grid-shop-m1')));
      await t.pumpAndSettle();
      expect(t.widget<Switch>(find.byKey(const ValueKey('grid-shop-m1'))).value, isFalse);
      expect(find.text('1 product changed · review before saving'), findsOneWidget);
      // back to the list
      await t.tap(find.byKey(const ValueKey('view-list')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('switch-row-m1')), findsOneWidget);
    });

  });

  group('A product (J.98)', () {
    testWidgets('a product opens the one Product page (it has its own tests in product_page_test.dart)', (t) async {
      final f = Fake();
      final id = (fx['stock_detail']['item'] as Map)['id'] as String;
      await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => f.env.open(c, StockPage.item, itemId: id), child: const Text('go')))), height: 4000);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byType(ProductPage), findsOneWidget);
    });
  });

  group('Alerts (J.106)', () {
    testWidgets('low stock, expiry, not selling and mismatch, each opening the tab that fixes it', (t) async {
      final f = Fake(record: true);
      await phone(t, StockAlertsScreen(env: f.env), height: 5000);
      for (final s in ['All', 'Low stock', 'Expiry', 'Not selling', 'Mismatch']) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      final cards = find.textContaining(' ›');
      expect(cards, findsWidgets);
      await t.tap(cards.first);
      expect(f.opened, isNotEmpty);
    });
  });

  group('Side menu', () {
    testWidgets('Stock and Purchase are not in the side menu any more: they are parts of Item', (t) async {
      await phone(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => showStoreSideNav(c, name: 'Riya', onReports: () {}, onSignOut: () {}), child: const Text('menu')))));
      await t.tap(find.text('menu'));
      await t.pumpAndSettle();
      for (final gone in ['Stock management', 'Purchase', 'Stock & Prices', 'Labels & Printing', 'Damage & Expiry']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.text('All Orders'), findsOneWidget);
    });
  });
}
